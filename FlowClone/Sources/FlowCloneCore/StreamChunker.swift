import Foundation

/// Decides when a *cumulative* streaming snapshot from the cleanup model has a
/// confirmed, stable sentence that is safe to paste into the user's document
/// early — the risky heart of Phase-2 streaming injection.
///
/// Deliberately BOUNDED: it emits at most ONE early sentence (`earlyChunk`),
/// after which the rest of the text is pasted in a single `remainder` at the
/// end. That caps the whole feature at two pastes / one settle gap, which is the
/// only shape the pasteboard+Cmd+V injector tolerates (see the adversarial
/// review, findings F3/F9/F10/F11).
///
/// Pure and synchronous so it is fully unit-testable without a model or a paste.
public struct StreamChunker {
    /// How many settled characters must follow a boundary before we trust it —
    /// stops us committing the very tail of a snapshot that is still growing or
    /// might still be revised (F9/F11 mitigation).
    public let lookahead: Int

    private var emitted = false

    public init(lookahead: Int = 12) {
        self.lookahead = max(1, lookahead)
    }

    /// True once the single early chunk has been handed out.
    public var didEmitEarly: Bool { emitted }

    /// Capitalized abbreviations whose trailing "." is NOT a sentence end even
    /// though the next word is capitalized ("Dr. Smith"). Lowercased, dot-free.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "no",
        "fig", "inc", "ltd", "co", "corp", "dept", "est", "gen", "capt", "sgt",
        "gov", "sen", "rep", "rev", "hon",
    ]

    /// Feed the latest cumulative snapshot. Returns the first confirmed sentence
    /// (including its terminal punctuation and trailing space) exactly once; nil
    /// while no stable boundary exists yet, or after the early chunk was emitted.
    public mutating func earlyChunk(_ snapshot: String) -> String? {
        guard !emitted else { return nil }
        guard let end = Self.firstStableBoundary(snapshot, lookahead: lookahead) else { return nil }
        emitted = true
        return String(snapshot[snapshot.startIndex..<end])
    }

    /// The text to paste at the end, after `earlyChunk` (pass what was actually
    /// committed, or nil if nothing was). Returns nil when the final text no
    /// longer begins with the already-pasted prefix — a model revision of
    /// committed text (F11); the caller must then STOP and mark degraded rather
    /// than risk a duplicated/garbled paste.
    public static func remainder(finalText: String, earlyChunk: String?) -> String? {
        guard let early = earlyChunk, !early.isEmpty else { return finalText }
        guard finalText.hasPrefix(early) else { return nil } // divergence → degrade
        return String(finalText.dropFirst(early.count))
    }

    // MARK: - Boundary detection

    /// Index just past the first confirmed sentence boundary (terminal
    /// punctuation + following whitespace), or nil if none is stable yet.
    static func firstStableBoundary(_ s: String, lookahead: Int) -> String.Index? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "." || c == "!" || c == "?" || c == "\n" else { i += 1; continue }

            // End of the whitespace run following the punctuation.
            var j = i + 1
            if c != "\n" {
                // A sentence end must be followed by whitespace — this alone
                // excludes URLs ("example.com") and decimals ("3.5").
                guard j < chars.count, chars[j].isWhitespace else { i += 1; continue }
            }
            while j < chars.count, chars[j].isWhitespace { j += 1 }

            // Need real content after the boundary to judge it a sentence start.
            guard j < chars.count else { return nil } // boundary is the tail — wait

            if c == "." {
                let word = precedingWord(chars, before: i)
                // "Dr." / "e.g." style abbreviation, or a single initial "J.".
                if Self.abbreviations.contains(word.lowercased())
                    || (word.count == 1 && (word.first?.isUppercase ?? false)) {
                    i += 1; continue
                }
                // Decimal like "3.5" (digit . digit) — defensive; the whitespace
                // rule above already handles the common no-space case.
                if let last = word.last, last.isNumber, chars[j].isNumber {
                    i += 1; continue
                }
            }

            // The next content char should look like a sentence start; this
            // rejects mid-sentence abbreviations followed by lowercase
            // ("e.g. the", "vs. the").
            let next = chars[j]
            let opensSentence = next.isUppercase || next.isNumber || "\"'([{“‘".contains(next)
            guard opensSentence else { i += 1; continue }

            // Require enough settled characters past the boundary before trusting
            // it — the first boundary of a still-growing snapshot waits for the
            // next, longer snapshot.
            if (chars.count - j) >= lookahead {
                return s.index(s.startIndex, offsetBy: j)
            }
            return nil
        }
        return nil
    }

    /// The run of letters/digits immediately before `index` (the abbreviation or
    /// word that owns the period).
    private static func precedingWord(_ chars: [Character], before index: Int) -> String {
        var k = index - 1
        var out: [Character] = []
        while k >= 0, chars[k].isLetter || chars[k].isNumber {
            out.append(chars[k]); k -= 1
        }
        return String(out.reversed())
    }
}
