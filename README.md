# herdr-voice

Talk to your coding agents and hear what they choose to say back.

Hold a button, speak, release. Your words are typed into the agent session you picked. The agent
writes its normal reply on screen and, separately, says one or two sentences out loud. Only those
sentences are voiced: written and spoken output are different on purpose.

It works with agent sessions that run in herdr-core (`hc`) terminals, on this computer or on other
machines `hc` reaches. There are two ways to talk:

- **HerdrVoice**, a small macOS app: a floating button and a global hold-to-talk key.
- **A phone page** served by the same Mac, for talking from the sofa or another room. It is off
  until you switch it on.

All speech, listening and speaking, is done on the Mac by the app, for the phone page too. Nothing
you say is sent to a speech service.

Status: a working prototype, started November 2026. macOS only; tried on Apple silicon, with an
iPhone as the phone, and with herdr-core 0.1.21. Intel Macs, Android phones and older versions of
`hc` are untried.

## What you need

- A Mac with Xcode (to build the app).
- `hc` (herdr-core) with the agent sessions you want to reach. This is the hard requirement: sessions
  must run inside `hc` terminals, and nothing works without it.
- `bun` and `openssl`; `ffmpeg` for the phone page.

`herdr-voice check` says which of these it finds, and so does Setup.

Two things to know before you start:

- **Put the command in `~/.local/bin`**, as below. The app looks for `herdr-voice` there, and for
  `hc` in `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`.
- **Let your agents run the speak command.** An agent speaks by running
  `/tmp/herdr-voice/herdr-speak "<words>"`. If your agent asks before running commands, allow that
  one, or it will stop at a permission prompt every time it has something to say. In Claude Code:
  add `Bash(/tmp/herdr-voice/herdr-speak:*)` to the allowed tools.

## Start

```sh
git clone https://github.com/TheRealHaoLiu/herdr-voice && cd herdr-voice
mkdir -p ~/.local/bin && ln -s "$PWD/bin/herdr-voice" ~/.local/bin/herdr-voice
herdr-voice app
```

`herdr-voice app` builds HerdrVoice into `~/Applications` the first time and opens it. The app starts
the server, and on its first run opens **Setup**:

- **Speech on this Mac.** Download the speech models (about 650 MB, once). Nothing can be said or
  heard until they are loaded.
- **Microphone.** Allow it when macOS asks.
- **Voice and talk shortcut.**
- **Where you talk from.** This Mac only (the default: the server listens on the Mac's own loopback
  address, which nothing on the network can reach), or this Mac and phones on your network.
- **Port.**

Setup is under the button's right-click menu afterwards.

Then hold the button, or hold Option+Command by themselves anywhere, and talk. Right-click the button
to choose the session. Drag it to move it.

## How one turn works

1. Your speech is turned into text by the app on the Mac. A clip from the phone page goes to the
   server, which hands it to the app.
2. The server types `[voice] <your words>` into the session with `hc send`.
3. The agent replies on screen and runs `herdr-speak "<words>"` for what it wants you to hear. That
   command only appends a line to a queue file on the agent's own machine.
4. The server reads the new lines for that session. The app voices them; for the phone page the
   app makes the audio and the page plays it.

Nothing is installed in the agents. The first voice message to a session carries a standing
instruction that explains `[voice]` and the `herdr-speak` command; later messages are just your
words. If a session ends a voice turn without speaking, for example after its context was
compacted, the instruction is sent again.

## While an agent is working

- **Narration.** For a request that takes several steps, the agent says a short line as it starts
  each one, and you hear it as it happens.
- **Steer.** Talk again while it works. Your words go into the running task and the agent reads them
  when its current step ends. It acknowledges out loud in a few words, so you know the moment it has
  read them.
- **Send now** (phone page, Claude Code sessions). Has the agent read your message at once. A command
  that was running continues in the background.
- **Stop.** A quick tap on the app's button, a double tap of its shortcut, or the Stop button on the
  phone page.
- **Permission prompts.** If the agent stops at a permission prompt mid-task, you hear that it is
  asking and see what for. On the phone page, for Claude Code sessions, **Allow** and **Deny** buttons answer it.
  It takes a tap, never a spoken word, so a misheard word cannot approve a command; and if the
  request on the agent's screen has changed since you were shown it, nothing is pressed and you are
  shown the new one.
- **Announcements.** An agent can speak when you have not just asked it something, for example when
  a long job finishes. It names its session first. Only the device you last talked through says it
  aloud; other open devices show the text. Each device can switch announcements off.

A typed message starting with `/` (for example `/compact`) is passed to the session as a slash
command, with nothing spoken back.

## Tidying what you said

Spoken text is tidied before it is shown or sent: the fillers `um`, `uh`, `er`, `erm`, `ah` and `hmm`
are dropped, and a word or short phrase said twice in a row is kept once. Numbers, "mm", hyphenated
sounds such as "uh-huh", and anything you type are left alone. It is two rules, not a model. Switch
it off with `echo off > ~/.local/state/herdr-voice/compact`.

## What is kept

The server keeps a history on the Mac of what was said both ways: your words, what agents said out
loud, and each permission answer. It is the file `~/.local/state/herdr-voice/history.jsonl`, readable
by you only, trimmed to the newest 3000 lines, and it never leaves the Mac. The phone page shows the
recent messages of a session when you open it, so a reload does not empty the conversation. Switch
it off with `echo off > ~/.local/state/herdr-voice/history`; delete the file to forget what is there.

No audio is kept on purpose. Three files hold the most recent clip of their kind and are overwritten
by the next one: the app's last recording and the last phone clip it transcribed (both in the Mac's
temporary folder), and the last clip the server could not decode (in the state folder).

## The phone page

First switch phones on: Setup → Use it from → **This Mac and phones on my network**. The server then
also listens on this Mac's address on your network, and makes a certificate that names that address.
Give the Mac a fixed address on your network (a DHCP reservation): if its address changes, a new
certificate is made at the next start and every phone has to install it again.

Then, in the app: right-click → **Connect a Phone**. It shows two QR codes.

1. The first installs the server's certificate. Do this once per phone, then switch the certificate
   on under Settings → General → About → Certificate Trust Settings.
2. The second opens the page already signed in. It holds a one-time code that works once and expires
   in two minutes, not the access key.

On the page, hold the big button to talk. Your words appear while you talk and again in full when
you release. While you hold the button, anything being spoken is turned down.

The phone and the Mac have to be on the same network, or the phone on a VPN to it. The page works
only while the app is open with its speech models loaded, because the app does the page's speech.
If the app cannot voice a reply, the phone falls back to its own built-in voice.

## Settings

`~/.config/herdr-voice/config.json`, written by hand. Both settings are optional;
`config.example.json` shows them.

| Setting | What it is |
|---|---|
| `allow` | Optional. A regular expression of source addresses let in, for example `^192\\.168\\.1\\.\\d+$`. Without it every source may try, and the access key and HTTPS are the gate. |
| `instruction` | Optional. Your own wording for the standing instruction. Write `{speak}` where the command belongs; if you leave it out, a sentence naming the command is added. |

Both apply after a restart.

Other settings live as small files in `~/.local/state/herdr-voice/`, next to the access key and the
certificate:

- `mode`: `local` (this Mac only, the default) or `network` (also phones). Set it in Setup or with
  `herdr-voice mode`.
- `address`: with phones on, this computer's address on its default network, found by setup. The
  server listens on that one address and on loopback, never on all addresses, and the certificate
  names exactly those two.
- `port`: set it with `herdr-voice port <number>` or in Setup. Default 8443.
- `voice`: the voice, shared by the app and the phone page.

## Commands

```sh
herdr-voice app             # open the app (builds it first if missing); the app runs the server
herdr-voice status
herdr-voice check           # is herdr-core there, and the other programs it needs
herdr-voice mode network    # switch phones on (or: local); then restart
herdr-voice key             # copy the access key to the clipboard
herdr-voice voice am_liam
herdr-voice port 9443       # then quit and reopen the app, and connect each phone again
herdr-voice pin-home <name> # optional home check, see below
herdr-voice start | stop    # run the server without the app, as background hc terminals
```

Nothing starts at login.

**Home check (optional, phones only).** After `herdr-voice pin-home <name>`, with phones on, the server only runs while your home
router's DNS gives the pinned answer for that name, and stops within about a minute when it no
longer does. Choose a name only your own network's DNS knows. It guards against the server running
by accident on another network; the access key and HTTPS remain the real gate. With a VPN to home
up, home DNS can answer from anywhere.

## Security

Whoever can use the page can type into any listed agent session, and some of those may run without
permission prompts. Treat the access key like a shell login.

- HTTPS only. A second, plain-HTTP port serves the public certificate and nothing else.
- By default the server listens only on this Mac's loopback address. With phones on it also listens
  on one network address; with `allow` set, other source addresses are refused there and logged.
- The access key is in `~/.local/state/herdr-voice/psk`, compared in constant time.
- The certificate authority can only vouch for the addresses the server listens on, and its signing
  key is deleted at creation, so it can never sign anything else.
- The page can list sessions, send text to one, press its stop and send-now keys, answer its
  permission prompts, and read its screen and spoken lines. It cannot start sessions or touch files.
- Words are typed into a session without a sender tag, as if you had typed them.

## Known limits

- An unsent draft in a session's input box can get merged with a voice message.
- Words-while-you-talk on the phone is a simple version: the recording so far is transcribed about
  once a second, so the words run a second or two behind. The app shows text only after release.
- Replies reach the phone as uncompressed audio, roughly 50 KB for each second spoken.
- The server's certificate is valid for 397 days; renewing it means installing it on the phone again.
- Send now is known to work for Claude Code sessions only.

## Pieces

| File | What it is |
|---|---|
| `server.ts` | The server (Bun): session list, turns, the standing instruction, speech jobs for the app. |
| `index.html` | The phone page. |
| `mac/` | HerdrVoice, the macOS app. `mac/build.sh` builds it. |
| `bin/herdr-voice` | Start, stop, status and settings. |
| `bin/setup` | Creates the access key and the certificate. |
| `bin/herdr-speak` | The command agents run. The server places it on a machine the first time a session there is spoken to. |
| `bin/herdr-speakd` | Optional: speaks the queue through the Mac's speakers with `say`, without the app. |

`HerdrVoice --selftest <audio file>` loads the speech models and prints timings.

## Licence

Apache-2.0, see `LICENSE`. Copyright 2026 Hao Liu.

The app uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) and downloads
its speech models when you ask it to in Setup: Parakeet TDT 0.6B v3 for speech-to-text and Kokoro
for text-to-speech. The models are not part of this repository and carry their own licences; see
their model cards.
