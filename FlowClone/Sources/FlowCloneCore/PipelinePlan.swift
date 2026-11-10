import Foundation

// The pure decisions inside the dictation pipeline, lifted out of
// `DictationController.runPipeline` so they are unit-tested instead of
// re-derived by eye: WHICH path turns the transcript into text, WHERE to fail
// over when a cleanup engine throws, and HOW a voice-edit rewrite joins the
// text before it. The controller keeps only the effects (models, AX, paste).

/// How a transcript becomes the text that gets pasted. Exactly one path runs
/// per utterance; the order of the rules below IS the product's precedence.
public enum CleanupPath: Equatable, Sendable {
    /// Context-aware drafting: write a finished message from the spoken intent.
    case draft
    /// "Speak one language, type another".
    case translate(to: String)
    /// Exactly as transcribed — no model, no filler strip.
    case verbatim
    /// No model: mechanical filler strip only (free tier, cleanup off, or an
    /// utterance too short to be worth a model pass).
    case mechanical
    /// Model cleanup with the live pill preview (and optional early paste).
    case streaming
    /// Model cleanup in one shot.
    case oneShot

    /// Precedence, highest first:
    /// 1. **draft** — an explicit "reply, tell them…" intent outranks
    ///    everything (the caller only detects it for paid users).
    /// 2. **translate** — a paid user with translate mode on, speaking a
    ///    language other than the target.
    /// 3. **verbatim** — the Verbatim tone means untouched, even for paid
    ///    users with cleanup on.
    /// 4. **mechanical** — free tier, cleanup switched off, or too short.
    /// 5. **streaming** / **oneShot** — full model cleanup.
    public static func decide(hasDraftIntent: Bool,
                              pro: Bool,
                              translateTo: String?,
                              detectedLanguage: String,
                              toneIsVerbatim: Bool,
                              cleanupEnabled: Bool,
                              skipForLength: Bool,
                              streamingPreview: Bool) -> CleanupPath {
        if hasDraftIntent { return .draft }
        if pro, let target = translateTo, target != detectedLanguage {
            return .translate(to: target)
        }
        if toneIsVerbatim { return .verbatim }
        if !pro || !cleanupEnabled || skipForLength { return .mechanical }
        return streamingPreview ? .streaming : .oneShot
    }
}

/// Where cleanup goes when the chosen engine throws before anything was
/// pasted. Symmetric, with one hard limit: Apple Intelligence is only ever a
/// fallback for English — it can't be trusted with other languages.
public enum CleanupFallback {
    /// - Returns: the engine to retry on, or `nil` when there is nowhere safe
    ///   to go (the caller then pastes the raw transcript, marked degraded).
    public static func engine(after failed: EngineRouter.Kind,
                              appleAvailable: Bool,
                              languageCode: String) -> EngineRouter.Kind? {
        switch failed {
        case .apple:
            return .ollama
        case .ollama:
            return appleAvailable && languageCode == "en" ? .apple : nil
        }
    }
}

/// Voice-edit rewrites ("make that formal") replace the previous injection.
public enum VoiceEdit {
    /// The text that replaces `previous`. The previous injection may begin
    /// with the mechanical joining space ("should" + " definitely"); the
    /// model's rewrite comes back trimmed, so that leading whitespace is
    /// restored — otherwise the rewrite glues onto the word before it.
    ///
    /// - Returns: `nil` when there is nothing to apply (empty rewrite, or a
    ///   rewrite identical to what is already there) — the caller must then
    ///   leave the document untouched.
    public static func replacement(previous: String, rewritten: String) -> String? {
        let trimmed = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lead = String(previous.prefix(while: { $0.isWhitespace }))
        let result = lead + trimmed
        return result == previous ? nil : result
    }

    /// Whether an utterance should be treated as an edit of the previous
    /// injection rather than as new dictation. All five must hold: no draft
    /// intent claimed it first, a paid user, a detected command, something
    /// previously injected, and the same destination app.
    public static func shouldHandle(hasDraftIntent: Bool,
                                    pro: Bool,
                                    commandDetected: Bool,
                                    hasPreviousInjection: Bool,
                                    sameApp: Bool) -> Bool {
        !hasDraftIntent && pro && commandDetected && hasPreviousInjection && sameApp
    }
}
