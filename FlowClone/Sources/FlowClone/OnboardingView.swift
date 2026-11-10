import SwiftUI
import AppKit
import AVFoundation

/// First-run onboarding: Welcome → Speak & see it (live local transcription,
/// the aha moment) → Accessibility.
///
/// The middle step runs the *real* on-device ASR: the user speaks and their
/// words appear in the window, proving "it hears me and writes it — all on this
/// Mac" before any paste permission is granted. No Ollama, no Accessibility,
/// no network — so the aha can't be blocked by an unconfigured machine.
///
/// No @State (CLT macro limitation) — all state lives in OnboardingModel.
final class OnboardingModel: ObservableObject {
    /// How the local ASR engine is doing on the mic step.
    enum ASRState: Equatable { case idle, warming, ready, failed }

    @Published var step = 0
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var axGranted = AXIsProcessTrusted()
    @Published var levels: [Float] = Array(repeating: 0, count: 18)

    /// Live transcript of what the user just said (head-truncated tail).
    @Published var liveText = ""
    /// The engine's readiness while the mic step is on screen.
    @Published var asrState: ASRState = .idle
    /// Flips true the first time we have real evidence the mic works — a
    /// transcript, or (if ASR failed) a loud-enough level. Gates Continue.
    @Published var heardSomething = false

    var onFinish: (() -> Void)?

    /// Injected by AppDelegate: returns the main pipeline's engine once it has
    /// loaded (nil while loading/switching). Re-evaluated every pass.
    var borrowEngine: (() -> (any ASREngine)?)?
    /// Fallback owned engine — created ONLY when borrowing is wrong:
    /// the pipeline engine is Whisper (first-run download + ~74s CoreML
    /// specialization would stall the demo) or never became available.
    private var ownEngine: Transcriber?
    private var ownEngineLoading = false
    /// How long we wait for the borrowed engine before giving up (its cold
    /// load is ~11s; 30s covers slow first compiles with margin).
    private var borrowDeadline: Date?

    /// The engine to use for the next demo pass, or nil to skip this pass.
    private func currentEngine() -> (any ASREngine)? {
        if let borrowed = borrowEngine?() {
            if borrowed is Transcriber { return borrowed }
            // Pipeline is on Whisper — fall back to our own Parakeet.
            loadOwnEngineIfNeeded()
            return ownEngine
        }
        return ownEngine // nil while borrow is still pending
    }

    private func loadOwnEngineIfNeeded() {
        guard ownEngine == nil, !ownEngineLoading else { return }
        ownEngineLoading = true
        let engine = Transcriber()
        Task { [weak self] in
            do {
                try await engine.load()
                await MainActor.run {
                    guard let self else { return }
                    self.ownEngine = engine
                    self.ownEngineLoading = false
                    if self.asrState == .warming { self.asrState = .ready }
                }
            } catch {
                await MainActor.run {
                    self?.ownEngineLoading = false
                    if self?.asrState == .warming { self?.asrState = .failed }
                }
            }
        }
    }

    private var recorder: AudioRecorder?
    private var pollTimer: Timer?

    // Self-pacing partial-transcription loop (mirrors the pill's live loop).
    private var loopActive = false
    private var loopRunning = false

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micGranted = granted
                if granted { self.startListening() }
            }
        }
    }

    /// Start loading the on-device engine as early as possible (the Welcome
    /// step) so the ~cold-load cost — measured at ~11s first-run — is hidden
    /// behind reading the welcome and granting the mic, not a dead wait staring
    /// at "Warming up…". Idempotent; safe to call more than once.
    func warmEngine() {
        guard asrState == .idle else { return }
        asrState = .warming
        borrowDeadline = Date().addingTimeInterval(30)
        pollForEngine()
    }

    private func pollForEngine() {
        // Resolved already?
        if currentEngine() != nil {
            asrState = .ready
            if recorder != nil { startLoop() } // mic already running
            return
        }
        // Fallback in flight? Its completion updates asrState.
        if ownEngineLoading { return }
        // Borrow timed out (pipeline load failed/stuck)? Try our own once.
        if let deadline = borrowDeadline, Date() > deadline {
            loadOwnEngineIfNeeded()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pollForEngine()
        }
    }

    /// Begin capturing (levels immediately). If the engine is already warm the
    /// live-transcript loop starts now; if it's still warming, its completion
    /// starts the loop; if it failed, levels drive the fallback "heard" signal.
    func startListening() {
        guard recorder == nil, micGranted else { return }
        let recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.levels.removeFirst()
            self.levels.append(level)
            // Fallback "did they speak" signal if ASR never comes up.
            if self.asrState == .failed, level > 0.16, !self.heardSomething {
                self.heardSomething = true
                self.announceHeard()
            }
        }
        do {
            try recorder.start()
            self.recorder = recorder
        } catch {
            // Keep `recorder` nil so the next attempt starts fresh — retaining
            // a recorder whose start failed would block every retry.
            Diag.error("onboarding mic start failed", error: error, logger: Diag.audio)
            return
        }

        switch asrState {
        case .ready: startLoop()
        case .idle: warmEngine()
        case .warming, .failed: break // warming completion starts the loop; failed uses levels
        }
    }

    func stopListening() {
        loopActive = false
        _ = recorder?.stop()
        recorder = nil
    }

    private func startLoop() {
        loopActive = true
        scheduleLoop(after: 0.6)
    }

    private func scheduleLoop(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runLoop()
        }
    }

    private func runLoop() {
        guard loopActive, !loopRunning, let recorder else { return }
        let samples = recorder.snapshot()
        guard samples.count > 12_000 else { // ~0.75s of audio minimum
            scheduleLoop(after: 0.4)
            return
        }
        guard let engine = currentEngine() else {
            scheduleLoop(after: 0.5) // engine still warming — try again shortly
            return
        }
        loopRunning = true
        Task { [weak self] in
            guard let self else { return }
            let text = try? await engine.transcribe(samples)
            await MainActor.run {
                self.loopRunning = false
                if let text, !text.isEmpty, self.loopActive {
                    let firstWords = self.liveText.isEmpty
                    self.liveText = text
                    if !self.heardSomething { self.heardSomething = true }
                    if firstWords { self.announceHeard() }
                }
                if self.loopActive { self.scheduleLoop(after: 0.5) }
            }
        }
    }

    /// Nudge VoiceOver when the first words land — the aha, announced.
    private func announceHeard() {
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Transcribed on this Mac. Onyx Scribe is working."]
        )
    }

    func startAXPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.axGranted = AXIsProcessTrusted()
        }
    }

    func openAXSettings() {
        // Trigger the system prompt (adds us to the list), then open the pane.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func finish() {
        stopListening()
        ownEngine = nil // free the demo's model memory if we had to own one
        pollTimer?.invalidate()
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        onFinish?()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case 0: welcome
                case 1: microphone
                default: accessibility
                }
            }
            .id(model.step)
            // Slide + fade between steps; a plain crossfade under Reduce Motion.
            .transition(motion.reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)

            stepDots
                .padding(.bottom, 24)
        }
        .frame(width: 560, height: 640)
        .background(FlowCanvasBackground())
        .animation(motion.anim(.easeOut(duration: 0.25)), value: model.step)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == model.step ? flowAccent : Color.secondary.opacity(0.3))
                    .frame(width: i == model.step ? 20 : 7, height: 7)
                    .animation(motion.anim(.easeOut(duration: 0.25)), value: model.step)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(model.step + 1) of 3")
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            // The mascot greets first — blinking, glow breathing.
            OnyxCatMark(size: 84)
                .accessibilityHidden(true)
            Text("Dictate anywhere.\n100% local.")
                .font(FlowType.fraunces(32, weight: 400, opsz: 144, soft: 40))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold a key, speak, release — polished text lands wherever you were typing. Your voice is transcribed on this Mac and never leaves it.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
            trustRow
            Spacer()
            VStack(spacing: 10) {
                primaryButton("Get Started") {
                    flowAnimate(.easeOut(duration: 0.3)) { model.step = 1 }
                }
                Text("Takes about 30 seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        // Warm the ASR engine now so it's ready by the time they reach the mic.
        .onAppear { model.warmEngine() }
    }

    /// Three quiet proof points that carry the local-first promise.
    private var trustRow: some View {
        HStack(alignment: .top, spacing: 14) {
            trustItem("wifi.slash", "No cloud")
            trustItem("cpu", "Neural Engine")
            trustItem("lock.fill", "Audio never stored")
        }
        .padding(.top, 4)
    }

    private func trustItem(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            // Fixed glyph box: SF Symbols differ in height, which staggered
            // the three labels.
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(FlowColor.indigoBright)
                .frame(height: 18)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 118)
        .accessibilityElement(children: .combine)
    }

    private var microphone: some View {
        VStack(spacing: 16) {
            Spacer()
            iconCircle(model.heardSomething ? "checkmark" : "mic.fill")
            Text(model.heardSomething ? "That's all local." : "Let's hear you")
                .font(FlowType.fraunces(27, weight: 420, opsz: 120, soft: 30))
                .animation(motion.anim(.easeOut(duration: 0.2)), value: model.heardSomething)
            Text(model.heardSomething
                 ? "Everything below was transcribed on this Mac's Neural Engine — no network, nothing saved."
                 : "Audio is transcribed on-device and immediately discarded. Grant the mic and say something.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)

            liveDemo
                .padding(.top, 4)

            Spacer()
            micActions
        }
        .onAppear { if model.micGranted { model.startListening() } }
        .onDisappear { model.stopListening() }
    }

    /// The aha: live mic bars over a transcript panel that fills with the user's
    /// actual words. Fixed height so the layout never jumps between states.
    private var liveDemo: some View {
        VStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(0..<model.levels.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(model.micGranted ? flowAccent : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 6 + CGFloat(min(max(model.levels[i], 0), 1)) * 38)
                        .animation(motion.anim(.easeOut(duration: 0.1)), value: model.levels[i])
                }
            }
            .frame(height: 48)
            .accessibilityElement()
            .accessibilityLabel("Microphone input level")

            transcriptPanel
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        let border = RoundedRectangle(cornerRadius: 12)
            .strokeBorder(model.heardSomething ? flowAccent.opacity(0.4) : Color(nsColor: .separatorColor),
                          lineWidth: 1)
        ZStack {
            if model.liveText.isEmpty {
                transcriptPlaceholder
            } else {
                Text(model.liveText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .frame(height: 92)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        .overlay(border)
        .animation(motion.anim(.easeOut(duration: 0.25)), value: model.liveText.isEmpty)
        .animation(motion.anim(.easeOut(duration: 0.25)), value: model.heardSomething)
        .accessibilityElement()
        .accessibilityLabel("Live transcription")
        .accessibilityValue(model.liveText.isEmpty ? transcriptHintText : model.liveText)
    }

    private var transcriptPlaceholder: some View {
        Group {
            switch model.asrState {
            case .idle:
                Text(transcriptHintText)
                    .foregroundStyle(.secondary)
            case .warming:
                Label("Warming up the on-device engine…", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
            case .ready:
                Text("Say something — watch it appear.")
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Speak and the bars will move — live text isn't available right now, but dictation still works.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.system(size: 13))
    }

    private var transcriptHintText: String {
        model.micGranted ? "Say something — watch it appear." : "Grant the microphone to try it."
    }

    @ViewBuilder
    private var micActions: some View {
        if model.micGranted {
            primaryButton("Continue", enabled: model.heardSomething) { advanceFromMic() }
            // Always an escape: a granted-but-silent mic (broken / wrong input
            // device) must never strand the user on a disabled Continue.
            if !model.heardSomething {
                Button("Skip this step") { advanceFromMic() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            primaryButton("Allow Microphone") { model.requestMic() }
            Button("Skip for now") { advanceFromMic() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func advanceFromMic() {
        model.stopListening()
        flowAnimate(.easeOut(duration: 0.3)) { model.step = 2 }
        model.startAXPolling()
    }

    private var accessibility: some View {
        VStack(spacing: 18) {
            Spacer()
            iconCircle(model.axGranted ? "checkmark" : "keyboard")
            Text(model.axGranted ? "You're all set" : "One last thing")
                .font(FlowType.fraunces(27, weight: 420, opsz: 120, soft: 30))
            Text(model.axGranted
                 ? "Click into any text field, hold \(Settings.hotkeyDisplay), and speak. Double-tap for hands-free mode."
                 : "Accessibility lets Onyx Scribe paste your words into the app you're using — and nothing else. It never reads your screen.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)

            permissionChip

            if model.axGranted { gestureHint }

            Spacer()
            if model.axGranted {
                primaryButton("Start Dictating") { model.finish() }
                Text("Everything's unlocked free for 14 days. After that, verbatim dictation stays free.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                primaryButton("Open Accessibility Settings") { model.openAXSettings() }
                Button("I'll do this later") { model.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionChip: some View {
        HStack(spacing: 8) {
            Image(systemName: model.axGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.axGranted ? Color(red: 0.20, green: 0.78, blue: 0.35) : .secondary)
            Text(model.axGranted ? "Accessibility granted" : "Waiting for Accessibility…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.quaternary.opacity(0.4)))
        .animation(motion.anim(.easeOut(duration: 0.25)), value: model.axGranted)
        .accessibilityElement(children: .combine)
    }

    /// The real gesture, shown once they're set up — the first thing to try.
    private var gestureHint: some View {
        HStack(spacing: 8) {
            Text("Hold")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(Settings.hotkeyDisplay)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(flowAccent.opacity(0.12)))
                .foregroundStyle(flowAccent)
            Text("anywhere, then speak")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private func iconCircle(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(FlowColor.indigo.opacity(0.18)).frame(width: 84, height: 84)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(FlowColor.indigoBright)
        }
        .shadow(color: FlowColor.indigo.opacity(0.45), radius: 16)
        .accessibilityHidden(true)
    }

    private func primaryButton(_ title: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(Capsule().fill(enabled ? flowAccent : Color.secondary.opacity(0.4)))
                .shadow(color: enabled ? FlowColor.indigo.opacity(0.45) : .clear,
                        radius: 12, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(motion.anim(.easeOut(duration: 0.2)), value: enabled)
    }
}

/// Owns the onboarding window; shows only when hasOnboarded is unset.
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model = OnboardingModel()

    static var needed: Bool { !UserDefaults.standard.bool(forKey: "hasOnboarded") }

    init(borrowEngine: (() -> (any ASREngine)?)? = nil) {
        model.borrowEngine = borrowEngine
    }

    func show() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // First run speaks the same dark, glowing language as the Hub.
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        AmbientGate.track(w) // ambient views animate only while actually visible
        w.center()
        model.onFinish = { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        w.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Debug: capture our own window's pixels (no Screen Recording needed),
    /// matching HubWindowController's self-snapshot approach.
    func snapshot(to path: String) {
        guard let window else { print("onboard snapshot: no window"); return }
        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else { print("onboard snapshot: capture failed"); return }
        try? NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("snapshot written: \(path)")
    }

    /// Debug: drive the model through representative states and snapshot each,
    /// so onboarding has the same visual-verification loop the Hub does.
    func snapshotSteps(to dir: String, then completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, () -> Void)] = [
            ("1-welcome", { self.model.step = 0 }),
            ("2-mic-prompt", {
                self.model.step = 1; self.model.micGranted = false
                self.model.asrState = .idle; self.model.liveText = ""
                self.model.heardSomething = false
            }),
            ("2-mic-warming", {
                self.model.step = 1; self.model.micGranted = true
                self.model.asrState = .warming; self.model.liveText = ""
                self.model.heardSomething = false
            }),
            ("2-mic-silent", {
                self.model.step = 1; self.model.micGranted = true
                self.model.asrState = .ready; self.model.liveText = ""
                self.model.heardSomething = false
            }),
            ("2-mic-heard", {
                self.model.step = 1; self.model.micGranted = true
                self.model.asrState = .ready
                self.model.liveText = "Send the report by five and CC the whole team."
                self.model.heardSomething = true
            }),
            ("3-ax-prompt", { self.model.step = 2; self.model.axGranted = false }),
            ("3-ax-done", { self.model.step = 2; self.model.axGranted = true }),
        ]
        var remaining = states
        func next() {
            guard !remaining.isEmpty else { completion(); return }
            let (name, apply) = remaining.removeFirst()
            apply()
            self.model.stopListening() // keep the demo loop from mutating snapshot state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.snapshot(to: "\(dir)/\(name).png")
                next()
            }
        }
        next()
    }
}
