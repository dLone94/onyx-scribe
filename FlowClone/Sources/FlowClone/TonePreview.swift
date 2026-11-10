import SwiftUI
import FlowCloneCore

/// Live tone preview for the Style page: one of the user's OWN recent
/// dictations, rewritten by the local cleanup engine in whichever tone is being
/// previewed — so a tone is judged on real words, not a canned sentence.
///
/// Everything stays on this Mac (same engines and prompt as the pipeline).
/// Results are cached per tone for the current sample; a hover that moves on
/// before the debounce elapses never reaches the model.
@MainActor
final class TonePreviewModel: ObservableObject {
    static let shared = TonePreviewModel()

    enum Phase: Equatable {
        case loading
        case ready(String)
        /// The engine this tone needs isn't reachable (e.g. Ollama not running).
        case unavailable
    }

    /// What the user said — the newest dictation of a comfortable length.
    @Published private(set) var sample: String?
    @Published private var phases: [String: Phase] = [:]

    private let ollama = OllamaClient()

    func phase(for tone: Tone) -> Phase? { phases[tone.id] }

    /// Pick the sample (called when the Style page appears). A changed sample
    /// drops the cache; failed previews are always retried on the next visit.
    func prepare(from entries: [HistoryEntry]) {
        func fits(_ s: String) -> Bool {
            (8...45).contains(s.split(whereSeparator: \.isWhitespace).count)
        }
        // Prefer a dictation whose raw transcript differs from what landed —
        // the before/after is only telling when there was something to clean.
        let pick = entries.first { $0.hasDistinctRaw && fits($0.raw ?? "") }?.raw
            ?? entries.lazy.map { $0.raw ?? $0.text }.first(where: fits)
        if pick != sample {
            sample = pick
            phases = [:]
        } else {
            phases = phases.filter { $0.value != .unavailable }
        }
    }

    /// Produce the preview for `tone`. Driven by `.task(id:)`, so SwiftUI
    /// cancels it the moment the previewed tone changes.
    func load(_ tone: Tone) async {
        guard let sample, phases[tone.id] == nil else { return }
        if tone.isVerbatim {
            phases[tone.id] = .ready(sample) // verbatim is exactly what was said
            return
        }
        phases[tone.id] = .loading
        // Hover debounce: skimming down the list must not queue six model calls.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { phases[tone.id] = nil; return }

        let cyrillic = sample.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let lang = cyrillic ? "bg" : "en"
        var inputs = CleanupPrompt.inputs()
        inputs.tone = tone
        let system = CleanupPromptBuilder.system(languageCode: lang, inputs: inputs)
        let engine = DictationController.cleanupEngine(
            for: lang, restyleTone: !tone.instruction.isEmpty)
        do {
            let out = try await (engine == .apple
                ? AppleCleanup.cleanup(sample, instructions: system)
                : ollama.cleanup(sample, systemPrompt: system))
            // A finished result is worth caching even if the hover moved on.
            phases[tone.id] = out.isEmpty ? .unavailable : .ready(out)
        } catch {
            phases[tone.id] = Task.isCancelled ? nil : .unavailable
        }
    }
}

/// "You said" → "Lands as": the before/after pair inside the tone panel.
struct TonePreviewPair: View {
    let tone: Tone
    let sample: String
    let phase: TonePreviewModel.Phase?
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            block("YOU SAID") {
                // Mono: the machine's own voice — what it heard, verbatim.
                Text(sample)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlowColor.inkSoft)
                    .lineSpacing(2)
            }
            block("LANDS AS") {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(FlowColor.indigoBright.opacity(0.75))
                        .frame(width: 2)
                    result
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .ready(let text):
            Text(text)
                .font(tone.isVerbatim ? .system(size: 13, design: .monospaced)
                                      : .system(size: 14))
                .foregroundStyle(FlowColor.ink)
                .lineSpacing(3)
                .transition(.opacity)
        case .unavailable:
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(tone.example)”")
                    .font(.system(size: 13)).italic()
                    .foregroundStyle(FlowColor.inkSoft)
                Text("Sample sentence — the live preview needs the cleanup engine running.")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowColor.inkSoft.opacity(0.8))
            }
        case .loading, .none:
            Text("polishing your words…")
                .font(.system(size: 13))
                .foregroundStyle(FlowColor.inkSoft)
                .opacity(motion.reduceMotion ? 1 : 0.75)
        }
    }

    private func block<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(FlowColor.inkSoft.opacity(0.85))
            content()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Insights centrepiece: thirty days of dictation as one lit strip, with
/// the destinations beside it — a single surface instead of two boxed charts.
/// Each bar is a small onyx column whose top edge catches the light; amber
/// marks only the peak (the Amber-Is-Graphic rule).
struct RhythmPanel: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject private var reveal = InsightsReveal.shared

    private static let span = 30
    private static let chartHeight: CGFloat = 104

    private var days: [(date: Date, words: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: history.entries) { cal.startOfDay(for: $0.date) }
        return (0..<Self.span).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, byDay[day]?.reduce(0) { $0 + $1.wordCount } ?? 0)
        }
    }

    var body: some View {
        let data = days
        let total = data.reduce(0) { $0 + $1.words }
        let peak = max(data.map(\.words).max() ?? 0, 1)
        // Amber singles out the peak only when there is something to compare.
        let markPeak = data.filter { $0.words > 0 }.count > 1
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your rhythm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlowColor.ink)
                    Spacer()
                    Text(total > 0 ? "\(total.formatted()) words · last \(Self.span) days"
                                   : "last \(Self.span) days")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowColor.inkSoft)
                }
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(data.enumerated()), id: \.offset) { index, day in
                            bar(day, peak: peak, markPeak: markPeak, isToday: index == data.count - 1)
                                // Launch reveal: columns rise left to right.
                                .scaleEffect(x: 1, y: reveal.revealed ? 1 : 0.02, anchor: .bottom)
                                .animation(.spring(response: 0.5, dampingFraction: 0.82)
                                    .delay(Double(index) * 0.012), value: reveal.revealed)
                        }
                    }
                    if total == 0 {
                        Text("A quiet stretch. Hold \(Settings.hotkeyDisplay) and speak — your rhythm draws itself here.")
                            .font(.system(size: 12))
                            .foregroundStyle(FlowColor.inkSoft)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: Self.chartHeight, alignment: .bottom)
                HStack {
                    Text(data.first?.date.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                    Spacer()
                    Text("today")
                }
                .font(.system(size: 9))
                .foregroundStyle(FlowColor.inkSoft.opacity(0.8))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(FlowColor.hairline.opacity(0.45))
                .frame(width: 1)
                .padding(.vertical, 14)
                .accessibilityHidden(true)

            TopAppsPanel(history: history)
        }
        .quietPanel()
    }

    private func bar(_ day: (date: Date, words: Int), peak: Int,
                     markPeak: Bool, isToday: Bool) -> some View {
        let isPeak = markPeak && day.words == peak && day.words > 0
        let height = day.words > 0
            ? max(6, (Self.chartHeight - 16) * CGFloat(day.words) / CGFloat(peak))
            : 2
        let body = isPeak ? FlowColor.amber : FlowColor.indigo
        let cap = isPeak ? Color(red: 1.0, green: 0.82, blue: 0.52) : FlowColor.crystal
        let label = "\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.words) words"
        return VStack(spacing: 3) {
            if isPeak {
                Text("\(day.words)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlowColor.amber)
                    .fixedSize()
            }
            if day.words > 0 {
                UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5)
                    .fill(LinearGradient(colors: [body, body.opacity(0.32)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        // The lit top edge.
                        UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5)
                            .fill(cap.opacity(0.9))
                            .frame(height: 1.5)
                    }
                    .frame(height: height)
            } else {
                // An empty day is a tick on the baseline; today's is lit.
                Capsule()
                    .fill(isToday ? FlowColor.indigoBright.opacity(0.8)
                                  : FlowColor.hairline.opacity(0.8))
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .help(label)
        .accessibilityLabel(label)
    }
}
