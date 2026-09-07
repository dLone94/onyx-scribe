import Foundation

/// Mechanical post-ASR replacement pass. Lines in ~/.flowclone/vocabulary.txt
/// of the form `wrong => right` are applied to the raw transcript BEFORE the
/// LLM sees it — deterministic fixes for terms the ASR reliably fumbles
/// (research: local Whisper/Parakeet have weak built-in vocabulary biasing, so
/// a dictionary pass is the robust local answer).
///
/// Matching is case-insensitive and **token-bounded**: a rule matches only
/// where it is not glued to a letter or digit on either side, so `ai => AI`
/// fixes "ai" and "ai-driven" but never corrupts "said" or "aid", in Latin and
/// Cyrillic text alike. The replacement is inserted exactly as configured.
public enum VocabularyCorrector {
    public struct Rule: Equatable {
        public let wrong: String
        public let right: String
        public init(wrong: String, right: String) {
            self.wrong = wrong
            self.right = right
        }
    }

    /// Hot-path entry: applies the on-disk vocabulary at `fileURL` with a
    /// modification-date cache — the file is re-read and re-compiled only when
    /// it actually changed. iOS passes its App Group vocabulary.txt.
    public static func apply(_ text: String, fileURL: URL) -> String {
        applyCompiled(text, cache.compiledRules(for: fileURL))
    }

#if os(macOS)
    /// macOS convenience: the user's ~/.flowclone/vocabulary.txt.
    public static func apply(_ text: String) -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/vocabulary.txt")
        return apply(text, fileURL: path)
    }
#endif

    /// Core, file-independent (unit-testable): applies `wrong => right` lines.
    public static func apply(_ text: String, rulesText: String) -> String {
        applyCompiled(text, parseRules(rulesText).compactMap(compile))
    }

    /// Parses `wrong => right` lines; `#` comments and plain vocab lines are ignored.
    public static func parseRules(_ rulesText: String) -> [Rule] {
        rulesText.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.contains("=>") else { return nil }
            let parts = trimmed.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let wrong = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty else { return nil }
            return Rule(wrong: wrong, right: right)
        }
    }

    // MARK: - Compiled rules

    struct CompiledRule {
        let regex: NSRegularExpression
        let template: String
    }

    /// One rule → one anchored regex. The phrase itself is escaped (literal);
    /// the lookarounds are the token boundary: no letter/digit may touch either
    /// end. `\p{L}\p{N}` (not `\b`) so Cyrillic and other scripts bound
    /// correctly, while punctuation, hyphens, and whitespace all count as edges.
    static func compile(_ rule: Rule) -> CompiledRule? {
        let pattern = "(?<![\\p{L}\\p{N}])"
            + NSRegularExpression.escapedPattern(for: rule.wrong)
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return CompiledRule(regex: regex,
                            template: NSRegularExpression.escapedTemplate(for: rule.right))
    }

    static func applyCompiled(_ text: String, _ rules: [CompiledRule]) -> String {
        var out = text
        for rule in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = rule.regex.stringByReplacingMatches(
                in: out, options: [], range: range, withTemplate: rule.template)
        }
        return out
    }

    // MARK: - File cache

    private static let cache = RuleCache()

    /// Modification-date-keyed cache of the compiled on-disk rules, so the hot
    /// path stops re-reading and re-parsing the vocabulary on every utterance.
    /// NSLock-guarded (never held across suspension — all sync work).
    private final class RuleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var compiled: [CompiledRule] = []
        private var cachedModDate: Date?
        private var cachedPath: String?

        func compiledRules(for url: URL) -> [CompiledRule] {
            let modDate = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            lock.lock()
            defer { lock.unlock() }
            if cachedPath == url.path, cachedModDate == modDate {
                return compiled
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            compiled = VocabularyCorrector.parseRules(text)
                .compactMap(VocabularyCorrector.compile)
            cachedModDate = modDate
            cachedPath = url.path
            return compiled
        }
    }
}

/// Mechanical filler strip for the no-LLM fast path ("um yes" → "Yes").
public enum TextCleanup {
    private static let fillerWords: Set<String> = ["um", "uh"]

    /// `capitalize: false` when inserting mid-sentence (context-aware fast path).
    ///
    /// Drops whole "um"/"uh" tokens ONLY — matching on word boundaries, never as
    /// substrings, so "forum", "premium", and "aluminum" survive intact (a raw
    /// `replacingOccurrences(of: "um ")` would eat those). Surrounding punctuation
    /// on the filler token itself ("Um,") is tolerated.
    public static func stripFillers(_ text: String, capitalize: Bool = true) -> String {
        let kept = text.split(separator: " ", omittingEmptySubsequences: true).filter { token in
            let bare = token.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
            return !fillerWords.contains(bare)
        }
        let out = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !out.isEmpty else { return text }
        return capitalize
            ? out.prefix(1).uppercased() + out.dropFirst()
            : out.prefix(1).lowercased() + out.dropFirst()
    }
}
