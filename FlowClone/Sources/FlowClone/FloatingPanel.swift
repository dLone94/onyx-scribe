import AppKit

/// Always-on-top, non-activating panel hosting the dictation pill.
/// The verified Wispr Flow-style recipe: `.nonactivatingPanel` is load-bearing —
/// clicking or dragging the pill must never steal focus from the app receiving
/// the dictation. styleMask is set at init only (dynamic flipping of
/// .nonactivatingPanel hits macOS bug FB16484811).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI capsule draws its own shadow
        isMovableByWindowBackground = true // user-draggable, unlike Wispr's pinned bar
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
