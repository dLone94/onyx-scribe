import Foundation

/// When a transcript is short enough that the LLM pass is more likely to
/// hallucinate than help, the pipeline pastes the vocabulary-corrected raw
/// text instead. English needs a few words before cleanup earns its latency;
/// Bulgarian ASR output needs repair even on short phrases, but a single
/// word is still too little signal to guess from.
public enum CleanupPassPolicy {
    /// Minimum word count that goes through cleanup, per language.
    public static func minimumWords(languageCode: String) -> Int {
        languageCode.lowercased().hasPrefix("bg") ? 2 : 5
    }

    public static func shouldSkipForLength(wordCount: Int, languageCode: String) -> Bool {
        wordCount < minimumWords(languageCode: languageCode)
    }
}

/// Per-language additions to the cleanup system prompt. Only Bulgarian needs
/// one today: small on-device models drift into English or transliteration
/// unless the target language is locked explicitly.
public enum LanguageCleanupGuidance {
    public static func instruction(for languageCode: String) -> String? {
        guard languageCode.lowercased().hasPrefix("bg") else { return nil }
        return """
        The transcript is in Bulgarian. Output Bulgarian in Cyrillic only — never \
        translate to English and never transliterate to Latin letters. Keep \
        Bulgarian grammar, agreement, and word order natural.
        """
    }
}
