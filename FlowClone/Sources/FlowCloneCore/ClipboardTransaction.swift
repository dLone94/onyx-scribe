import Foundation

/// Pure decision core of TextInjector's serialized clipboard transaction.
///
/// The injector saves the user's clipboard, writes its own payload, pastes,
/// and restores after a delay. These functions decide — from pasteboard
/// `changeCount` observations and a monotonically increasing transaction
/// token — when a snapshot is the user's real clipboard and when a restore is
/// still safe. The effectful half (NSPasteboard) stays in the app; this half
/// is unit-tested.
public enum ClipboardTransaction {
    /// Should a new write snapshot the live pasteboard as "the user's
    /// clipboard"? NO when the pasteboard still holds OUR previous payload
    /// (chained pastes inside one restore window) — snapshotting then would
    /// capture our own injected text and lose the user's real clipboard.
    public static func shouldSnapshotUser(currentChangeCount: Int,
                                          lastWriteChangeCount: Int?,
                                          havePendingSnapshot: Bool) -> Bool {
        guard havePendingSnapshot, let last = lastWriteChangeCount else { return true }
        // changeCount moved past our write → someone else owns the pasteboard
        // again, so the live contents ARE the user's clipboard.
        return currentChangeCount != last
    }

    public enum RestoreDecision: Equatable, Sendable {
        /// Put the user's saved clipboard back.
        case restore
        /// A newer transaction owns the restore now — this one stands down.
        case skipSuperseded
        /// The user copied something during the delay — their newer clipboard
        /// wins; never overwrite it with the old snapshot.
        case skipUserCopied
    }

    /// A restore may run only for the LATEST transaction (token match) and only
    /// while the pasteboard still holds our payload (changeCount unchanged
    /// since our write) — i.e. while the transaction still owns the pasteboard.
    public static func restoreDecision(ticket: Int,
                                       currentToken: Int,
                                       currentChangeCount: Int,
                                       lastWriteChangeCount: Int?) -> RestoreDecision {
        guard ticket == currentToken else { return .skipSuperseded }
        guard let last = lastWriteChangeCount, currentChangeCount == last else {
            return .skipUserCopied
        }
        return .restore
    }
}
