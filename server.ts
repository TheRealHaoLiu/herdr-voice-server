// herdr-voice: talk to herdr-core (hc) agent sessions from a phone page and hear what they choose to say.
// Speech is done on this Mac by the desktop app (HerdrVoice), for the phone page too: the server hands
// it each clip to transcribe and each reply to voice. No speech service is involved.
import { timingSafeEqual } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";

const ROOT = import.meta.dir;
const STATE = process.env.HERDR_VOICE_STATE ?? `${homedir()}/.local/state/herdr-voice`; // key, certificate, settings
const QDIR = process.env.HERDR_VOICE_DIR ?? "/tmp/herdr-voice"; // same path on every machine: command + queue
// Settings a person writes: ~/.config/herdr-voice/config.json (see config.example.json). Read fresh
// where a change should apply without a restart (the speech services); the rest is read at start.
const CONFIG_F = process.env.HERDR_VOICE_CONFIG ?? `${homedir()}/.config/herdr-voice/config.json`;
function config(): any { try { return JSON.parse(readFileSync(CONFIG_F, "utf8")); } catch { return {}; } }
// Where the server listens. Always on this computer's own loopback address, which nothing else on
// the network can reach: that is what the desktop app uses, and it is all there is in the default
// mode, "local". In the mode "network" (state file `mode`, set in the app's Setup or with
// `herdr-voice mode network`) it also listens on one address of this computer for phones: the one
// setup found and wrote to the state file `address`, which the certificate also names.
const LOOP = "127.0.0.1";
const readState = (name: string) => { try { return readFileSync(`${STATE}/${name}`, "utf8").trim(); } catch { return ""; } };
const MODE = (process.env.HERDR_VOICE_MODE ?? readState("mode")) === "network" ? "network" : "local";
const LAN = MODE === "network" ? (process.env.HERDR_VOICE_BIND ?? readState("address")) : "";
if (MODE === "network" && !/^\d{1,3}(\.\d{1,3}){3}$/.test(LAN)) { console.error(`Phones are switched on but no network address is recorded. Run: herdr-voice start  (it writes ${STATE}/address)`); process.exit(1); }
// The port is a setting: the file `port` in the state folder (written by `herdr-voice port <number>`),
// read by this server, the herdr-voice command and the desktop app. The certificate download is one above it.
function savedPort(): number {
  try { const n = Number(readFileSync(`${STATE}/port`, "utf8").trim()); if (Number.isInteger(n) && n >= 1024 && n <= 65534) return n; } catch {}
  return 8443;
}
const PORT = Number(process.env.HERDR_VOICE_PORT ?? savedPort());
// Source addresses allowed in (optional). With no `allow` setting every source may try, and the access
// key and HTTPS are the gate. Set `allow` in the config file to a regular expression to also refuse
// requests by where they come from, for example "^192\\.168\\.1\\.\\d+$" for one home network.
const ALLOW_SRC = process.env.HERDR_VOICE_ALLOW ?? (typeof config().allow === "string" ? config().allow.trim() : "");
const ALLOW = ALLOW_SRC ? new RegExp(ALLOW_SRC) : null;
const refusedAt = new Map<string, number>();
function allowed(ip: string): boolean {
  if (ip === LOOP || !ALLOW || ALLOW.test(ip)) return true; // this computer itself is always let in
  if (Date.now() - (refusedAt.get(ip) ?? 0) > 60000) { refusedAt.set(ip, Date.now()); console.log(`refused a request from ${ip || "an unknown address"}`); }
  return false;
}
const DEFAULT_VOICE = "am_echo";

const PSK = readFileSync(`${STATE}/psk`, "utf8").trim();
const SPEAK_SRC = readFileSync(`${ROOT}/bin/herdr-speak`, "utf8"); // placed on machines on first use
const SPEAK = `${QDIR}/herdr-speak`, QUEUE = `${QDIR}/outbox.tsv`;
mkdirSync(`${STATE}/claims`, { recursive: true });
mkdirSync(`${STATE}/tmp`, { recursive: true });

// The one prompt this app injects. Sent with a session's first voice message, and again only
// if that session ends a voice turn without speaking (for example after its context was compacted).
// The setting `instruction` in the config file replaces the wording. Write {speak} where the command
// belongs; if it is left out, a sentence naming the command is added, because without the command an
// agent cannot speak at all. Read at start: a change applies after a restart, and every session then
// gets the new wording once.
const DEFAULT_INSTRUCTION =
  `(Standing instruction, given once: messages starting with [voice] are spoken by the user from their phone. ` +
  `Reply on screen as usual and ALSO run this command with what you would say to them out loud, ` +
  `one or two short plain sentences: {speak} "<spoken words>" . ` +
  `For typed messages, speak only when they ask you to. ` +
  `When a [voice] request takes more than a couple of steps, also run it with one short line as you start each ` +
  `major step, so they can follow along while you work. ` +
  `When a [voice] message reaches you while you are in the middle of a task, first run it with a few words ` +
  `that acknowledge the message, then carry on. ` +
  `Never answer a [voice] message with a multiple-choice question tool or any other on-screen form: ` +
  `ask your question in plain words, on screen and with the command, and wait for the spoken answer.)`;
const INSTRUCTION = (() => {
  const own = typeof config().instruction === "string" ? config().instruction.trim().replace(/\s+/g, " ") : "";
  const text = own || DEFAULT_INSTRUCTION;
  return text.includes("{speak}") ? text.replaceAll("{speak}", SPEAK) : `${text} (To say something out loud, run: ${SPEAK} "<spoken words>" .)`;
})();

// This server speaks for the person, not for an agent. If it was started from inside an hc terminal (for
// example by an agent restarting the app), hc would stamp every message it types with that terminal
// as the sender (<hc from="t7 ...">), and the receiving agent would take the person's words for a peer
// session's. Without the identity, hc types the words bare, as if he had typed them.
// The environment is handed to every command explicitly: deleting the variable from process.env is
// not enough, Bun still passes the original on (found the hard way, 2026-11-18).
const CHILD_ENV: Record<string, string> = Object.fromEntries(Object.entries(process.env).filter(([k, v]) => k !== "HC_TERMINAL_ID" && v !== undefined)) as Record<string, string>;

async function run(argv: string[], stdin?: Uint8Array | string, timeoutMs = 30000) {
  const p = Bun.spawn(argv, { stdin: stdin === undefined ? "ignore" : "pipe", stdout: "pipe", stderr: "pipe", env: CHILD_ENV });
  if (stdin !== undefined) { p.stdin!.write(stdin); p.stdin!.end(); }
  const timer = setTimeout(() => p.kill(), timeoutMs);
  const [out, err, code] = await Promise.all([new Response(p.stdout).arrayBuffer(), new Response(p.stderr).text(), p.exited]);
  clearTimeout(timer);
  return { out: new Uint8Array(out), text: () => new TextDecoder().decode(out), err, code };
}

// ---- speech -------------------------------------------------------------------------------
// Compaction: take the ums out of spoken text before it is shown or typed into a session. Two rules,
// no model: drop the filler words um, uh, er, erm, ah, hmm; and collapse a word or short phrase said
// twice in a row to one copy. Left alone on purpose: "like", "you know", "right", "mm", anything joined
// by a hyphen ("uh-huh", "mm-hmm"), and numbers ("four four three" stays). If nothing would be left,
// the text is returned as it was. Switch it off with the word `off` in the state file `compact`.
const NUMBER = /^(\d+|zero|oh|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand)$/;
function compact(text: string): string {
  try { if (readFileSync(`${STATE}/compact`, "utf8").trim() === "off") return text; } catch {}
  // A filler that opened a sentence leaves the next word to take the capital letter.
  let t = text.replace(/(?<![\w'-])(um+|uh+|erm?|ah+|hmm+)(?![\w'-])[,.]?/gi, (_m, _f, at: number) => {
    const before = text.slice(0, at).trimEnd();
    return before === "" || /[.!?]$/.test(before) ? " \u0001" : " ";
  }).replace(/\u0001\s*(\p{L})/gu, (_m, c: string) => c.toUpperCase()).replace(/\u0001/g, "");
  const words = t.split(/\s+/).filter(Boolean);
  const norm = (w: string) => w.toLowerCase().replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, "");
  for (let n = 6; n >= 1; n--) {
    for (let i = 0; i + 2 * n <= words.length; ) {
      const gram = words.slice(i, i + n).map(norm);
      const same = gram.every((w, k) => w && !NUMBER.test(w) && w === norm(words[i + n + k]));
      if (same) words.splice(i, n); else i++; // keep the later copy: it carries the punctuation that follows
    }
  }
  t = words.join(" ").replace(/\s+([,.!?])/g, "$1").replace(/^[,.\s]+/, "").replace(/,\s*([.!?])/g, "$1").trim();
  if (!/[\p{L}\p{N}]/u.test(t)) return text.trim();
  return t[0].toUpperCase() + t.slice(1);
}

// An iPhone recording made in pieces can arrive with its header (the ftyp and moov boxes) after the
// first piece of sound instead of before it, which no decoder accepts ("no tfhd was found"). Seen
// 2026-11-18 on an iPhone. If the clip is a run of MP4 boxes that does not start with the header, move
// the header to the front and leave everything else in order.
function headerFirst(audio: Uint8Array): Uint8Array {
  const dv = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
  const type = (i: number) => String.fromCharCode(audio[i + 4], audio[i + 5], audio[i + 6], audio[i + 7]);
  if (audio.length < 16 || type(0) === "ftyp" || !["moof", "mdat", "styp"].includes(type(0))) return audio;
  const head: Uint8Array[] = [], rest: Uint8Array[] = [];
  let i = 0;
  while (i + 8 <= audio.length) {
    const n = dv.getUint32(i);
    if (n < 8 || i + n > audio.length) break;
    (type(i) === "ftyp" || type(i) === "moov" ? head : rest).push(audio.subarray(i, i + n));
    i += n;
  }
  if (!head.length) return audio;
  return Buffer.concat([...head, ...rest, audio.subarray(i)]);
}

const STT_FAILED = "Could not turn that into text. Speech runs in the HerdrVoice app on the Mac: it has to be open with its speech models loaded (see its Setup). Until then, type or dictate into the text box.";

// Speech jobs. The desktop app holds the speech models, so it does the work: it asks for the next job
// over this Mac's loopback address (long poll), does it, and posts the result. A job waits here until
// then. If the app has not asked for a while there is nobody to do it, and the job fails at once.
type Job = { id: string; kind: "stt" | "tts"; wav?: string; text?: string; voice?: string };
const jobs: Job[] = [];
const jobWaiters = new Set<() => void>();
const jobDone = new Map<string, { ok: (r: any) => void; fail: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
let workerSeen = 0; // when the app last asked for work
function speechJob(job: Omit<Job, "id">, ms: number): Promise<any> {
  if (Date.now() - workerSeen > 40000) return Promise.reject(new Error("the app is not doing speech right now"));
  const id = crypto.randomUUID();
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => { jobDone.delete(id); const i = jobs.findIndex(j => j.id === id); if (i >= 0) jobs.splice(i, 1); fail(new Error("speech took too long")); }, ms);
    jobDone.set(id, { ok, fail, timer });
    jobs.push({ id, ...job });
    for (const wake of jobWaiters) wake(); jobWaiters.clear();
  });
}
async function nextJob(waitSecs: number): Promise<Job | null> {
  workerSeen = Date.now();
  if (!jobs.length && waitSecs > 0)
    await new Promise<void>(res => { const t = setTimeout(res, Math.min(waitSecs, 30) * 1000); jobWaiters.add(() => { clearTimeout(t); res(); }); });
  workerSeen = Date.now();
  return jobs.shift() ?? null;
}
function finishJob(id: string, result: any): boolean {
  const w = jobDone.get(id); if (!w) return false;
  clearTimeout(w.timer); jobDone.delete(id); workerSeen = Date.now();
  if (typeof result?.error === "string" && result.error) w.fail(new Error(result.error)); else w.ok(result ?? {});
  return true;
}

async function stt(audio: Uint8Array): Promise<string> {
  audio = headerFirst(audio);
  const id = crypto.randomUUID();
  const src = `${STATE}/tmp/${id}.in`, wav = `${STATE}/tmp/${id}.wav`;
  writeFileSync(src, audio);
  try {
    const ff = await run(["ffmpeg", "-loglevel", "error", "-y", "-i", src, "-ar", "16000", "-ac", "1", wav]);
    if (ff.code !== 0) { try { writeFileSync(`${STATE}/tmp/last-unreadable-clip`, audio, { mode: 0o600 }); } catch {} // kept for diagnosis, overwritten each time
      console.log(`speech-to-text: could not read a ${audio.length}-byte clip: ${ff.err.trim().split("\n")[0].slice(0, 160)}`); throw new Error("could not decode the audio"); }
    const r = await speechJob({ kind: "stt", wav: Buffer.from(readFileSync(wav)).toString("base64") }, 20000);
    return compact(String(r.text ?? "").trim());
  } finally { rmSync(src, { force: true }); rmSync(wav, { force: true }); }
}

function voice(): string { // read per call so it can change without a restart
  try { const v = readFileSync(`${STATE}/voice`, "utf8").trim(); if (/^[a-z]{2}_[a-z0-9_]{2,30}$/.test(v)) return v; } catch {}
  return DEFAULT_VOICE;
}
async function tts(text: string): Promise<string | null> { // WAV, base64; null when the app cannot voice it right now
  try { const r = await speechJob({ kind: "tts", text, voice: voice() }, 30000); return typeof r.audio === "string" && r.audio.length > 200 ? r.audio : null; }
  catch { return null; } // the phone then falls back to its own built-in voice
}

// ---- sessions and their spoken queues -------------------------------------------------------
type Addr = { machine: string | null; tid: string; full: string };
function parseAddr(a: string): Addr | null {
  const m = /^(?:([A-Za-z0-9._-]{1,40})\/)?(t[0-9a-z]{1,8})$/.exec(a);
  return m ? { machine: m[1] ?? null, tid: m[2], full: a } : null;
}

let machineCache = { at: 0, names: new Set<string>() };
async function machines(): Promise<Set<string>> {
  if (Date.now() - machineCache.at < 30000) return machineCache.names;
  try {
    const j = JSON.parse((await run(["hc", "machine", "ls", "--json"])).text());
    machineCache = { at: Date.now(), names: new Set((j.machines as any[]).filter(m => m.state === "connected").map(m => String(m.name))) };
  } catch {}
  return machineCache.names;
}

// Make sure the herdr-speak command exists where the session runs. Pushed out over the existing hc line.
async function ensureSpeak(machine: string | null) {
  if (!machine) {
    if (existsSync(SPEAK) && readFileSync(SPEAK, "utf8") === SPEAK_SRC) return;
    mkdirSync(QDIR, { recursive: true, mode: 0o700 });
    writeFileSync(SPEAK, SPEAK_SRC); chmodSync(SPEAK, 0o755);
    return;
  }
  if ((await run(["hc", "exec", "--on", machine, "--", "test", "-x", SPEAK])).code === 0) return;
  await run(["hc", "exec", "--on", machine, "--", "mkdir", "-p", "-m", "700", QDIR]);
  const w = await run(["hc", "file", "write", "--on", machine, SPEAK], SPEAK_SRC);
  if (w.code !== 0) throw new Error(`could not place herdr-speak on ${machine}`);
  await run(["hc", "exec", "--on", machine, "--", "chmod", "+x", SPEAK]);
  console.log(`placed herdr-speak on ${machine}`);
}

async function queueRows(a: Addr, after: number): Promise<string[]> { // rows after line number `after`
  if (!a.machine) return existsSync(QUEUE) ? readFileSync(QUEUE, "utf8").split("\n").filter(Boolean).slice(after) : [];
  const r = await run(["hc", "exec", "--on", a.machine, "--", "sh", "-c", `[ -f ${QUEUE} ] && tail -n +${after + 1} ${QUEUE}`]);
  return r.text().split("\n").filter(Boolean);
}
const queueLen = async (a: Addr) => (await queueRows(a, 0)).length;

async function sessions() {
  const j = JSON.parse((await run(["hc", "ls", "--json"])).text());
  const picked = (j.terminals as any[]).filter(t => t.state === "live" && t.agent && t.status !== undefined && parseAddr(t.address));
  const rows = await Promise.all(picked.map(async t => {
    let g: any = {}; try { g = JSON.parse((await run(["hc", "get", "--json", t.address], undefined, 8000)).text()); } catch {}
    const title = typeof g.title === "string" && !/^(claude code|claude|zsh|bash)?$/i.test(g.title.trim()) ? g.title.trim() : null;
    const st = typeof g.status === "object" && g.status ? g.status.state : (t.status ?? null);
    return { address: t.address, machine: parseAddr(t.address)!.machine ?? "This machine", name: t.name ?? null, title, status: st,
      folder: String(t.cwd ?? "").split("/").filter(Boolean).pop() ?? "", active_ms: g.status_ms ?? g.created_ms ?? 0 };
  }));
  return rows.sort((x, y) => y.active_ms - x.active_ms);
}
// What the session wrote since your last message: the text after the last `[voice]` line on its
// screen. When no such line is found (a slash command, or it scrolled too far back) it is the end of
// the screen as before. Either way at most the last 45 lines that are not empty.
function sinceLastTurn(text: string): string {
  const lines = text.split("\n").map(l => l.replace(/\s+$/, ""));
  let at = -1;
  for (let i = lines.length - 1; i >= 0; i--) if (/^\s*\S{0,2}\s*\[voice\] /.test(lines[i])) { at = i; break; }
  const rules = lines.map((l, i) => /^[─━-]{20,}$/.test(l) ? i : -1).filter(i => i >= 0); // an input box drawn at the bottom is not something it wrote
  if (rules.length >= 2 && lines.length - rules[rules.length - 2] <= 12 && rules[rules.length - 2] > at) lines.length = rules[rules.length - 2];
  for (let i = Math.max(at + 1, lines.length - 12); i < lines.length; i++) // opencode's input box: bare bars down to a heavy rule
    if (/^\s*┃\s*$/.test(lines[i]) && lines.slice(i).some(l => /^\s*╹?▀{20,}/.test(l)) && lines.slice(i).every(l => !l.length || /^\s*[┃╹\/]/.test(l))) { lines.length = i; break; }
  let rest = lines;
  if (at >= 0) { let j = at + 1; while (j < lines.length && lines[j].length) j++; rest = lines.slice(j); } // the message can wrap over several lines; it ends at the first empty one
  rest = rest.filter(l => l.length);
  return (rest.length ? rest : lines.filter(l => l.length)).slice(-45).join("\n");
}
async function screen(a: Addr): Promise<string> {
  const r = await run(["hc", "read", "--lines", "300", a.full]);
  return sinceLastTurn(r.text());
}
async function status(a: Addr): Promise<string> {
  try { const s = JSON.parse((await run(["hc", "get", "--json", a.full])).text()).status; return typeof s === "string" ? s : s?.state ?? "unknown"; }
  catch { return "unknown"; }
}

// ---- history: what was said, both ways -------------------------------------------------------
// One line per message in the state file `history.jsonl` (readable by the owner only): what you said,
// what an agent said out loud, and each permission answer. The phone page shows the recent ones for a
// session when it opens, so a reload does not empty the conversation. It never leaves this Mac.
// Kept to the newest 3000 lines, trimmed when the server starts. Switch it off with the word `off`
// in the state file `history`.
type Said = { at: number; t: string; who: "me" | "agent" | "note"; text: string; from?: string };
const HISTORY_F = `${STATE}/history.jsonl`;
const historyOn = () => readState("history") !== "off";
function remember(t: string, who: Said["who"], text: string, from?: string) {
  text = text.trim(); if (!text || !historyOn()) return;
  try { appendFileSync(HISTORY_F, JSON.stringify({ at: Date.now(), t, who, text: text.slice(0, 4000), ...(from ? { from } : {}) }) + "\n", { mode: 0o600 }); } catch {}
}
function historyOf(t: string, limit: number): Said[] {
  if (!historyOn()) return [];
  let rows: Said[] = [];
  try { rows = readFileSync(HISTORY_F, "utf8").split("\n").filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter((r): r is Said => !!r && r.t === t); } catch {}
  return rows.slice(-Math.max(1, Math.min(limit || 60, 300)));
}
try { const all = readFileSync(HISTORY_F, "utf8").split("\n").filter(Boolean); if (all.length > 3600) writeFileSync(HISTORY_F, all.slice(-3000).join("\n") + "\n", { mode: 0o600 }); } catch {}

// ---- announcements: an agent speaking when nobody just asked it -----------------------------
// Any herdr-speak line that is not the answer to a turn in progress becomes an announcement. It is
// voiced with the session's name first ("From <session>, on <machine>. ..."), because several
// sessions may be running, and handed to whichever clients have announcements switched on.
// kind "progress" is narration during a turn: it goes only to the device that asked (target), with no
// "From ..." prefix, and is played as it arrives instead of being held until the turn ends.
type Announcement = { id: number; kind: "announcement" | "progress"; address: string; from: string; text: string; target?: string; audio?: string | null };
const EPOCH = Date.now(); // lets clients notice a restarted server, whose ids start again from zero
const turnClient = new Map<string, string>(); // session -> the device that asked the turn in progress
const streamed = new Set<string>(); // "<machine>:<line number>" already played as narration
const announcements: Announcement[] = [];
let announceSeq = 0;
const announceWaiters = new Set<() => void>();
const consumed = new Set<string>(); // "<machine>:<line number>" of lines a turn already delivered
const labels = new Map<string, { at: number; label: string }>();
async function labelOf(a: Addr): Promise<string> {
  const hit = labels.get(a.full);
  if (hit && Date.now() - hit.at < 60000) return hit.label;
  let label = a.tid;
  try {
    const g = JSON.parse((await run(["hc", "get", "--json", a.full], undefined, 8000)).text());
    const title = typeof g.title === "string" && !/^(claude code|claude|zsh|bash)?$/i.test(g.title.trim()) ? g.title.trim() : "";
    label = g.name || title || String(g.cwd ?? "").split("/").filter(Boolean).pop() || a.tid;
  } catch {}
  labels.set(a.full, { at: Date.now(), label });
  return label;
}
async function announce(a: Addr, text: string) {
  if (!text.trim()) return;
  const who = await labelOf(a);
  push({ id: ++announceSeq, kind: "announcement", address: a.full, from: a.machine ? `${who}, on ${a.machine}` : who, text: text.trim() });
  remember(a.full, "agent", text, a.machine ? `${who}, on ${a.machine}` : who);
  console.log(`announcement from ${a.full}`);
}
function push(x: Announcement) {
  announcements.push(x);
  if (announcements.length > 80) announcements.shift();
  if (consumed.size > 5000) consumed.clear();
  if (streamed.size > 5000) streamed.clear();
  for (const wake of announceWaiters) wake();
  announceWaiters.clear();
}
// Which device should say an announcement aloud: the one you last talked through, as long as it is
// still listening. If that one has gone (page closed, app quit), every listening device says it.
// The others still receive the text, marked play:false, so they can show it silently.
// The device is remembered across a restart (state file `last-device`). For the first minute after a
// start it is taken to be listening even before it has reconnected, so the first announcement does not
// go to every device just because the server is new.
const LAST_F = `${STATE}/last-device`;
let lastTalkedThrough: string | null = (() => { try { return readFileSync(LAST_F, "utf8").trim().slice(0, 64) || null; } catch { return null; } })();
const remembered = lastTalkedThrough;
function talkedThrough(c: string) { if (c === lastTalkedThrough) return; lastTalkedThrough = c; try { writeFileSync(LAST_F, c, { mode: 0o600 }); } catch {} }
const listening = new Map<string, number>(); // client id -> last time it asked for announcements
const isListening = (c: string) => Date.now() - (listening.get(c) ?? 0) < 40000 || (c === remembered && Date.now() - EPOCH < 60000);
async function announcementsAfter(after: number, waitSecs: number, client: string, wantAudio = true) {
  listening.set(client, Date.now());
  if (after < 0) return { items: [], last: announceSeq, epoch: EPOCH }; // a new client starts from now, with no backlog
  const forMe = (x: Announcement) => x.id > after && (!x.target || x.target === client);
  if (!announcements.some(forMe) && waitSecs > 0)
    await new Promise<void>(res => { const t = setTimeout(res, Math.min(waitSecs, 30) * 1000); announceWaiters.add(() => { clearTimeout(t); res(); }); });
  listening.set(client, Date.now());
  const mine = !lastTalkedThrough || !isListening(lastTalkedThrough) || lastTalkedThrough === client;
  const items = [];
  for (const x of announcements.filter(forMe)) {
    const play = x.kind === "progress" || mine;
    if (play && wantAudio && x.audio === undefined) x.audio = await tts(x.kind === "progress" ? x.text : `From ${x.from}. ${x.text}`);
    items.push({ id: x.id, kind: x.kind, address: x.address, from: x.from, text: x.text, play, audio: play && wantAudio ? x.audio ?? null : null });
  }
  return { items, last: announceSeq, epoch: EPOCH };
}

// Watch every machine's queue. Lines that belong to a turn in progress are left to that turn.
const watched = new Map<string, number>(); // machine ("" = this one) -> lines already looked at
async function watchQueue(machine: string | null) {
  const key = machine ?? "";
  let all: string[];
  if (!machine) all = existsSync(QUEUE) ? readFileSync(QUEUE, "utf8").split("\n").filter(Boolean) : [];
  else {
    const r = await run(["hc", "exec", "--on", machine, "--", "sh", "-c", `[ -f ${QUEUE} ] && cat ${QUEUE}`], undefined, 15000);
    if (r.code !== 0) return;
    all = r.text().split("\n").filter(Boolean);
  }
  const seen = watched.get(key);
  if (seen === undefined || all.length < seen) { watched.set(key, all.length); return; } // first look, or the queue was reset
  watched.set(key, all.length);
  all.slice(seen).forEach((row, i) => {
    const [tid, ...rest] = row.split("\t");
    const a = parseAddr(machine ? `${machine}/${tid}` : tid);
    if (!a || consumed.delete(`${key}:${seen + i}`)) return;
    if (busy.has(a.full)) { // mid-turn: narrate it now to the device that asked, if that device is listening
      const who = turnClient.get(a.full);
      if (who && isListening(who) && rest.join(" ").trim()) {
        streamed.add(`${key}:${seen + i}`);
        push({ id: ++announceSeq, kind: "progress", address: a.full, from: "", text: rest.join(" ").trim(), target: who });
        remember(a.full, "agent", rest.join(" "));
      }
      return; // otherwise the end of the turn delivers it
    }
    void announce(a, rest.join(" "));
  });
}
setInterval(() => void watchQueue(null).catch(() => {}), 1000);
let remoteWatchRunning = false;
let remoteTick = 0;
setInterval(async () => { // every machine each 4.5s; a machine with a turn in progress each 1.5s, for narration
  if (remoteWatchRunning) return; remoteWatchRunning = true;
  try {
    const everyone = remoteTick++ % 3 === 0;
    const active = new Set([...busy].map(b => parseAddr(b)?.machine).filter(Boolean) as string[]);
    for (const m of await machines()) if (everyone || active.has(m)) await watchQueue(m).catch(() => {});
  } finally { remoteWatchRunning = false; }
}, 1500);

// ---- one voice turn -------------------------------------------------------------------------
// Sessions that already have the instruction. The file name carries a fingerprint of the instruction
// text, so when the wording changes every session is given the new one once.
const PRIMED_F = `${STATE}/primed-${Bun.hash(INSTRUCTION).toString(16).slice(0, 8)}.json`;
const primed = new Set<string>((() => { try { return JSON.parse(readFileSync(PRIMED_F, "utf8")); } catch { return []; } })());
const cursor = new Map<string, number>(); // per-session line position in its machine's queue
// A voice task spans several requests: the first turn, then one collect after another while the agent
// is still working. `busy` and `turnClient` last for the whole task, so narration keeps reaching the
// device that asked and lines spoken between two requests are not mistaken for announcements.
// `inflight` marks a request being served right now.
const busy = new Set<string>();
const inflight = new Set<string>();
const lingering = new Map<string, ReturnType<typeof setTimeout>>(); // task still working, waiting for the next collect
const TURN_WAIT = Number(process.env.HERDR_VOICE_TURN_WAIT ?? 150); // seconds the first request waits before handing over to collect
const LINGER_MS = Number(process.env.HERDR_VOICE_LINGER_MS ?? 30000);
function endTask(full: string) { busy.delete(full); turnClient.delete(full); clearTimeout(lingering.get(full)); lingering.delete(full); }
const claim = (a: Addr) => `${STATE}/claims/${a.full.replace("/", "_")}`; // tells a local herdr-speakd to stay quiet

// wantAudio=false is for a client that does its own text-to-speech (the desktop app with local speech).
async function collect(a: Addr, wantAudio = true) {
  const st = await status(a);
  const from = cursor.get(a.full) ?? (await queueLen(a));
  const rows = await queueRows(a, from);
  cursor.set(a.full, from + rows.length);
  const mk = a.machine ?? "";
  let narrated = false;
  const fresh: string[] = [];
  rows.forEach((l, i) => {
    const c = l.split("\t"); if (c[0] !== a.tid) return;
    if (streamed.delete(`${mk}:${from + i}`)) { narrated = true; return; } // already played as narration
    consumed.add(`${mk}:${from + i}`); fresh.push(c.slice(1).join(" "));     // answered here, so not an announcement
  });
  const spoken = fresh.join(" ").trim();
  remember(a.full, "agent", spoken);
  if (st !== "working") rmSync(claim(a), { force: true });
  return { status: st, spoken, narrated, audio: spoken && wantAudio ? await tts(spoken) : null, screen: await screen(a) };
}

// A session that stops at a permission prompt mid-task has not finished. Say so instead of letting the
// client report "finished without saying anything".
// herdr-core says what kind of stop it is (permission, question, auth) and, for a permission prompt,
// what is being asked ("approve Bash: <command>"). That is passed on as `ask`, with speech, and
// `ask.can` says whether it can be answered from here (see answer()). `error` carries the same words
// for a client that does not know `ask`.
async function detail(a: Addr): Promise<{ state: string; kind: string; msg: string; app: string }> {
  let s: any = null; try { s = JSON.parse((await run(["hc", "get", "--json", a.full])).text()).status; } catch {}
  const o = s && typeof s === "object" ? s : {};
  return { state: typeof s === "string" ? s : String(o.state ?? "unknown"), kind: String(o.kind ?? ""), msg: String(o.msg ?? ""), app: String(o.app ?? "") };
}
// The keys that answer a permission prompt, per agent program. Only programs listed here can be
// answered from the phone. Codex: "Yes, proceed (y)" and Esc to cancel. opencode shows
// "Allow once / Always allow / Reject" with the first one selected: Enter allows once, and two steps
// right then Enter rejects.
const ANSWER_KEYS: Record<string, { allow: string[]; deny: string[] }> = {
  "claude-code": { allow: ["1"], deny: ["esc"] },
  "codex": { allow: ["y"], deny: ["esc"] },
  "opencode": { allow: ["enter"], deny: ["right", "right", "enter"] },
};
// What is being asked. herdr-core gives it for Claude Code; for Codex and opencode it is read off
// the prompt on screen (the line that starts with "$"), with herdr-core's words as the fallback.
async function asked(a: Addr, d: { msg: string; app: string }): Promise<string> {
  if (d.app !== "codex" && d.app !== "opencode") return requestOf(d.msg);
  try { const m = (await run(["hc", "read", "--lines", "0", a.full])).text().split("\n").map(l => l.match(/^\s*┃?\s*\$ (.+?)\s*$/)?.[1]).filter(Boolean); return requestOf(m[m.length - 1] ?? d.msg); }
  catch { return requestOf(d.msg); }
}
const requestOf = (msg: string) => msg.replace(/^approve\s+/i, "").replace(/\s+/g, " ").trim().slice(0, 400);
async function blockedNote(a: Addr, res: { status: string; spoken: string }, wantAudio = true) {
  if (res.status !== "blocked") return {};
  const d = await detail(a);
  if (d.state !== "blocked") return {}; // answered in the meantime
  const what = await asked(a, d);
  const permission = d.kind === "permission";
  const text = permission ? (what ? `It is asking for permission: ${what}` : "It is asking for permission.") : "It has stopped to ask you something. Answer it in Herdr.";
  const can = permission && d.app in ANSWER_KEYS;
  const say = permission ? "It is asking for your permission." : text; // the request itself is shown, not read out: commands are tiresome to listen to
  return { blocked: true, ...(res.spoken ? {} : { error: can ? text : `${text}${permission ? " Answer it in Herdr." : ""}` }),
           ask: { text, what, can, audio: wantAudio ? await tts(say) : null, say } };
}
// Answer a permission prompt from the phone: Allow presses the prompt's "Yes" (key 1), Deny presses
// Esc. Claude Code, Codex and opencode only (see ANSWER_KEYS): other agent programs' prompts take other keys. The client sends back the
// request it was shown; if the prompt on screen is a different one by now, nothing is pressed and
// the new request is returned instead, so nobody approves something they have not seen.
async function answer(a: Addr, choice: string, shown: string, wantAudio = true) {
  if (choice !== "allow" && choice !== "deny") return { answered: false, error: "Say allow or deny." };
  const d = await detail(a);
  if (d.state !== "blocked" || d.kind !== "permission") return { answered: false, error: "That session is not waiting for permission any more." };
  const keys = ANSWER_KEYS[d.app];
  if (!keys) return { answered: false, error: "Answering from here is only known to work for Claude Code, Codex and opencode sessions. Answer it in Herdr." };
  if ((await asked(a, d)) !== shown) return { answered: false, changed: true, ...(await blockedNote(a, { status: "blocked", spoken: "" }, wantAudio)) };
  const k = await run(["hc", "keys", "--json", a.full, ...(choice === "allow" ? keys.allow : keys.deny)]);
  if (k.code !== 0) return { answered: false, error: "Could not press the key in that session." };
  console.log(`permission ${choice === "allow" ? "allowed" : "denied"} for ${a.full}: ${shown.slice(0, 120)}`);
  remember(a.full, "note", `${choice === "allow" ? "Allowed" : "Denied"}: ${shown}`);
  await Bun.sleep(700);
  return { answered: true, choice, status: await status(a) };
}

// spokenText: the words came from speech the client had transcribed first (/api/hear), so a leading
// slash is not a typed slash command.
async function turn(a: Addr, audio: Uint8Array | null, typed = "", wantAudio = true, spokenText = false) {
  let heard = typed.trim().slice(0, 4000);
  if (spokenText) heard = compact(heard); // words a client transcribed itself (the desktop app, or the page's /api/hear)
  if (audio) {
    try { heard = await stt(audio); }
    catch { return { heard: "", error: STT_FAILED }; }
  }
  if (!heard) return { heard: "", error: "I didn't catch anything." };
  if (!audio && !spokenText && /^\/[a-z][\w:-]*( |$)/i.test(heard)) return command(a, heard);
  // Already stopped at a prompt: nothing can be typed into it. Hand the pending request back so it
  // can be answered, and say that these words were not delivered.
  if ((await status(a)) === "blocked")
    return { heard, status: "blocked", spoken: "", ...(await blockedNote(a, { status: "blocked", spoken: "" }, wantAudio)),
             note: "Your message was not sent: the session is waiting for an answer first." };
  await ensureSpeak(a.machine);
  cursor.set(a.full, await queueLen(a));
  writeFileSync(claim(a), "");
  const msg = primed.has(a.full) ? `[voice] ${heard}` : `[voice] ${heard}  ${INSTRUCTION}`;
  remember(a.full, "me", heard);
  const s = await run(["hc", "send", "--wait", "--timeout", String(TURN_WAIT), "--json", a.full, msg], undefined, (TURN_WAIT + 20) * 1000);
  let sent: any = {}; try { sent = JSON.parse(s.text()); } catch {}
  const res = await collect(a, wantAudio);
  // Narration counts as having spoken. A turn waiting on a permission prompt says nothing for that
  // reason, not because the session forgot the instruction.
  if (res.spoken || res.narrated) primed.add(a.full); else if (res.status !== "working" && res.status !== "blocked") primed.delete(a.full);
  try { writeFileSync(PRIMED_F, JSON.stringify([...primed])); } catch {}
  return { heard, ...res, ...(await blockedNote(a, res, wantAudio)), note: s.code !== 0 ? (sent.error ?? s.err.trim().slice(0, 200)) : undefined };
}

// A typed slash command (/compact, /clear, /model ...) is typed into the session key by key, exactly
// as written: no [voice] tag, no instruction, nothing spoken back. `hc send` cannot be used here because
// it wraps text in an <hc> tag, which stops the session recognising a slash command. The session may
// forget the instruction afterwards (/clear, /compact), so it is marked to receive it again.
async function command(a: Addr, text: string) {
  if (!/^\/[A-Za-z][\w:-]*( [\w .:@=,+\/-]*)?$/.test(text) || text.length > 200)
    return { heard: text, command: true, error: "That slash command has characters I can't type safely." };
  if ((await status(a)) === "working") return { heard: text, command: true, error: "That session is busy. Try the command when it has finished." };
  const keys = [...text].map(c => (c === " " ? "space" : c));
  const typed = await run(["hc", "keys", "--json", a.full, ...keys]);
  if (typed.code !== 0) return { heard: text, command: true, error: "Could not type into that session." };
  remember(a.full, "me", text);
  await Bun.sleep(300);
  await run(["hc", "keys", "--json", a.full, "enter"]);
  await run(["hc", "wait", "--timeout", "30", a.full], undefined, 40000);
  primed.delete(a.full);
  try { writeFileSync(PRIMED_F, JSON.stringify([...primed])); } catch {}
  return { heard: text, command: true, status: await status(a), spoken: "", audio: null, screen: await screen(a) };
}

// Interrupting. Steer: a message sent while the session is mid-turn is typed into the running task
// (the agent picks it up at its next step); the turn already in progress still delivers the speech.
// Stop: herdr-core's interrupt, which presses the agent's stop key.
async function steer(a: Addr, audio: Uint8Array | null, typed: string, client: string, spokenText = false) {
  let heard = typed.trim().slice(0, 4000);
  if (spokenText) heard = compact(heard);
  if (audio) { try { heard = await stt(audio); } catch { return { heard: "", error: STT_FAILED }; } }
  if (!heard) return { heard: "", error: "I didn't catch anything." };
  const s = await run(["hc", "send", "--json", a.full, primed.has(a.full) ? `[voice] ${heard}` : `[voice] ${heard}  ${INSTRUCTION}`], undefined, 70000);
  if (s.code !== 0) return { heard, error: "Could not reach that session to steer it." };
  turnClient.set(a.full, client); talkedThrough(client); // narration now follows the device that steered
  remember(a.full, "me", heard);
  return { heard, steered: true, status: "working" };
}
// Send now: a steering message waits in the agent's own queue until its current step ends. Claude Code
// has a key for "send the queued message now" (ctrl+enter): the message is read at once and a command
// that was running is moved to the background, not killed (seen 2026-11-18, Claude Code 2.1.327).
// Other agent programs are refused, because what that key does there is not known.
async function sendNow(a: Addr) {
  let st: any = null; try { st = JSON.parse((await run(["hc", "get", "--json", a.full])).text()).status; } catch {}
  if (st?.app !== "claude-code") return { sent: false, error: "Send now is only known to work for Claude Code sessions." };
  if (st?.state !== "working") return { sent: false, error: "That session is not in the middle of a step, so nothing is waiting." };
  const k = await run(["hc", "keys", "--json", a.full, "ctrl+enter"]);
  return k.code === 0 ? { sent: true } : { sent: false, error: "Could not press the send-now key in that session." };
}
async function stopTask(a: Addr) {
  // One press of the stop key is not always enough: with vim-style input the first press only leaves
  // insert mode. Press until herdr-core reports the turn stopped, a few times at most.
  let outcome = "";
  for (let i = 0; i < 5 && outcome !== "stopped"; i++) {
    if (i) await Bun.sleep(600);
    if ((await status(a)) !== "working") { outcome = "stopped"; break; }
    try { outcome = JSON.parse((await run(["hc", "interrupt", "--json", a.full], undefined, 20000)).text()).outcome ?? ""; } catch { outcome = ""; }
  }
  return { stopped: outcome === "stopped", status: await status(a) };
}

// ---- http -----------------------------------------------------------------------------------
const ipOf = (req: Request, server: any) => String(server.requestIP(req)?.address ?? "").replace(/^::ffff:/, "");
function authed(req: Request) {
  const k = Buffer.from(req.headers.get("x-voice-key") ?? ""), p = Buffer.from(PSK);
  return k.length === p.length && timingSafeEqual(k, p);
}
// Pairing: the desktop app shows a QR code holding a one-time code (2 minutes, single use). The phone
// page trades it for the access key, so the long-lived key itself is never put on screen.
const pairCodes = new Map<string, number>();
let pairMisses = 0;
function newPairCode() {
  for (const [c, exp] of pairCodes) if (exp < Date.now()) pairCodes.delete(c);
  const code = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64url");
  pairCodes.set(code, Date.now() + 120000);
  return { code, expires_in: 120, url: `https://${LAN}:${PORT}/#pair=${code}`, cert_url: `http://${LAN}:${PORT + 1}/ca.crt` };
}
function redeemPairCode(code: string): string | null {
  const exp = pairCodes.get(code);
  if (!exp || exp < Date.now()) { if (++pairMisses >= 5) { pairCodes.clear(); pairMisses = 0; } return null; } // repeated wrong guesses void every code
  pairCodes.delete(code); pairMisses = 0;
  return PSK;
}
const json = (o: unknown, code = 200) => new Response(JSON.stringify(o), { status: code, headers: { "content-type": "application/json", "cache-control": "no-store" } });

const listen = (hostname: string) => Bun.serve({
  hostname, port: PORT, idleTimeout: 255, maxRequestBodySize: 12 * 1024 * 1024,
  tls: { cert: Bun.file(`${STATE}/tls/leaf.crt`), key: Bun.file(`${STATE}/tls/leaf.key`) },
  async fetch(req, server) {
    if (!allowed(ipOf(req, server))) return new Response("forbidden", { status: 403 });
    const u = new URL(req.url);
    if (req.method === "GET" && u.pathname === "/")
      return new Response(Bun.file(`${ROOT}/index.html`), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
    if (!u.pathname.startsWith("/api/")) return new Response("not found", { status: 404 });
    if (req.method === "POST" && u.pathname === "/api/pair") {
      let code = ""; try { code = String((await req.json()).code ?? ""); } catch {}
      const key = redeemPairCode(code);
      return key ? json({ key }) : json({ error: "That code has expired or was already used. Show a new one in the app." }, 403);
    }
    if (!authed(req)) return json({ error: "bad key" }, 401);
    const clientId = (req.headers.get("x-voice-client") ?? "").slice(0, 64) || "unknown";
    if (u.pathname.startsWith("/api/speech/")) { // the app taking and returning speech jobs: this Mac only
      if (ipOf(req, server) !== LOOP) return json({ error: "only from this Mac" }, 403);
      if (req.method === "GET" && u.pathname === "/api/speech/next") return json({ job: await nextJob(Number(u.searchParams.get("wait") ?? 0)) });
      if (req.method === "POST" && u.pathname === "/api/speech/done") { let b: any = {}; try { b = await req.json(); } catch {} return json({ ok: finishJob(String(b.id ?? ""), b) }); }
      return json({ error: "not found" }, 404);
    }
    const wantAudio = u.searchParams.get("audio") !== "0";
    try {
      if (req.method === "POST" && u.pathname === "/api/pair-code")
        return MODE === "network" ? json(newPairCode()) : json({ error: "Phones are switched off: the server only listens on this Mac. Switch on phones in Setup first." }, 409);
      if (req.method === "GET" && u.pathname === "/api/sessions") return json({ sessions: await sessions() });
      if (req.method === "GET" && u.pathname === "/api/announcements")
        return json(await announcementsAfter(Number(u.searchParams.get("after") ?? -1), Number(u.searchParams.get("wait") ?? 0), clientId, wantAudio));
      // Speech to text by itself, so a client can show what was heard before the agent has answered.
      // The client then sends the words with /api/say?spoken=1.
      if (req.method === "POST" && u.pathname === "/api/hear") {
        try { const heard = await stt(new Uint8Array(await req.arrayBuffer())); return json(heard ? { heard } : { heard: "", error: "I didn't catch anything." }); }
        catch { return json({ heard: "", error: STT_FAILED }); }
      }
      const a = parseAddr(u.searchParams.get("t") ?? "");
      if (!a || (a.machine && !(await machines()).has(a.machine))) return json({ error: "unknown session" }, 400);
      if (req.method === "GET" && u.pathname === "/api/screen") { // also says what a stopped session is waiting for, so a page that was reloaded can show it again
        const st = await status(a);
        return json({ status: st, screen: await screen(a), ...(st === "blocked" ? await blockedNote(a, { status: "blocked", spoken: "" }, false) : {}) });
      }
      if (req.method === "GET" && u.pathname === "/api/history") return json({ items: historyOf(a.full, Number(u.searchParams.get("limit") ?? 60)) });
      if (req.method === "POST" && u.pathname === "/api/stop") return json(await stopTask(a));
      if (req.method === "POST" && u.pathname === "/api/now") return json(await sendNow(a));
      if (req.method === "POST" && u.pathname === "/api/answer") {
        let shown = ""; try { shown = String((await req.json()).what ?? ""); } catch {}
        // Allowing lets the task go on, and its first spoken line can land before the client's next
        // collect arrives. Count the task as in progress from the moment of the answer, so that line is
        // the reply (or narration for this device) and not, as well, an announcement.
        const allow = u.searchParams.get("choice") === "allow", was = busy.has(a.full);
        if (allow && !was) { busy.add(a.full); if (!turnClient.has(a.full)) turnClient.set(a.full, clientId); }
        const r: any = await answer(a, u.searchParams.get("choice") ?? "", shown, wantAudio);
        if (allow && !was) {
          if (r.answered && !inflight.has(a.full)) { clearTimeout(lingering.get(a.full)); lingering.set(a.full, setTimeout(() => endTask(a.full), LINGER_MS)); }
          else if (!r.answered) endTask(a.full);
        }
        return json(r);
      }
      const isTurn = req.method === "POST" && (u.pathname === "/api/turn" || u.pathname === "/api/say");
      const isCollect = req.method === "POST" && u.pathname === "/api/collect";
      if (!isTurn && !isCollect) return json({ error: "not found" }, 404);
      if (isTurn && busy.has(a.full)) { // mid-task: a new message steers the running task instead of being refused
        if (u.pathname === "/api/turn") return json(await steer(a, new Uint8Array(await req.arrayBuffer()), "", clientId));
        return json(await steer(a, null, String((await req.json()).text ?? ""), clientId, u.searchParams.get("spoken") === "1"));
      }
      if (inflight.has(a.full)) return json({ error: "A turn is already running for that session." }, 409);
      clearTimeout(lingering.get(a.full)); lingering.delete(a.full);
      busy.add(a.full); inflight.add(a.full);
      // If the page or app that asked goes away mid-turn, release the claim so a local herdr-speakd
      // speaks the reply instead of it being lost.
      req.signal.addEventListener("abort", () => rmSync(claim(a), { force: true }));
      let res: any;
      try {
        if (isTurn) {
          talkedThrough(clientId); turnClient.set(a.full, clientId);
          res = u.pathname === "/api/turn" ? await turn(a, new Uint8Array(await req.arrayBuffer()), "", wantAudio)
                                           : await turn(a, null, String((await req.json()).text ?? ""), wantAudio, u.searchParams.get("spoken") === "1");
          if (req.signal.aborted && res.spoken) void announce(a, res.spoken); // the asker went away: don't lose the reply
        } else {
          if (!turnClient.has(a.full)) turnClient.set(a.full, clientId);
          await run(["hc", "wait", "--timeout", "120", a.full], undefined, 130000);
          res = await collect(a, wantAudio);
          res = { ...res, ...(await blockedNote(a, res, wantAudio)) };
        }
        return json(res);
      } finally {
        inflight.delete(a.full);
        // Still working and the asker is still there: the task goes on, and the next collect is expected
        // shortly. If none comes, the task is let go so later lines become announcements.
        if (res?.status === "working" && !req.signal.aborted) lingering.set(a.full, setTimeout(() => endTask(a.full), LINGER_MS));
        else endTask(a.full);
      }
    } catch (e: any) { return json({ error: String(e?.message ?? e).slice(0, 300) }, 500); }
  },
});
listen(LOOP);

// Phones (mode "network" only): the same server on the network address, plus a plain-HTTP side door
// serving ONLY the public CA certificate, for the one-time install on the phone.
if (LAN) {
  listen(LAN);
  Bun.serve({
    hostname: LAN, port: PORT + 1,
    fetch(req, server) {
      if (!allowed(ipOf(req, server))) return new Response("forbidden", { status: 403 });
      if (new URL(req.url).pathname !== "/ca.crt") return new Response("not found", { status: 404 });
      return new Response(Bun.file(`${STATE}/tls/ca.crt`), { headers: { "content-type": "application/x-x509-ca-cert" } });
    },
  });
}
// The home-network check lives in bin/herdr-voice (`run`), which starts this process and stops it
// when the computer leaves home. It is done there because an address lookup from this runtime comes back empty on macOS.
console.log(LAN ? `herdr-voice ready: https://${LOOP}:${PORT}/ and, for phones, https://${LAN}:${PORT}/  (CA cert: http://${LAN}:${PORT + 1}/ca.crt)`
                : `herdr-voice ready: https://${LOOP}:${PORT}/  (this Mac only)`);
