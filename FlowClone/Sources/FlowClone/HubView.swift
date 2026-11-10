import SwiftUI
import AVFoundation
import ServiceManagement
import FlowCloneCore

/// Window-level state (no @State — SwiftUI macros unavailable under CLT builds;
/// all bindings are manual against ObservableObjects).
final class HubModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case home, style, scratchpad, history, dictionary, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Insights"
            case .style: "Style"
            case .scratchpad: "Scratchpad"
            case .history: "History"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .home: "chart.bar"
            case .style: "paintbrush"
            case .scratchpad: "note.text"
            case .history: "clock.arrow.circlepath"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    @Published var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "hubPage") ?? "") ?? .home
    @Published var query = ""
    @Published var hoveredEntry: UUID?
    @Published var expandedEntry: UUID?
    @Published var newTerm = ""
    @Published var newWrong = ""
    @Published var newRight = ""
    @Published var newProfileApp = ""
    @Published var newProfileInstruction = ""
    @Published var newExclusion = ""
    @Published var hoveredPage: Page?
    @Published var hoveredTone: String?
    /// History app filter (nil = all apps).
    @Published var historyApp: String?

    @Published var capturingHotkey = false
    @Published var hotkeyDisplay = Settings.hotkeyDisplay
    let hotkeyRecorder = HotkeyRecorder()

    /// Set by AppDelegate so Settings can trigger engine reloads.
    var reloadEngine: (() -> Void)?
    var resetPillPosition: (() -> Void)?
    var updateHotkey: (() -> Void)?

    func open(_ page: Page) {
        UserDefaults.standard.set(page.rawValue, forKey: "hubPage")
        flowAnimate(FlowMotion.quick) { self.page = page }
    }
}

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var stats = StatsStore.shared
    @ObservedObject var vocab: VocabStore
    @ObservedObject var profiles: ProfilesStore
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        HStack(spacing: 0) {
            FlowSidebar(model: model)
            Rectangle().fill(FlowColor.hairline.opacity(0.5)).frame(width: 1)
            content
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(FlowCanvasBackground())
        // Native controls (switches, pickers, focus rings) speak the brand's
        // indigo instead of the system accent.
        .tint(FlowColor.indigo)
    }

    private var content: some View {
        ZStack {
            switch model.page ?? .home {
            case .home: HomeView(model: model, history: history, stats: stats)
            case .style: StyleView(model: model)
            case .scratchpad: ScratchpadView(scratch: ScratchpadStore.shared, model: model)
            case .history: HistoryView(model: model, history: history)
            case .dictionary: DictionaryView(model: model, vocab: vocab, profiles: profiles)
            case .settings: SettingsPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(model.page)
        // A quiet cross-fade: the page change is the state change; 200 ms.
        .transition(.opacity)
    }
}

// MARK: - Sidebar

/// A quiet, narrow rail: the brandmark up top, primary pages, and Settings
/// pinned at the bottom. The selected row is a restrained blackberry fill —
/// no glow, no traveling capsule. Every row is a real button (focusable,
/// keyboard-operable) with a ⌘-number shortcut.
struct FlowSidebar: View {
    @ObservedObject var model: HubModel
    @ObservedObject private var motion = MotionPreferences.shared

    private let primary: [HubModel.Page] = [.home, .style, .scratchpad, .history, .dictionary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brandmark, cleared below the traffic lights. Identity, not décor.
            HStack(spacing: 9) {
                OnyxCatMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Onyx Scribe")
                        .font(FlowType.fraunces(16, weight: 500, opsz: 80, soft: 18))
                        .foregroundStyle(FlowColor.ink)
                    Text("Local dictation")
                        .font(.system(size: 10))
                        .foregroundStyle(FlowColor.inkSoft)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 66)
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Onyx Scribe — local dictation")

            VStack(spacing: 1) {
                ForEach(Array(primary.enumerated()), id: \.element) { index, page in
                    navRow(page, shortcut: index + 1)
                }
            }

            Spacer()

            Rectangle().fill(FlowColor.hairline.opacity(0.4)).frame(height: 1)
                .padding(.vertical, 8)
            navRow(.settings, shortcut: 6)
                .padding(.bottom, 12)
        }
        .frame(width: 176)
        .padding(.horizontal, 12)
        // Positioned from the window's top, not the safe area: History adds a
        // native toolbar that deepens the title bar, which used to push the
        // whole rail down ~10pt on that one page.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func navRow(_ page: HubModel.Page, shortcut: Int) -> some View {
        let selected = (model.page ?? .home) == page
        let hovered = model.hoveredPage == page
        return Button {
            model.open(page)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? FlowColor.ink
                             : (hovered ? FlowColor.ink : FlowColor.inkSoft))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? FlowColor.blackberry
                          : (hovered ? FlowColor.hover : .clear))
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("\(page.title)  ⌘\(shortcut)")
        .onHover { h in
            flowAnimate(.easeOut(duration: 0.15)) {
                if h { model.hoveredPage = page }
                else if model.hoveredPage == page { model.hoveredPage = nil }
            }
        }
    }
}

// MARK: - Insights (daily command center)

struct HomeView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore
    @ObservedObject var stats: StatsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubMetrics.sectionSpacing) {
                // Greeting — the page's single Fraunces moment.
                VStack(alignment: .leading, spacing: 5) {
                    Text(greeting)
                        .font(FlowType.fraunces(30, weight: 400, opsz: 100, soft: 30))
                        .foregroundStyle(FlowColor.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(Date().formatted(date: .complete, time: .omitted))
                        .font(.system(size: 13))
                        .foregroundStyle(FlowColor.inkSoft)
                }

                // Readiness first: is dictation going to work right now?
                ReadinessRow(model: model)

                // The primary summary — one sentence, then quiet figures.
                leadParagraph
                figureStrip

                // The centrepiece: thirty days of rhythm + destinations, one surface.
                RhythmPanel(history: history)
                PerformancePanel(stats: stats)

                // Recent activity, in the same rows History uses.
                HubSection(title: "Recent") {
                    if history.entries.isEmpty {
                        EmptyHistoryHint()
                    } else {
                        RowGroup {
                            ForEach(Array(history.entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { RowDivider() }
                                HistoryRow(entry: entry, history: history, model: model)
                            }
                        }
                        Button("Open History") { model.open(.history) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.horizontal, HubMetrics.pageHPad)
            .padding(.top, HubMetrics.pageTopPad)
            .padding(.bottom, HubMetrics.pageBottomPad)
            .frame(maxWidth: HubMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { OllamaHealth.shared.checkIfStale(olderThan: 10) }
    }

    private var greeting: String {
        let name = NSFullUserName().components(separatedBy: " ").first ?? "there"
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning, \(name)"
        case 12..<18: return "Good afternoon, \(name)"
        default: return "Good evening, \(name)"
        }
    }

    /// The lifetime figure: the stats counter, floored by what history itself
    /// proves (the two live in different stores and must never contradict).
    private var totalWordsDisplay: Int {
        max(stats.totalWords, history.entries.reduce(0) { $0 + $1.wordCount })
    }

    /// The headline figures as a sentence (or a teaching empty state).
    private var leadParagraph: some View {
        Group {
            if totalWordsDisplay == 0 {
                Text("Your first words are waiting. Hold \(Settings.hotkeyDisplay), speak, and cleaned text lands right at your cursor.")
                    .font(.system(size: 17))
                    .foregroundStyle(FlowColor.inkSoft)
                    .lineSpacing(3)
            } else {
                (Text("You've dictated ").foregroundStyle(FlowColor.inkSoft)
                 + Text(totalWordsDisplay.formatted()).foregroundStyle(FlowColor.ink).fontWeight(.semibold)
                 + Text(" words — about ").foregroundStyle(FlowColor.inkSoft)
                 + Text(timeSavedString).foregroundStyle(FlowColor.ink).fontWeight(.semibold)
                 + Text(" you didn't spend typing.").foregroundStyle(FlowColor.inkSoft))
                    .font(.system(size: 17))
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    /// today's words · time saved · streak · speaking speed — quiet, no boxes.
    private var figureStrip: some View {
        HStack(alignment: .center, spacing: 20) {
            figure("\(todayWords)", "words today")
            figureDivider
            figure(timeSavedString, "saved vs typing")
            figureDivider
            stats.streakDays > 0
                ? figure("\(stats.streakDays)-day", "streak")
                : figure("today", "start your streak")
            figureDivider
            figure(speakingWPMString, "speaking speed")
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(FlowColor.ink)
            Text(label).font(.system(size: 11)).foregroundStyle(FlowColor.inkSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private var figureDivider: some View {
        Rectangle().fill(FlowColor.hairline).frame(width: 1, height: 30)
            .accessibilityHidden(true)
    }

    /// Words dictated so far today.
    private var todayWords: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return history.entries
            .filter { cal.startOfDay(for: $0.date) == today }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// Minutes saved vs typing at ~40 WPM (minus the time spent speaking at ~150).
    private var timeSavedString: String {
        let minutes = Double(totalWordsDisplay) * (1.0 / 40 - 1.0 / 150)
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(Int(minutes)) min" }
        return String(format: "%.1f h", minutes / 60)
    }

    /// Measured speaking rate from entries that carry an audio duration.
    private var speakingWPMString: String {
        let timed = history.entries.filter { ($0.audioSec ?? 0) > 1 }
        let totalSec = timed.reduce(0.0) { $0 + ($1.audioSec ?? 0) }
        guard totalSec > 10 else { return "—" }
        let words = timed.reduce(0) { $0 + $1.wordCount }
        return "\(Int(Double(words) / (totalSec / 60))) wpm"
    }
}

/// A single readable performance narrative, not a dashboard of metric cards.
/// Samples contain timing metadata only; the privacy note is part of the UI so
/// users never have to infer what measurement means for their dictations.
struct PerformancePanel: View {
    @ObservedObject var stats: StatsStore

    private var summary: PipelineLatencySummary? {
        PipelineLatencyAnalyzer.summarize(stats.recentLatencies)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Performance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowColor.ink)
                Spacer()
                Circle()
                    .fill(FlowColor.indigoBright)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("measured on this Mac")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(FlowColor.inkSoft)
            }

            if let summary, let last = stats.recentLatencies.last {
                (Text("Your last dictation landed in ")
                    .foregroundStyle(FlowColor.inkSoft)
                 + Text(format(last.totalMs)).foregroundStyle(FlowColor.ink).fontWeight(.semibold)
                 + Text(". Recent median is ").foregroundStyle(FlowColor.inkSoft)
                 + Text(format(summary.medianTotalMs)).foregroundStyle(FlowColor.ink).fontWeight(.semibold)
                 + Text("; 95% finish within ").foregroundStyle(FlowColor.inkSoft)
                 + Text(format(summary.p95TotalMs)).foregroundStyle(FlowColor.ink).fontWeight(.semibold)
                 + Text(".").foregroundStyle(FlowColor.inkSoft))
                    .font(.system(size: 13))

                stageBar(summary)

                HStack(spacing: 18) {
                    stageLabel("Recognition", summary.averageASRMs, FlowColor.indigo)
                    stageLabel("Cleanup", summary.averageCleanupMs, FlowColor.indigoBright)
                    stageLabel("Insert", summary.averageInjectionMs, FlowColor.amber)
                    Spacer(minLength: 0)
                }

                Text(footer(summary))
                    .font(.system(size: 10.5))
                    .foregroundStyle(FlowColor.inkSoft)
            } else {
                Text(emptyMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowColor.inkSoft)
                Text("Only durations, engine, timestamp, and word count are kept—never audio or dictated text.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(FlowColor.inkSoft.opacity(0.9))
            }
        }
        .padding(14)
        .quietPanel(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }

    private func stageBar(_ summary: PipelineLatencySummary) -> some View {
        GeometryReader { proxy in
            let values = [summary.averageASRMs, summary.averageCleanupMs,
                          summary.averageInjectionMs].map { max($0, 1) }
            let total = max(values.reduce(0, +), 1)
            let available = max(proxy.size.width - 4, 36)
            let flexible = max(available - 36, 0)
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(FlowColor.indigo)
                    .frame(width: 12 + flexible * CGFloat(values[0]) / CGFloat(total))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(FlowColor.indigoBright)
                    .frame(width: 12 + flexible * CGFloat(values[1]) / CGFloat(total))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(FlowColor.amber)
                    .frame(width: 12 + flexible * CGFloat(values[2]) / CGFloat(total))
            }
        }
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }

    private func stageLabel(_ name: String, _ ms: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(name) \(format(ms))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(FlowColor.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(_ summary: PipelineLatencySummary) -> String {
        let stage: String
        switch summary.slowestStage {
        case .recognition: stage = "Recognition"
        case .cleanup: stage = "Cleanup"
        case .insertion: stage = "Insertion"
        }
        let slow = summary.unusuallySlowCount
        let tail: String
        if slow == 0 {
            tail = "No unusual slowdowns in the recent sample."
        } else if let latest = stats.recentLatencies.last(where: {
            $0.totalMs > summary.slowThresholdMs
        }) {
            let when = DateFormatter.localizedString(
                from: latest.timestamp, dateStyle: .short, timeStyle: .short)
            tail = "\(slow) unusually slow \(slow == 1 ? "dictation" : "dictations"); "
                + "latest was \(format(latest.totalMs)) at \(when)."
        } else {
            tail = "\(slow) unusually slow \(slow == 1 ? "dictation" : "dictations") in the recent sample."
        }
        return "\(stage) is currently the slowest stage. \(tail) Performance tracking stores no text or audio."
    }

    private var emptyMessage: String {
        if stats.avgLatencyMs > 0 {
            return "Your existing overall average is \(format(stats.avgLatencyMs)). Stage timing starts with your next dictation."
        }
        return "Stage timing starts with your next dictation."
    }

    private func format(_ ms: Int) -> String {
        if ms < 1_000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1_000)
    }
}

/// Live readiness: engine + cleanup route + the dictation shortcut when all is
/// well; concise, actionable problem rows when it isn't. Reads the same
/// `ReadinessSummary` the menu bar uses. Refreshes every few seconds while
/// visible — permissions change outside the app.
struct ReadinessRow: View {
    @ObservedObject var model: HubModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 4)) { _ in
            let state = ReadinessSummary.compute()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    StatusLine(kind: state.ready ? .ok : .warn,
                               text: state.ready ? "Ready — \(state.summary)"
                                                 : "Needs attention — \(state.summary)")
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Text("Hold")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowColor.inkSoft)
                        KeycapHint(text: Settings.hotkeyDisplay)
                        Text("to dictate")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowColor.inkSoft)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Hold \(Settings.hotkeyDisplay) to dictate")
                }
                ForEach(Array(state.problems.enumerated()), id: \.offset) { _, problem in
                    problemRow(problem)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .quietPanel(cornerRadius: 10)
        }
    }

    private func problemRow(_ problem: ReadinessSummary.Problem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(FlowColor.amber)
                .accessibilityHidden(true)
            Text(problem.text)
                .font(.system(size: 12))
                .foregroundStyle(FlowColor.ink.opacity(0.9))
            Spacer()
            Button(actionTitle(problem.action)) { perform(problem.action) }
                .controlSize(.small)
        }
    }

    private func actionTitle(_ action: ReadinessSummary.Problem.Action) -> String {
        switch action {
        case .openAccessibility, .openMicrophone: "Open System Settings"
        case .fixOllama: "Fix in Settings"
        }
    }

    private func perform(_ action: ReadinessSummary.Problem.Action) {
        switch action {
        case .openAccessibility:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .openMicrophone:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .fixOllama:
            model.open(.settings)
        }
    }
}

/// Where dictations land — top 3 apps with proportional bars, direct labels.
/// Unframed: it sits inside RhythmPanel's surface, not in a box of its own.
struct TopAppsPanel: View {
    @ObservedObject var history: HistoryStore

    private var topApps: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: history.entries.compactMap(\.app)) { $0 }
            .mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }
    }

    var body: some View {
        let apps = topApps
        let maxCount = max(apps.first?.count ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Top apps")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowColor.ink)
            if apps.isEmpty {
                Text("Dictate somewhere and it shows up here.")
                    .font(.system(size: 11)).foregroundStyle(FlowColor.inkSoft)
            }
            ForEach(Array(apps.enumerated()), id: \.element.name) { _, app in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app.name).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FlowColor.ink)
                        Spacer()
                        Text("\(app.count)").font(.system(size: 11)).foregroundStyle(FlowColor.inkSoft)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(FlowColor.indigo.opacity(0.85))
                            .frame(width: max(6, geo.size.width * CGFloat(app.count) / CGFloat(maxCount)),
                                   height: 5)
                    }
                    .frame(height: 5)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(app.name): \(app.count) dictations")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 200, alignment: .topLeading)
    }
}

// MARK: - Scratchpad

/// The editor is the page. One compact toolbar, then text.
struct ScratchpadView: View {
    @ObservedObject var scratch: ScratchpadStore
    @ObservedObject var model: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PageHeader(title: "Scratchpad",
                           subtitle: "Dictations with no text field focused land here. It's also a plain notepad — autosaved.")
                Spacer()
                HStack(spacing: 8) {
                    Button("Export…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "scratchpad.md"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? scratch.text.write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                    .disabled(scratch.text.isEmpty)
                    Button("Copy All") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scratch.text, forType: .string)
                    }
                    .disabled(scratch.text.isEmpty)
                    Button("Clear…", role: .destructive) { confirmClear() }
                        .disabled(scratch.text.isEmpty)
                }
                .buttonStyle(QuietCapsuleButtonStyle())
            }

            TextEditor(text: Binding(get: { scratch.text }, set: { scratch.text = $0 }))
                .font(.system(size: 13))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(12)
                .quietPanel(cornerRadius: 10)
                .overlay(alignment: .topLeading) {
                    if scratch.text.isEmpty {
                        Text("Nothing here yet. Dictate with no text field focused — desktop, a web page, anywhere — and the words are kept here instead of lost.")
                            .font(.system(size: 13))
                            .foregroundStyle(FlowColor.inkSoft.opacity(0.8))
                            .padding(.horizontal, 18)
                            .padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Scratchpad text")
        }
        .padding(.horizontal, HubMetrics.pageHPad)
        .padding(.top, HubMetrics.pageTopPad)
        .padding(.bottom, HubMetrics.pageBottomPad)
        .navigationTitle("Scratchpad")
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear the Scratchpad?"
        alert.informativeText = "This deletes everything in the Scratchpad. It can't be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { scratch.clear() }
    }
}

// MARK: - Style (writing tone)

/// Tone selection as a compact list + focused preview: scan the list on the
/// left, read the full voice — description, example, requirements — on the
/// right. American English sits below as a language preference, deliberately
/// not shaped like a tone.
struct StyleView: View {
    @ObservedObject var model: HubModel
    @ObservedObject private var license = LicenseModel.shared

    private var effectiveToneID: String { license.entitlement.hasPro ? Settings.tone : "verbatim" }
    /// The tone shown in the preview: hovered if any, else the active one.
    private var previewTone: Tone {
        Tone.all.first { $0.id == (model.hoveredTone ?? effectiveToneID) }
            ?? Tone.current
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubMetrics.sectionSpacing) {
                PageHeader(title: "Style",
                           subtitle: "How dictations sound after cleanup. Tone changes style only — never what you said.")

                HStack(alignment: .top, spacing: 20) {
                    // The list: every tone's name set in its own voice.
                    VStack(spacing: 1) {
                        ForEach(Tone.all) { tone in
                            ToneListRow(tone: tone, model: model,
                                        selected: effectiveToneID == tone.id,
                                        locked: !license.entitlement.hasPro && !tone.isVerbatim)
                        }
                    }
                    .frame(width: 236)

                    ToneDetailPanel(tone: previewTone,
                                    active: effectiveToneID == previewTone.id,
                                    locked: !license.entitlement.hasPro && !previewTone.isVerbatim,
                                    model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                HubSection(title: "Language preference",
                           caption: "Applies with every tone — it's spelling, not style.") {
                    RowGroup {
                        HubRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("American English")
                                    .font(.system(size: 13))
                                    .foregroundStyle(FlowColor.ink)
                                Text("US spelling and idioms — color, not colour.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(FlowColor.inkSoft)
                            }
                            Spacer(minLength: 12)
                            // Switch on the trailing edge, like every other row.
                            Toggle("American English", isOn: Binding(
                                get: { Settings.usEnglish },
                                set: { Settings.usEnglish = $0; AppleCleanup.prewarm(); model.objectWillChange.send() }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }

                HubSection(title: "Say it out loud",
                           caption: "While dictating, these short phrases are commands, not text.") {
                    RowGroup {
                        voiceCommandRow("“Scratch that.”", "deletes what just pasted")
                        RowDivider()
                        voiceCommandRow("“Make it shorter.”", "rewrites what just pasted")
                        RowDivider()
                        voiceCommandRow("“Switch to formal tone.”", "changes your writing style")
                        RowDivider()
                        voiceCommandRow("“Translate to English.”", "speak one language, type another")
                        RowDivider()
                        voiceCommandRow("“Reply, tell them Thursday works.”",
                                        "drafts a reply from the thread on screen — read on-device")
                    }
                }
            }
            .padding(.horizontal, HubMetrics.pageHPad)
            .padding(.top, HubMetrics.pageTopPad)
            .padding(.bottom, HubMetrics.pageBottomPad)
            .frame(maxWidth: HubMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Style")
        .onAppear { TonePreviewModel.shared.prepare(from: HistoryStore.shared.entries) }
    }

    private func voiceCommandRow(_ phrase: String, _ effect: String) -> some View {
        HubRow {
            Text(phrase)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(FlowColor.indigoBright)
                .frame(width: 260, alignment: .leading)
            Text(effect)
                .font(.system(size: 12))
                .foregroundStyle(FlowColor.inkSoft)
            Spacer(minLength: 0)
        }
    }
}

/// Typography-as-icon: the voice each tone writes in, worn as its title.
func toneSpecimenFont(_ id: String, size: CGFloat) -> Font {
    switch id {
    case "verbatim":      return .system(size: size, weight: .medium, design: .monospaced)
    case "super-casual":  return .system(size: size + 1, weight: .bold, design: .rounded)
    case "casual":        return .system(size: size, weight: .semibold, design: .rounded)
    case "gentlemanly":   return FlowType.fraunces(size + 2, weight: 480, opsz: 70, soft: 60, wonk: 1)
    case "formal":        return FlowType.fraunces(size + 2, weight: 540, opsz: 80)
    default:              return .system(size: size, weight: .semibold)
    }
}

func toneSpecimenTitle(_ tone: Tone) -> String {
    tone.id == "super-casual" ? tone.name.lowercased() : tone.name
}

struct ToneListRow: View {
    let tone: Tone
    @ObservedObject var model: HubModel
    let selected: Bool
    let locked: Bool

    private var hovered: Bool { model.hoveredTone == tone.id }

    var body: some View {
        Button {
            guard !locked else {
                model.open(.settings) // calm route to the License section
                return
            }
            flowAnimate(FlowMotion.quick) {
                Settings.tone = tone.id
                model.objectWillChange.send()
            }
            // Re-prewarm the Apple FM session with the new tone's prompt so the
            // first dictation after picking a tone isn't a cold start.
            AppleCleanup.prewarm()
        } label: {
            HStack(spacing: 8) {
                Text(toneSpecimenTitle(tone))
                    .font(toneSpecimenFont(tone.id, size: 14))
                    .foregroundStyle(FlowColor.ink)
                Spacer(minLength: 0)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(FlowColor.inkSoft)
                        .accessibilityLabel("Locked — paid feature")
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FlowColor.indigoBright)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: HubMetrics.rowCorner, style: .continuous)
                    .fill(selected ? FlowColor.blackberry
                          : (hovered ? FlowColor.hover : .clear))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tone.name) tone\(selected ? ", active" : "")\(locked ? ", locked" : "")")
        .help(locked ? "A paid feature — unlocks with a subscription." : tone.description)
        .onHover { h in
            flowAnimate(.easeOut(duration: 0.14)) {
                if h { model.hoveredTone = tone.id }
                else if model.hoveredTone == tone.id { model.hoveredTone = nil }
            }
        }
    }
}

/// The focused preview: the hovered/active tone's full character.
struct ToneDetailPanel: View {
    let tone: Tone
    let active: Bool
    let locked: Bool
    @ObservedObject var model: HubModel
    @ObservedObject private var preview = TonePreviewModel.shared

    /// Restyle tones run on the local Ollama model; faithful/verbatim don't.
    private var needsOllama: Bool { !tone.instruction.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(toneSpecimenTitle(tone))
                    .font(toneSpecimenFont(tone.id, size: 21))
                    .foregroundStyle(FlowColor.ink)
                if active {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowColor.indigoBright)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FlowColor.indigo.opacity(0.18)))
                }
                Spacer(minLength: 0)
            }

            Text(tone.description)
                .font(.system(size: 13))
                .foregroundStyle(FlowColor.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if let sample = preview.sample, !locked {
                // Live: the user's own last dictation, in this tone.
                TonePreviewPair(tone: tone, sample: sample, phase: preview.phase(for: tone))
                    .padding(.top, 4)
                    .task(id: tone.id) { await preview.load(tone) }
            } else {
            // No history yet (or locked): the canned example. fixedSize keeps
            // the accent bar hugging the text instead of stretching the panel.
            HStack(spacing: 10) {
                Rectangle()
                    .fill(FlowColor.indigoBright.opacity(0.6))
                    .frame(width: 2)
                Text("“\(tone.example)”")
                    .font(tone.id == "verbatim"
                          ? .system(size: 13, design: .monospaced)
                          : .system(size: 13))
                    .italic(tone.id != "verbatim")
                    .foregroundStyle(FlowColor.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
            }

            if locked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(FlowColor.inkSoft)
                    Text("Included with the subscription — verbatim dictation stays free.")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowColor.inkSoft)
                }
            } else if needsOllama {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(FlowColor.inkSoft)
                        .accessibilityHidden(true)
                    Text("Styled by the local Ollama model — keep Ollama running for this tone.")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowColor.inkSoft)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        .quietPanel()
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var history: HistoryStore

    var body: some View {
        Group {
            if history.entries.isEmpty {
                VStack(spacing: 12) { EmptyHistoryHint() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                // A search/filter with no hits is its own state, not "no history".
                VStack(spacing: 8) {
                    Text("No matches")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlowColor.ink)
                    Text(noResultsHint)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowColor.inkSoft)
                    if model.historyApp != nil {
                        Button("Show all apps") { model.historyApp = nil }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if Settings.historyPaused {
                            HStack(spacing: 6) {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundStyle(FlowColor.amber)
                                    .accessibilityHidden(true)
                                Text("History is paused — new dictations aren't being saved.")
                                    .font(.system(size: 12)).foregroundStyle(FlowColor.ink.opacity(0.9))
                                Button("Resume") {
                                    Settings.historyPaused = false
                                    model.objectWillChange.send()
                                }
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .quietPanel(cornerRadius: 9)
                        }
                        ForEach(groupedByDay, id: \.0) { day, entries in
                            VStack(alignment: .leading, spacing: 8) {
                                // Editorial day marker: small Fraunces date over
                                // a hairline running to the right edge.
                                HStack(spacing: 12) {
                                    Text(day)
                                        .font(FlowType.fraunces(15, weight: 480, opsz: 60, soft: 20))
                                        .foregroundStyle(FlowColor.ink.opacity(0.9))
                                        .accessibilityAddTraits(.isHeader)
                                    Rectangle()
                                        .fill(FlowColor.hairline.opacity(0.5))
                                        .frame(height: 1)
                                        .accessibilityHidden(true)
                                    // The day at a glance, so the eye can skim days
                                    // before reading rows.
                                    Text(daySummary(entries))
                                        .font(.system(size: 11))
                                        .foregroundStyle(FlowColor.inkSoft)
                                        .fixedSize()
                                }
                                RowGroup {
                                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 { RowDivider() }
                                        HistoryRow(entry: entry, history: history, model: model)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, HubMetrics.pageHPad)
                    .padding(.top, 18)
                    .padding(.bottom, HubMetrics.pageBottomPad)
                    .frame(maxWidth: HubMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }),
                    prompt: "Search dictations")
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("All apps") { model.historyApp = nil }
                    Divider()
                    ForEach(appNames, id: \.self) { app in
                        Button {
                            model.historyApp = app
                        } label: {
                            if model.historyApp == app {
                                Label(app, systemImage: "checkmark")
                            } else {
                                Text(app)
                            }
                        }
                    }
                } label: {
                    Label(model.historyApp ?? "All apps",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter by destination app")
                .disabled(appNames.isEmpty)
            }
            ToolbarItem {
                Button {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "onyx-scribe-history.md"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? history.exportMarkdown()
                            .write(to: url, atomically: true, encoding: .utf8)
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(history.entries.isEmpty)
                    .help("Export all history as Markdown")
            }
        }
    }

    private var appNames: [String] {
        Array(Set(history.entries.compactMap(\.app))).sorted()
    }

    private var noResultsHint: String {
        var parts: [String] = []
        if !model.query.isEmpty { parts.append("“\(model.query)”") }
        if let app = model.historyApp { parts.append("in \(app)") }
        return "Nothing matches \(parts.joined(separator: " ")). Try a different search."
    }

    private var filtered: [HistoryEntry] {
        history.entries.filter { entry in
            let matchesQuery = model.query.isEmpty
                || entry.text.localizedCaseInsensitiveContains(model.query)
                || (entry.raw?.localizedCaseInsensitiveContains(model.query) ?? false)
            let matchesApp = model.historyApp == nil || entry.app == model.historyApp
            return matchesQuery && matchesApp
        }
    }

    private func daySummary(_ entries: [HistoryEntry]) -> String {
        let words = entries.reduce(0) { $0 + $1.wordCount }
        return "\(entries.count) dictation\(entries.count == 1 ? "" : "s") · \(words.formatted()) words"
    }

    private var groupedByDay: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.sorted { $0.key > $1.key }.map { day, entries in
            let title: String = cal.isDateInToday(day) ? "Today"
                : cal.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(date: .abbreviated, time: .omitted)
            return (title, entries.sorted { $0.date > $1.date })
        }
    }
}

/// One dictation as a compact row: the text, then a quiet meta line with
/// hover-revealed actions. Used identically by History and Insights Recent.
struct HistoryRow: View {
    let entry: HistoryEntry
    let history: HistoryStore
    @ObservedObject var model: HubModel

    private var hovered: Bool { model.hoveredEntry == entry.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
        // The time lives in a gutter, in the machine's mono voice: the eye
        // runs down one column of times, then reads across.
        Text(entry.date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(FlowColor.inkSoft)
            .frame(width: 44, alignment: .leading)
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(FlowColor.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.hasDistinctRaw, model.expandedEntry == entry.id, let raw = entry.raw {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(FlowColor.hairline)
                        .frame(width: 2)
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlowColor.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You said: \(raw)")
                .transition(.opacity)
            }
            HStack(spacing: 7) {
                if let app = entry.app {
                    Text(app).fontWeight(.medium)
                    metaDot
                }
                // The engine is noise while every entry shares one; it earns
                // its place only when history actually mixes engines.
                if history.usesMultipleEngines {
                    Text(entry.engine)
                    metaDot
                }
                Text(String(format: "%.1fs", Double(entry.durationMs) / 1000))
                if entry.hasDistinctRaw {
                    Button {
                        flowAnimate(.easeOut(duration: 0.18)) {
                            model.expandedEntry = model.expandedEntry == entry.id ? nil : entry.id
                        }
                    } label: {
                        Image(systemName: model.expandedEntry == entry.id ? "chevron.up" : "text.quote")
                    }
                    .buttonStyle(.borderless)
                    .help("Show what you said before cleanup")
                    .accessibilityLabel("Show original transcript")
                }
                Spacer()
                // Pin stays visible when pinned; everything else reveals on hover.
                Button {
                    flowAnimate(.easeOut(duration: 0.15)) { history.togglePin(entry.id) }
                } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(entry.isPinned ? AnyShapeStyle(FlowColor.indigoBright)
                                                        : AnyShapeStyle(FlowColor.inkSoft))
                }
                .buttonStyle(.borderless)
                .help(entry.isPinned ? "Unpin" : "Pin (survives the 100-entry limit)")
                .accessibilityLabel(entry.isPinned ? "Unpin" : "Pin")
                .opacity(entry.isPinned || hovered ? 1 : 0)
                HStack(spacing: 9) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                        .accessibilityLabel("Copy dictation")
                    Button {
                        let text = entry.text
                        NSApp.hide(nil) // give focus back to the previous app…
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            // User-directed paste into whatever regains focus
                            // (still refuses secure fields).
                            TextInjector.inject(text, target: .userDirected)
                        }
                    } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless)
                        .help("Insert into the previous app")
                        .accessibilityLabel("Insert into the previous app")
                    Button(role: .destructive) {
                        flowAnimate(.easeOut(duration: 0.2)) { history.delete(entry.id) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                        .accessibilityLabel("Delete dictation")
                }
                .opacity(hovered ? 1 : 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(FlowColor.inkSoft)
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: HubMetrics.rowCorner, style: .continuous)
                .fill(hovered ? FlowColor.hover : .clear)
        )
        .animation(MotionPreferences.shared.anim(.easeOut(duration: 0.15)), value: hovered)
        .onHover { inside in
            model.hoveredEntry = inside ? entry.id : (hovered ? nil : model.hoveredEntry)
        }
    }

    private var metaDot: some View {
        Text("·").accessibilityHidden(true)
    }
}

struct EmptyHistoryHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic")
                .font(.system(size: 32))
                .foregroundStyle(FlowColor.indigo.opacity(0.7))
                .accessibilityHidden(true)
            Text("Hold \(Settings.hotkeyDisplay) anywhere to dictate")
                .font(.system(size: 13))
                .foregroundStyle(FlowColor.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
