import Foundation

/// A transform the user can apply to a selected passage by voice. Unlike the
/// dictation-mode detectors (which must avoid firing on ordinary speech), the
/// transform gesture has ALREADY declared intent, so detection is permissive:
/// a recognized shortcut maps to a canned operation, and anything else becomes a
/// `.freeform` instruction. The kind carries its own model directive and a short
/// label for the confirmation pill.
public enum TransformKind: Equatable, Sendable {
    case formal
    case casual
    case concise
    case expand
    case bullets
    case grammar
    case summarize
    case translate(code: String, name: String)
    case freeform(String)

    /// Stable id for the JSON payload's "kind" field and for prompt tests.
    public var id: String {
        switch self {
        case .formal:    return "formal"
        case .casual:    return "casual"
        case .concise:   return "concise"
        case .expand:    return "expand"
        case .bullets:   return "bullets"
        case .grammar:   return "grammar"
        case .summarize: return "summarize"
        case .translate: return "translate"
        case .freeform:  return "freeform"
        }
    }

    /// Short label for the pill confirmation ("Formal", "→ Bulgarian").
    public var label: String {
        switch self {
        case .formal:    return "Formal"
        case .casual:    return "Casual"
        case .concise:   return "Concise"
        case .expand:    return "Expanded"
        case .bullets:   return "Bulleted"
        case .grammar:   return "Grammar"
        case .summarize: return "Summary"
        case .translate(_, let name): return "→ \(name)"
        case .freeform:  return "Rewritten"
        }
    }

    /// The operation directive embedded in the transform system prompt. Every
    /// directive reasserts "preserve facts/names/numbers and the original
    /// language" so the model never drifts into inventing or answering.
    public var directive: String {
        switch self {
        case .formal:
            return "Rewrite the selection in a more formal, professional register. Preserve every fact, name, number, and the original language."
        case .casual:
            return "Rewrite the selection in a warmer, more casual and conversational register. Preserve every fact, name, number, and the original language."
        case .concise:
            return "Make the selection more concise: cut redundancy and tighten the wording while preserving all information, names, numbers, and the original language."
        case .expand:
            return "Expand the selection with slightly more detail and clearer phrasing, without inventing facts, names, or numbers. Keep the original language."
        case .bullets:
            return "Reformat the selection as a clear Markdown bullet list — one point per line — preserving all information and the original language."
        case .grammar:
            return "Fix grammar, spelling, punctuation, and awkward phrasing in the selection. Change nothing else; preserve meaning, names, numbers, and the original language."
        case .summarize:
            return "Summarize the selection into its essential points, clearly shorter than the original. Preserve the key facts, names, and numbers, and keep the original language."
        case .translate(_, let name):
            return "Translate the selection into \(name). Output only the \(name) translation, preserving names and numbers; do not add or omit information."
        case .freeform(let instruction):
            return "Apply this instruction to the selection: \"\(instruction)\". Change only what the instruction requires; preserve the original language unless the instruction explicitly says otherwise, and never invent facts, names, or numbers."
        }
    }
}

/// Maps a spoken transform command to a `TransformKind`. Always returns a kind
/// (never nil): the gesture already committed to transforming, so an
/// unrecognized utterance becomes a `.freeform` instruction rather than a
/// no-op. `languages` supplies the known translation targets (code, name).
public enum SelectionCommand {

    private static let leadingFillers = [
        "okay ", "ok ", "so ", "um ", "uh ", "please ", "can you ", "could you ",
        "make this ", "make it ", "turn this ", "turn it ",
    ]

    public static func detect(_ raw: String, languages: [(code: String, name: String)] = []) -> TransformKind {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single leading filler/politeness so "please make this formal"
        // and "make it formal" both resolve to .formal.
        var changed = true
        while changed {
            changed = false
            for lead in leadingFillers where t.lowercased().hasPrefix(lead) {
                t = String(t.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        let l = t.lowercased()

        // Translate — an explicit translate verb plus a known target language.
        if l.contains("translat") {
            for lang in languages.sorted(by: { $0.name.count > $1.name.count })
            where l.contains(lang.name.lowercased()) {
                return .translate(code: lang.code, name: lang.name)
            }
        }

        // Summarize (explicit only — it removes information).
        if l.contains("summ") || l.contains("tl;dr") || l.contains("tldr")
            || l.contains("sum this up") || l.contains("sum it up") {
            return .summarize
        }
        // Bullets / list.
        if l.contains("bullet") || l.contains("bulleted")
            || l.contains("as a list") || l.contains("into a list")
            || l.contains("a list") {
            return .bullets
        }
        // Grammar / proofread.
        if l.contains("grammar") || l.contains("proofread") || l.contains("spelling")
            || l.contains("typo") || l.contains("fix this") || l.contains("correct this")
            || l.contains("clean this up") || l.contains("clean it up") {
            return .grammar
        }
        // Formal.
        if l.contains("formal") || l.contains("professional")
            || l.contains("polished") || l.contains("polish") {
            return .formal
        }
        // Casual.
        if l.contains("casual") || l.contains("informal")
            || l.contains("relaxed") || l.contains("friendl") || l.contains("chill") {
            return .casual
        }
        // Concise / shorten.
        if l.contains("concise") || l.contains("shorter") || l.contains("shorten")
            || l.contains("tighten") || l.contains("trim") || l.contains("condense")
            || l.contains("briefer") || l.contains("more brief") {
            return .concise
        }
        // Expand / lengthen.
        if l.contains("expand") || l.contains("longer") || l.contains("elaborate")
            || l.contains("flesh") {
            return .expand
        }
        // Anything else: the spoken words are a freeform instruction.
        return .freeform(t)
    }
}

/// Encodes a transform request as a JSON string for the model's user turn.
/// JSON escaping (quotes, backslashes, control chars) makes the untrusted
/// `selection` structurally inert — no delimiter it contains can break out of
/// its field. Semantic injection ("ignore your instructions") is handled
/// separately by the system prompt's inert-selection clause.
public enum TransformPayload {
    public static func json(kind: TransformKind, command: String, selection: String) -> String {
        struct P: Encodable { let kind: String; let command: String; let selection: String }
        let encoder = JSONEncoder()
        // Stable bytes make prompt equivalence checks deterministic and avoid
        // sending needlessly different token sequences for identical requests.
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try? encoder.encode(
            P(kind: kind.id, command: command, selection: selection))
        guard let encoded, let s = String(data: encoded, encoding: .utf8) else { return "{}" }
        return s
    }
}
