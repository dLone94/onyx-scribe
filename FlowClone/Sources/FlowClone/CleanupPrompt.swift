import FlowCloneCore
import Foundation

/// macOS adapter over the shared `CleanupPromptBuilder` (FlowCloneCore): the
/// prompt text lives in Core so the iOS app composes the identical editorial
/// brain; this file only gathers the inputs from macOS settings and files.
/// Designed in ../prompts/cleanup_system_prompt.md.
enum CleanupPrompt {

    /// Snapshot of the settings-derived prompt inputs.
    static func inputs() -> CleanupPromptInputs {
        CleanupPromptInputs(
            vocabularyTerms: loadVocabularyTerms(),
            learnedTerms: LearnedStore.currentTerms(),
            appProfiles: loadProfiles(),
            tone: Tone.current,
            usEnglish: Settings.usEnglish)
    }

    /// The full composed system prompt for the current settings.
    static func system(app: String? = nil, context: ContextReader.Context? = nil,
                       languageCode: String? = nil) -> String {
        CleanupPromptBuilder.system(
            app: app, context: context, languageCode: languageCode, inputs: inputs())
    }

    /// The parts that change only with settings (tone, vocabulary, US English).
    /// Stable between dictations, so the Apple FM engine can pre-compute them
    /// into a prewarmed session's instructions — that's where the latency was.
    static func stableSystem() -> String {
        CleanupPromptBuilder.stableSystem(inputs: inputs())
    }

    /// The per-dictation parts (insertion context, destination app).
    static func situational(app: String? = nil, context: ContextReader.Context? = nil,
                            languageCode: String? = nil) -> String {
        CleanupPromptBuilder.situational(
            app: app, context: context, languageCode: languageCode, inputs: inputs())
    }

    static func draftSystem(app: String? = nil) -> String {
        CleanupPromptBuilder.draftSystem(app: app, tone: Tone.current)
    }

    static func draftUserTurn(context: String, intent: String) -> String {
        CleanupPromptBuilder.draftUserTurn(context: context, intent: intent)
    }

    static func transcriptUserTurn(_ transcript: String) -> String {
        CleanupPromptBuilder.transcriptUserTurn(transcript)
    }

    static func rewriteUserTurn(original: String, command: String) -> String {
        CleanupPromptBuilder.rewriteUserTurn(original: original, command: command)
    }

    static func transformSystem(kind: TransformKind) -> String {
        CleanupPromptBuilder.transformSystem(kind: kind)
    }

    static func transformUserTurn(selection: String, kind: TransformKind, command: String) -> String {
        CleanupPromptBuilder.transformUserTurn(selection: selection, kind: kind, command: command)
    }

    static func translateSystem(toName targetName: String) -> String {
        CleanupPromptBuilder.translateSystem(toName: targetName)
    }

    static var rewriteSystem: String { CleanupPromptBuilder.rewriteSystem }

    /// Personal dictionary: one term per line in ~/.flowclone/vocabulary.txt
    private static func loadVocabularyTerms() -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/vocabulary.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return CleanupPromptInputs.manualTerms(fromVocabularyText: text)
    }

    /// Per-app cleanup instructions: ~/.flowclone/profiles.json {"Slack": "…", "Mail": "…"}
    private static func loadProfiles() -> [String: String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/profiles.json")
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }
}
