import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT ASR (CoreML, runs on the Apple Neural Engine).
/// `@unchecked Sendable`: `asrManager` is written only in `load()`, before the
/// instance is shared; see the ASREngine protocol's ownership rule.
final class Transcriber: @unchecked Sendable {
    private var asrManager: AsrManager?

    /// Downloads (first run) and loads the Parakeet models.
    func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
    }

    /// Language pin — without it Parakeet v3 auto-detects per utterance and can
    /// flip script on short commands ("scratch that" once came out "Скраждат.").
    /// Override: defaults write com.todor.flowclone language <code, e.g. "bg">
    private var language: Language? {
        Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "en")
    }

    /// Transcribes 16 kHz mono samples to raw text.
    /// Each utterance is independent, so a fresh decoder state per call is correct.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeDetailed(samples, languageCode: language?.rawValue).text
    }

    /// Transcribe forcing a specific language's script filter (nil = auto), and
    /// return the confidence alongside the text. The confidence discriminates a
    /// correct-script decode from a forced-wrong-script one, which is what the
    /// EN⇄BG auto-detect arbitration relies on.
    func transcribeDetailed(_ samples: [Float], languageCode: String?)
        async throws -> (text: String, confidence: Float) {
        guard let asrManager else { throw TranscriberError.notLoaded }
        let forced = languageCode.flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make()
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState, language: forced)
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.confidence)
    }

    /// Transcribe once per candidate language and keep the highest-confidence
    /// decode. For EN⇄BG (Latin vs Cyrillic) the winning margin is large
    /// (~0.9 vs ~0.2), so this reliably picks the spoken language — including
    /// short commands, where forcing the wrong script scores far lower.
    func transcribeAuto(_ samples: [Float], candidates: [String]) async throws
        -> (text: String, code: String, confidence: Float) {
        var best: (text: String, code: String, confidence: Float) = ("", candidates.first ?? "en", -1)
        for code in candidates {
            let r = try await transcribeDetailed(samples, languageCode: code)
            if r.confidence > best.confidence { best = (r.text, code, r.confidence) }
            // Decisive decode — skip the remaining candidates. Margins are wide
            // (right language ~0.9+, wrong-script ~0.2–0.4), so 0.75 never locks
            // in a wrong language but saves a full decode (~180ms) on nearly
            // every dictation. Callers order the likely language first.
            if best.confidence >= 0.75 { break }
        }
        return best
    }

    /// Transcribes an audio file (any format/rate — FluidAudio resamples).
    func transcribe(url: URL) async throws -> String {
        guard let asrManager else { throw TranscriberError.notLoaded }
        var decoderState = TdtDecoderState.make()
        let result = try await asrManager.transcribe(url, decoderState: &decoderState, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: Error {
        case notLoaded
    }
}
