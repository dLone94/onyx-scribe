import Foundation

/// Mirrors Ollama's model-name resolution for health checks.
/// A bare name ("gemma4") resolves to its ":latest" tag only —
/// "gemma4:12b" being pulled does NOT make bare "gemma4" available.
public enum OllamaModelMatch {
    public static func isAvailable(setting: String, tags: [String]) -> Bool {
        let s = setting.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        return tags.contains { tag in
            tag == s || (!s.contains(":") && tag == s + ":latest")
        }
    }
}
