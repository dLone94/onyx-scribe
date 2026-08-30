import Foundation
import WhisperKit

/// Whisper large-v3-turbo via WhisperKit (CoreML/ANE) — the max-accuracy option
/// (5.2% WER on clean English per the WhisperKit paper). Model (~0.6 GB)
/// downloads from Hugging Face on first load.
/// `@unchecked Sendable`: `pipe` is written only in `load()`, before the
/// instance is shared; see the ASREngine protocol's ownership rule.
final class WhisperEngine: ASREngine, @unchecked Sendable {
    private var pipe: WhisperKit?

    var displayName: String { "Whisper large-v3-turbo (accurate)" }

    func load() async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(model: "large-v3_turbo")
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw EngineError.notLoaded }
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(language: language)
        )
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum EngineError: Error { case notLoaded }
}
