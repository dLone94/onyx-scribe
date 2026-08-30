import AppKit
import ApplicationServices

/// Reads the text surrounding the caret in the focused text field via the
/// Accessibility API — the same permission we already hold for injection.
/// Gives the cleanup LLM insertion context (match case/punctuation/terms).
/// Returns nil gracefully for secure fields, non-text elements, and apps
/// that don't expose AX text (some Electron apps).
enum ContextReader {
    struct Context {
        let before: String // up to ~400 chars before the caret
        let after: String  // up to ~200 chars after the caret
        var isEmpty: Bool { before.isEmpty && after.isEmpty }
    }

    static func read() -> Context? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        // Never read password fields.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, subrole == secureSubrole { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef) == .success,
            let text = valueRef as? String, !text.isEmpty
        else { return nil }

        // Caret position (UTF-16 units, matching NSString indexing).
        let ns = text as NSString
        var caret = ns.length
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue((rv as! AXValue), .cfRange, &range) {
                caret = min(max(0, range.location), ns.length)
            }
        }

        let beforeLen = min(400, caret)
        let before = ns.substring(with: NSRange(location: caret - beforeLen, length: beforeLen))
        let afterLen = min(200, ns.length - caret)
        let after = ns.substring(with: NSRange(location: caret, length: afterLen))
        let context = Context(before: before, after: after)
        return context.isEmpty ? nil : context
    }

    /// The visible conversation/document text of the frontmost window — the
    /// material for context-aware drafting. Read locally via Accessibility; it
    /// never leaves the Mac, which is exactly why a cloud app can't offer this.
    /// Best-effort: rich in AX-native apps (Mail, Messages, Notes, TextEdit,
    /// Safari), thin or empty in some Electron apps. Returns nil when nothing
    /// readable is found.
    struct Surrounding { let text: String }

    static func readSurrounding(maxChars: Int = 2600, maxNodes: Int = 4000) -> Surrounding? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
            let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }

        var pieces: [String] = []
        var budget = maxChars
        var nodes = maxNodes
        collectText(win as! AXUIElement, pieces: &pieces, budget: &budget, nodes: &nodes)

        // Collapse whitespace runs and drop consecutive duplicate lines (chat UIs
        // repeat labels); keep it compact for the prompt.
        var seen = Set<String>()
        let lines = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return Surrounding(text: String(joined.prefix(maxChars)))
    }

    /// Depth-first gather of text-bearing AX elements, bounded by a char budget
    /// and a node cap so a huge window tree can't stall the pipeline.
    private static func collectText(_ element: AXUIElement,
                                    pieces: inout [String],
                                    budget: inout Int,
                                    nodes: inout Int) {
        if budget <= 0 || nodes <= 0 { return }
        nodes -= 1

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, subrole == secureSubrole { return }

        // Prefer the value (text fields/areas), then static-text title/description.
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as [CFString] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
               let s = ref as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 1 {
                    pieces.append(t)
                    budget -= t.count
                    break // one text attribute per node is enough
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children {
            if budget <= 0 || nodes <= 0 { return }
            collectText(child, pieces: &pieces, budget: &budget, nodes: &nodes)
        }
    }

    /// AX subrole marking a password/secure field. One constant so every reader
    /// and writer applies the same test.
    static let secureSubrole = "AXSecureTextField"

    /// What the focused element is, for target capture and write-time checks.
    struct TargetInfo {
        /// A text target exists to paste into (errs toward "yes" for web areas).
        let editable: Bool
        /// The focused element is a secure (password) field. Checked BEFORE the
        /// role shortcut — a password field's role is AXTextField, so the old
        /// role-first order classified it as an ordinary editable target.
        let secure: Bool

        static let none = TargetInfo(editable: false, secure: false)
    }

    /// Classifies the currently focused element. Secure detection runs first;
    /// a secure field is never reported as editable.
    static func targetInfo() -> TargetInfo {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .none }
        let element = focused as! AXUIElement

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == secureSubrole {
            return TargetInfo(editable: false, secure: true)
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        // Web content: benefit of the doubt.
        if role == "AXWebArea" || role == "AXTextField" || role == "AXTextArea" {
            return TargetInfo(editable: true, secure: false)
        }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return TargetInfo(editable: settable.boolValue, secure: false)
    }

    /// Best-effort: is there an editable text target to paste into?
    /// Used to route no-target dictations to the Scratchpad instead of a
    /// vanished paste. Errs on the side of "yes" (web areas can't be probed
    /// reliably, and a wrong "yes" just means a harmless paste attempt).
    /// Secure fields are NOT editable targets.
    static func hasEditableTarget() -> Bool { targetInfo().editable }

    /// True when the caret sits at a sentence start (or empty field) —
    /// used by the no-LLM fast path to decide capitalization.
    static func isSentenceStart(_ context: Context?) -> Bool {
        guard let context else { return true }
        let trimmed = context.before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        return ".!?…:\n".contains(last)
    }

    /// Mechanical spacing: if the char right before the caret is a word
    /// character or comma with no trailing whitespace, the injection needs a
    /// leading space ("should" + "definitely" → "should definitely").
    static func needsLeadingSpace(_ context: Context?) -> Bool {
        guard let last = context?.before.last else { return false }
        return last.isLetter || last.isNumber || last == "," || last == ";"
    }
}
