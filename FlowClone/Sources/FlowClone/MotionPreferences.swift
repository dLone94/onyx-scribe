import AppKit
import SwiftUI

/// Single source of truth for the system **Reduce Motion** accessibility setting.
///
/// Read `reduceMotion` to branch inside a view, or observe it as an
/// `@ObservedObject` so the view re-renders the instant the user flips the
/// setting in System Settings › Accessibility › Display.
///
/// Deliberately backed by `NSWorkspace` rather than
/// `@Environment(\.accessibilityReduceMotion)`: SwiftUI's environment/state
/// property-wrapper macros don't compile under a CommandLineTools-only
/// toolchain, and every other piece of shared state in this app already rides
/// the same `ObservableObject` singleton pattern (`HistoryStore.shared`, …).
final class MotionPreferences: ObservableObject {
    static let shared = MotionPreferences()

    /// True when the user has asked the system to minimise non-essential motion.
    @Published private(set) var reduceMotion: Bool

    private init() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Live updates: the notification fires on the main queue, so a direct
        // assignment is safe.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if now != self.reduceMotion { self.reduceMotion = now }
        }
    }

    /// The supplied animation, or `nil` (an instant, non-interpolated change)
    /// when Reduce Motion is on. Use with `.animation(_:value:)`.
    func anim(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// `withAnimation`, but the change lands instantly when Reduce Motion is on.
/// A crossfade/instant settle is the accessible alternative to a spring or
/// slide (see the animate guidance: reduced motion is never optional).
@discardableResult
func flowAnimate<Result>(_ animation: Animation, _ body: () -> Result) -> Result {
    withAnimation(MotionPreferences.shared.reduceMotion ? nil : animation, body)
}

/// Drives the Insights charts' one-shot grow-in.
///
/// The reveal plays **once per app launch** (subsequent visits to Insights
/// settle instantly, so the dashboard never feels like it's performing for a
/// daily user), and is skipped entirely under Reduce Motion. The charts always
/// render their full, final state when `revealed` is true — which it becomes
/// synchronously in every non-animated path — so a headless or snapshot render
/// can never capture a blank chart.
final class InsightsReveal: ObservableObject {
    static let shared = InsightsReveal()

    /// When true, bars sit at full height. Starts collapsed only for the single
    /// animated launch; `play()` is the only thing that ever flips it.
    @Published private(set) var revealed = false
    private var didPlay = false

    private init() {}

    /// Called from `HomeView.onAppear`. First call of the session animates the
    /// grow-in; later calls (and Reduce Motion) settle to full immediately.
    func play() {
        if didPlay { revealed = true; return }
        didPlay = true

        if MotionPreferences.shared.reduceMotion {
            revealed = true
            return
        }

        // One runloop tick collapsed, then let each bar spring up (the stagger
        // lives on the per-bar `.animation(_:value:)` in the charts).
        revealed = false
        DispatchQueue.main.async { self.revealed = true }
    }
}
