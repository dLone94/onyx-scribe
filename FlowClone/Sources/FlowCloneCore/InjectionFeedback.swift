/// Chooses the final user-visible state after an injection attempt. Kept pure
/// so uncertain Accessibility classifications cannot silently change the
/// meaning of a confirmed write.
public enum InjectionFeedback {
    public enum Outcome: Equatable, Sendable {
        case noWrite
        case success
        case toneUnavailable
        case cleanupDegraded
    }

    public static func decide(writeSucceeded: Bool,
                              capturedTargetEditable: Bool,
                              toneUnavailable: Bool,
                              cleanupDegraded: Bool) -> Outcome {
        guard writeSucceeded else { return .noWrite }

        // A successful AX write or paste command is authoritative. The earlier
        // Accessibility classification is only a best-effort preflight and is
        // frequently uncertain for web/custom editors. Write-time app-change
        // and secure-field blocks are handled before this decision.
        _ = capturedTargetEditable
        if toneUnavailable { return .toneUnavailable }
        if cleanupDegraded { return .cleanupDegraded }
        return .success
    }
}
