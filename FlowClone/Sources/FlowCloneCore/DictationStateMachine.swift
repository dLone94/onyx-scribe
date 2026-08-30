import Foundation

/// Identity of one dictation utterance. Monotonically increasing, never reused —
/// every pipeline side effect is tagged with the session it belongs to, and a
/// stale session's effects are dropped instead of leaking into a newer one.
public struct DictationSessionID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
    public var description: String { "#\(raw)" }
}

/// The dictation controller's explicit lifecycle, as a pure value type.
/// Every transition is a value-level decision unit-tested without AppKit;
/// the controller only *executes* what the machine decides.
///
/// Policy encoded here (the safe initial policy): a new recording may start
/// only from `idle`. While an older utterance is processing, the gesture is
/// rejected — two pipelines never share mutable operation state.
public struct DictationStateMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case idle
        case recording(DictationSessionID)
        case processing(DictationSessionID)
        case failed(String)
    }

    public enum StartDecision: Equatable, Sendable {
        case start(DictationSessionID)
        /// An older utterance is still processing — show a quiet pill message.
        case rejectStillProcessing
        /// Model loading or failed — not ready to record.
        case rejectNotReady
        /// Already recording (double-start guard).
        case rejectAlreadyRecording
    }

    public private(set) var phase: Phase = .loading
    private var nextRaw = 1

    public init() {}

    /// The session that owns the machine right now (recording or processing).
    public var activeSession: DictationSessionID? {
        switch phase {
        case .recording(let id), .processing(let id): return id
        case .loading, .idle, .failed: return nil
        }
    }

    /// True while `id` is the session every side effect must belong to.
    public func isCurrent(_ id: DictationSessionID) -> Bool { activeSession == id }

    // MARK: - Model lifecycle

    public mutating func modelUnloading() { phase = .loading }

    public mutating func modelLoaded() {
        switch phase {
        case .loading, .failed: phase = .idle
        case .idle, .recording, .processing: break
        }
    }

    public mutating func modelFailed(_ reason: String) {
        phase = .failed(reason)
    }

    // MARK: - Utterance lifecycle

    /// A hotkey gesture wants to start recording.
    public mutating func requestRecording() -> StartDecision {
        switch phase {
        case .idle:
            let id = DictationSessionID(raw: nextRaw)
            nextRaw += 1
            phase = .recording(id)
            return .start(id)
        case .processing:
            return .rejectStillProcessing
        case .recording:
            return .rejectAlreadyRecording
        case .loading, .failed:
            return .rejectNotReady
        }
    }

    /// Recording stopped; the pipeline is now running. Only the session that
    /// owns the recording can move it to processing.
    @discardableResult
    public mutating func beginProcessing(_ id: DictationSessionID) -> Bool {
        guard case .recording(let current) = phase, current == id else { return false }
        phase = .processing(id)
        return true
    }

    /// A recording was dropped without processing (stray tap, gated transform,
    /// mic failure). Stale ids are no-ops.
    @discardableResult
    public mutating func abortRecording(_ id: DictationSessionID) -> Bool {
        guard case .recording(let current) = phase, current == id else { return false }
        phase = .idle
        return true
    }

    /// The pipeline for `id` ended (success or failure). A STALE id is a no-op:
    /// an older task can never yank the phase out from under a newer session —
    /// which is exactly what protects the newer session's UI state and Escape
    /// monitor from an older, slower pipeline.
    @discardableResult
    public mutating func finish(_ id: DictationSessionID) -> Bool {
        guard activeSession == id else { return false }
        phase = .idle
        return true
    }

    /// Esc: cancel whatever is active. Returns the canceled session (nil if none).
    @discardableResult
    public mutating func cancelActive() -> DictationSessionID? {
        guard let id = activeSession else { return nil }
        phase = .idle
        return id
    }
}
