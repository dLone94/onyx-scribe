import Foundation

/// Detects a spoken "draft a reply from what's on screen" command and extracts
/// the user's intent. Deliberately explicit and conservative, like
/// CommandDetector / ToneSwitchCommand: drafting reads surrounding content and
/// GENERATES new text, so it must never be triggered by accident — only a clear
/// leading phrase counts; everything else is normal dictation.
///
/// "reply, tell them Thursday works and ask for the deck"
///   → intent: "tell them Thursday works and ask for the deck"
public enum DraftCommand {
    /// Leading phrases that put us in draft mode. Longest-first at match time so
    /// "draft a reply" wins over "draft". A trailing "that"/"to that"/"saying"
    /// filler after the verb is swallowed.
    private static let prefixes = [
        "draft a reply", "draft a response", "write a reply", "write back",
        "reply with", "reply saying", "reply to that", "reply", "respond with",
        "respond to that", "respond", "answer that", "draft",
    ]

    /// Returns the intent (text after the trigger phrase) when `raw` opens with a
    /// draft trigger, else nil. The intent must be non-empty — a bare "reply"
    /// with nothing after it is treated as normal dictation, not a draft.
    public static func detect(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single leading filler the ASR often keeps ("ok reply …").
        for lead in ["okay ", "ok ", "so ", "um ", "uh "] where t.lowercased().hasPrefix(lead) {
            t = String(t.dropFirst(lead.count)); break
        }
        let lower = t.lowercased()
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            // Match the phrase only as a whole word run followed by a boundary
            // (space, comma, colon) — "replying to customers" must NOT match.
            guard lower.hasPrefix(prefix) else { continue }
            let after = t.index(t.startIndex, offsetBy: prefix.count)
            let boundary = t[after...].first
            if let b = boundary, !(b == " " || b == "," || b == ":" ) { continue }
            var intent = String(t[after...])
            // Drop connective filler between the verb and the intent.
            intent = intent.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
            for filler in ["that ", "to that ", "saying ", "with ", "and say ", "and tell them "] {
                if intent.lowercased().hasPrefix(filler) {
                    intent = String(intent.dropFirst(filler.count)); break
                }
            }
            intent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
            return intent.isEmpty ? nil : intent
        }
        return nil
    }
}
