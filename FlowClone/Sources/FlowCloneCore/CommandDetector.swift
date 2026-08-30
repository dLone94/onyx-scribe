import Foundation

/// Keyword-gated detection of voice-editing commands aimed at the PREVIOUS injection.
/// Deliberately conservative: only short, unambiguous command phrases match —
/// anything else is treated as normal dictation (safer to keep words than delete them).
public enum CommandDetector {
    public enum Kind {
        case delete   // remove the last injected text
        case rewrite  // transform the last injected text per the spoken command
    }

    public static func detect(_ raw: String) -> Kind? {
        let t = normalize(raw)

        let deletePhrases = [
            "scratch that", "delete that", "never mind", "nevermind",
            "undo that", "forget that", "erase that",
            // Common ASR near-misses for the above.
            "scratch it", "scratch dat", "delete it", "delete last",
        ]
        // Pure-delete must be essentially the whole utterance.
        if t.count < 25, deletePhrases.contains(where: { t == $0 || t.hasPrefix($0) }) {
            return .delete
        }

        let rewritePrefixes = [
            "make that", "make it", "make this", "rewrite that", "rewrite it",
            "reword that", "reword it", "turn that", "turn it", "format that",
            "format it", "capitalize that", "all caps", "change that to", "change it to",
        ]
        // Short utterances only — a long sentence starting with "make it…" is content.
        if t.count < 80, rewritePrefixes.contains(where: { t.hasPrefix($0) }) {
            return .rewrite
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
    }
}
