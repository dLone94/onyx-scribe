import Foundation

/// Learns the words YOU use. Scans your own past dictations (on-device, never
/// uploaded) for names and terms that recur but aren't in your dictionary yet,
/// so cleanup stops mis-spelling them over time. Pure + deterministic so it's
/// unit-tested; the app persists what it learns and feeds it back into cleanup.
///
/// This is a local-only feature by nature: it works precisely because all your
/// text already lives on your Mac — a cloud tool would have to hoard it to do this.
public enum StyleMemory {

    public struct Term: Equatable {
        public let text: String
        public let count: Int
        public init(text: String, count: Int) { self.text = text; self.count = count }
    }

    /// Extract learn-worthy terms from dictation history.
    /// - A candidate is a capitalized token (a likely proper noun / product name)
    ///   OR an ALL-CAPS acronym, that appears at least `minCount` times.
    /// - Sentence-initial-only capitalization is discounted: a word that is ONLY
    ///   ever seen at the start of a sentence isn't evidence it's a proper noun.
    /// - Common English words and anything already `known` are excluded.
    public static func learn(from history: [String],
                             known: Set<String> = [],
                             minCount: Int = 2,
                             limit: Int = 40) -> [Term] {
        let knownLower = Set(known.map { $0.lowercased() })

        // total occurrences, and how many were NOT at a sentence start.
        var total: [String: Int] = [:]
        var midSentence: [String: Int] = [:]
        var display: [String: String] = [:]   // canonical casing (first mid-sentence hit)

        for text in history {
            let tokens = tokenize(text)
            for (i, tok) in tokens.enumerated() {
                guard isCandidate(tok.word) else { continue }
                let key = tok.word.lowercased()
                if knownLower.contains(key) || stopwords.contains(key) { continue }
                total[key, default: 0] += 1
                let atStart = i == 0 || tokens[i - 1].endsSentence
                if !atStart {
                    midSentence[key, default: 0] += 1
                    if display[key] == nil { display[key] = tok.word }
                }
            }
        }

        var terms: [Term] = []
        for (key, n) in total where n >= minCount {
            // Need at least one mid-sentence sighting to trust it's a real noun,
            // not just a sentence-starter like "Send" or "The".
            guard (midSentence[key] ?? 0) >= 1 else { continue }
            terms.append(Term(text: display[key] ?? key, count: n))
        }
        // Most-used first; stable tiebreak by text so output is deterministic.
        terms.sort { $0.count != $1.count ? $0.count > $1.count : $0.text < $1.text }
        return Array(terms.prefix(limit))
    }

    // MARK: - tokenizing

    struct Token { let word: String; let endsSentence: Bool }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush(endsSentence: Bool) {
            var w = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            // Strip a possessive so "Todor's" is learned as "Todor".
            if w.hasSuffix("'s") || w.hasSuffix("’s") { w = String(w.dropLast(2)) }
            if !w.isEmpty { tokens.append(Token(word: w, endsSentence: endsSentence)) }
            current = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-" {
                current.append(ch)
            } else {
                let ends = ".!?…\n".contains(ch)
                flush(endsSentence: ends)
            }
        }
        flush(endsSentence: false)
        return tokens
    }

    /// A word worth learning: a Capitalized word (proper noun / product) or an
    /// ALL-CAPS acronym of 2+ letters. Plain lowercase words are never learned.
    static func isCandidate(_ word: String) -> Bool {
        // Reject contractions ("I'm", "don't"): after possessive-stripping in the
        // tokenizer, a remaining apostrophe means a contraction, never a name.
        if word.contains("'") || word.contains("’") { return false }
        guard word.count >= 2, let first = word.first, first.isLetter else { return false }
        let letters = word.filter { $0.isLetter }
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) { return true } // acronym
        // Capitalized: first upper, remainder has at least one lowercase (so we
        // skip ALL-CAPS handled above and single-letter noise).
        return first.isUppercase && word.dropFirst().contains { $0.isLowercase }
    }

    /// Common capitalized sentence-starters and function words to never learn.
    static let stopwords: Set<String> = [
        "the","a","an","and","or","but","so","if","then","this","that","these","those",
        "i","you","he","she","it","we","they","me","him","her","us","them","my","your",
        "his","its","our","their","is","are","was","were","be","been","being","am",
        "do","does","did","have","has","had","can","could","will","would","should",
        "may","might","must","shall","to","of","in","on","at","for","with","by","from",
        "as","into","about","over","after","before","when","where","why","how","what",
        "who","which","while","yes","no","ok","okay","hi","hey","hello","thanks","thank",
        "please","let","send","make","tell","ask","just","really","also","not","now",
        "here","there","today","tomorrow","yesterday","yeah","um","uh",
    ]
}
