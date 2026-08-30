import AVFoundation
import ApplicationServices
import FlowCloneCore

/// One place that answers "is dictation ready — and if not, what exactly is
/// wrong". The menu-bar dropdown and the Insights readiness line both read
/// from here, so the two surfaces can never disagree.
enum ReadinessSummary {
    struct Problem {
        /// String raw values so NSMenuItem.representedObject can carry one.
        enum Action: String { case openAccessibility, openMicrophone, fixOllama }
        let text: String
        let action: Action
    }

    struct State {
        let problems: [Problem]
        let engineName: String
        let cleanupLine: String
        var ready: Bool { problems.isEmpty }
        /// "Parakeet · Apple Intelligence cleanup"
        var summary: String { "\(engineName) · \(cleanupLine)" }
    }

    static func compute() -> State {
        var problems: [Problem] = []

        if !AXIsProcessTrusted() {
            problems.append(Problem(text: "Accessibility permission needed — text can't paste",
                                    action: .openAccessibility))
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            problems.append(Problem(text: "Microphone access denied — dictation can't hear you",
                                    action: .openMicrophone))
        default:
            break // authorized, or will ask on first use — not a problem row
        }

        let engineName = Settings.asrEngine == "whisper" ? "Whisper" : "Parakeet"

        // Cleanup route for every language this configuration can dictate —
        // the same pure router the pipeline uses.
        let langs = (Settings.autoLanguage && Settings.autoLanguageAvailable
                     && Settings.language != Settings.altLanguage)
            ? [Settings.language, Settings.altLanguage] : [Settings.language]
        let kinds = langs.map {
            EngineRouter.cleanupEngine(
                languageCode: $0,
                preference: Settings.cleanupEngine,
                appleAvailable: AppleCleanup.isAvailable,
                detectionReliable: DictationController.detectionReliable,
                restyleTone: !Tone.current.instruction.isEmpty)
        }

        let cleanupLine: String
        if !Settings.cleanupEnabled {
            cleanupLine = "cleanup off"
        } else if kinds.allSatisfy({ $0 == .apple }) {
            cleanupLine = "Apple Intelligence cleanup"
        } else {
            cleanupLine = kinds.allSatisfy { $0 == .ollama }
                ? "Ollama cleanup" : "Apple + Ollama cleanup"
            switch OllamaHealth.shared.status {
            case .offline:
                problems.append(Problem(text: "Ollama isn't running — needed for cleanup",
                                        action: .fixOllama))
            case .modelMissing:
                problems.append(Problem(text: "Ollama model \"\(Settings.ollamaModel)\" isn't pulled",
                                        action: .fixOllama))
            case .ready, .unknown:
                break
            }
        }

        return State(problems: problems, engineName: engineName, cleanupLine: cleanupLine)
    }
}
