import AppKit
import FlowCloneCore

/// Injects text into the frontmost app. Prefers a direct AX insertion (no
/// clipboard touched) and falls back to pasteboard + simulated Cmd+V (CGEvent).
/// Requires Accessibility permission; the app must NOT be sandboxed.
///
/// **Target discipline.** Every write validates its target immediately before
/// touching anything: the frontmost app must still be the one captured when the
/// dictation began (`TargetGuard`), and the focused field must not be secure.
/// A blocked write returns a decision instead of pasting into the wrong app.
///
/// **Clipboard discipline.** Pasteboard writes run as a serialized transaction:
/// the user's clipboard (every representation) is saved once per burst, our
/// payload's `changeCount` is recorded, and the restore runs only while the
/// pasteboard still holds our payload — if the user copies during the delay,
/// their newer clipboard wins. Overlapping restores are token-serialized. The
/// pure decisions live in `ClipboardTransaction` (FlowCloneCore, unit-tested).
///
/// Every entry point is `@MainActor`: they drive the shared `NSPasteboard` and
/// post CGEvents, so serializing them on one actor is what makes an interleaved
/// paste impossible.
///
/// **What a "success" means.** `.pasted` means the payload was placed and the
/// Cmd+V events were posted to a validated frontmost target — whether the app
/// actually consumed the paste cannot be observed from here (manual smoke-test
/// territory). `.insertedAX` means the AX write returned success.
@MainActor
enum TextInjector {
    // MARK: - Targets & results

    /// Where a write is allowed to land.
    struct WriteTarget {
        /// nil = user-directed at whatever app is frontmost (explicit "insert"
        /// buttons only). Pipelines always pin; an unknown pin is -1, which can
        /// never match a real pid — fail closed.
        let pid: pid_t?

        static let userDirected = WriteTarget(pid: nil)
        static func pinned(_ pid: pid_t?) -> WriteTarget { WriteTarget(pid: pid ?? -1) }
    }

    enum InjectResult: Equatable {
        case insertedAX                          // direct AX write, clipboard untouched
        case pasted                              // pasteboard + Cmd+V posted
        case blocked(TargetGuard.WriteDecision)  // target changed / secure field

        var succeeded: Bool { self == .insertedAX || self == .pasted }
        var blockDecision: TargetGuard.WriteDecision? {
            if case .blocked(let d) = self { return d }
            return nil
        }
    }

    /// Mandatory settle gap between two successive pastes (F3) — a fast app can
    /// drop or duplicate a second Cmd+V that arrives too soon after the first.
    static let settleGap: TimeInterval = 0.11

    /// How long to wait after a Cmd+V before putting the user's clipboard back.
    /// Conservative so slow apps still read our payload before it disappears;
    /// the changeCount ownership check makes a too-early user copy safe anyway.
    static let clipboardRestoreDelay: TimeInterval = 0.5

    // MARK: - Injection

    /// Validates the target, then writes: direct AX insertion when the focused
    /// element supports it, else pasteboard + Cmd+V with a serialized restore.
    @discardableResult
    static func inject(_ text: String, target: WriteTarget) -> InjectResult {
        let decision = TargetGuard.decide(
            capturedPID: target.pid,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            secureFieldFocused: ContextReader.targetInfo().secure)
        guard decision == .proceed else { return .blocked(decision) }

        if axInsert(text) { return .insertedAX }

        writePayload(text)
        pressCmdV()
        scheduleRestore(after: clipboardRestoreDelay)
        return .pasted
    }

    /// Replaces the last injection: backspaces `charCount` characters, then
    /// injects the replacement (empty replacement = pure delete). The target is
    /// validated before the backspaces AND again after the settle delay before
    /// the replacement lands. Returns false without touching anything if the
    /// target changed.
    @discardableResult
    static func replaceLast(charCount: Int, with replacement: String,
                            target: WriteTarget, previous: String? = nil) -> Bool {
        let decision = TargetGuard.decide(
            capturedPID: target.pid,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            secureFieldFocused: ContextReader.targetInfo().secure)
        guard decision == .proceed else { return false }

        // Preferred: a verified in-place AX replacement (native text controls).
        // Only when that can't be verified do we fall back to backspaces.
        if let previous, previous.count == charCount,
           SelectionEditor.replaceBeforeCaret(previous, with: replacement) {
            return true
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let backspace: CGKeyCode = 51
        for i in 0..<charCount {
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Brief pause every batch so slower apps keep up.
            if i % 25 == 24 { usleep(10_000) }
        }
        guard !replacement.isEmpty else { return true }
        // Give the target app a beat to process the deletions before pasting.
        // `inject` revalidates the target after this suspension.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            inject(replacement, target: target)
        }
        return true
    }

    // MARK: - Direct AX insertion

    /// Inserts at the caret by setting the focused element's selected-text
    /// attribute — the same mechanism SelectionEditor uses for transforms.
    /// Conservative: only native text controls (AXTextArea/AXTextField) that
    /// declare the attribute settable; web areas and Electron apps fall back to
    /// paste. Returns true only when the AX write reports success.
    private static func axInsert(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String,
              role == "AXTextArea" || role == "AXTextField" else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    // MARK: - Serialized clipboard transaction

    private typealias SavedClipboard = [[NSPasteboard.PasteboardType: Data]]

    /// The user's real clipboard, saved while one or more of our payloads own
    /// the pasteboard. All three are main-actor confined.
    private static var userSnapshot: SavedClipboard?
    private static var lastWriteChangeCount: Int?
    private static var restoreToken = 0

    /// Saves the user's clipboard (unless the pasteboard still holds our own
    /// previous payload) and writes ours, recording the resulting changeCount.
    private static func writePayload(_ text: String) {
        let pasteboard = NSPasteboard.general
        if ClipboardTransaction.shouldSnapshotUser(
            currentChangeCount: pasteboard.changeCount,
            lastWriteChangeCount: lastWriteChangeCount,
            havePendingSnapshot: userSnapshot != nil) {
            userSnapshot = snapshotClipboard(pasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWriteChangeCount = pasteboard.changeCount
    }

    /// Restore the user's clipboard after `delay`, but only if this is still the
    /// latest transaction AND the pasteboard still holds our payload. A user
    /// copy during the window wins; overlapping restores are token-serialized.
    private static func scheduleRestore(after delay: TimeInterval) {
        restoreToken += 1
        let ticket = restoreToken
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            switch ClipboardTransaction.restoreDecision(
                ticket: ticket,
                currentToken: restoreToken,
                currentChangeCount: NSPasteboard.general.changeCount,
                lastWriteChangeCount: lastWriteChangeCount) {
            case .restore:
                if let snap = userSnapshot { restoreClipboard(snap) }
                userSnapshot = nil
                lastWriteChangeCount = nil
            case .skipSuperseded:
                break // the newer transaction's restore takes over
            case .skipUserCopied:
                userSnapshot = nil // the user's newer clipboard stays
                lastWriteChangeCount = nil
            }
        }
    }

    /// Every representation of every item — an image/RTF/file clipboard
    /// survives a paste, not just plain text.
    private static func snapshotClipboard(_ pasteboard: NSPasteboard) -> SavedClipboard {
        (pasteboard.pasteboardItems ?? []).map { item in
            var rep: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { rep[type] = d } }
            return rep
        }
    }

    /// Rewrite the pasteboard with every representation we saved.
    private static func restoreClipboard(_ saved: SavedClipboard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.compactMap { rep -> NSPasteboardItem? in
            guard !rep.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in rep { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: - Streaming (bounded incremental paste)

    /// One streaming injection's state: the pinned target and the last commit
    /// time (settle-gap pacing). The user's clipboard is held by the shared
    /// transaction state, so chained stream commits and the final restore all
    /// follow the same ownership rules. `@MainActor` makes it implicitly
    /// `Sendable`, so the model's streaming callback can carry it while every
    /// *use* still hops back here.
    @MainActor
    final class StreamSession {
        fileprivate let target: WriteTarget
        fileprivate var lastCommitAt: Date?
        fileprivate init(target: WriteTarget) { self.target = target }
    }

    /// Begin a streaming injection against the target captured when dictation
    /// began (never the app frontmost at cleanup time). Saves the user's
    /// clipboard once. Call `commitStream` per chunk, then `endStream` exactly
    /// once (via `defer`) so the clipboard is always restored.
    static func beginStream(target: WriteTarget) -> StreamSession {
        let pasteboard = NSPasteboard.general
        if ClipboardTransaction.shouldSnapshotUser(
            currentChangeCount: pasteboard.changeCount,
            lastWriteChangeCount: lastWriteChangeCount,
            havePendingSnapshot: userSnapshot != nil) {
            userSnapshot = snapshotClipboard(pasteboard)
        }
        return StreamSession(target: target)
    }

    /// Paste one chunk. Returns false WITHOUT pasting if the pinned target is
    /// no longer frontmost, a secure field took focus (F10), or `stillCurrent()`
    /// reports the dictation was superseded — the caller must then stop and
    /// degrade rather than scatter text into the wrong app.
    ///
    /// The mandatory settle gap since the previous commit (F3) is awaited, not
    /// slept, so the main thread keeps drawing; BOTH invariants are re-verified
    /// after the suspension.
    @discardableResult
    static func commitStream(_ session: StreamSession,
                             _ chunk: String,
                             stillCurrent: () -> Bool = { true }) async -> Bool {
        guard !chunk.isEmpty else { return true }
        guard writeAllowed(session.target) else { return false }

        if let last = session.lastCommitAt {
            let remaining = settleGap - Date().timeIntervalSince(last)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                // Re-verify after the suspension — focus may have moved, or the
                // user may have pressed Esc, while we were waiting.
                guard stillCurrent(), writeAllowed(session.target) else { return false }
            }
        }
        writePayload(chunk)
        pressCmdV()
        session.lastCommitAt = Date()
        return true
    }

    private static func writeAllowed(_ target: WriteTarget) -> Bool {
        TargetGuard.decide(
            capturedPID: target.pid,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            secureFieldFocused: ContextReader.targetInfo().secure) == .proceed
    }

    /// Restore the user's original clipboard ONCE, at least
    /// `clipboardRestoreDelay` after the final commit's Cmd+V so the paste
    /// lands before the clipboard changes back (F2/F4). Ownership-checked like
    /// every restore. Safe to call on any exit path (success, throw, cancel).
    static func endStream(_ session: StreamSession) {
        let sinceLast = session.lastCommitAt.map { Date().timeIntervalSince($0) }
            ?? clipboardRestoreDelay
        scheduleRestore(after: max(0, clipboardRestoreDelay - sinceLast))
    }

    // MARK: - Key events

    private static func pressCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
