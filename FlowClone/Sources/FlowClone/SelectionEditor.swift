import AppKit
import ApplicationServices

/// Reads and replaces the user's *selected* text via the Accessibility API —
/// the write side of voice selection-transform. Everything here is best-effort
/// and fail-safe: if the selection can't be read, or has changed by the time we
/// write, we abort rather than corrupt the user's document.
enum SelectionEditor {

    /// A snapshot of the selection at gesture time — the fingerprint we re-check
    /// before writing so a moved caret / changed selection can't be overwritten.
    struct Selection {
        let pid: pid_t
        let element: AXUIElement
        let text: String
        let range: CFRange?   // selected range, when the element exposes one
    }

    /// The outcome of an in-place replacement attempt.
    enum ReplaceResult {
        case replaced         // written via AX, verified
        case pasted           // written via the pasteboard fallback (still verified current)
        case selectionChanged // fingerprint no longer matches — aborted, untouched
    }

    /// Reads the current selection from the focused element. Returns nil for
    /// secure fields, non-text elements, or an empty selection (nothing to do).
    /// The entitlement gate MUST be checked before calling this — we never read
    /// private selected content for a user who can't use the feature.
    static func readSelection() -> Selection? {
        guard let element = focusedElement() else { return nil }

        // Never read password fields.
        if subrole(of: element) == ContextReader.secureSubrole { return nil }

        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selRef) == .success,
            let selected = selRef as? String, !selected.isEmpty
        else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        return Selection(pid: pid, element: element, text: selected, range: selectedRange(of: element))
    }

    /// Replaces `selection` with `replacement`, but only if the LIVE selection
    /// still matches the full fingerprint — same focused element (`CFEqual`),
    /// same pid, same selected text, AND same range. Must be called on the main
    /// thread with no suspension around it, so the verify and the write are
    /// atomic (focus can't change in between). Tries AX writes first (no
    /// clipboard touched):
    /// 1. settable `kAXSelectedText` → set it directly;
    /// 2. else settable `kAXValue` + known range → splice + set + verify;
    /// 3. else paste over the still-verified selection (Cmd+V) as a last resort.
    /// `@MainActor` makes the "main thread, no suspension" contract above a
    /// compiler guarantee rather than a comment callers had to honor by hand.
    @MainActor
    static func replaceSelection(_ selection: Selection, with replacement: String) -> ReplaceResult {
        // Re-read the live selection and confirm NOTHING moved — element, pid,
        // text, and range must all still match.
        guard let element = focusedElement(), CFEqual(element, selection.element) else {
            return .selectionChanged
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var liveRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &liveRef)
        guard pid == selection.pid, (liveRef as? String) == selection.text,
              rangesEqual(selectedRange(of: element), selection.range) else {
            return .selectionChanged
        }

        // Strategy 1: set the selected-text attribute directly (replaces it).
        if isSettable(element, kAXSelectedTextAttribute) {
            if AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success {
                return .replaced
            }
        }

        // Strategy 2: splice into the full value at the selected range, then verify.
        if let range = selection.range, isSettable(element, kAXValueAttribute) {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let whole = valueRef as? String {
                let ns = whole as NSString
                let loc = max(0, min(range.location, ns.length))
                let len = max(0, min(range.length, ns.length - loc))
                let spliced = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: replacement)
                if AXUIElementSetAttributeValue(
                    element, kAXValueAttribute as CFString, spliced as CFString) == .success {
                    // Move the caret to the end of the inserted text (best-effort).
                    var caret = CFRange(location: loc + (replacement as NSString).length, length: 0)
                    if let axCaret = AXValueCreate(.cfRange, &caret) {
                        AXUIElementSetAttributeValue(
                            element, kAXSelectedTextRangeAttribute as CFString, axCaret)
                    }
                    // Verify the write took.
                    var checkRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &checkRef) == .success,
                       let after = checkRef as? String, after == spliced {
                        return .replaced
                    }
                }
            }
        }

        // Strategy 3: paste over the selection. The fingerprint above passed with
        // no suspension since, so the selection we're replacing is the verified
        // one — Cmd+V replaces exactly it. Done here (not by the caller) so the
        // check and the paste stay atomic. The injector re-validates the pid.
        guard TextInjector.inject(replacement, target: .pinned(selection.pid)).succeeded else {
            return .selectionChanged
        }
        return .pasted
    }

    private static func rangesEqual(_ a: CFRange?, _ b: CFRange?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.location == y.location && x.length == y.length
        default: return false
        }
    }

    /// Whether the caret sits right after `previous` with no active selection.
    /// `nil` = the element doesn't expose AX text (web/Electron) so we can't tell.
    /// Guards `TextInjector.replaceLast`'s blind backspaces against clobbering
    /// unrelated text when the caret has moved.
    static func caretIsAtEndOf(_ previous: String) -> Bool? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let whole = valueRef as? String else { return nil }
        guard let range = selectedRange(of: element) else { return nil }
        guard range.length == 0 else { return false } // an active selection isn't a caret
        let ns = whole as NSString
        let caret = min(max(0, range.location), ns.length)
        let prevLen = (previous as NSString).length
        guard caret >= prevLen else { return false }
        return ns.substring(with: NSRange(location: caret - prevLen, length: prevLen)) == previous
    }

    // MARK: - AX helpers

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    private static func subrole(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref)
        return ref as? String
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue((rv as! AXValue), .cfRange, &range) ? range : nil
    }

    private static func isSettable(_ element: AXUIElement, _ attr: String) -> Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, attr as CFString, &settable)
        return settable.boolValue
    }
}
