import Foundation

/// Keyword-gated detection of spoken tone-switch commands ("switch to formal
/// tone"). Deliberately conservative, like CommandDetector: only short, exact
/// command phrases match — anything else is treated as normal dictation.
public enum ToneSwitchCommand {
    /// `tones` are (id, spoken name) pairs, e.g. ("super-casual", "Super Casual").
    /// Returns the matched tone id, or nil when the utterance is content.
    public static func detect(_ raw: String,
                              tones: [(id: String, name: String)]) -> String? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        // Commands are short; a long sentence mentioning a tone is dictation.
        guard t.count < 40 else { return nil }

        let prefixes = ["switch to ", "switch the tone to ", "change tone to ",
                        "change the tone to ", "set tone to ", "set the tone to ",
                        "use "]
        // Longest names first so "super casual" wins over "casual".
        for tone in tones.sorted(by: { $0.name.count > $1.name.count }) {
            let name = tone.name.lowercased()
            // Bare "<name> tone" with no prefix ("formal tone").
            if t == name + " tone" { return tone.id }
            for prefix in prefixes {
                for form in [name + " tone", name + " mode", name]
                where t == prefix + form {
                    return tone.id
                }
            }
        }
        return nil
    }
}
