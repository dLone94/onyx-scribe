import Foundation

/// The pure half of streaming injection: *what* bytes to paste, and *which
/// terminal decision* a streaming cleanup attempt reached. Split out of
/// `DictationController.runStreamingCleanup` so the adversarial-review rules
/// (F6/F8/F10/F11/F13) are unit-tested instead of trusted — the controller keeps
/// only the effectful parts (talking to the model, pasting, cancellation).
///
/// Nothing here touches AppKit, the pasteboard, or Accessibility.
public enum StreamInjectionPlan {

    /// F8: the first chunk committed into the document is left-trimmed (the
    /// model often opens a snapshot with whitespace), then given a mechanical
    /// leading space when it has to join the word already before the caret.
    public static func earlyChunk(_ chunk: String, needsLeadingSpace: Bool) -> String {
        let trimmed = String(chunk.drop(while: { $0.isWhitespace }))
        guard needsLeadingSpace, let first = trimmed.first,
              first.isLetter || first.isNumber else { return trimmed }
        return " " + trimmed
    }

    /// F13: the single paste used when no early chunk was ever committed (the
    /// output was short, or no boundary ever settled). Falls back to the raw
    /// transcript when the model produced nothing usable, so a dictation never
    /// silently vanishes.
    public static func whole(snapshot: String, fallbackRaw: String,
                             needsLeadingSpace: Bool) -> String {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let built = trimmed.isEmpty ? fallbackRaw : trimmed
        guard needsLeadingSpace, let first = built.first,
              first.isLetter || first.isNumber else { return built }
        return " " + built
    }

    /// The trailing paste after an early chunk was committed, right-trimmed.
    ///
    /// - Returns: `nil` when the model revised text it had already committed
    ///   (F11) — the caller must degrade rather than paste a garbled overlap;
    ///   `""` when the early chunk turned out to be the entire output, so there
    ///   is nothing left to paste.
    public static func tail(finalSnapshot: String, earlyChunk: String) -> String? {
        guard let remainder = StreamChunker.remainder(
            finalText: finalSnapshot, earlyChunk: earlyChunk) else { return nil }
        return String(remainder.reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}

/// The terminal decision for a streaming cleanup attempt, derived only from the
/// signals the model and the injector produced. Pure, so the precedence between
/// "canceled", "focus moved away" and "the model threw" is unit-tested rather
/// than re-derived by eye every time the pipeline changes.
public enum StreamOutcome: Equatable {
    /// Esc / a new generation superseded us. `injected` is whatever actually
    /// landed before that (F6) — the caller keeps it as the voice-edit target.
    case canceled(injected: String)
    /// Something landed, but the result is not the clean full text: mark degraded.
    case degradedAfterCommit(injected: String)
    /// The model threw before anything was pasted — safe to retry on Ollama.
    case failedBeforeCommit
    /// No terminal condition; the caller finishes the paste normally.
    case proceed(injected: String)

    /// Precedence, highest first:
    /// 1. **canceled** outranks everything — a superseded generation must never
    ///    be treated as a focus/aborted-model problem, and must never paste more.
    /// 2. **focusLost** — if nothing landed this is indistinguishable from a
    ///    cancel (nothing to tell the user about); if something did land, the
    ///    document holds a partial, so degrade.
    /// 3. **failed** — retryable on the other engine ONLY while nothing has been
    ///    pasted; once an early chunk is in the document a retry would duplicate
    ///    text, so degrade instead.
    public static func resolve(canceled: Bool,
                               focusLost: Bool,
                               failed: Bool,
                               committedEarly: Bool,
                               injected: String) -> StreamOutcome {
        if canceled { return .canceled(injected: injected) }
        if focusLost {
            return injected.isEmpty ? .canceled(injected: "")
                                    : .degradedAfterCommit(injected: injected)
        }
        if failed {
            return committedEarly ? .degradedAfterCommit(injected: injected)
                                  : .failedBeforeCommit
        }
        return .proceed(injected: injected)
    }
}
