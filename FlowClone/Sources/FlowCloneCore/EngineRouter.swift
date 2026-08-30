import Foundation

/// Single source of truth for which engine cleans a transcript. Pure —
/// callers supply every input — so the whole truth table is unit-tested in
/// FlowCloneChecks and a future "prefer the warm engine" edit can't silently
/// reroute a language to an engine that can't handle it (which is exactly how
/// the prefer-ready-Ollama regression slipped in and cost English dictation
/// ~1s per utterance on the prewarmed Apple path).
///
/// `detectionReliable`: whether `languageCode` can be trusted. Each caller
/// computes it from the ASR engine it ACTUALLY uses — a pinned language is
/// always reliable; Parakeet's confidence arbitration is reliable; Whisper
/// under auto-language is NOT (its default `transcribeAuto` just reports the
/// first candidate), so a "en" label there may really be Bulgarian.
public enum EngineRouter {
    public enum Kind: Equatable { case apple, ollama }

    /// Rules, in order — later rules only see what earlier ones let through:
    /// 1. explicit `ollama` preference → Ollama (quality-seekers keep the 8B).
    /// 2. non-English → Ollama. Apple FM is only trusted for English; this
    ///    OUTRANKS an explicit `apple` preference (honoring "apple" for
    ///    Bulgarian would send it to a model that can't do it).
    /// 3. unreliable detection → Ollama. A possibly-mislabeled "en" must not
    ///    reach Apple; Ollama is safe for both languages it could really be.
    /// 4. a restyle tone (Casual/Work/Formal/…) → Ollama. Apple FM does great
    ///    cleanup but IGNORES the "rewrite in this style" instruction, so tones
    ///    silently come out un-styled on it; only gemma honors them. This also
    ///    outranks an explicit `apple` preference — a wanted tone beats speed.
    ///    (The Faithful/Verbatim tones carry no instruction, so they skip this
    ///    and keep the fast Apple path.)
    /// 5. English, reliably detected, no restyle tone → Apple when available
    ///    (fast, prewarmed), else Ollama (Macs without Apple Intelligence).
    public static func cleanupEngine(languageCode: String,
                                     preference: String,
                                     appleAvailable: Bool,
                                     detectionReliable: Bool,
                                     restyleTone: Bool = false) -> Kind {
        if preference == "ollama" { return .ollama }
        if languageCode != "en" { return .ollama }
        if !detectionReliable { return .ollama }
        if restyleTone { return .ollama }
        return appleAvailable ? .apple : .ollama
    }
}
