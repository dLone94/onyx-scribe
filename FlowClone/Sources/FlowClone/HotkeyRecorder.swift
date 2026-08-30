import AppKit
import FlowCloneCore

/// One-shot capture of the next hotkey chord, used by the Settings recorder.
/// Local monitors only: the Hub window is key while recording, and local
/// monitors can swallow the event (return nil) so the captured chord doesn't
/// also type into the UI.
final class HotkeyRecorder {
    private var monitors: [Any] = []
    /// Modifier keyCode seen going DOWN, pending release (modifierOnly capture).
    private var pendingModifier: UInt16?

    /// Starts capturing. Calls completion exactly once with the captured spec
    /// (validated) or nil if capture was cancelled (Esc).
    func begin(completion: @escaping (HotkeySpec?) -> Void) {
        cancel()
        let finish: (HotkeySpec?) -> Void = { [weak self] spec in
            self?.cancel()
            completion(spec)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged],
                                                    handler: { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { finish(nil); return nil } // Esc = cancel capture
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                let spec = HotkeySpec(kind: .key, keyCode: event.keyCode, modifiers: mods)
                finish(spec.validationError == nil ? spec : nil)
                return nil // swallow
            case .flagsChanged:
                guard HotkeySpec.modifierKeyCodes.contains(event.keyCode) else { return event }
                if let flag = Self.flag(for: event.keyCode),
                   event.modifierFlags.contains(flag) {
                    // Modifier went down — remember it; a keyDown before its
                    // release means it was part of a chord, not modifierOnly.
                    self.pendingModifier = event.keyCode
                } else if self.pendingModifier == event.keyCode {
                    // Same modifier released with no key in between → modifierOnly.
                    let spec = HotkeySpec(kind: .modifierOnly, keyCode: event.keyCode, modifiers: 0)
                    finish(spec.validationError == nil ? spec : nil)
                }
                return event
            default:
                return event
            }
        }) { monitors.append(m) }
    }

    func cancel() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pendingModifier = nil
    }

    private static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }
}
