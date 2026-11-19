// Speech on this Mac, with no network: Parakeet for speech-to-text and Kokoro for text-to-speech,
// through FluidAudio. The models are downloaded on first use (about 650 MB) and then kept loaded,
// so each call is only the model's own work.
import AVFoundation
import FluidAudio
import Foundation

actor LocalSpeech {
    static let shared = LocalSpeech()
    private var asr: AsrManager?
    private var tts: KokoroAneManager?
    private(set) var ready = false

    func prepare(voice: String) async throws {
        if asr == nil {
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if tts == nil {
            let kokoro = KokoroAneManager(version: .v3)
            try await kokoro.initialize(preloadVoices: [voice])
            tts = kokoro
        }
        ready = true
    }

    func transcribe(_ clip: URL) async throws -> String {
        guard let asr else { throw VoiceError(message: "Local speech is not loaded yet.") }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(clip, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns WAV data ready for AVAudioPlayer.
    func speak(_ text: String, voice: String) async throws -> Data {
        guard let tts else { throw VoiceError(message: "Local speech is not loaded yet.") }
        return try await tts.synthesize(text: text, voice: voice)
    }
}

func logLine(_ text: String) { // timings and one-line events, into the same log as the server
    let line = "[app] \(text)\n"
    if let h = FileHandle(forWritingAtPath: stateDir + "/app.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
}
func timed<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
    let start = Date(); let value = try await work()
    logLine(String(format: "%@ %.2fs", label, Date().timeIntervalSince(start))); return value
}
