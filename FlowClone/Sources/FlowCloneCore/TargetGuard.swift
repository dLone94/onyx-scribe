import Foundation

/// Pure write-time target validation: may this pipeline write into the
/// frontmost app right now? Consulted immediately before EVERY paste or AX
/// write — normal injection, streaming commits, voice edits, and delayed
/// rewrite pastes — so text can never land in an app the user has since
/// focused, and never in a secure field.
public enum TargetGuard {
    public enum WriteDecision: Equatable, Sendable {
        case proceed
        /// Focus is in a secure (password) field — never write, never persist.
        case blockedSecureField
        /// The frontmost app is not the one captured when dictation began.
        case blockedTargetChanged
    }

    /// - Parameters:
    ///   - capturedPID: the target pinned when dictation began. `nil` means the
    ///     write is user-directed at whatever is frontmost (no pid pin) — used
    ///     by explicit "insert into previous app" actions, never by pipelines.
    ///   - frontmostPID: the live frontmost app at write time.
    ///   - secureFieldFocused: live secure-field probe at write time.
    public static func decide(capturedPID: Int32?,
                              frontmostPID: Int32?,
                              secureFieldFocused: Bool) -> WriteDecision {
        if secureFieldFocused { return .blockedSecureField }
        guard let captured = capturedPID else { return .proceed }
        guard let front = frontmostPID, front == captured else { return .blockedTargetChanged }
        return .proceed
    }

    /// What happens to the dictated text when its write is blocked.
    public enum BlockedTextOutcome: Equatable, Sendable {
        case saveToScratchpad
        case discard
    }

    /// A secure-field block always discards (the text was aimed at a password
    /// field); a changed target keeps the words in the Scratchpad — unless the
    /// intended target's privacy classification forbids persisting them.
    public static func blockedOutcome(decision: WriteDecision,
                                      mayPersist: Bool) -> BlockedTextOutcome {
        if decision == .blockedSecureField { return .discard }
        return mayPersist ? .saveToScratchpad : .discard
    }
}
