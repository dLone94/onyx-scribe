import Foundation

/// Pure, timestamp-driven state machine that turns raw hotkey press/release
/// events into dictation-vs-transform intents. It owns no timers and no audio —
/// the host feeds it `.press`/`.release`/`.timeout` events (each carrying an
/// absolute timestamp) and executes the `GestureOutput`s it returns. That keeps
/// the gesture logic fully unit-testable (see FlowCloneChecks) and free of
/// AppKit, so a mistimed double-tap can never silently start the wrong mode.
///
/// Gestures on the SAME hotkey:
/// - **hold** → `.dictation` (press and keep holding; release stops).
/// - **double-tap-hold** → `.transform` (a quick tap, then press-and-hold within
///   the tap window; the hold's audio is the spoken command).
/// - a lone tap, or two quick taps, resolve to nothing (capture discarded).
///
/// Audio capture starts on the FIRST press (`.startCapture`) so a normal
/// dictation never clips its leading words while we wait to see whether a hold
/// is coming; a tap that turns out not to be a hold emits `.cancelCapture`.
public struct GestureRecognizer {

    public struct Config: Equatable {
        /// A press shorter than this counts as a tap, not a hold.
        public var tapMaxDuration: TimeInterval
        /// Max idle between a tap's release and the next press for them to pair
        /// as a double-tap.
        public var doubleTapMaxGap: TimeInterval

        public init(tapMaxDuration: TimeInterval = 0.35,
                    doubleTapMaxGap: TimeInterval = 0.6) {
            self.tapMaxDuration = tapMaxDuration
            self.doubleTapMaxGap = doubleTapMaxGap
        }
    }

    public enum Mode: Equatable { case dictation, transform }

    public enum Event: Equatable {
        case press(TimeInterval)
        case release(TimeInterval)
        /// The host delivers this at the absolute time a prior `.armTimeout`
        /// requested. Stale timeouts (superseded by a newer `.armTimeout`) are
        /// ignored by matching on the exact deadline.
        case timeout(TimeInterval)
    }

    public enum Output: Equatable {
        /// Begin buffering mic audio now (a fresh press — may become anything).
        case startCapture
        /// Drop the in-progress capture: the press was a tap, not a hold.
        case cancelCapture
        /// The current capture is a dictation; show recording UI, run partials.
        case beginDictation
        /// The current capture is a transform; gate + read the selection first.
        case beginTransform
        /// Key released after a confirmed hold — stop capture and process.
        case finish
        /// Ask the host to deliver `.timeout(deadline)` at this absolute time.
        case armTimeout(TimeInterval)
    }

    private enum Phase: Equatable {
        case idle
        case firstDown(pressedAt: TimeInterval)       // capturing; hold→dictation, quick→tap
        case awaitingSecond(firstTapAt: TimeInterval) // first was a quick tap; capture dropped
        case secondDown(pressedAt: TimeInterval)      // capturing; hold→transform, quick→nothing
        case recording(Mode)                          // hold confirmed; capturing until release
    }

    public let config: Config
    private var phase: Phase = .idle
    /// The single deadline currently honored; timeouts that don't match are stale.
    private var armed: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// True while a hold is confirmed and recording — used by the host to know
    /// whether a release should finish (vs. the hands-free lock, handled outside).
    public var isRecording: Bool { if case .recording = phase { return true }; return false }

    public mutating func handle(_ event: Event) -> [Output] {
        switch event {
        case .press(let t):    return onPress(t)
        case .release(let t):  return onRelease(t)
        case .timeout(let t):  return onTimeout(t)
        }
    }

    private mutating func onPress(_ t: TimeInterval) -> [Output] {
        switch phase {
        case .idle:
            phase = .firstDown(pressedAt: t)
            return arm(t + config.tapMaxDuration, [.startCapture])

        case .awaitingSecond(let firstTapAt):
            // Within the double-tap window → this is the second press (transform
            // candidate). Otherwise the earlier tap is stale; start fresh.
            if t - firstTapAt <= config.doubleTapMaxGap {
                phase = .secondDown(pressedAt: t)
            } else {
                phase = .firstDown(pressedAt: t)
            }
            return arm(t + config.tapMaxDuration, [.startCapture])

        case .firstDown, .secondDown, .recording:
            // A press while already down shouldn't occur (HotkeyManager guards
            // key-repeat/re-entry); ignore defensively.
            return []
        }
    }

    private mutating func onRelease(_ t: TimeInterval) -> [Output] {
        switch phase {
        case .firstDown(let pressedAt):
            if t - pressedAt < config.tapMaxDuration {
                // Quick tap — drop its audio, wait for a possible second press.
                phase = .awaitingSecond(firstTapAt: t)
                return arm(t + config.doubleTapMaxGap, [.cancelCapture])
            }
            // Held past the window but the timeout hasn't been delivered yet:
            // promote to dictation, then finish.
            phase = .idle
            return disarm([.beginDictation, .finish])

        case .secondDown(let pressedAt):
            if t - pressedAt < config.tapMaxDuration {
                // Two quick taps, no hold → nothing (double-tap alone is unbound).
                phase = .idle
                return disarm([.cancelCapture])
            }
            phase = .idle
            return disarm([.beginTransform, .finish])

        case .recording:
            phase = .idle
            return disarm([.finish])

        case .idle, .awaitingSecond:
            return []
        }
    }

    private mutating func onTimeout(_ t: TimeInterval) -> [Output] {
        guard let armed, abs(t - armed) < 0.0005 else { return [] } // stale timer
        switch phase {
        case .firstDown:
            phase = .recording(.dictation)
            self.armed = nil
            return [.beginDictation]

        case .secondDown:
            phase = .recording(.transform)
            self.armed = nil
            return [.beginTransform]

        case .awaitingSecond:
            // No second press arrived — the lone tap is discarded (already
            // cancelled on release); return to idle.
            phase = .idle
            self.armed = nil
            return []

        case .idle, .recording:
            self.armed = nil
            return []
        }
    }

    private mutating func arm(_ deadline: TimeInterval, _ outputs: [Output]) -> [Output] {
        armed = deadline
        return outputs + [.armTimeout(deadline)]
    }

    private mutating func disarm(_ outputs: [Output]) -> [Output] {
        armed = nil
        return outputs
    }
}
