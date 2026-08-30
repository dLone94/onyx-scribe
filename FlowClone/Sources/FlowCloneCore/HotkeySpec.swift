import Foundation

/// A dictation hotkey. Two kinds:
/// - `.modifierOnly`: a single modifier key held alone (the classic Right ⌥).
///   Detected via flagsChanged; `modifiers` is 0.
/// - `.key`: a regular key, optionally with required modifiers (⌃⇧D, F5).
///   Detected via keyDown/keyUp.
///
/// Foundation-only on purpose: FlowCloneChecks can't import AppKit, so
/// modifier masks are stored as raw UInt matching NSEvent.ModifierFlags.
public struct HotkeySpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case modifierOnly, key }

    public let kind: Kind
    public let keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue restricted to deviceIndependentFlagsMask.
    /// Always 0 for .modifierOnly.
    public let modifiers: UInt

    public init(kind: Kind, keyCode: UInt16, modifiers: UInt) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = kind == .modifierOnly ? 0 : modifiers
    }

    /// The shipping default.
    public static let rightOption = HotkeySpec(kind: .modifierOnly, keyCode: 61, modifiers: 0)

    // Raw values of NSEvent.ModifierFlags (AppKit), usable without AppKit.
    public static let commandMask: UInt = 1 << 20
    public static let optionMask: UInt = 1 << 19
    public static let controlMask: UInt = 1 << 18
    public static let shiftMask: UInt = 1 << 17

    /// keyCodes of the modifier keys themselves (for .modifierOnly capture).
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    /// Bare function keys that are allowed with no modifiers.
    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100,
                                                       101, 109, 103, 111, 105, 107, 113, 106]

    /// nil = valid; otherwise a user-facing reason the spec is rejected.
    public var validationError: String? {
        if keyCode == 53 { return "Esc cancels dictation and can't be the hotkey." }
        if keyCode == 63 { return "The fn/globe key is reserved by macOS." }
        switch kind {
        case .modifierOnly:
            guard Self.modifierKeyCodes.contains(keyCode) else {
                return "Not a modifier key."
            }
            if keyCode == 57 { return "Caps Lock can't be held — pick another key." }
            return nil
        case .key:
            if Self.modifierKeyCodes.contains(keyCode) { return "Not a regular key." }
            if modifiers == 0 && !Self.functionKeyCodes.contains(keyCode) {
                return "A bare letter/number would trigger while typing — add a modifier or use an F-key."
            }
            return nil
        }
    }

    /// Two specs conflict when a single physical press can fire BOTH monitors —
    /// an ambiguous dispatch. `.key` matching in HotkeyManager triggers on a
    /// modifier SUPERSET (you may hold extra modifiers), so pressing the union of
    /// two chords on the same key (`⌃⇧D`) satisfies BOTH `⌃D` and `⇧D`. Hence any
    /// two specs sharing kind + keyCode conflict, whatever their modifiers.
    public func conflicts(with other: HotkeySpec) -> Bool {
        kind == other.kind && keyCode == other.keyCode
    }

    /// Validation for a hotkey that must ALSO be distinct from another (e.g. the
    /// hands-free hotkey vs. the dictation hotkey). nil = valid.
    public func validationError(against other: HotkeySpec?) -> String? {
        if let base = validationError { return base }
        if let other, conflicts(with: other) {
            return "Already used by the dictation hotkey — pick a different key."
        }
        return nil
    }

    public var displayString: String {
        var prefix = ""
        if modifiers & Self.controlMask != 0 { prefix += "⌃" }
        if modifiers & Self.optionMask != 0 { prefix += "⌥" }
        if modifiers & Self.shiftMask != 0 { prefix += "⇧" }
        if modifiers & Self.commandMask != 0 { prefix += "⌘" }
        return prefix + Self.keyName(keyCode)
    }

    public static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            // Modifier keys (for .modifierOnly display)
            54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 60: "Right ⇧",
            58: "Left ⌥", 61: "Right ⌥", 59: "Left ⌃", 62: "Right ⌃",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16",
            // Letters (ANSI layout keycodes)
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            // Digits
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0",
            // Misc
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "key \(code)"
    }
}
