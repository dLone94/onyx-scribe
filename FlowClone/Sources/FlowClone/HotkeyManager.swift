import AppKit
import FlowCloneCore

/// Push-to-talk on a configurable hotkey (default: hold the Right Option key,
/// keyCode 61). Global monitor covers other apps; local monitor covers our own
/// windows. `.modifierOnly` specs watch flagsChanged; `.key` specs watch keyDown/Up.
final class HotkeyManager {
    private var monitors: [Any] = []
    private var isDown = false
    /// Where this manager reads its spec. The dictation manager uses the default
    /// (`Settings.hotkey`); the optional hands-free manager passes its own
    /// provider. A nil spec means "no hotkey" — events are ignored.
    private let specProvider: () -> HotkeySpec?
    private var spec: HotkeySpec?

    init(spec: @escaping () -> HotkeySpec? = { Settings.hotkey }) {
        self.specProvider = spec
        self.spec = spec()
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when Esc is pressed while the escape monitor is active
    /// (only during recording/processing — cancels the dictation).
    var onEscape: (() -> Void)?

    private var escapeMonitors: [Any] = []
    private static let escapeKeyCode: UInt16 = 53

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isDown = false
    }

    /// Re-read the spec after the user changes it in Settings.
    func reload() {
        spec = specProvider()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard let spec else { return } // no hotkey configured
        switch spec.kind {
        case .modifierOnly:
            guard event.type == .flagsChanged, event.keyCode == spec.keyCode,
                  let flag = Self.modifierFlag(for: spec.keyCode) else { return }
            let pressed = event.modifierFlags.contains(flag)
            if pressed && !isDown {
                isDown = true
                onPress?()
            } else if !pressed && isDown {
                isDown = false
                onRelease?()
            }

        case .key:
            if event.type == .keyDown {
                guard !event.isARepeat,                       // holding a key autorepeats!
                      !isDown,
                      event.keyCode == spec.keyCode,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                          .isSuperset(of: NSEvent.ModifierFlags(rawValue: spec.modifiers))
                else { return }
                isDown = true
                onPress?()
            } else if event.type == .keyUp {
                // Match on keyCode ONLY: users often release the modifier
                // before the key, so requiring modifiers here would miss
                // the release and leave recording stuck on.
                guard isDown, event.keyCode == spec.keyCode else { return }
                isDown = false
                onRelease?()
            }
        }
    }

    /// Which ModifierFlags bit a given modifier keyCode toggles.
    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }

    /// Watches for Esc while a dictation is in flight. Observe-only: the Esc
    /// keypress still reaches the frontmost app.
    func startEscapeMonitor() {
        guard escapeMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == Self.escapeKeyCode { self?.onEscape?() }
        }) { escapeMonitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == Self.escapeKeyCode { self?.onEscape?() }
            return event
        }
        if let local { escapeMonitors.append(local) }
    }

    func stopEscapeMonitor() {
        escapeMonitors.forEach { NSEvent.removeMonitor($0) }
        escapeMonitors.removeAll()
    }
}
