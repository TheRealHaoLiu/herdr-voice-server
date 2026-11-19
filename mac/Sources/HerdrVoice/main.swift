// HerdrVoice: a floating talk button and a global hold-to-talk key for the herdr-voice server.
// Hold the button (or hold Option+Command by themselves), speak, release. The reply plays on this Mac.
// Right-click the button to pick the session. It is a thin client: all logic stays in server.ts.
import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage

let env = ProcessInfo.processInfo.environment
let stateDir = env["HERDR_VOICE_STATE"] ?? NSHomeDirectory() + "/.local/state/herdr-voice"
// Settings shared with the server are small files in the state folder, read each time they are
// needed so a change made in Setup applies at once.
func stateFile(_ name: String) -> String? {
    (try? String(contentsOfFile: stateDir + "/" + name, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}
var savedPort: Int { stateFile("port").flatMap { Int($0) }.flatMap { (1024...65534).contains($0) ? $0 : nil } ?? 8443 }
var phonesOn: Bool { stateFile("mode") == "network" }   // otherwise the server listens on this Mac only
var savedAddress: String { stateFile("address") ?? "" } // this computer's network address, for phones
// The app always reaches the server over this Mac's own loopback address.
var baseURL: String { env["HERDR_VOICE_URL"] ?? "https://127.0.0.1:\(savedPort)" }
let toolPath = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
func toolFound(_ name: String) -> Bool { toolPath.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) } }

// Trust only the server's own CA certificate (the same file the phone installs).
final class PinnedTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pem = try? String(contentsOfFile: stateDir + "/tls/ca.crt", encoding: .utf8),
              let b64 = pem.components(separatedBy: "-----").dropFirst(2).first?
                  .components(separatedBy: .whitespacesAndNewlines).joined(),
              let der = Data(base64Encoded: b64),
              let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

struct VoiceError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class API {
    let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust(), delegateQueue: nil)
    static let clientId: String = { // tells the server which device you last talked through
        if let c = UserDefaults.standard.string(forKey: "clientId") { return c }
        let c = "mac-" + UUID().uuidString.prefix(8).lowercased(); UserDefaults.standard.set(c, forKey: "clientId"); return c
    }()
    func call(_ path: String, method: String = "GET", body: Data? = nil, type: String? = nil, timeout: TimeInterval = 240) async throws -> [String: Any] {
        guard let key = try? String(contentsOfFile: stateDir + "/psk", encoding: .utf8) else {
            throw VoiceError(message: "No access key found. Run: herdr-voice start")
        }
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method; req.httpBody = body; req.timeoutInterval = timeout
        req.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-voice-key")
        req.setValue(API.clientId, forHTTPHeaderField: "x-voice-client")
        if let type { req.setValue(type, forHTTPHeaderField: "content-type") }
        let data: Data
        do { (data, _) = try await session.data(for: req) }
        catch { throw VoiceError(message: "The herdr-voice server is not answering. Run: herdr-voice start") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceError(message: "The server sent something unreadable.")
        }
        return obj
    }
}

enum Phase { case idle, recording, thinking, speaking }

// Settings offered in the right-click menu.
let voices: [(title: String, id: String)] = [
    ("Echo (American, male)", "am_echo"), ("Liam (American, male)", "am_liam"), ("Puck (American, male)", "am_puck"),
    ("Eric (American, male)", "am_eric"), ("Michael (American, male, deep)", "am_michael"),
    ("George (British, male)", "bm_george"), ("Fable (British, male)", "bm_fable"), ("Heart (American, female)", "af_heart"),
]
// key -1 means "these modifiers held by themselves, no other key".
let shortcuts: [(title: String, key: Int, mods: Int)] = [
    ("⌥⌘ (Option+Command, no other key)", -1, optionKey | cmdKey), ("⌃⌘ (Control+Command, no other key)", -1, controlKey | cmdKey),
    ("⌃⌥⌘Space", kVK_Space, controlKey | optionKey | cmdKey), ("⌃⌥Space", kVK_Space, controlKey | optionKey),
    ("⌥Space", kVK_Space, optionKey), ("F5", kVK_F5, 0),
]
var shortcutIndex: Int {
    get { let i = UserDefaults.standard.integer(forKey: "shortcut"); return shortcuts.indices.contains(i) ? i : 0 }
    set { UserDefaults.standard.set(newValue, forKey: "shortcut") }
}
var shortcutTitle: String { String(shortcuts[shortcutIndex].title.split(separator: " ").first ?? "") }
var currentVoice: String {
    (try? String(contentsOfFile: stateDir + "/voice", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "am_echo"
}

// A small text bubble beside the button: who you are talking to, what was heard, what was said, any problem.
@MainActor
final class Bubble {
    let panel: NSPanel
    let label = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var pinned = false // true while a timed message is showing, so moving the mouse away does not hide it
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        let box = NSView(); box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.96).cgColor; box.layer?.cornerRadius = 10
        label.textColor = .white; label.font = .systemFont(ofSize: 13); label.maximumNumberOfLines = 6
        box.addSubview(label); panel.contentView = box
    }
    func show(_ text: String, near button: NSWindow, seconds: Double?) {
        timer?.invalidate(); timer = nil; pinned = seconds != nil
        label.stringValue = text
        label.preferredMaxLayoutWidth = 300
        let fit = label.sizeThatFits(NSSize(width: 300, height: 400))
        let size = NSSize(width: ceil(fit.width) + 24, height: ceil(fit.height) + 16)
        label.frame = NSRect(x: 12, y: 8, width: ceil(fit.width), height: ceil(fit.height))
        let screen = button.screen?.visibleFrame ?? .zero
        var x = button.frame.minX - size.width - 8
        if x < screen.minX + 4 { x = button.frame.maxX + 8 }
        let y = min(max(button.frame.midY - size.height / 2, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if let seconds { timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in Task { @MainActor in self.hide() } } }
    }
    func hide() { timer?.invalidate(); timer = nil; pinned = false; panel.orderOut(nil) }
}

@MainActor
final class Controller: NSObject, AVAudioPlayerDelegate {
    static let shared = Controller()
    let api = API()
    var phase = Phase.idle { didSet { button?.needsDisplay = true } }
    let bubble = Bubble()
    let connect = ConnectWindow()
    @objc func connectPhone() {
        if phonesOn { connect.open() } else { note("Phones are switched off: the server listens on this Mac only. Switch them on in Setup.", seconds: 8) }
    }
    let setup = SetupWindow()
    @objc func openSetup() { setup.open() }
    var hovering = false
    func note(_ text: String, seconds: Double? = 5) { if let w = button?.window { bubble.show(text, near: w, seconds: seconds) } }
    var targetName: String { sessions.first { ($0["address"] as? String) == target }.map(Controller.label) ?? (target ?? "no session picked") }
    func hover(_ inside: Bool) {
        hovering = inside
        if inside { if !bubble.pinned { note("Talking to: \(targetName)\nHold to talk (or \(shortcutTitle)) · right-click to switch\nWhile it works: talk to steer, tap to stop", seconds: nil) } }
        else if !bubble.pinned { bubble.hide() }
    }
    weak var button: TalkButton?
    var recorder: AVAudioRecorder?
    var player: AVAudioPlayer?
    var sessions: [[String: Any]] = []
    var lastHeard = "", lastSaid = "", lastNote = ""
    var target: String? {
        get { UserDefaults.standard.string(forKey: "session") }
        set { UserDefaults.standard.set(newValue, forKey: "session") }
    }
    let clip = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("herdr-voice-clip.m4a")

    static func label(_ s: [String: Any]) -> String {
        (s["name"] as? String) ?? (s["title"] as? String) ?? (s["folder"] as? String) ?? (s["address"] as? String) ?? "?"
    }

    var serverUp = false
    // Run the herdr-voice command. A GUI app has a bare PATH, so the usual tool folders are added.
    func herdrVoice(_ verb: String) async -> (ok: Bool, lastLine: String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/herdr-voice")
                p.arguments = [verb]
                var e = ProcessInfo.processInfo.environment
                e["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = e; p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { done.resume(returning: (false, "The herdr-voice command is not installed.")); return }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                let last = out.split(separator: "\n").last.map(String.init) ?? ""
                done.resume(returning: (p.terminationStatus == 0, last))
            }
        }
    }
    // The server and the laptop speaker run as this app's own child processes: they start with the app
    // and stop when it quits. Their output goes to a log file in the state folder.
    var serverProc: Process?, speakerProc: Process?
    func spawn(_ verb: String) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/herdr-voice")
        p.arguments = [verb]
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = e
        let log = stateDir + "/app.log"
        if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
        do { try p.run(); return p } catch { return nil }
    }
    func ensureServer() async {
        if serverProc?.isRunning == true { await refreshSessions(); if serverUp { note("Talking to: \(targetName)", seconds: 4); return } }
        note("Starting the herdr-voice server…", seconds: nil)
        stopChildren()
        _ = await herdrVoice("stop") // clear any copy left running as hc terminals or from an earlier launch
        serverProc = spawn("run")
        for _ in 0..<24 { // up to about 12 seconds
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshSessions()
            if serverUp || serverProc?.isRunning != true { break }
        }
        if serverUp { note("Server started. Talking to: \(targetName)", seconds: 6) }
        else {
            let why = (try? String(contentsOfFile: stateDir + "/app.log", encoding: .utf8))?.split(separator: "\n").last.map(String.init) ?? ""
            stopChildren(); note("Could not start the server. \(why)", seconds: 10)
        }
    }
    func stopChildren() {
        for p in [serverProc, speakerProc] { if let p, p.isRunning { p.terminate() } }
        serverProc = nil; speakerProc = nil
    }
    @objc func startServer() { Task { await ensureServer() } }
    func restartServer() async { stopChildren(); try? await Task.sleep(nanoseconds: 800_000_000); await ensureServer() }
    @objc func stopServer() { stopChildren(); Task { try? await Task.sleep(nanoseconds: 800_000_000); await refreshSessions(); note("Server stopped. The phone page is off too.", seconds: 6) } }

    func refreshSessions() async {
        guard let r = try? await api.call("/api/sessions", timeout: 6), let list = r["sessions"] as? [[String: Any]] else { serverUp = false; sessions = []; return }
        serverUp = true
        sessions = list
        if target == nil || !list.contains(where: { ($0["address"] as? String) == target }) { target = list.first?["address"] as? String }
    }

    func startTalking() {
        guard phase == .idle || phase == .speaking || (phase == .thinking && turnPending) else { return }
        player?.stop(); waiting.removeAll() // talking always cuts whatever is being said
        wantRecording = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard self.wantRecording else { return } // released before the recorder could start
                guard granted else { self.fail("Microphone access is off for HerdrVoice (System Settings → Privacy → Microphone)."); return }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]
                guard let rec = try? AVAudioRecorder(url: self.clip, settings: settings), rec.record() else { self.fail("Could not start recording."); return }
                self.recorder = rec; self.phase = .recording
                self.note("Listening… (to \(self.targetName))", seconds: nil)
            }
        }
    }

    func cancelTalking() { wantRecording = false; recorder?.stop(); recorder = nil; if phase == .recording { phase = turnPending ? .thinking : .idle; bubble.hide() } }

    // Interrupting. While an agent is working: talking steers it (your words go into the running task);
    // a quick tap on the button, or a double tap of the shortcut, stops the task.
    func stopTask() {
        guard turnPending, let t = target else { return }
        player?.stop(); waiting.removeAll()
        note("Stopping \(targetName)…", seconds: nil)
        let q = "?t=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
        Task { let r = try? await api.call("/api/stop" + q, method: "POST", timeout: 25)
               note((r?["stopped"] as? Bool) == true ? "Stopped \(targetName)." : "Could not stop \(targetName).", seconds: 6) }
    }
    func steer(_ t: String, _ audio: Data) async {
        let q = "?t=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
        do {
            guard localReady else { note("The speech models are not loaded yet. Open Setup from the right-click menu.", seconds: 8); return }
            let said = try await timed("local speech: speech-to-text") { try await LocalSpeech.shared.transcribe(self.clip) }
            guard !said.isEmpty else { note("I didn't catch anything.", seconds: 4); return }
            let r = try await api.call("/api/say" + q + "&audio=0&spoken=1", method: "POST",
                                       body: try JSONSerialization.data(withJSONObject: ["text": said]), type: "application/json")
            if let e = r["error"] as? String { note(e, seconds: 6); return }
            let heard = (r["heard"] as? String) ?? ""
            if !heard.isEmpty { lastHeard = heard }
            note("Sent to \(targetName) mid-task: \(heard)", seconds: 6)
        } catch { note(error.localizedDescription, seconds: 6) }
    }

    var wantRecording = false
    func stopTalking() {
        wantRecording = false
        guard phase == .recording, let rec = recorder else { if turnPending { stopTask() }; return } // a tap too quick to record
        let length = rec.currentTime
        rec.stop(); recorder = nil
        if turnPending { // mid-task: a quick tap stops the task, a held message steers it
            phase = .thinking
            guard length > 0.4, let audio = try? Data(contentsOf: clip), let t = target else { stopTask(); return }
            Task { await self.steer(t, audio) }
            return
        }
        guard length > 0.4, let audio = try? Data(contentsOf: clip) else { phase = .idle; note("Too short. Hold while you talk.", seconds: 3); return }
        guard let t = target else { fail("Pick a session first: right-click the button."); return }
        phase = .thinking
        note("Sent. Waiting for \(targetName)…", seconds: nil)
        Task { await self.turn(t, audio) }
    }

    func turn(_ t: String, _ audio: Data) async {
        let q = "?t=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)
        turnPending = true; defer { turnPending = false }
        do {
            // Speech happens here on the Mac: transcribe, send the words, and voice the reply here too.
            guard localReady else { fail("The speech models are not loaded yet. Open Setup from the right-click menu."); return }
            let said = try await timed("local speech: speech-to-text") { try await LocalSpeech.shared.transcribe(self.clip) }
            guard !said.isEmpty else { fail("I didn't catch anything."); return }
            lastHeard = said; note("You: \(said)\nWaiting for \(targetName)…", seconds: nil)
            var r = try await api.call("/api/say" + q + "&audio=0&spoken=1", method: "POST",
                                       body: try JSONSerialization.data(withJSONObject: ["text": said]), type: "application/json")
            if let h = r["heard"] as? String, !h.isEmpty { lastHeard = h }
            var saidSomething = false
            while true {
                if let e = r["error"] as? String { fail(e); return }
                if (r["narrated"] as? Bool) == true { saidSomething = true }
                if let said = r["spoken"] as? String, !said.isEmpty {
                    lastSaid = said; saidSomething = true
                    var clip = (r["audio"] as? String).flatMap { Data(base64Encoded: $0) }
                    if clip == nil { clip = await voiceLocally(said) }
                    waiting.append(("You: \(lastHeard)\n\(targetName): \(said)", clip))
                    if phase != .speaking { phase = .idle; playNextAnnouncement() } // otherwise it follows the clip now playing
                }
                guard (r["status"] as? String) == "working" else { break }
                note("You: \(lastHeard)\n\(targetName) is still working…", seconds: nil)
                r = try await api.call("/api/collect" + q + "&audio=0", method: "POST")
            }
            lastNote = ""
            if !saidSomething { note("You: \(lastHeard)\n\(targetName) finished without saying anything.", seconds: 6) }
            turnPending = false
            if phase == .thinking { phase = .idle }
            playNextAnnouncement()
        } catch { fail(error.localizedDescription) }
    }

    func play(_ mp3: Data) {
        guard let p = try? AVAudioPlayer(data: mp3) else { return }
        player = p; p.delegate = self; phase = .speaking; p.play()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully ok: Bool) {
        Task { @MainActor in if self.phase == .speaking { self.phase = self.turnPending ? .thinking : .idle }; self.playNextAnnouncement() }
    }

    // Announcements: an agent speaking when you had not just asked it something. The server names the
    // session first. They wait their turn: never over a recording, a pending reply or another clip.
    var announceOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "announceOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "announceOff") }
    }
    // Speech runs on this Mac: Parakeet and Kokoro through FluidAudio. The app also does the phone
    // page's speech, as a worker for the server (see speechWorker).
    var localReady = false, localLoading = false
    func loadLocalSpeech() async {
        guard !localReady, !localLoading else { return }
        localLoading = true; defer { localLoading = false }
        note("Loading speech models on this Mac… (the first time downloads about 650 MB)", seconds: nil)
        do {
            try await timed("local speech: load models") { try await LocalSpeech.shared.prepare(voice: currentVoice) }
            localReady = true; note("Speech is ready on this Mac.", seconds: 5)
        } catch {
            logLine("local speech failed to load: \(error.localizedDescription)")
            note("The speech models could not load. \(error.localizedDescription)", seconds: 10)
        }
    }
    func voiceLocally(_ text: String) async -> Data? {
        guard localReady, !text.isEmpty else { return nil }
        return try? await timed("local speech: text-to-speech") { try await LocalSpeech.shared.speak(text, voice: currentVoice) }
    }
    // The phone page has no speech of its own. The server hands its clips and replies to this app as
    // jobs, over this Mac's loopback address: ask for the next job, do it with the models loaded here,
    // post the result. One at a time; each takes a fraction of a second.
    func speechWorker() async {
        let wavFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("herdr-voice-job.wav")
        while true {
            guard serverUp, localReady, let r = try? await api.call("/api/speech/next?wait=25", timeout: 45) else {
                try? await Task.sleep(nanoseconds: 2_000_000_000); continue
            }
            guard let job = r["job"] as? [String: Any], let id = job["id"] as? String else { continue }
            var result: [String: Any] = ["id": id]
            do {
                if (job["kind"] as? String) == "stt" {
                    guard let wav = (job["wav"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw VoiceError(message: "no audio in the job") }
                    try wav.write(to: wavFile)
                    result["text"] = try await timed("phone: speech-to-text") { try await LocalSpeech.shared.transcribe(wavFile) }
                } else {
                    let text = (job["text"] as? String) ?? "", voice = (job["voice"] as? String) ?? currentVoice
                    result["audio"] = try await timed("phone: text-to-speech") { try await LocalSpeech.shared.speak(text, voice: voice) }.base64EncodedString()
                }
            } catch { result["error"] = error.localizedDescription }
            if let body = try? JSONSerialization.data(withJSONObject: result) {
                _ = try? await api.call("/api/speech/done", method: "POST", body: body, type: "application/json", timeout: 15)
            }
        }
    }
    var waiting: [(text: String, audio: Data?)] = []
    var turnPending = false // a reply is still on its way; narration may play meanwhile
    func playNextAnnouncement() {
        guard phase == .idle || phase == .thinking, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        note(next.text, seconds: 12)
        if let audio = next.audio { play(audio) } else { playNextAnnouncement() }
    }
    func listenForAnnouncements() async {
        var last = -1, epoch = 0.0
        while true {
            guard serverUp, let r = try? await api.call("/api/announcements?after=\(last)&wait=25&audio=0", timeout: 45) else {
                try? await Task.sleep(nanoseconds: 3_000_000_000); continue
            }
            let e = (r["epoch"] as? Double) ?? 0
            // First call: start from now. Server restarted (its numbering began again): take everything since.
            if last < 0 || e != epoch { last = (epoch != 0 && e != epoch) ? 0 : ((r["last"] as? Int) ?? 0); epoch = e; continue }
            for item in (r["items"] as? [[String: Any]]) ?? [] {
                last = max(last, (item["id"] as? Int) ?? last)
                let body = (item["text"] as? String) ?? ""
                var clip = (item["audio"] as? String).flatMap { Data(base64Encoded: $0) }
                if (item["kind"] as? String) == "progress" { // narration during a turn: no "From", play as it arrives
                    if clip == nil { clip = await voiceLocally(body) }
                    waiting.append((body, clip)); continue
                }
                guard announceOn else { continue }
                let text = "From \((item["from"] as? String) ?? "an agent"): \((item["text"] as? String) ?? "")"
                if (item["play"] as? Bool) == false { note(text, seconds: 8); continue } // another device says it; show it here
                if clip == nil { clip = await voiceLocally("From \((item["from"] as? String) ?? "an agent"). \(body)") }
                waiting.append((text, clip))
            }
            playNextAnnouncement()
        }
    }
    @objc func toggleAnnounce() { announceOn.toggle(); note(announceOn ? "Announcements on: agents can speak up by themselves here." : "Announcements off on this Mac.", seconds: 5) }
    func fail(_ why: String) { lastNote = why; phase = .idle; NSSound.beep(); note(why, seconds: 8) }

    func menu() -> NSMenu {
        let m = NSMenu()
        if !lastHeard.isEmpty { m.addItem(info("You: " + lastHeard)) }
        if !lastSaid.isEmpty { m.addItem(info("It said: " + lastSaid)) }
        if !lastNote.isEmpty { m.addItem(info("Problem: " + lastNote)) }
        if m.items.count > 0 { m.addItem(.separator()) }
        if !serverUp { m.addItem(info("The server is not running")) }
        else if sessions.isEmpty { m.addItem(info("No agent sessions found")) }
        var machine = ""
        for s in sessions {
            let mach = (s["machine"] as? String) ?? ""
            if mach != machine { machine = mach; m.addItem(info(mach)) }
            let item = NSMenuItem(title: "  " + Controller.label(s), action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = s["address"] as? String
            item.state = (s["address"] as? String) == target ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        m.addItem(info("Hold \(shortcutTitle) anywhere to talk"))
        let phone = NSMenuItem(title: "Connect a Phone…", action: #selector(connectPhone), keyEquivalent: ""); phone.target = self
        phone.isEnabled = serverUp; m.addItem(phone)
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: ""); setupItem.target = self; m.addItem(setupItem)
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""); let sm = NSMenu()
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: ""); let vm = NSMenu()
        let now = currentVoice
        for v in voices {
            let i = NSMenuItem(title: v.title, action: #selector(setVoice(_:)), keyEquivalent: ""); i.target = self
            i.representedObject = v.id; i.state = v.id == now ? .on : .off; vm.addItem(i)
        }
        if !voices.contains(where: { $0.id == now }) { let i = info("Current: " + now); i.state = .on; vm.addItem(i) }
        voiceItem.submenu = vm; sm.addItem(voiceItem)
        let keyItem = NSMenuItem(title: "Talk Shortcut", action: nil, keyEquivalent: ""); let km = NSMenu()
        for (n, sc) in shortcuts.enumerated() {
            let i = NSMenuItem(title: "Hold " + sc.title, action: #selector(setShortcut(_:)), keyEquivalent: ""); i.target = self
            i.tag = n; i.state = n == shortcutIndex ? .on : .off; km.addItem(i)
        }
        keyItem.submenu = km; sm.addItem(keyItem)
        let ann = NSMenuItem(title: "Speak Announcements from Agents", action: #selector(toggleAnnounce), keyEquivalent: ""); ann.target = self
        ann.state = announceOn ? .on : .off; sm.addItem(ann)
        settings.submenu = sm; m.addItem(settings)
        let server = serverUp ? NSMenuItem(title: "Stop Server (also stops the phone page)", action: #selector(stopServer), keyEquivalent: "")
                              : NSMenuItem(title: "Start Server", action: #selector(startServer), keyEquivalent: "")
        server.target = self; m.addItem(server)
        let quit = NSMenuItem(title: "Quit HerdrVoice (stops the server)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        return m
    }
    func info(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text.count > 90 ? String(text.prefix(88)) + "…" : text, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    // The voice is the server's setting (one file it reads on every reply), so it changes for the phone page too.
    @objc func setVoice(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        do { try (id + "\n").write(toFile: stateDir + "/voice", atomically: true, encoding: .utf8); note("Voice: \(item.title). Applies to the phone page too.", seconds: 5) }
        catch { fail("Could not save the voice setting.") }
    }
    @objc func setShortcut(_ item: NSMenuItem) {
        shortcutIndex = item.tag
        let ok = delegate.registerHotKey()
        note(ok ? "Talk shortcut: hold \(shortcutTitle)" : "\(shortcutTitle) is taken by something else. Pick another.", seconds: 6)
    }

    // Modifier-only shortcut (for example Option+Command held alone). Read from the keyboard state a few
    // times a second, which needs no special permission. Recording starts only after the modifiers have
    // been held by themselves for a moment, and is abandoned if any other key is pressed, so ordinary
    // shortcuts that begin with the same modifiers do not trigger it.
    var chordTimer: Timer?, chordSince: Date?, chordActive = false, chordSpoiled = false
    var lastChordTap: Date? // a short, clean press-and-release; two within 0.6s stop the running task
    func watchChord(_ carbonMods: Int?) {
        chordTimer?.invalidate(); chordTimer = nil; chordSince = nil; chordActive = false; chordSpoiled = false
        guard let carbonMods else { return }
        var want: CGEventFlags = []
        if carbonMods & cmdKey != 0 { want.insert(.maskCommand) }
        if carbonMods & optionKey != 0 { want.insert(.maskAlternate) }
        if carbonMods & controlKey != 0 { want.insert(.maskControl) }
        if carbonMods & shiftKey != 0 { want.insert(.maskShift) }
        let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        chordTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            Task { @MainActor in
                let held = CGEventSource.flagsState(.combinedSessionState).intersection(all) == want
                guard held else {
                    if self.chordActive { self.chordActive = false; self.stopTalking() }
                    else if let since = self.chordSince, !self.chordSpoiled, Date().timeIntervalSince(since) < 0.35 { // a tap
                        if let last = self.lastChordTap, Date().timeIntervalSince(last) < 0.6 { self.lastChordTap = nil; self.stopTask() }
                        else { self.lastChordTap = Date() }
                    }
                    self.chordSince = nil; self.chordSpoiled = false; return
                }
                let since = self.chordSince ?? Date(); self.chordSince = since
                let heldFor = Date().timeIntervalSince(since)
                if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < heldFor { // another key was pressed
                    self.chordSpoiled = true
                    if self.chordActive { self.chordActive = false; self.cancelTalking() }
                }
                if !self.chordSpoiled && !self.chordActive && heldFor >= 0.35 { self.chordActive = true; self.startTalking() }
            }
        }
    }
    @objc func pick(_ item: NSMenuItem) { target = item.representedObject as? String; note("Now talking to: \(targetName)", seconds: 4) }
}

// "Connect a Phone": two QR codes. The first installs the server's certificate (once per phone);
// the second opens the page with a one-time code that is traded for the access key.
@MainActor
final class ConnectWindow: NSObject, NSWindowDelegate {
    var window: NSWindow?
    let image = NSImageView(), caption = NSTextField(wrappingLabelWithString: ""), steps = NSSegmentedControl()
    var certURL = "", pairURL = "", expires = Date(), timer: Timer?

    static func qr(_ text: String, side: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: side / out.extent.width, y: side / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
    func open() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Connect a Phone"; w.isReleasedWhenClosed = false; w.level = .floating; w.delegate = self
            steps.segmentCount = 2; steps.setLabel("1 · Certificate", forSegment: 0); steps.setLabel("2 · Connect", forSegment: 1)
            steps.trackingMode = .selectOne; steps.target = self; steps.action = #selector(render)
            steps.frame = NSRect(x: 40, y: 426, width: 260, height: 28)
            image.frame = NSRect(x: 30, y: 136, width: 280, height: 280); image.imageScaling = .scaleProportionallyUpOrDown
            caption.frame = NSRect(x: 24, y: 12, width: 292, height: 116); caption.font = .systemFont(ofSize: 12.5); caption.alignment = .center
            w.contentView?.addSubview(steps); w.contentView?.addSubview(image); w.contentView?.addSubview(caption)
            window = w
        }
        steps.selectedSegment = 1; image.image = nil; caption.stringValue = "Getting a code…"
        window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        Task { await self.fetch() }
    }
    func fetch() async {
        do {
            let r = try await Controller.shared.api.call("/api/pair-code", method: "POST", timeout: 8)
            guard let url = r["url"] as? String, let cert = r["cert_url"] as? String else { throw VoiceError(message: (r["error"] as? String) ?? "No code came back.") }
            pairURL = url; certURL = cert; expires = Date().addingTimeInterval((r["expires_in"] as? Double) ?? 120)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.render() } }
            render()
        } catch { image.image = nil; caption.stringValue = error.localizedDescription }
    }
    @objc func render() {
        let left = Int(expires.timeIntervalSinceNow)
        if steps.selectedSegment == 0 {
            image.image = ConnectWindow.qr(certURL, side: 560)
            caption.stringValue = "First time on this phone only. Scan with the Camera, allow the profile, then install it in Settings → General → VPN & Device Management and switch it on under About → Certificate Trust Settings."
        } else if left > 0 {
            image.image = ConnectWindow.qr(pairURL, side: 560)
            caption.stringValue = "Scan with the phone's Camera on your home Wi-Fi. The page opens already signed in.\n\nThis code works once and expires in \(left) seconds."
        } else {
            image.image = nil; timer?.invalidate()
            caption.stringValue = "That code expired. Close this window and choose Connect a Phone again."
        }
    }
    func windowWillClose(_ n: Notification) { timer?.invalidate(); image.image = nil; pairURL = "" }
}

// Setup: shown the first time the app runs, and under Setup… in the menu afterwards. One window for
// the things a new person has to decide: speech on this Mac (a 650 MB download) or speech services,
// the microphone permission, voice and talk shortcut, the speech services the phone page uses, the port.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDone") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDone") }
    }
    var window: NSWindow?
    var timer: Timer?
    let modelStatus = NSTextField(labelWithString: ""), modelButton = NSButton(title: "", target: nil, action: nil), spinner = NSProgressIndicator()
    let micStatus = NSTextField(labelWithString: ""), micButton = NSButton(title: "", target: nil, action: nil)
    let voicePop = NSPopUpButton(), keyPop = NSPopUpButton()
    let portField = NSTextField(), addressLabel = NSTextField(labelWithString: ""), problem = NSTextField(wrappingLabelWithString: "")
    let needStatus = NSTextField(wrappingLabelWithString: ""), modePop = NSPopUpButton()

    static var modelsOnDisk: Bool {
        let dir = NSHomeDirectory() + "/Library/Application Support/FluidAudio/Models"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix("parakeet") }
    }

    func header(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.font = .boldSystemFont(ofSize: 13); return l }
    func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 470; return l
    }
    func label(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.alignment = .right; return l }

    func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "HerdrVoice Setup"; w.isReleasedWhenClosed = false; w.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        modelButton.bezelStyle = .rounded; modelButton.target = self; modelButton.action = #selector(getModels)
        micButton.bezelStyle = .rounded; micButton.target = self; micButton.action = #selector(askMic)
        modePop.addItems(withTitles: ["This Mac only", "This Mac and phones on my network"])
        needStatus.preferredMaxLayoutWidth = 330; needStatus.setContentHuggingPriority(.required, for: .vertical)
        for v in voices { voicePop.addItem(withTitle: v.title) }
        for sc in shortcuts { keyPop.addItem(withTitle: "Hold " + sc.title) }
        problem.textColor = .systemRed; problem.preferredMaxLayoutWidth = 470
        let modelRow = NSStackView(views: [modelStatus, spinner, modelButton]); modelRow.spacing = 8
        let micRow = NSStackView(views: [micStatus, micButton]); micRow.spacing = 8
        let portRow = NSStackView(views: [portField, addressLabel]); portRow.spacing = 8
        let phone = NSButton(title: "Connect a Phone…", target: self, action: #selector(connectPhone)); phone.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(finish)); done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [phone, NSView(), done]); buttons.distribution = .fill
        let grid = NSGridView(views: [
            [header("What it needs"), NSGridCell.emptyContentView],
            [label("Programs"), needStatus],
            [header("Speech on this Mac"), NSGridCell.emptyContentView],
            [label("Models"), modelRow],
            [label("Microphone"), micRow],
            [hint("Speech never leaves this Mac. The models are a one-time download of about 650 MB, and nothing can be said or heard until they are loaded. The phone page uses them too, through this app."), NSGridCell.emptyContentView],
            [header("Talking"), NSGridCell.emptyContentView],
            [label("Voice"), voicePop],
            [label("Talk shortcut"), keyPop],
            [header("Where you talk from"), NSGridCell.emptyContentView],
            [label("Use it from"), modePop],
            [label("Port"), portRow],
            [hint("This Mac only: nothing on the network can reach it. With phones: it also listens on this Mac's network address, and a phone needs the certificate once (Connect a Phone). Changing either setting restarts the server, and phones connected before have to be connected again."), NSGridCell.emptyContentView],
            [problem, NSGridCell.emptyContentView],
            [buttons, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for r in 0..<grid.numberOfRows where grid.cell(atColumnIndex: 1, rowIndex: r).contentView == nil { // a header, hint or button row: full width
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: r, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
        }
        grid.cell(for: buttons)?.xPlacement = .fill
        for r in 0..<grid.numberOfRows where r > 0 && (grid.cell(atColumnIndex: 0, rowIndex: r).contentView as? NSTextField)?.font == NSFont.boldSystemFont(ofSize: 13) { grid.row(at: r).topPadding = 12 }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                                     grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22)])
        w.contentView = content
        content.layoutSubtreeIfNeeded(); w.setContentSize(content.fittingSize) // as tall as its contents, no more
        window = w
    }
    func fill() { // show what is set now
        portField.stringValue = String(savedPort); modePop.selectItem(at: phonesOn ? 1 : 0)
        addressLabel.stringValue = phonesOn && !savedAddress.isEmpty ? "phones use \(savedAddress)" : ""
        var missing: [String] = []
        if !toolFound("hc") { missing.append("herdr-core (hc) is not installed. herdr-voice talks to agent sessions through it, so nothing works without it.") }
        if !toolFound("bun") { missing.append("bun is not installed. The server runs on it.") }
        if !toolFound("ffmpeg") { missing.append("ffmpeg is not installed. Only the phone page needs it.") }
        needStatus.stringValue = missing.isEmpty ? "herdr-core (hc), bun and ffmpeg found" : missing.joined(separator: "\n")
        needStatus.textColor = toolFound("hc") && toolFound("bun") ? .labelColor : .systemRed
        addressLabel.textColor = .secondaryLabelColor
        voicePop.selectItem(at: voices.firstIndex { $0.id == currentVoice } ?? 0)
        keyPop.selectItem(at: shortcutIndex)
        problem.stringValue = ""
        refresh()
    }
    func refresh() { // the two things that change while the window is open
        let c = Controller.shared
        if c.localReady { modelStatus.stringValue = "Ready"; modelButton.isHidden = true; spinner.stopAnimation(nil) }
        else if c.localLoading { modelStatus.stringValue = SetupWindow.modelsOnDisk ? "Loading…" : "Downloading (about 650 MB)…"; modelButton.isHidden = true; spinner.startAnimation(nil) }
        else { modelStatus.stringValue = SetupWindow.modelsOnDisk ? "Downloaded, not loaded" : "Not downloaded"
               modelButton.title = SetupWindow.modelsOnDisk ? "Load" : "Download (about 650 MB)"; modelButton.isHidden = false; spinner.stopAnimation(nil) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus.stringValue = "Allowed"; micButton.isHidden = true
        case .notDetermined: micStatus.stringValue = "Not asked yet"; micButton.title = "Allow…"; micButton.isHidden = false
        default: micStatus.stringValue = "Refused"; micButton.title = "Open System Settings…"; micButton.isHidden = false
        }
    }
    func open() {
        if window == nil { build() }
        fill()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc func getModels() { let c = Controller.shared; Task { await c.loadLocalSpeech(); self.refresh() }; refresh() }
    @objc func askMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } } }
        else if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }
    // Saving may restart the server (mode or port changed), so what follows waits for that.
    @objc func connectPhone() {
        guard save() else { return }
        guard phonesOn else { problem.stringValue = "Choose \"This Mac and phones on my network\" first."; return }
        Task { await self.applyServerChange(); Controller.shared.connect.open() }
    }
    @objc func finish() { if save() { SetupWindow.done = true; window?.close(); Task { await self.applyServerChange() } } }
    var serverChanged = false
    func applyServerChange() async {
        guard serverChanged else { return }
        serverChanged = false
        await Controller.shared.restartServer()
        fill()
    }
    func save() -> Bool { // false, with the reason shown, if something entered cannot be used
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)), (1024...65534).contains(port) else { problem.stringValue = "The port has to be a number from 1024 to 65534."; return false }
        do {
            if port != savedPort { try (String(port) + "\n").write(toFile: stateDir + "/port", atomically: true, encoding: .utf8); serverChanged = true }
            let wantPhones = modePop.indexOfSelectedItem == 1
            if wantPhones != phonesOn { try ((wantPhones ? "network" : "local") + "\n").write(toFile: stateDir + "/mode", atomically: true, encoding: .utf8); serverChanged = true }
            try (voices[max(0, voicePop.indexOfSelectedItem)].id + "\n").write(toFile: stateDir + "/voice", atomically: true, encoding: .utf8)
        } catch { problem.stringValue = "Could not save: \(error.localizedDescription)"; return false }
        let ctl = Controller.shared
        if keyPop.indexOfSelectedItem != shortcutIndex {
            shortcutIndex = keyPop.indexOfSelectedItem
            if !delegate.registerHotKey() { problem.stringValue = "\(shortcutTitle) is taken by something else. Pick another shortcut."; return false }
        }
        problem.stringValue = ""; return true
    }
    func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil }
}

final class TalkButton: NSView {
    var downAt = NSPoint.zero, dragging = false
    override func draw(_ dirty: NSRect) {
        let phase = Controller.shared.phase
        let color: NSColor = [.idle: NSColor(calibratedRed: 0.88, green: 0.51, blue: 0.24, alpha: 0.95), .recording: .systemRed,
                              .thinking: .systemGray, .speaking: .systemGreen][phase]!
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        let symbol = [.idle: "mic.fill", .recording: "waveform", .thinking: "ellipsis", .speaking: "speaker.wave.2.fill"][phase]!
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold)) {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { Controller.shared.hover(true) }
    override func mouseExited(with e: NSEvent) { Controller.shared.hover(false) }
    override func mouseDown(with e: NSEvent) { downAt = NSEvent.mouseLocation; dragging = false; Controller.shared.startTalking() }
    override func mouseDragged(with e: NSEvent) {
        let now = NSEvent.mouseLocation
        if !dragging && hypot(now.x - downAt.x, now.y - downAt.y) > 8 { dragging = true; Controller.shared.cancelTalking() }
        if dragging, let w = window {
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x + e.deltaX, y: w.frame.origin.y - e.deltaY))
        }
    }
    override func mouseUp(with e: NSEvent) {
        if dragging, let w = window { UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "origin") }
        else { Controller.shared.stopTalking() }
    }
    override func rightMouseDown(with e: NSEvent) {
        Task { @MainActor in
            await Controller.shared.refreshSessions()
            NSMenu.popUpContextMenu(Controller.shared.menu(), with: e, for: self)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var hotKey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ note: Notification) {
        let size: CGFloat = 56
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: screen.maxX - size - 24, y: screen.minY + 24)
        if let saved = UserDefaults.standard.string(forKey: "origin") {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.contains(p) }) { origin = p }
        }
        panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        let button = TalkButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = button
        Controller.shared.button = button
        panel.orderFrontRegardless()
        installHotKey()
        // The first time, Setup opens and nothing is downloaded until the person asks for it there.
        // Models already on this Mac are loaded either way: that costs no download.
        let firstRun = !SetupWindow.done
        if !firstRun || SetupWindow.modelsOnDisk { Task { @MainActor in await Controller.shared.loadLocalSpeech() } }
        Task { @MainActor in await Controller.shared.ensureServer(); if firstRun { Controller.shared.setup.open() }; await Controller.shared.listenForAnnouncements() }
        Task { @MainActor in await Controller.shared.speechWorker() }
    }
    func applicationWillTerminate(_ note: Notification) { MainActor.assumeIsolated { Controller.shared.stopChildren() } }
    // Carbon hot keys deliver both press and release, and keep working while Secure Input is on.
    func installHotKey() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { if pressed { Controller.shared.startTalking() } else { Controller.shared.stopTalking() } }
            return noErr
        }, 2, &types, nil, nil)
        registerHotKey()
    }
    @discardableResult func registerHotKey() -> Bool {
        if let old = hotKey { UnregisterEventHotKey(old); hotKey = nil }
        let sc = shortcuts[shortcutIndex]
        MainActor.assumeIsolated { Controller.shared.watchChord(sc.key == -1 ? sc.mods : nil) }
        if sc.key == -1 { return true }
        return RegisterEventHotKey(UInt32(sc.key), UInt32(sc.mods), EventHotKeyID(signature: OSType(0x48565643), id: 1),
                                   GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
}

// `HerdrVoice --selftest <audio file>`: load the local models, transcribe the file three times and
// voice a sentence three times, printing how long each took. No window, no server.
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > i + 1 {
    let clip = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        func clock<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
            let t = Date(); let v = try await work(); print(String(format: "%@: %.2fs", label, Date().timeIntervalSince(t))); return v
        }
        do {
            try await clock("load models") { try await LocalSpeech.shared.prepare(voice: "am_echo") }
            for n in 1...3 { let text = try await clock("speech-to-text #\(n)") { try await LocalSpeech.shared.transcribe(clip) }; if n == 1 { print("  heard: \(text)") } }
            for n in 1...3 {
                let wav = try await clock("text-to-speech #\(n)") { try await LocalSpeech.shared.speak("The backup finished at two fifteen, and it took about nine minutes.", voice: "am_echo") }
                if n == 1 { try wav.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "herdr-voice-selftest.wav")); print("  audio bytes: \(wav.count)") }
            }
        } catch { print("selftest failed: \(error)") }
        done.signal()
    }
    done.wait(); exit(0)
}

// `HerdrVoice --setup-preview <file.png>`: draw the Setup window into a picture and exit. Starts no
// server and registers no shortcut; for checking the layout.
if let i = CommandLine.arguments.firstIndex(of: "--setup-preview"), CommandLine.arguments.count > i + 1 {
    let out = CommandLine.arguments[i + 1]
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let s = SetupWindow(); s.build(); s.fill()
        s.window?.appearance = NSAppearance(named: .aqua) // dark text, so it shows on the picture's white background
        guard let v = s.window?.contentView else { exit(1) }
        v.layoutSubtreeIfNeeded()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print("drew \(Int(v.bounds.width))x\(Int(v.bounds.height)) to \(out)")
    }
    exit(0)
}

// A plain stop signal (as sent by `pkill` or a rebuild) should also take the server and speaker down.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { MainActor.assumeIsolated { Controller.shared.stopChildren() }; exit(0) }
termSource.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
