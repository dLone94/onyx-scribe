import Foundation

/// Detects a spoken command to turn "speak one language, type another" mode on or
/// off ("translate to English", "stop translating"). Keyword-gated and
/// conservative like ToneSwitchCommand — a long sentence that happens to mention
/// translating is dictation, not a command. The caller supplies the user's
/// languages (code, spoken name), mirroring how tones are passed in.
public enum TranslateCommand {
    public enum Result: Equatable {
        case to(String)   // target language code
        case off
    }

    public static func detect(_ raw: String,
                              languages: [(code: String, name: String)]) -> Result? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        guard t.count < 42 else { return nil }   // commands are short

        let offPhrases = [
            "stop translating", "stop translation", "stop the translation",
            "turn off translation", "turn off translate", "turn off translating",
            "no translation", "disable translation",
        ]
        if offPhrases.contains(t) { return .off }

        let prefixes = ["translate to ", "translate output to ", "translate into ",
                        "translate everything to ", "translate my speech to ",
                        "start translating to ", "output in "]
        // Longest language name first so multi-word names win.
        for lang in languages.sorted(by: { $0.name.count > $1.name.count }) {
            let name = lang.name.lowercased()
            for prefix in prefixes where t == prefix + name {
                return .to(lang.code)
            }
        }
        return nil
    }
}
