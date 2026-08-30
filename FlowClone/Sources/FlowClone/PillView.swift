import SwiftUI

/// Observable state for the floating pill.
final class PillModel: ObservableObject {
    enum PillState: Equatable {
        /// Panel hidden, nothing to draw. MUST be the state whenever the pill
        /// is ordered out: the hosted SwiftUI tree stays alive in the hidden
        /// panel, and any TimelineView in the active branch keeps rendering
        /// on the main thread — an invisible waveform once burned ~9% CPU at
        /// idle because the initial state was `.recording`.
        case idle
        case recording
        case processing
        case success
        /// Text WAS pasted, but a pipeline stage failed (e.g. Ollama cleanup
        /// unavailable) so it went in unpolished. Distinct from `error`
        /// (nothing pasted) and `success` (everything worked).
        case degraded(String)
        case error(String)
        case info(String) // settings changed by voice (e.g. tone switch)
    }

    @Published var state: PillState = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: PillView.barCount)
    @Published var elapsed: TimeInterval = 0
    @Published var locked = false
    /// Drives the entrance spring (set true one runloop tick after presenting).
    @Published var entered = false
    /// Rolling partial transcript shown while recording (head-truncated).
    @Published var liveText = ""
    /// Current ASR language code shown as a clickable badge ("EN"/"BG").
    @Published var language = "en"
    /// Whether language is being auto-detected (drives the badge's dot).
    @Published var autoLanguage = false
    /// Wired by PillController — toggles primary/alt language.
    var onLanguageToggle: (() -> Void)?
    /// When the current success state began — drives the one-shot glint.
    var successAt: Date?
}

/// A quiet, angular vein running through the onyx shell. Its geometry is
/// intentionally shallow so it reads as a material detail, not an illustration.
private struct PillLightningSeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.62,
                              y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72,
                                 y: rect.minY + rect.height * 0.46))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68,
                                 y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.82,
                                 y: rect.minY + rect.height * 0.84))
        return path
    }
}

/// The dictation pill: always-dark capsule with a live waveform.
/// No @State anywhere (SwiftUI macros unavailable under CLT) — continuous
/// animations use TimelineView, discrete ones use withAnimation in PillController.
struct PillView: View {
    static let barCount = 14

    @ObservedObject var model: PillModel
    @ObservedObject private var motion = MotionPreferences.shared

    private var accent: Color { FlowColor.indigo }
    private var recordingRed: Color { FlowColor.recording }
    private var successGreen: Color { FlowColor.success }

    /// Each phase owns its accent. The shell stays recognisably Onyx Scribe,
    /// while this small colour change makes state readable in peripheral vision.
    private var stateAccent: Color {
        switch model.state {
        case .recording: return recordingRed
        case .processing, .info: return FlowColor.indigoBright
        case .success: return successGreen
        case .degraded, .error: return FlowColor.amber
        case .idle: return accent
        }
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(
                Capsule()
                    .fill(FlowColor.pillInk.opacity(0.97))
                    .background(.ultraThinMaterial, in: Capsule())
                    // A restrained pool connects the floating control to the
                    // app icon without washing every state in the same glow.
                    .overlay(
                        Capsule().fill(
                            RadialGradient(colors: [stateAccent.opacity(0.17), .clear],
                                           center: UnitPoint(x: 0.04, y: 0.5),
                                           startRadius: 0, endRadius: 76))
                    )
                    // The faint angular seam is the icon's purple-lightning
                    // motif, abstracted so it never competes with live text.
                    .overlay(
                        PillLightningSeam()
                            .stroke(FlowColor.indigoBright.opacity(0.12),
                                    style: StrokeStyle(lineWidth: 0.8,
                                                       lineCap: .round,
                                                       lineJoin: .round))
                            .padding(.horizontal, 7)
                            .clipShape(Capsule())
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.12), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 0.8)
                            .padding(1.4)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(colors: [stateAccent.opacity(0.78),
                                                    .white.opacity(0.10),
                                                    stateAccent.opacity(0.24)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.0)
                    )
                    // One-shot glint sweeping the stone when text lands.
                    .overlay(successGlint)
                    // Close, state-aware edge light plus physical depth. The
                    // previous 16pt halo made every phase look like a blue orb.
                    .shadow(color: stateAccent.opacity(0.24), radius: 7, y: 2)
                    .shadow(color: .black.opacity(0.48), radius: 5, y: 2)
            )
            // Entrance: rise + scale + fade, spring-driven. Under Reduce Motion
            // the pill simply appears at rest — no travel, no scale, no spring.
            .scaleEffect(motion.reduceMotion ? 1 : (model.entered ? 1 : 0.85))
            .offset(y: motion.reduceMotion ? 0 : (model.entered ? 0 : 16))
            .opacity(motion.reduceMotion ? 1 : (model.entered ? 1 : 0))
            .animation(motion.anim(.spring(response: 0.35, dampingFraction: 0.75)), value: model.entered)
            .animation(motion.anim(.easeOut(duration: 0.25)), value: model.state)
            .animation(motion.anim(.easeOut(duration: 0.25)), value: model.locked)
    }

    /// The purr made visible: a single edge-light sweep across the capsule the
    /// moment text lands. Runs once (~0.45s) per success; nothing under Reduce
    /// Motion. The TimelineView lives only while the short-lived success state
    /// is on screen, so it costs nothing at rest.
    @ViewBuilder
    private var successGlint: some View {
        if case .success = model.state, !motion.reduceMotion, let t0 = model.successAt {
            TimelineView(.animation(minimumInterval: 1.0 / 40)) { ctx in
                let p = min(1, max(0, ctx.date.timeIntervalSince(t0) / 0.45))
                LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 46)
                    .rotationEffect(.degrees(16))
                    .offset(x: (p * 2 - 1) * 70)
                    .blendMode(.screen)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .recording:
            HStack(spacing: 7) {
                stateBeacon
                if model.liveText.isEmpty {
                    waveform
                } else {
                    // Compact waveform + live transcript, newest words visible.
                    miniWaveform
                    Text(model.liveText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 200, alignment: .trailing)
                        .transition(.opacity)
                }
                Text(timeString)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
                languageBadge
                if model.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .transition(.opacity)
        case .processing:
            HStack(spacing: 7) {
                stateBeacon
                shimmerWaveform
                if model.liveText.isEmpty {
                    Text("Polishing")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                } else {
                    // Streaming cleanup preview: the cleaned text forming live.
                    Text(model.liveText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 224, alignment: .trailing)
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
        case .success:
            HStack(spacing: 7) {
                stateBeacon
                Text("Inserted")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .degraded(let message):
            HStack(spacing: 7) {
                stateBeacon
                Text(message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .error(let message):
            HStack(spacing: 7) {
                stateBeacon
                Text(message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .info(let message):
            HStack(spacing: 7) {
                stateBeacon
                Text(message)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// A stable 24pt anchor means the Pill never has to rely on copy or colour
    /// alone to explain what it is doing. It also makes state transitions feel
    /// intentional instead of swapping unrelated loose symbols.
    private var stateBeacon: some View {
        ZStack {
            Circle()
                .fill(stateAccent.opacity(0.15))
            Circle()
                .strokeBorder(stateAccent.opacity(0.42), lineWidth: 0.8)

            switch model.state {
            case .recording:
                pulsingDot
            case .processing:
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateAccent)
            case .success, .degraded:
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(stateAccent)
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(stateAccent)
            case .info:
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(stateAccent)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: stateAccent.opacity(0.18), radius: 4)
        .accessibilityHidden(true)
    }

    /// One-click language toggle (EN ⇄ BG by default). The panel is
    /// non-activating, so clicking never steals focus from the target app;
    /// the next partial pass already transcribes in the new language.
    private var languageBadge: some View {
        Button { model.onLanguageToggle?() } label: {
            HStack(spacing: 2.5) {
                // Accent dot = auto-detecting; the code is the current/detected language.
                if model.autoLanguage {
                    Circle().fill(accent).frame(width: 4, height: 4)
                }
                Text(model.language.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(model.autoLanguage ? "Auto-detecting language — tap to pin" : "Switch dictation language")
    }

    /// Recording dot. Slow breathing pulse by default; a steady lit dot under
    /// Reduce Motion (still unmistakably "recording", just not oscillating).
    private var pulsingDot: some View {
        Group {
            if motion.reduceMotion {
                Circle().fill(recordingRed).frame(width: 7, height: 7)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 3.2))
                    Circle()
                        .fill(recordingRed)
                        .frame(width: 7, height: 7)
                        .opacity(pulse)
                        .scaleEffect(0.9 + 0.2 * pulse)
                }
            }
        }
    }

    private var barFill: LinearGradient {
        LinearGradient(colors: [accent, .white.opacity(0.9)],
                       startPoint: .bottom, endPoint: .top)
    }

    /// Full-width live waveform. Under Reduce Motion it drops the breathing
    /// floor and the continuous redraw but stays level-reactive — the bars are
    /// essential "you're being heard" feedback, so they respond to your voice
    /// and sit flat and still during silence rather than idling.
    private var waveform: some View {
        Group {
            if motion.reduceMotion {
                HStack(spacing: 2.5) {
                    ForEach(0..<Self.barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.25)
                            .fill(barFill)
                            .frame(width: 2.5, height: barHeight(model.levels[i]))
                    }
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2.5) {
                        ForEach(0..<Self.barCount, id: \.self) { i in
                            // A whisper of ambient life; the bars settle near-flat
                            // during silence and dance to your actual voice levels.
                            let breath = 0.5 * (0.5 + 0.5 * sin(t * 1.6 + Double(i) * 0.45))
                            RoundedRectangle(cornerRadius: 1.25)
                                .fill(barFill)
                                .frame(width: 2.5, height: barHeight(model.levels[i]) + breath)
                                .animation(.easeOut(duration: 0.08), value: model.levels[i])
                        }
                    }
                }
            }
        }
    }

    /// Ten-bar compact waveform used when the live transcript is showing.
    private var miniWaveform: some View {
        Group {
            if motion.reduceMotion {
                HStack(spacing: 2.5) {
                    ForEach(0..<10, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.25)
                            .fill(barFill)
                            .frame(width: 2.5, height: barHeight(model.levels[Self.barCount - 10 + i]))
                    }
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2.5) {
                        ForEach(0..<10, id: \.self) { i in
                            // A whisper of ambient life; the bars settle near-flat
                            // during silence and dance to your actual voice levels.
                            let breath = 0.5 * (0.5 + 0.5 * sin(t * 1.6 + Double(i) * 0.45))
                            RoundedRectangle(cornerRadius: 1.25)
                                .fill(barFill)
                                .frame(width: 2.5,
                                       height: barHeight(model.levels[Self.barCount - 10 + i]) + breath)
                                .animation(.easeOut(duration: 0.08), value: model.levels[Self.barCount - 10 + i])
                        }
                    }
                }
            }
        }
    }

    /// "Thinking" shimmer: a gentle sine wave sweeping across the bars. Under
    /// Reduce Motion it becomes a static, evenly-lit bar row — the "polishing…"
    /// label carries the state instead of the sweep.
    private var shimmerWaveform: some View {
        Group {
            if motion.reduceMotion {
                HStack(spacing: 2.5) {
                    ForEach(0..<Self.barCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.25)
                            .fill(accent.opacity(0.6))
                            .frame(width: 2.5, height: 6)
                    }
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2.5) {
                        ForEach(0..<Self.barCount, id: \.self) { i in
                            let wave = 0.5 + 0.5 * sin(t * 4.5 - Double(i) * 0.55)
                            RoundedRectangle(cornerRadius: 1.25)
                                .fill(accent.opacity(0.35 + 0.5 * wave))
                                .frame(width: 2.5, height: 3 + 6 * wave)
                        }
                    }
                }
            }
        }
    }

    private func barHeight(_ level: Float) -> CGFloat {
        3 + CGFloat(min(max(level, 0), 1)) * 14
    }

    private var timeString: String {
        let s = Int(model.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
