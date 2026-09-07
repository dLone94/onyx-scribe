import Foundation

/// Abstraction over local ASR engines so the pipeline can swap between
/// Parakeet (fast, ~110ms) and Whisper large-v3-turbo (max accuracy).
///
/// `Sendable`: engine instances cross from the main actor into the decode's
/// async work. The concrete engines are `@unchecked Sendable` under a shared
/// ownership rule — their mutable state is written only inside `load()`,
/// before the instance is shared (`DictationController` swaps engines only
/// while idle and snapshots the instance per session), and transcribe calls
/// are serialized by the controller (the final decode awaits any in-flight
/// partial).
protocol ASREngine: AnyObject, Sendable {
    var displayName: String { get }
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// Decode with a language captured by the owning session rather than a
    /// setting that may change while the model is working.
    func transcribe(_ samples: [Float], languageCode: String) async throws -> String
    /// Transcribe, auto-selecting the best of `candidates` (language codes) by
    /// decode confidence. Returns the winning text, its language code, and its
    /// confidence. Enables EN⇄BG auto-detect without the free-language-ID
    /// short-command script flip: it only ever chooses among the user's own
    /// languages, and a wrong-script decode scores far lower.
    func transcribeAuto(_ samples: [Float], candidates: [String]) async throws
        -> (text: String, code: String, confidence: Float)
}

extension ASREngine {
    func transcribe(_ samples: [Float], languageCode: String) async throws -> String {
        try await transcribe(samples)
    }

    /// Default: no confidence arbitration — transcribe with the engine's own
    /// pinned language and report the first candidate. Used by WhisperEngine,
    /// which doesn't expose comparable per-decode confidence.
    func transcribeAuto(_ samples: [Float], candidates: [String]) async throws
        -> (text: String, code: String, confidence: Float) {
        let code = candidates.first ?? "en"
        return (try await transcribe(samples, languageCode: code), code, 1)
    }
}

extension Transcriber: ASREngine {
    var displayName: String { "Parakeet (fast)" }
}
