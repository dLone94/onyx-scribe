import FlowCloneCore
import AppKit

/// One utterance, snapshotted when the gesture resolves. Immutable: the
/// pipeline reads its identity, target, and configuration from here — never
/// from live controller state — so an older pipeline can't act on a newer
/// session's world (or vice versa).
struct DictationSession {
    enum Mode {
        case dictation
        case transform(SelectionEditor.Selection)
    }

    /// The app + field this utterance is aimed at, captured at recording start.
    struct Target {
        let pid: pid_t?
        let bundleID: String?
        let appName: String?
        /// Secure (password) field focus at capture. Secure targets never start
        /// a dictation at all; the flag exists so persistence decisions fail
        /// closed even if that policy ever changes.
        let secure: Bool
        /// Whether an editable paste target was focused at recording start.
        let editable: Bool
        /// Text around the caret at recording start (nil if unreadable).
        let insertionContext: ContextReader.Context?
    }

    let id: DictationSessionID
    let startedAt: Date
    let mode: Mode
    /// Engine snapshot — an engine switch mid-utterance can't retarget a
    /// running pipeline (reloads are also rejected while non-idle).
    let engine: any ASREngine
    let engineName: String
    /// Language configuration snapshot.
    let autoLanguage: Bool
    let language: String
    let altLanguage: String
    let target: Target?

    /// Languages auto-detect arbitrates between (deduped).
    var autoCandidates: [String] {
        altLanguage == language ? [language] : [language, altLanguage]
    }
}

/// Orchestrates the pipeline: hotkey → record → transcribe → cleanup → inject.
///
/// **Isolation.** The controller is `@MainActor`. Every input it reacts to is
/// already main-thread (global hotkey monitors, the Esc monitor, menu actions),
/// and every output it drives is main-thread (the pill, the menu-bar state), so
/// the main actor is the natural home for its mutable state.
///
/// **Lifecycle.** The pure `DictationStateMachine` (FlowCloneCore, unit-tested)
/// owns the phase: loading / idle / recording(session) / processing(session) /
/// failed. A new gesture while an older utterance is processing is rejected
/// with a quiet pill message — two pipelines never share operation state.
///
/// **Cancellation.** Esc cancels the stored pipeline `Task` AND retires the
/// session in the machine. Every pipeline re-checks `isCurrent(session)`
/// immediately after each `await` and immediately before every side effect
/// (settings changes, clipboard writes, AX writes, deletes/rewrites,
/// persistence, sounds, UI) — a canceled utterance can do none of them, and a
/// stale task can never touch a newer session's UI or Escape monitor.
///
/// **Targets.** The intended app is pinned in the session at recording start;
/// `TextInjector` revalidates it (and secure-field focus) immediately before
/// every write. If the user switched apps mid-processing, nothing is pasted —
/// the words go to the Scratchpad when privacy allows, otherwise they are
/// discarded with an honest pill message.
@MainActor
final class DictationController {
    enum State { case loadingModel, idle, recording, processing, failed }

    private let hotkey = HotkeyManager()
    private let recorder = AudioRecorder()
    private var engine: any ASREngine
    private let ollama = OllamaClient()
    private let performanceClock = ContinuousClock()

    enum CleanupEngineKind { case apple, ollama }

    /// Which engine cleans this transcript. Delegates to the pure, unit-tested
    /// `EngineRouter` (FlowCloneCore): English → the fast, prewarmed Apple
    /// engine when available and the language is reliably detected; everything
    /// else → Ollama. Non-English and unreliable detection outrank even an
    /// explicit "apple" preference — Apple FM can't be trusted beyond English.
    ///
    /// `nonisolated`: it reads only `Settings` (UserDefaults, thread-safe) and
    /// `AppleCleanup.isAvailable` (a device fact), then delegates to the pure
    /// `EngineRouter` — no controller state is touched. That keeps the headless
    /// CLI paths in `main.swift` and the menu-building code in `AppDelegate`
    /// callable without dragging either onto this actor.
    nonisolated static func cleanupEngine(for langCode: String, restyleTone: Bool = false) -> CleanupEngineKind {
        EngineRouter.cleanupEngine(
            languageCode: langCode,
            preference: Settings.cleanupEngine,
            appleAvailable: AppleCleanup.isAvailable,
            detectionReliable: Self.detectionReliable,
            restyleTone: restyleTone
        ) == .apple ? .apple : .ollama
    }

    /// Where to retry when `failed` threw before anything was pasted — the
    /// pure, unit-tested `CleanupFallback` rule, in this file's engine type.
    nonisolated static func fallbackEngine(after failed: CleanupEngineKind,
                                           languageCode: String) -> CleanupEngineKind? {
        switch CleanupFallback.engine(after: failed == .apple ? .apple : .ollama,
                                      appleAvailable: AppleCleanup.isAvailable,
                                      languageCode: languageCode) {
        case .apple: return .apple
        case .ollama: return .ollama
        case nil: return nil
        }
    }

    /// Whether the language label fed to the router can be trusted, derived
    /// from the ASR engine the live pipeline ACTUALLY uses. Pinned language →
    /// always reliable. Auto-language → reliable only on Parakeet, whose
    /// confidence arbitration is real; Whisper's default just relabels the
    /// first candidate (which is also why auto-language is disabled on Whisper).
    nonisolated static var detectionReliable: Bool {
        !Settings.autoLanguage || Settings.asrEngine != "whisper"
    }

    private let onStateChange: (State) -> Void
    /// Floating pill UI (optional — headless/--test paths run without it).
    var pill: PillController?

    // MARK: - Lifecycle state

    /// Pure phase machine — the single authority on what may happen next.
    private var machine = DictationStateMachine()
    /// Audio capture began but the gesture hasn't resolved to dictation or
    /// transform yet (the buffer-early fix: no leading words are clipped).
    private struct PendingCapture { let id: DictationSessionID; let startedAt: Date }
    private var pendingCapture: PendingCapture?
    /// The resolved, immutable session for the active utterance.
    private var activeSession: DictationSession?
    /// The running pipeline — canceled on Esc, authoritatively.
    private var pipelineTask: Task<Void, Never>?

    private var modelReady = false
    /// The loaded ASR engine, for borrowing by the onboarding demo.
    /// nil while loading or switching — callers must re-poll, never cache.
    var sharedEngine: (any ASREngine)? { modelReady ? engine : nil }

    /// Last text we injected — the target for voice-editing commands.
    /// Only valid while the caret is still right after it (same app, same field).
    private var lastInjected: String?
    private var lastInjectedApp: String?

    /// Hands-free: armed via the menu item / optional hotkey, it locks the NEXT
    /// dictation on so the user can speak without holding; the next press stops.
    private var handsFreeArmed = false
    private var handsFreeLocked = false
    /// Turns raw press/release into dictation-vs-transform intents (pure, tested).
    private var recognizer = GestureRecognizer()
    private var pendingTimeout: DispatchWorkItem?
    /// Optional second hotkey that arms hands-free (validated distinct from the
    /// dictation hotkey).
    private var handsFreeHotkey: HotkeyManager?
    /// Selection-transform is capped so a huge selection can't stall the model.
    private static let maxTransformChars = 8000
    private var keepWarmTimer: Timer?

    /// Self-pacing live-transcript loop (avoids overlapping partials).
    private var partialRunning = false
    private var partialActive = false
    /// The in-flight partial decode. The final decode AWAITS it, so the two
    /// never overlap on the same engine instance.
    private var partialTask: Task<Void, Never>?
    /// Sticky auto-detected language for the current recording: the partial loop
    /// arbitrates once, then reuses it so live partials stay single-pass. The
    /// final transcribe re-arbitrates authoritatively regardless.
    private var partialLang: String?

    init(onStateChange: @escaping (State) -> Void) {
        self.onStateChange = onStateChange
        self.engine = Self.makeEngine()
    }

    private static func makeEngine() -> any ASREngine {
        Settings.asrEngine == "whisper" ? WhisperEngine() : Transcriber()
    }

    /// Every side effect belongs to exactly one session; this is the check that
    /// gates them all. True only while `session` still owns the machine AND the
    /// surrounding task hasn't been canceled.
    private func isCurrent(_ session: DictationSession) -> Bool {
        isCurrentID(session.id)
    }

    private func isCurrentID(_ id: DictationSessionID) -> Bool {
        machine.isCurrent(id) && !Task.isCancelled
    }

    /// Switches ASR engine (called from the menu / Settings). Rejected while an
    /// utterance is active — an engine swap must never race a live
    /// transcription. Loads the new engine before swapping so dictation keeps
    /// working if the load fails.
    func reloadEngine() {
        // `.failed` (the last load threw) is recoverable: there is no working
        // engine to protect, so a switch — or a retry of the same engine — is
        // always allowed. Only a live utterance or an in-flight load rejects.
        let recovering: Bool
        switch machine.phase {
        case .idle: recovering = false
        case .failed: recovering = true
        case .loading, .recording, .processing:
            // Revert the already-written setting; the swap didn't happen.
            Settings.asrEngine = engine is WhisperEngine ? "whisper" : "parakeet"
            pill?.showInfo("busy — try the engine switch again")
            Diag.event("engine switch rejected: utterance in flight")
            return
        }
        machine.modelUnloading()
        onStateChange(.loadingModel)
        modelReady = false
        let newEngine = Self.makeEngine()
        Task {
            do {
                try await newEngine.load()
                engine = newEngine
                modelReady = true
                Diag.event("engine switched: \(newEngine.displayName)")
            } catch {
                if recovering {
                    // Nothing was loaded before either — stay failed (honestly)
                    // on the engine the user last chose, so the next retry
                    // targets it.
                    engine = newEngine
                    machine.modelFailed("ASR model failed to load")
                    Diag.pipelineError("ASR model failed to load", error)
                    pill?.showError("speech model failed to load")
                    onStateChange(.failed)
                    return
                }
                // Revert setting; keep the old (already loaded) engine.
                Settings.asrEngine = engine is WhisperEngine ? "whisper" : "parakeet"
                modelReady = true
                Diag.pipelineError("engine switch failed — staying on \(engine.displayName)", error)
            }
            machine.modelLoaded()
            onStateChange(.idle)
        }
    }

    /// Called after the user changes the hotkey in Settings.
    func updateHotkey() {
        hotkey.reload()
        // Rebuild the optional hands-free monitor (it may have been added/removed).
        handsFreeHotkey?.stop()
        startHandsFreeHotkey()
    }

    func start() {
        onStateChange(.loadingModel)
        Task {
            do {
                try await engine.load()
                modelReady = true
                machine.modelLoaded()
                Diag.event("\(engine.displayName) loaded — ready to dictate")
                onStateChange(.idle)
            } catch {
                machine.modelFailed("ASR model failed to load")
                Diag.pipelineError("ASR model failed to load", error)
                pill?.showError("speech model failed to load")
                onStateChange(.failed)
            }
        }

        hotkey.onPress = { [weak self] in self?.onHotkeyPress() }
        hotkey.onRelease = { [weak self] in self?.onHotkeyRelease() }
        hotkey.start()
        startHandsFreeHotkey()

        // Captures the pill directly (thread-safe by design): the tap thread
        // must not touch main-actor controller state.
        let pill = self.pill
        recorder.onLevel = { level in pill?.updateLevel(level) }
        hotkey.onEscape = { [weak self] in self?.cancelDictation() }

        // Page the Apple Intelligence model in so first cleanup isn't cold.
        AppleCleanup.prewarm()
        // Keep the cleanup model resident in Ollama so it never cold-starts.
        Task {
            await ollama.keepWarm()
            OllamaHealth.shared.check()
        }
        keepWarmTimer = Timer.scheduledTimer(withTimeInterval: 8 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.ollama.keepWarm()
                OllamaHealth.shared.check()
            }
        }
    }

    // MARK: - Hotkey gestures
    // Hold = dictate. Double-tap-hold = transform the selection. Hands-free
    // (armed via menu / optional hotkey) locks the next dictation on. All
    // disambiguation lives in the pure, tested GestureRecognizer.

    private func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    private func onHotkeyPress() {
        // A locked hands-free recording: this press stops and processes it.
        if handsFreeLocked {
            handsFreeLocked = false
            resetRecognizer()
            finishRecording()
            return
        }
        // Armed hands-free: start a locked dictation immediately (no hold needed).
        if handsFreeArmed {
            handsFreeArmed = false
            resetRecognizer()
            startCapture()
            if pendingCapture != nil {
                handsFreeLocked = true
                beginDictation()
            }
            return
        }
        execute(recognizer.handle(.press(now())))
    }

    private func onHotkeyRelease() {
        if handsFreeLocked { return } // locked session ends on the next press
        execute(recognizer.handle(.release(now())))
    }

    /// Runs the recognizer's outputs against the recorder/pill.
    private func execute(_ outputs: [GestureRecognizer.Output]) {
        for out in outputs {
            switch out {
            case .startCapture:   startCapture()
            case .cancelCapture:  cancelCapture()
            case .beginDictation: beginDictation()
            case .beginTransform: beginTransform()
            case .finish:         finishRecording()
            case .armTimeout(let deadline): scheduleTimeout(deadline)
            }
        }
    }

    private func scheduleTimeout(_ deadline: TimeInterval) {
        pendingTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.execute(self.recognizer.handle(.timeout(deadline)))
        }
        pendingTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now()), execute: item)
    }

    private func resetRecognizer() {
        recognizer = GestureRecognizer()
        pendingTimeout?.cancel()
        pendingTimeout = nil
    }

    /// Esc pressed: abort whatever is in flight — recording or processing —
    /// and never inject. Cancellation is authoritative: the machine retires the
    /// session AND the pipeline task itself is canceled, so an in-flight model
    /// call unwinds instead of running to completion.
    private func cancelDictation() {
        if case .recording = machine.phase { _ = recorder.stop() }
        if let pending = pendingCapture {
            machine.abortRecording(pending.id)
            pendingCapture = nil
            _ = recorder.stop()
        }
        _ = machine.cancelActive()
        pipelineTask?.cancel()
        pipelineTask = nil
        activeSession = nil
        handsFreeLocked = false
        handsFreeArmed = false
        resetRecognizer()
        stopPartialLoop()
        hotkey.stopEscapeMonitor()
        pill?.hide()
        onStateChange(.idle)
        Diag.event("dictation canceled")
    }

    /// Arms hands-free for the next dictation (menu item / optional hotkey).
    func armHandsFree() {
        guard modelReady else { return }
        handsFreeArmed = true
        pill?.showInfo("Hands-free armed")
        Diag.event("hands-free armed")
    }

    private func startHandsFreeHotkey() {
        guard Settings.handsFreeHotkey != nil else { handsFreeHotkey = nil; return }
        let mgr = HotkeyManager(spec: { Settings.handsFreeHotkey })
        mgr.onPress = { [weak self] in self?.armHandsFree() }
        mgr.start()
        handsFreeHotkey = mgr
    }

    // MARK: - Live transcript (partial transcription loop)

    /// Re-transcribes the accumulated buffer roughly once a second while
    /// recording (Parakeet on the ANE is ~190× realtime, so each pass costs
    /// ~100ms) and streams the tail into the pill. Self-pacing: the next pass
    /// only schedules after the previous finishes, so a slower engine
    /// (Whisper) naturally degrades to a slower cadence instead of piling up.
    private func startPartialLoop(_ session: DictationSession) {
        partialActive = true
        schedulePartial(session, after: 0.9)
    }

    private func stopPartialLoop() {
        partialActive = false
    }

    private func schedulePartial(_ session: DictationSession, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runPartial(session)
        }
    }

    private func runPartial(_ session: DictationSession) {
        guard partialActive, machine.phase == .recording(session.id) else { return }
        // A decode from the PREVIOUS recording can still be in flight (slow
        // engine, quick re-dictation). Wait it out instead of returning — a
        // bare return here ended this session's loop for good.
        guard !partialRunning else {
            schedulePartial(session, after: 0.3)
            return
        }
        let samples = recorder.snapshot()
        guard samples.count > 12_000 else { // ~0.75s of audio minimum
            schedulePartial(session, after: 0.5)
            return
        }
        partialRunning = true
        partialTask = Task {
            defer {
                partialRunning = false
                if partialActive, machine.phase == .recording(session.id) {
                    schedulePartial(session, after: 0.6)
                }
            }
            let candidates = session.autoLanguage
                ? (partialLang.map { [$0] } ?? session.autoCandidates)  // sticky after first detect
                : [session.language]
            guard let r = try? await session.engine.transcribeAuto(samples, candidates: candidates),
                  machine.phase == .recording(session.id), partialActive, !r.text.isEmpty
            else { return }
            if session.autoLanguage {
                partialLang = r.code
                pill?.setLanguage(r.code)
            }
            pill?.updateLiveText(r.text)
        }
    }

    // MARK: - Capture lifecycle

    /// Begins buffering audio the instant the key goes down — BEFORE we know
    /// whether this is a dictation hold or a transform tap — so a normal
    /// dictation never clips its leading words. AUDIO + UI ONLY: it must read no
    /// AX/screen content, because a free user's transform gesture also lands here
    /// first; the caret/selection reads happen only after the gesture resolves.
    /// Promoted by beginDictation/beginTransform, or dropped by cancelCapture.
    private func startCapture() {
        switch machine.requestRecording() {
        case .rejectStillProcessing:
            // Safe policy: never two pipelines. Quiet pill note; the gesture is
            // swallowed so a stray release can't confuse the recognizer.
            pill?.showInfo("still finishing the last one…")
            resetRecognizer()
            return
        case .rejectNotReady:
            Diag.event("gesture ignored — model not ready")
            resetRecognizer()
            // A failed load (e.g. the first-run model download had no network)
            // must not be terminal: the next hotkey press retries it.
            if case .failed = machine.phase {
                pill?.showInfo("retrying speech model…")
                reloadEngine()
            }
            return
        case .rejectAlreadyRecording:
            return
        case .start(let id):
            partialLang = nil // fresh auto-detect each recording
            do {
                try recorder.start()
                pendingCapture = PendingCapture(id: id, startedAt: Date())
                pill?.showRecording()
                hotkey.startEscapeMonitor()
            } catch {
                machine.abortRecording(id)
                pendingCapture = nil
                Diag.error("mic start failed", error: error, logger: Diag.audio)
                pill?.showError("mic unavailable")
                resetRecognizer()
            }
        }
    }

    /// The gesture resolved to a plain dictation — NOW read the caret context
    /// (deferred from startCapture so it never runs for a gated transform),
    /// pin the target app, light up the recording UI, and start the live
    /// transcript loop. Secure fields block dictation outright.
    private func beginDictation() {
        guard let pending = pendingCapture else { return }
        let info = ContextReader.targetInfo()
        if info.secure {
            // Never dictate into a password field — no audio kept, no paste.
            cancelCapture()
            pill?.showInfo("secure field — dictation blocked")
            Diag.event("secure field focused — dictation blocked")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let session = DictationSession(
            id: pending.id,
            startedAt: pending.startedAt,
            mode: .dictation,
            engine: engine,
            engineName: engine is WhisperEngine ? "Whisper" : "Parakeet",
            autoLanguage: Settings.autoLanguage && Settings.autoLanguageAvailable,
            language: Settings.language,
            altLanguage: Settings.altLanguage,
            target: DictationSession.Target(
                pid: app?.processIdentifier,
                bundleID: app?.bundleIdentifier,
                appName: app?.localizedName,
                secure: false,
                editable: info.editable,
                insertionContext: Settings.contextAware ? ContextReader.read() : nil))
        activeSession = session
        pendingCapture = nil
        onStateChange(.recording)
        startPartialLoop(session)
        FlowSound.recordStart()
        if handsFreeLocked {
            pill?.setLocked()
            Diag.event("hands-free recording locked")
        }
    }

    /// The gesture resolved to a selection-transform. Gate BEFORE reading the
    /// selection (never touch a free user's private content), enforce the size
    /// cap, and capture the fingerprint we'll re-verify before writing.
    private func beginTransform() {
        guard let pending = pendingCapture else { return }
        guard LicenseModel.shared.snapshot().hasPro else {
            cancelCapture()
            pill?.showInfo("Transform is a paid feature")
            Diag.event("transform gesture gated (free tier)")
            return
        }
        guard let selection = SelectionEditor.readSelection() else {
            cancelCapture()
            pill?.showError("select text to transform")
            FlowSound.error()
            return
        }
        guard selection.text.count <= Self.maxTransformChars else {
            cancelCapture()
            pill?.showError("selection too large")
            FlowSound.error()
            Diag.event("selection too large (\(selection.text.count) chars, cap \(Self.maxTransformChars))")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication
        let session = DictationSession(
            id: pending.id,
            startedAt: pending.startedAt,
            mode: .transform(selection),
            engine: engine,
            engineName: engine is WhisperEngine ? "Whisper" : "Parakeet",
            autoLanguage: Settings.autoLanguage && Settings.autoLanguageAvailable,
            language: Settings.language,
            altLanguage: Settings.altLanguage,
            target: DictationSession.Target(
                pid: selection.pid,
                bundleID: app?.bundleIdentifier,
                appName: app?.localizedName,
                secure: false,
                editable: true,
                insertionContext: nil))
        activeSession = session
        pendingCapture = nil
        onStateChange(.recording)
        FlowSound.recordStart()
        pill?.showRecording()
        Diag.event("transform mode — \(selection.text.count) selected chars")
    }

    /// Drop an in-progress capture (a tap that wasn't a hold, an aborted
    /// transform, a secure-field block). Nothing is transcribed or injected.
    private func cancelCapture() {
        _ = recorder.stop()
        if let pending = pendingCapture { machine.abortRecording(pending.id) }
        if let session = activeSession { machine.abortRecording(session.id) }
        pendingCapture = nil
        activeSession = nil
        stopPartialLoop()
        hotkey.stopEscapeMonitor()
        pill?.hide()
        onStateChange(.idle)
    }

    private func finishRecording() {
        guard let session = activeSession, machine.phase == .recording(session.id) else {
            // The gesture's capture never resolved (blocked/aborted) — nothing to do.
            return
        }
        let duration = Date().timeIntervalSince(session.startedAt)
        stopPartialLoop()
        let samples = recorder.stop()

        // Selection-transform runs on its own pipeline branch (bypasses dictation,
        // tone-switch, translate-mode, and voice-edit command detection).
        if case .transform(let selection) = session.mode {
            machine.beginProcessing(session.id)
            onStateChange(.processing)
            pill?.showProcessing()
            pipelineTask = Task { await self.runTransform(session, selection: selection, samples: samples) }
            return
        }

        // Ignore accidental taps.
        guard duration > 0.3, samples.count > 4800 else {
            machine.abortRecording(session.id)
            activeSession = nil
            hotkey.stopEscapeMonitor()
            pill?.hide()
            onStateChange(.idle)
            return
        }

        FlowSound.recordStop()
        machine.beginProcessing(session.id)
        onStateChange(.processing)
        pill?.showProcessing()
        pipelineTask = Task { await self.runPipeline(session, samples: samples, duration: duration) }
    }

    /// The single exit for both pipelines. A stale session (canceled, or
    /// superseded after a cancel) is a no-op here — it must not touch the newer
    /// session's UI state or remove its Escape monitor.
    private func finishPipeline(_ session: DictationSession) {
        guard machine.finish(session.id) else { return }
        if activeSession?.id == session.id { activeSession = nil }
        onStateChange(.idle)
        hotkey.stopEscapeMonitor()
    }

    // MARK: - Streaming cleanup

    /// Outcome of a streaming primary cleanup path (Apple or local Ollama).
    private enum StreamCleanupOutcome {
        case cleaned(String)                           // preview-only: nothing pasted yet
        case injected(full: String, injected: String, injectionMs: Int)
        case canceled(injected: String)                // Esc / focus-lost mid-stream
        case degradedAfterCommit(injected: String, injectionMs: Int)
        case failedBeforeCommit(Error)                 // nothing pasted → caller retries on Ollama
    }

    /// Mutable bookkeeping for one streaming cleanup, in a `@MainActor` box so
    /// the model's off-actor streaming callback can carry it while every
    /// mutation still happens here, in order.
    @MainActor
    private final class StreamState {
        var chunker = StreamChunker()
        var earlyChunk: String?   // untrimmed early chunk consumed (remainder math)
        var injected = ""         // exact bytes pasted so far (F7)
        var injectionMs = 0        // paste time that overlaps the cleanup interval
        var lastSnapshot = ""     // latest untrimmed cumulative snapshot
        var focusLost = false     // pinned target lost focus, or we were superseded
    }

    /// Stream Apple FM or Ollama cleanup. `earlyInject: false` (the default) is
    /// pill-preview only — each snapshot shows in the pill and the caller does
    /// ONE validated paste at the end, zero injection risk. `earlyInject: true`
    /// (advanced opt-in) additionally pastes one confirmed sentence early and
    /// the remainder at the end, bounded to two pastes, with every adversarial-
    /// review guard (F1–F14; see PLAN.md). Never streams the fallback engines.
    private func runStreamingCleanup(raw: String,
                                     session dictSession: DictationSession,
                                     engine: CleanupEngineKind,
                                     languageCode: String,
                                     earlyInject: Bool) async -> StreamCleanupOutcome {
        let appName = dictSession.target?.appName
        let context = dictSession.target?.insertionContext

        let sessionID = dictSession.id
        guard earlyInject else {
            do {
                let final = try await streamCleanup(
                    engine: engine, raw: raw, app: appName, context: context,
                    languageCode: languageCode
                ) { snapshot in
                    await self.preview(snapshot, for: sessionID)
                }
                return .cleaned(final.isEmpty ? raw : final)
            } catch {
                return .failedBeforeCommit(error)
            }
        }

        let needsLeadingSpace = ContextReader.needsLeadingSpace(context)
        // The stream writes into the target pinned at RECORDING start — never
        // whatever happens to be frontmost when cleanup begins.
        let session = TextInjector.beginStream(
            target: .pinned(dictSession.target?.pid))
        defer { TextInjector.endStream(session) }                         // F2: restore on every exit
        let state = StreamState()
        var streamError: Error?
        let t1 = Date()

        do {
            _ = try await streamCleanup(
                engine: engine, raw: raw, app: appName, context: context,
                languageCode: languageCode
            ) { snapshot in
                await self.ingest(snapshot, into: state, session: session,
                                  needsLeadingSpace: needsLeadingSpace, sessionID: sessionID)
            }
        } catch {
            streamError = error
        }

        let llmMs = Int(Date().timeIntervalSince(t1) * 1000)
        let outcome: StreamCleanupOutcome

        switch StreamOutcome.resolve(canceled: !isCurrentID(sessionID),
                                     focusLost: state.focusLost,
                                     failed: streamError != nil,
                                     committedEarly: state.earlyChunk != nil,
                                     injected: state.injected) {
        case .canceled(let injected):
            if injected.isEmpty, isCurrentID(sessionID) {
                // NOT an Esc: the pinned target lost focus before anything
                // landed. Hand the text to the caller's single validated paste,
                // which re-checks the target and otherwise saves the words to
                // the Scratchpad — never a silent drop behind a stuck pill.
                outcome = .cleaned(streamError == nil
                    ? StreamInjectionPlan.whole(snapshot: state.lastSnapshot,
                                                fallbackRaw: raw,
                                                needsLeadingSpace: false)
                    : raw)
            } else {
                outcome = .canceled(injected: injected)                    // F5/F6
            }
        case .degradedAfterCommit(let injected):
            outcome = .degradedAfterCommit(
                injected: injected, injectionMs: state.injectionMs)         // F10/F11
        case .failedBeforeCommit:
            // Nothing pasted → the caller can safely retry the whole utterance
            // on Ollama. `streamError` is non-nil whenever this case is reached.
            outcome = .failedBeforeCommit(streamError ?? AppleCleanup.Unavailable())
        case .proceed(var injected):
            if let early = state.earlyChunk {
                // Success with an early sentence committed: paste the remainder once.
                if let tail = StreamInjectionPlan.tail(finalSnapshot: state.lastSnapshot,
                                                       earlyChunk: early) {
                    if !tail.isEmpty {
                        let result = await timedCommit(
                            tail, to: session, sessionID: sessionID)
                        state.injectionMs += result.durationMs
                        if result.succeeded { injected += tail }
                        else {
                            outcome = .degradedAfterCommit(
                                injected: injected, injectionMs: state.injectionMs)
                            break
                        }
                    }
                    outcome = .injected(
                        full: injected, injected: injected,
                        injectionMs: state.injectionMs)
                } else {
                    outcome = .degradedAfterCommit(
                        injected: injected, injectionMs: state.injectionMs) // F11 divergence
                }
            } else {
                // No early chunk (short / no stable boundary): one clean paste (F13).
                let whole = StreamInjectionPlan.whole(snapshot: state.lastSnapshot,
                                                      fallbackRaw: raw,
                                                      needsLeadingSpace: needsLeadingSpace)
                let result = await timedCommit(
                    whole, to: session, sessionID: sessionID)
                state.injectionMs += result.durationMs
                if result.succeeded {
                    outcome = .injected(
                        full: whole, injected: whole,
                        injectionMs: state.injectionMs)
                } else if isCurrentID(sessionID) {
                    // Focus lost on the only paste (not an Esc): same hand-off
                    // to the caller's validated paste / Scratchpad fallback.
                    outcome = .cleaned(StreamInjectionPlan.whole(
                        snapshot: state.lastSnapshot, fallbackRaw: raw,
                        needsLeadingSpace: false))
                } else {
                    outcome = .canceled(injected: "")                      // Esc during the only paste
                }
            }
        }

        if case .injected(let full, _, _) = outcome {
            Diag.content("streamed [\(engine == .apple ? "Apple" : "Ollama")] "
                         + "(\(llmMs)ms, \(full.count) chars)", content: full)
        }
        return outcome
    }

    private func streamCleanup(
        engine: CleanupEngineKind,
        raw: String,
        app: String?,
        context: ContextReader.Context?,
        languageCode: String,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        switch engine {
        case .apple:
            return try await AppleCleanup.cleanupStreaming(
                raw, app: app, context: context, languageCode: languageCode,
                onPartial: onPartial)
        case .ollama:
            return try await ollama.cleanupStreaming(
                raw, app: app, context: context, languageCode: languageCode,
                onPartial: onPartial)
        }
    }

    /// Phase-1 preview: show the streaming snapshot in the pill — but only for
    /// the session that's still current (a stale stream must not repaint a
    /// newer session's UI).
    private func preview(_ snapshot: String, for id: DictationSessionID) {
        guard machine.isCurrent(id) else { return }
        pill?.updateLiveText(snapshot)
    }

    /// One streaming snapshot: preview it in the pill and, at most once, commit
    /// the first confirmed sentence into the document (opt-in Phase 2 only).
    private func ingest(_ snapshot: String,
                        into state: StreamState,
                        session: TextInjector.StreamSession,
                        needsLeadingSpace: Bool,
                        sessionID: DictationSessionID) async {
        state.lastSnapshot = snapshot
        preview(snapshot, for: sessionID)
        // F5: stop committing once canceled / focus lost / already committed early.
        guard isCurrentID(sessionID), !state.focusLost, state.earlyChunk == nil else { return }
        guard let chunk = state.chunker.earlyChunk(snapshot) else { return }
        let toPaste = StreamInjectionPlan.earlyChunk(chunk, needsLeadingSpace: needsLeadingSpace)
        let result = await timedCommit(
            toPaste, to: session, sessionID: sessionID)
        state.injectionMs += result.durationMs
        if result.succeeded {
            state.earlyChunk = chunk
            state.injected = toPaste
        } else {
            state.focusLost = true                                         // F10, or superseded
        }
    }

    /// Paste one streamed chunk; the injector re-validates the pinned target
    /// and re-checks `stillCurrent` after its settle-gap suspension.
    private func commit(_ chunk: String,
                        to session: TextInjector.StreamSession,
                        sessionID: DictationSessionID) async -> Bool {
        await TextInjector.commitStream(session, chunk,
                                        stillCurrent: { self.isCurrentID(sessionID) })
    }

    private func timedCommit(_ chunk: String,
                             to session: TextInjector.StreamSession,
                             sessionID: DictationSessionID) async
        -> (succeeded: Bool, durationMs: Int) {
        let startedAt = performanceClock.now
        let succeeded = await commit(chunk, to: session, sessionID: sessionID)
        return (succeeded, elapsedMs(since: startedAt))
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: performanceClock.now).components
        let whole = components.seconds * 1_000
        let fractional = components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(whole + fractional))
    }

    // MARK: - Dictation pipeline

    private func runPipeline(_ session: DictationSession,
                             samples: [Float],
                             duration: TimeInterval) async {
        defer { finishPipeline(session) }
        do {
            var cleanupDegraded = false
            var didStreamInject = false   // streaming path already pasted (F1)
            var streamInjected = ""       // exact bytes the stream pasted (F6/F7)
            var streamInjectionMs = 0     // paste time overlapping streamed cleanup
            var toneUnavailable = false   // restyle tone wanted but Ollama couldn't apply it
            var latencyEngine: PipelineLatencySample.Engine = .local
            let t0 = performanceClock.now

            // ASR serialization: the final decode never overlaps an in-flight
            // partial on the same engine instance.
            stopPartialLoop()
            await partialTask?.value

            var raw: String
            var detectedLang = session.language
            if session.autoLanguage {
                // Authoritative: arbitrate the final decode. The partial
                // loop's detection goes first so the early-exit usually
                // makes this a single decode; a low-confidence first pass
                // still falls through to the other language.
                let ordered = partialLang.map { lang in
                    [lang] + session.autoCandidates.filter { $0 != lang }
                } ?? session.autoCandidates
                let r = try await session.engine.transcribeAuto(samples, candidates: ordered)
                raw = r.text
                detectedLang = r.code
                guard isCurrent(session) else { Diag.event("result discarded (canceled)"); return }
                pill?.setLanguage(r.code)
                Diag.event("lang=\(r.code) conf=\(String(format: "%.2f", r.confidence))")
            } else {
                raw = try await session.engine.transcribe(
                    samples, languageCode: session.language)
            }
            // Cancellation is authoritative — re-check after every await.
            guard isCurrent(session) else { Diag.event("result discarded (canceled)"); return }
            let asrMs = elapsedMs(since: t0)
            guard !raw.isEmpty else {
                pill?.showError("didn't catch that")
                FlowSound.error()
                return
            }
            raw = VocabularyCorrector.apply(raw)
            Diag.content("ASR done (\(asrMs)ms, \(raw.count) chars)", content: raw)

            // Paid-feature gate: trial and active subscription unlock cleanup,
            // tones, and voice commands; the free tier is verbatim dictation.
            let pro = LicenseModel.shared.snapshot().hasPro

            // Spoken tone switch ("switch to formal tone"): a settings
            // command, not dictation — confirm on the pill, paste nothing.
            // A canceled command must not change settings.
            if pro, let toneID = ToneSwitchCommand.detect(
                raw, tones: Tone.all.map { ($0.id, $0.name) }) {
                guard isCurrent(session) else { return }
                let name = Tone.all.first { $0.id == toneID }?.name ?? toneID
                Settings.tone = toneID
                AppleCleanup.prewarm() // re-prewarm with the new tone's prompt
                Diag.event("voice command: tone switch")
                pill?.showInfo("\(name) tone")
                FlowSound.success()
                return
            }

            // Spoken translate-mode switch ("translate to English" / "stop
            // translating"): a settings command, paste nothing.
            if pro, let cmd = TranslateCommand.detect(raw, languages: AppDelegate.translateLanguages) {
                guard isCurrent(session) else { return }
                switch cmd {
                case .to(let code):
                    Settings.translateTo = code
                    pill?.showInfo("Translating → \(AppDelegate.englishName(code))")
                    Diag.event("voice command: translate mode → \(code)")
                case .off:
                    Settings.translateTo = nil
                    pill?.showInfo("Translation off")
                    Diag.event("voice command: translate mode off")
                }
                FlowSound.success()
                return
            }

            // Context-aware drafting ("reply, tell them Thursday works"):
            // detected up front so it isn't mistaken for a voice-edit command.
            let draftIntent: String? = pro ? DraftCommand.detect(raw) : nil

            // Voice-editing command targeting the previous injection?
            // Only when the caret is plausibly still there (same app).
            let command = CommandDetector.detect(raw)
            if VoiceEdit.shouldHandle(
                hasDraftIntent: draftIntent != nil, pro: pro,
                commandDetected: command != nil,
                hasPreviousInjection: lastInjected != nil,
                sameApp: session.target?.appName == lastInjectedApp),
               let kind = command, let previous = lastInjected {
                try await handleCommand(kind, raw: raw, previous: previous,
                                        session: session, languageCode: detectedLang)
                return
            }

            var final = raw
            let wordCount = raw.split(whereSeparator: \.isWhitespace).count
            // A non-empty tone instruction means the user wants a REWRITE
            // (Casual/Work/Formal/…), which only Ollama honors — the router
            // uses this to keep tones off Apple FM. Faithful/Verbatim carry
            // no instruction and stay on the fast Apple path.
            let restyleTone = !Tone.current.instruction.isEmpty
            let cleanupStartedAt = performanceClock.now
            let path = CleanupPath.decide(
                hasDraftIntent: draftIntent != nil,
                pro: pro,
                translateTo: Settings.translateTo,
                detectedLanguage: detectedLang,
                toneIsVerbatim: Tone.current.isVerbatim,
                cleanupEnabled: Settings.cleanupEnabled,
                skipForLength: CleanupPassPolicy.shouldSkipForLength(
                    wordCount: wordCount, languageCode: detectedLang),
                streamingPreview: Settings.streamingPreview)
            switch path {
            case .draft:
                let intent = draftIntent ?? raw
                // Read what's on screen (locally, via Accessibility) and write
                // the finished message. Falls back to pasting the intent when
                // there's nothing readable or the engine declines — never a
                // dead end. The screen content never leaves the local model.
                let surrounding = ContextReader.readSurrounding()
                if let surrounding {
                    do {
                        let t1 = Date()
                        let ek = Self.cleanupEngine(for: detectedLang, restyleTone: restyleTone)
                        latencyEngine = ek == .apple ? .apple : .ollama
                        let drafted = try await (ek == .apple
                            ? AppleCleanup.draft(context: surrounding.text, intent: intent,
                                                 app: session.target?.appName)
                            : ollama.draft(context: surrounding.text, intent: intent,
                                           app: session.target?.appName))
                        guard isCurrent(session) else { Diag.event("draft discarded (canceled)"); return }
                        let ms = Int(Date().timeIntervalSince(t1) * 1000)
                        final = drafted.isEmpty ? intent : drafted
                        Diag.content("drafted [\(ek == .apple ? "Apple" : "Ollama")] (\(ms)ms)", content: final)
                    } catch {
                        guard isCurrent(session) else { return }
                        Diag.pipelineError("draft failed — pasting the intent", error)
                        final = intent
                        cleanupDegraded = true
                    }
                } else {
                    Diag.event("nothing readable on screen to draft from — pasting the intent")
                    final = intent
                }
            case .translate(let target):
                // Speak one language, type another — translate + clean in one
                // pass, fully offline. Bulgarian anywhere routes to Ollama (Apple
                // FM can't be trusted with it); everything else follows auto.
                do {
                    let t1 = Date()
                    let ek = Self.cleanupEngine(for: (target == "bg" || detectedLang == "bg") ? "bg" : target)
                    latencyEngine = ek == .apple ? .apple : .ollama
                    let name = AppDelegate.englishName(target)
                    let out = try await (ek == .apple
                        ? AppleCleanup.translate(raw, toName: name)
                        : ollama.translate(raw, toName: name))
                    guard isCurrent(session) else { Diag.event("translation discarded (canceled)"); return }
                    let ms = Int(Date().timeIntervalSince(t1) * 1000)
                    final = out.isEmpty ? raw : out
                    Diag.content("translated [\(ek == .apple ? "Apple" : "Ollama")] \(detectedLang)→\(target) (\(ms)ms)",
                                 content: final)
                } catch {
                    guard isCurrent(session) else { return }
                    Diag.pipelineError("translation failed — pasting the original", error)
                    final = raw
                    cleanupDegraded = true
                }
            case .verbatim:
                // Verbatim: exactly as transcribed — no LLM, no filler strip.
                // (Dictionary corrections above still apply; they're user rules.)
                break
            case .mechanical:
                // Free tier, cleanup-off, or short utterances skip the LLM pass
                // entirely — Parakeet already punctuates; just strip stray
                // fillers. Context still applies mechanically (no mid-sentence
                // capital). Free tier gets this clean-verbatim result, not raw.
                final = TextCleanup.stripFillers(
                    raw, capitalize: ContextReader.isSentenceStart(session.target?.insertionContext))
                if !pro {
                    Diag.event("free tier — verbatim only")
                } else if CleanupPassPolicy.shouldSkipForLength(
                    wordCount: wordCount, languageCode: detectedLang), Settings.cleanupEnabled {
                    Diag.event("short utterance — skipped cleanup")
                }
            case .streaming:
                // Both local cleanup engines now stream into the Pill. Early
                // in-document landing remains behind the explicit advanced
                // opt-in and reuses the same bounded two-paste safety contract.
                let streamEngine = Self.cleanupEngine(
                    for: detectedLang, restyleTone: restyleTone)
                latencyEngine = streamEngine == .apple ? .apple : .ollama
                switch await runStreamingCleanup(
                    raw: raw, session: session, engine: streamEngine,
                    languageCode: detectedLang,
                    earlyInject: Settings.streamingEarlyInject
                ) {
                case .cleaned(let text):
                    final = text
                    // falls through to the single validated paste below
                case .injected(let full, let injected, let injectionMs):
                    final = full
                    didStreamInject = true
                    streamInjected = injected
                    streamInjectionMs = injectionMs
                case .canceled(let injected):
                    // F6: keep whatever actually landed so a later voice-edit
                    // targets the right span; then bail like an Esc discard.
                    if !injected.isEmpty {
                        lastInjected = injected
                        lastInjectedApp = session.target?.appName
                    }
                    Diag.event("canceled mid-stream (kept \(injected.count) chars)")
                    return
                case .degradedAfterCommit(let injected, let injectionMs):
                    final = injected
                    didStreamInject = true
                    streamInjected = injected
                    streamInjectionMs = injectionMs
                    cleanupDegraded = true
                case .failedBeforeCommit(let err):
                    // Nothing pasted yet — safe to fail over once using the
                    // non-streaming path. Never retry after an early commit.
                    guard isCurrent(session) else { return }
                    do {
                        let fallback = Self.fallbackEngine(after: streamEngine, languageCode: detectedLang)
                        if streamEngine == .ollama, fallback != nil {
                            OllamaHealth.shared.noteFailure()
                        }
                        guard let fallback else { throw err }
                        Diag.pipelineError(
                            "\(streamEngine == .apple ? "Apple" : "Ollama") streaming failed "
                            + "pre-commit — trying \(fallback == .apple ? "Apple" : "Ollama")", err)
                        let t1 = Date()
                        let cleaned = try await (fallback == .apple
                            ? AppleCleanup.cleanup(raw, app: session.target?.appName,
                                                   context: session.target?.insertionContext,
                                                   languageCode: detectedLang)
                            : ollama.cleanup(raw, app: session.target?.appName,
                                             context: session.target?.insertionContext,
                                             languageCode: detectedLang))
                        guard isCurrent(session) else { return }
                        latencyEngine = fallback == .apple ? .apple : .ollama
                        if !cleaned.isEmpty { final = cleaned }
                        Diag.content("cleaned [\(fallback == .apple ? "Apple" : "Ollama"), via fallback] "
                                     + "(\(Int(Date().timeIntervalSince(t1) * 1000))ms)",
                                     content: cleaned)
                        if restyleTone && fallback != .ollama { toneUnavailable = true }
                    } catch {
                        guard isCurrent(session) else { return }
                        Diag.pipelineError("cleanup failed — injecting raw transcript", error)
                        cleanupDegraded = true
                        OllamaHealth.shared.noteFailure()
                    }
                }
            case .oneShot:
                do {
                    let engineKind = Self.cleanupEngine(for: detectedLang, restyleTone: restyleTone)
                    // Log the engine that ACTUALLY produced the text and its
                    // own attempt's timing — after a failover, the selected
                    // engine and combined latency would both be lies.
                    var actualEngine = engineKind
                    var t1 = Date()
                    var cleaned: String
                    do {
                        cleaned = try await (engineKind == .apple
                            ? AppleCleanup.cleanup(raw, app: session.target?.appName,
                                                   context: session.target?.insertionContext,
                                                   languageCode: detectedLang)
                            : ollama.cleanup(raw, app: session.target?.appName,
                                             context: session.target?.insertionContext,
                                             languageCode: detectedLang))
                    } catch {
                        guard isCurrent(session) else { return }
                        // Symmetric failover before degrading to raw:
                        // FM hiccup/guardrail → Ollama; Ollama down → FM
                        // (English only — FM can't be trusted with BG).
                        switch Self.fallbackEngine(after: engineKind, languageCode: detectedLang) {
                        case .ollama:
                            Diag.pipelineError("Apple cleanup failed — trying Ollama", error)
                            actualEngine = .ollama
                            t1 = Date()
                            cleaned = try await ollama.cleanup(raw, app: session.target?.appName,
                                                               context: session.target?.insertionContext,
                                                               languageCode: detectedLang)
                        case .apple:
                            Diag.pipelineError("Ollama cleanup failed — trying Apple", error)
                            OllamaHealth.shared.noteFailure()
                            actualEngine = .apple
                            t1 = Date()
                            cleaned = try await AppleCleanup.cleanup(raw, app: session.target?.appName,
                                                                     context: session.target?.insertionContext,
                                                                     languageCode: detectedLang)
                        case nil:
                            throw error
                        }
                    }
                    guard isCurrent(session) else { Diag.event("result discarded (canceled)"); return }
                    let llmMs = Int(Date().timeIntervalSince(t1) * 1000)
                    if !cleaned.isEmpty {
                        final = cleaned
                        let label = actualEngine == .apple ? "Apple" : "Ollama"
                        latencyEngine = actualEngine == .apple ? .apple : .ollama
                        let viaFallback = actualEngine == engineKind ? "" : ", via fallback"
                        Diag.content("cleaned [\(label)\(viaFallback)] (\(llmMs)ms)", content: cleaned)
                    }
                    // A restyle tone is honored only by Ollama; if we ended up on
                    // Apple (Ollama down → failover) the text is clean but NOT
                    // styled — tell the user why instead of degrading silently.
                    if restyleTone && actualEngine != .ollama {
                        toneUnavailable = true
                        Diag.event("restyle tone needs Ollama — pasted faithful cleanup instead")
                    }
                } catch {
                    guard isCurrent(session) else { return }
                    // Whatever ran last was Ollama (direct or as fallback).
                    Diag.pipelineError("cleanup failed — injecting raw transcript", error)
                    cleanupDegraded = true
                    if restyleTone { toneUnavailable = true }
                    OllamaHealth.shared.noteFailure()
                }
            }

            let cleanupIntervalMs = elapsedMs(since: cleanupStartedAt)
            let cleanupMs = PipelineStageTiming.cleanupOnly(
                totalCleanupIntervalMs: cleanupIntervalMs,
                streamedInjectionMs: streamInjectionMs)

            // Canceled (Esc) while we were working? Never inject.
            guard isCurrent(session) else {
                Diag.event("result discarded (canceled)")
                return
            }

            // Privacy classification describes the ACTUAL pinned target.
            let mayPersist = PrivacyFilter.shouldRecord(
                bundleID: session.target?.bundleID, appName: session.target?.appName,
                excluded: Settings.excludedApps, paused: Settings.historyPaused,
                secureTarget: session.target?.secure ?? false)
            let writeTarget = TextInjector.WriteTarget.pinned(session.target?.pid)

            let textToInject: String
            var landed: Bool
            let injectionStartedAt = performanceClock.now
            if didStreamInject {
                // The streaming path already pasted exactly these bytes (F1) and
                // they are what lastInjected must equal (F7) — never paste again.
                textToInject = streamInjected
                lastInjected = streamInjected
                lastInjectedApp = session.target?.appName
                landed = true
            } else {
                // Mechanical spacing: "should" + "definitely…" → "should definitely…"
                if ContextReader.needsLeadingSpace(session.target?.insertionContext),
                   let first = final.first, first.isLetter || first.isNumber {
                    final = " " + final
                }
                textToInject = final
                // The injector revalidates the pinned target + secure focus
                // immediately before writing. A changed target never gets the text.
                let result = TextInjector.inject(textToInject, target: writeTarget)
                landed = result.succeeded
                if landed {
                    lastInjected = textToInject
                    lastInjectedApp = session.target?.appName
                } else if let decision = result.blockDecision {
                    switch TargetGuard.blockedOutcome(decision: decision, mayPersist: mayPersist) {
                    case .saveToScratchpad:
                        ScratchpadStore.shared.append(textToInject)
                        pill?.showError("app changed — saved to Scratchpad")
                    case .discard:
                        pill?.showError("app changed — not pasted")
                    }
                    FlowSound.error()
                    Diag.event("write blocked (\(decision)) — \(mayPersist ? "scratchpad" : "discarded")")
                }
            }

            let totalMs = elapsedMs(since: t0)
            let injectionMs = didStreamInject
                ? streamInjectionMs
                : elapsedMs(since: injectionStartedAt)
            let words = textToInject.split(whereSeparator: \.isWhitespace).count
            // Text-free performance metadata is safe even when History is
            // paused: no transcript, audio, app, or surrounding context.
            StatsStore.shared.record(
                words: words,
                latency: PipelineLatencySample(
                    timestamp: Date(), asrMs: asrMs, cleanupMs: cleanupMs,
                    injectionMs: injectionMs, totalMs: totalMs,
                    engine: latencyEngine, wordCount: words),
                includeInRecent: landed)
            guard landed else { return }

            if mayPersist {
                HistoryStore.shared.add(
                    text: textToInject, app: session.target?.appName,
                    engine: session.engineName,
                    durationMs: totalMs, audioSec: duration, tone: Tone.current.id,
                    raw: raw == textToInject ? nil : raw)
                // Learn the user's own words as they dictate (off the hot path).
                DispatchQueue.global(qos: .utility).async { LearnedStore.shared.refresh() }
            }
            switch InjectionFeedback.decide(
                writeSucceeded: landed,
                capturedTargetEditable: session.target?.editable ?? false,
                toneUnavailable: toneUnavailable,
                cleanupDegraded: cleanupDegraded
            ) {
            case .success:
                pill?.showSuccess()
                FlowSound.success() // text landed — the cat purrs
            case .toneUnavailable:
                pill?.showDegraded("start Ollama for \(Tone.current.name) tone")
                FlowSound.success()
            case .cleanupDegraded:
                pill?.showDegraded("pasted unpolished")
                FlowSound.success()
            case .noWrite:
                break // handled at the write boundary above
            }
        } catch {
            guard isCurrent(session) else { return }
            Diag.pipelineError("transcription failed", error)
            pill?.showError("transcription failed")
            FlowSound.error()
        }
    }

    // MARK: - Selection transform

    /// Transforms the captured selection by the spoken command, then writes it
    /// back in place. Bypasses every dictation-mode detector. Never persisted —
    /// the selection is the user's pre-existing private content.
    private func runTransform(_ session: DictationSession,
                              selection: SelectionEditor.Selection,
                              samples: [Float]) async {
        defer { finishPipeline(session) }
        do {
            await partialTask?.value
            // Transcribe the spoken command.
            let heard: String = session.autoLanguage
                ? (try await session.engine.transcribeAuto(samples, candidates: session.autoCandidates)).text
                : (try await session.engine.transcribe(
                    samples, languageCode: session.language))
            guard isCurrent(session) else { Diag.event("transform discarded (canceled)"); return }
            let cmd = VocabularyCorrector.apply(heard)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else {
                pill?.showError("no command heard"); FlowSound.error(); return
            }
            let kind = SelectionCommand.detect(cmd, languages: AppDelegate.translateLanguages)

            // Route by engine availability; a translate target picks its language.
            let langHint: String = { if case .translate(let code, _) = kind { return code }; return "en" }()
            let ek = Self.cleanupEngine(for: langHint)
            let out: String
            do {
                out = try await (ek == .apple
                    ? AppleCleanup.transform(selection: selection.text, kind: kind, command: cmd)
                    : ollama.transform(selection: selection.text, kind: kind, command: cmd))
            } catch {
                guard isCurrent(session) else { return }
                Diag.pipelineError("transform failed", error)
                pill?.showError("transform failed"); FlowSound.error(); return
            }
            let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCurrent(session) else { Diag.event("transform discarded (canceled)"); return }
            guard !result.isEmpty, result != selection.text else {
                pill?.showInfo("no change"); return
            }

            // Write in place. replaceSelection re-verifies the full fingerprint
            // (element/pid/text/range) and does its own paste fallback
            // atomically on the main thread, so focus can't shift mid-write.
            let outcome = SelectionEditor.replaceSelection(selection, with: result)
            switch outcome {
            case .replaced, .pasted:
                Diag.event("transformed [\(kind.id)] (\(outcome == .pasted ? "paste" : "AX"), \(result.count) chars)")
                pill?.showInfo(kind.label); FlowSound.success()
            case .selectionChanged:
                Diag.event("selection changed before write — aborted")
                pill?.showError("selection changed"); FlowSound.error()
            }
        } catch {
            guard isCurrent(session) else { return }
            Diag.pipelineError("transform failed", error)
            pill?.showError("transform failed"); FlowSound.error()
        }
    }

    // MARK: - Voice-edit commands

    private func handleCommand(_ kind: CommandDetector.Kind, raw: String,
                               previous: String, session: DictationSession,
                               languageCode: String) async throws {
        // A canceled command must never delete or rewrite anything.
        guard isCurrent(session) else { return }
        // Guard the blind backspace-replace: only edit when the caret is
        // verifiably still right after the previous injection. `nil` = the app
        // doesn't expose AX text (web/Electron) → trust it, as before.
        if SelectionEditor.caretIsAtEndOf(previous) == false {
            Diag.event("caret moved — voice edit skipped")
            pill?.showError("caret moved — no change")
            return
        }
        let target = TextInjector.WriteTarget.pinned(session.target?.pid)
        switch kind {
        case .delete:
            Diag.event("voice command: delete last injection (\(previous.count) chars)")
            guard TextInjector.replaceLast(charCount: previous.count, with: "",
                                           target: target, previous: previous) else {
                pill?.showError("app changed — no change")
                return
            }
            lastInjected = nil
        case .rewrite:
            let t = Date()
            // Route by the language actually SPOKEN (auto-detect may differ
            // from the pin) — Apple FM must never get a Bulgarian rewrite.
            let rewritten = try await (Self.cleanupEngine(for: languageCode) == .apple
                ? AppleCleanup.rewrite(original: previous, command: raw)
                : ollama.rewrite(original: previous, command: raw))
            // The previous injection may carry the mechanical joining space
            // ("should" + " definitely"); the model's output is trimmed, so
            // put it back or the rewrite glues onto the word before it.
            let replacement = VoiceEdit.replacement(previous: previous, rewritten: rewritten)
            // Esc during the model call: the document is untouched — keep it so.
            guard isCurrent(session) else { Diag.event("rewrite discarded (canceled)"); return }
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            // Never delete unless we have a real replacement in hand.
            guard let replacement else {
                Diag.event("rewrite produced no change")
                pill?.hide()
                return
            }
            Diag.content("rewrite applied (\(ms)ms, \(replacement.count) chars)", content: replacement)
            guard TextInjector.replaceLast(charCount: previous.count, with: replacement,
                                           target: target, previous: previous) else {
                pill?.showError("app changed — no change")
                return
            }
            lastInjected = replacement
        }
        guard isCurrent(session) else { return }
        pill?.showSuccess()
        FlowSound.success()
    }
}
