import SwiftUI
import ServiceManagement
import AVFoundation
import FlowCloneCore

// MARK: - Dictionary (vocabulary + learned terms + corrections + app profiles)

/// Three clearly different kinds of words, three flat sections — no cards:
/// what YOU added, what Onyx LEARNED, and the mechanical corrections. App
/// profiles follow as per-app cleanup instructions.
struct DictionaryView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var vocab: VocabStore
    @ObservedObject var profiles: ProfilesStore
    @ObservedObject private var learned = LearnedStore.shared

    var body: some View {
        PageScaffold(title: "Dictionary",
                     subtitle: "Teach it your words — names, jargon, and the fixes it should always make.") {
            HubSection(title: "Vocabulary",
                       caption: "Words you added. Given to the AI cleanup as spelling hints.") {
                HStack {
                    TextField("Add a term (e.g. Kubernetes)",
                              text: Binding(get: { model.newTerm }, set: { model.newTerm = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                        .accessibilityLabel("New vocabulary term")
                    Button("Add", action: addTerm)
                        .buttonStyle(QuietCapsuleButtonStyle())
                        .disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if vocab.terms.isEmpty {
                    DictEmptyHint(text: "No terms yet — add the words it keeps misspelling.")
                } else {
                    RowGroup {
                        ForEach(Array(vocab.terms.enumerated()), id: \.element) { index, term in
                            if index > 0 { RowDivider() }
                            HubRow {
                                Text(term).font(.system(size: 13)).foregroundStyle(FlowColor.ink)
                                Spacer()
                                Button(role: .destructive) {
                                    vocab.terms.removeAll { $0 == term }
                                    vocab.save()
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove \(term)")
                                    .accessibilityLabel("Remove \(term)")
                            }
                        }
                    }
                }
            }

            // Auto-learned terms — local style memory. Only shown when it has
            // actually learned something, so it never nags an empty state.
            if !learned.terms.isEmpty {
                HubSection(title: "Learned automatically",
                           caption: "Picked up from your own dictations — on-device, never uploaded. Add the real ones to Vocabulary; remove the noise.") {
                    RowGroup {
                        ForEach(Array(learned.terms.enumerated()), id: \.element) { index, term in
                            if index > 0 { RowDivider() }
                            HubRow {
                                Text(term).font(.system(size: 13)).foregroundStyle(FlowColor.ink)
                                Spacer()
                                Button("Add to Vocabulary") {
                                    if !vocab.terms.contains(where: {
                                        $0.caseInsensitiveCompare(term) == .orderedSame }) {
                                        vocab.terms.append(term); vocab.save()
                                    }
                                    learned.dismiss(term) // promoted — stop auto-listing it
                                }
                                .buttonStyle(.borderless).font(.system(size: 12))
                                Button(role: .destructive) {
                                    learned.dismiss(term)
                                } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .help("Not a word I use — don't learn this")
                                    .accessibilityLabel("Remove learned term \(term)")
                            }
                        }
                    }
                }
            }

            HubSection(title: "Corrections",
                       caption: "Literal replacements applied to the raw transcript before the AI sees it.") {
                HStack {
                    TextField("heard (e.g. cube er netties)",
                              text: Binding(get: { model.newWrong }, set: { model.newWrong = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("What was heard")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(FlowColor.indigoBright)
                        .accessibilityHidden(true)
                    TextField("should be (e.g. Kubernetes)",
                              text: Binding(get: { model.newRight }, set: { model.newRight = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addRule)
                        .accessibilityLabel("What it should be")
                    Button("Add", action: addRule)
                        .buttonStyle(QuietCapsuleButtonStyle())
                        .disabled(model.newWrong.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.newRight.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if vocab.rules.isEmpty {
                    DictEmptyHint(text: "No corrections yet — map what it hears to what you meant.")
                } else {
                    RowGroup {
                        ForEach(Array(vocab.rules.enumerated()), id: \.offset) { index, rule in
                            if index > 0 { RowDivider() }
                            HubRow {
                                Text(rule.wrong).font(.system(size: 13)).foregroundStyle(FlowColor.inkSoft)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10)).foregroundStyle(FlowColor.indigoBright)
                                    .accessibilityHidden(true)
                                Text(rule.right).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FlowColor.ink)
                                Spacer()
                                Button(role: .destructive) {
                                    vocab.rules.remove(at: index)
                                    vocab.save()
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove this correction")
                                    .accessibilityLabel("Remove correction \(rule.wrong) to \(rule.right)")
                            }
                        }
                    }
                }
            }

            HubSection(title: "App profiles",
                       caption: "Extra cleanup instructions applied when dictating into a specific app.") {
                HStack {
                    TextField("App (e.g. Slack)",
                              text: Binding(get: { model.newProfileApp }, set: { model.newProfileApp = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .accessibilityLabel("App name")
                    TextField("Instruction (e.g. casual tone, keep it short)",
                              text: Binding(get: { model.newProfileInstruction }, set: { model.newProfileInstruction = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addProfile)
                        .accessibilityLabel("Cleanup instruction for this app")
                    Button("Add", action: addProfile)
                        .buttonStyle(QuietCapsuleButtonStyle())
                        .disabled(model.newProfileApp.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.newProfileInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if profiles.profiles.isEmpty {
                    DictEmptyHint(text: "No profiles yet — give an app its own voice, like “casual, keep it short” for Slack.")
                } else {
                    RowGroup {
                        ForEach(Array(profiles.profiles.enumerated()), id: \.offset) { index, profile in
                            if index > 0 { RowDivider() }
                            HubRow(alignment: .top) {
                                Text(profile.app).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FlowColor.ink)
                                    .frame(width: 140, alignment: .leading)
                                Text(profile.instruction).font(.system(size: 13))
                                    .foregroundStyle(FlowColor.inkSoft)
                                Spacer()
                                Button(role: .destructive) {
                                    profiles.profiles.remove(at: index)
                                    profiles.save()
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove the \(profile.app) profile")
                                    .accessibilityLabel("Remove the \(profile.app) profile")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .onAppear { DispatchQueue.global(qos: .utility).async { learned.refresh() } }
    }

    private func addTerm() {
        let t = model.newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        // The list is keyed by the term itself — a duplicate would give two
        // rows one identity (and one trash button deleting both).
        if !vocab.terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            vocab.terms.append(t)
            vocab.save()
        }
        model.newTerm = ""
    }

    private func addRule() {
        let w = model.newWrong.trimmingCharacters(in: .whitespaces)
        let r = model.newRight.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !r.isEmpty else { return }
        vocab.rules.append((w, r))
        vocab.save()
        model.newWrong = ""; model.newRight = ""
    }

    private func addProfile() {
        let a = model.newProfileApp.trimmingCharacters(in: .whitespaces)
        let i = model.newProfileInstruction.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !i.isEmpty else { return }
        // Case-insensitive upsert: a duplicate app name updates the existing
        // entry instead of appending a second one.
        profiles.upsert(app: a, instruction: i)
        model.newProfileApp = ""; model.newProfileInstruction = ""
    }
}

/// Quiet empty-state line shown before the first entry exists.
struct DictEmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(FlowColor.inkSoft)
            .padding(.vertical, 4)
    }
}

// MARK: - Settings

/// Native grouped Form, re-sectioned into a clean system: License,
/// Transcription, Languages, AI Cleanup (advanced options disclosed),
/// Privacy & History, Shortcuts, General, Permissions.
struct SettingsPane: View {
    @ObservedObject var model: HubModel
    @ObservedObject private var ollamaHealth = OllamaHealth.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var license = LicenseModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page identity above the native form — the form itself stays
            // native (system controls belong to the system's material).
            PageHeader(title: "Settings",
                       subtitle: "Engine, cleanup, privacy — everything stays on this Mac.")
                .padding(.horizontal, HubMetrics.pageHPad)
                .padding(.top, HubMetrics.pageTopPad)
                .padding(.bottom, 4)
            settingsForm
        }
    }

    @ViewBuilder private var licenseStatusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            switch license.entitlement {
            case .subscribed(let until):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Licensed" + (license.licenseEmail.map { " · \($0)" } ?? ""))
                    Text("Active until \(until, format: .dateTime.year().month().day())")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .trial:
                let days = license.entitlement.trialDaysLeft(now: Date()) ?? 0
                Image(systemName: "clock.badge.checkmark.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free trial — \(days) day\(days == 1 ? "" : "s") left")
                    Text("Everything unlocked. After the trial, verbatim dictation stays free.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .free:
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free tier — verbatim dictation")
                    Text("Cleanup, tones, and voice commands unlock with a subscription.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var settingsForm: some View {
        Form {
            Section("License") {
                if LicenseModel.licensingEnabled {
                    licenseStatusRow
                    if !license.isSubscribed {
                        Button("Subscribe to Onyx Scribe") {
                            NSWorkspace.shared.open(LicenseModel.subscribeURL)
                        }
                    }
                    HStack {
                        TextField("Paste license key", text: Binding(
                            get: { license.draftKey },
                            set: { license.draftKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Activate") { license.activateDraft() }
                            .disabled(license.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 12) {
                        Button("Refresh License") { Task { await license.refreshFromStore() } }
                        if license.isSubscribed {
                            Button("Remove License") { license.clearLicense() }
                        }
                        Spacer()
                    }
                    if let err = license.activationError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                    if let msg = license.lastRefreshMessage {
                        Text(msg).foregroundStyle(.secondary).font(.callout)
                    }
                } else {
                    // Owner build: no subscription, nothing to buy or paste.
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("All features unlocked — this build has no subscription.")
                    }
                }
            }

            Section("Transcription") {
                Picker("Speech engine", selection: Binding(
                    get: { Settings.asrEngine },
                    set: { Settings.setASREngine($0); model.reloadEngine?(); model.objectWillChange.send() }
                )) {
                    Text("Parakeet — fast").tag("parakeet")
                    Text("Whisper — most accurate, slower").tag("whisper")
                }
            }

            Section("Languages") {
                Toggle("Auto-detect language (EN ⇄ BG)", isOn: Binding(
                    get: { Settings.autoLanguage && Settings.autoLanguageAvailable },
                    set: { Settings.autoLanguage = $0; model.objectWillChange.send() }
                ))
                .disabled(!Settings.autoLanguageAvailable)
                if !Settings.autoLanguageAvailable {
                    Text("Whisper can't tell which of your languages an utterance is in, "
                         + "so dictation uses the pinned language below. "
                         + "Switch to Parakeet for auto-detect.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Language", selection: Binding(
                    get: { Settings.language },
                    set: { code in
                        // Mirror the menu's semantics: the old primary becomes
                        // the pill-toggle alternate; a manual pin disables auto.
                        if code != Settings.language {
                            Settings.altLanguage = Settings.language
                            Settings.language = code
                        }
                        Settings.autoLanguage = false
                        model.objectWillChange.send()
                    }
                )) {
                    ForEach(AppDelegate.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Picker("Translate output", selection: Binding(
                    get: { Settings.translateTo ?? "off" },
                    set: { Settings.translateTo = ($0 == "off") ? nil : $0; model.objectWillChange.send() }
                )) {
                    Text("Off — type the language you speak").tag("off")
                    ForEach(AppDelegate.languages, id: \.code) { lang in
                        Text("Into \(AppDelegate.englishName(lang.code))").tag(lang.code)
                    }
                }
                Toggle("American English (US spelling and idioms)", isOn: Binding(
                    get: { Settings.usEnglish },
                    set: { Settings.usEnglish = $0; AppleCleanup.prewarm(); model.objectWillChange.send() }
                ))
            }

            Section("AI Cleanup") {
                Toggle("Clean up transcripts (grammar, fillers, tone)", isOn: Binding(
                    get: { Settings.cleanupEnabled },
                    set: { Settings.cleanupEnabled = $0; model.objectWillChange.send() }
                ))
                Picker("Cleanup engine", selection: Binding(
                    get: { Settings.cleanupEngine },
                    set: { Settings.cleanupEngine = $0; model.objectWillChange.send() }
                )) {
                    Text("Automatic — best available engine per language").tag("auto")
                    Text("Apple Intelligence (built-in)").tag("apple")
                    Text("Ollama (advanced)").tag("ollama")
                }
                if Settings.cleanupEngine != "ollama" {
                    HStack {
                        if AppleCleanup.isAvailable {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Apple Intelligence ready — nothing to install")
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(AppleCleanup.unavailableReason
                                 ?? "Apple Intelligence isn't available")
                        }
                    }
                }
                if Settings.cleanupEngine != "apple" {
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        HStack {
                            switch ollamaHealth.status {
                            case .unknown:
                                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                                Text("Checking Ollama…")
                            case .offline:
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                Text("Ollama isn't running")
                                Spacer()
                                Button("Get Ollama") {
                                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                                }
                            case .modelMissing:
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                Text("Model \"\(Settings.ollamaModel)\" isn't pulled")
                                Spacer()
                                Button("Copy pull command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("ollama pull \(Settings.ollamaModel)",
                                                                   forType: .string)
                                }
                            case .ready(let warm):
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(warm ? "Ollama ready (model warm)" : "Ollama ready")
                            }
                        }
                        .onAppear { ollamaHealth.checkIfStale(olderThan: 5) }
                    }
                }
                Toggle("Fit insertions to surrounding text (reads around the caret on-device)", isOn: Binding(
                    get: { Settings.contextAware },
                    set: { Settings.contextAware = $0; model.objectWillChange.send() }
                ))
                DisclosureGroup("Advanced") {
                    if Settings.cleanupEngine != "apple" {
                        TextField("Ollama model", text: Binding(
                            get: { Settings.ollamaModel },
                            set: { Settings.ollamaModel = $0; model.objectWillChange.send() }
                        ))
                    }
                    Toggle("Live preview while polishing", isOn: Binding(
                        get: { Settings.streamingPreview },
                        set: { Settings.streamingPreview = $0; model.objectWillChange.send() }
                    ))
                    Text("Shows the cleaned text forming in the pill as the on-device model "
                         + "streams it. Preview only — the text still lands in one paste.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Early paste while polishing", isOn: Binding(
                        get: { Settings.streamingEarlyInject },
                        set: { Settings.streamingEarlyInject = $0; model.objectWillChange.send() }
                    ))
                    .disabled(!Settings.streamingPreview)
                    Text("Pastes the first finished sentence into your document before "
                         + "cleanup completes. Risk: if the model later revises that "
                         + "sentence, what's already in your document can't be corrected. "
                         + "Leave off unless you've verified it in the apps you dictate into.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Privacy & History") {
                Toggle("Pause history (don't save any dictation text)", isOn: Binding(
                    get: { Settings.historyPaused },
                    set: { Settings.historyPaused = $0; model.objectWillChange.send() }
                ))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Never save dictations made in these apps:")
                    ForEach(Settings.excludedApps, id: \.self) { app in
                        HStack {
                            Text(app)
                            Spacer()
                            Button {
                                Settings.excludedApps.removeAll { $0 == app }
                                model.objectWillChange.send()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop excluding \(app)")
                                .accessibilityLabel("Stop excluding \(app)")
                        }
                    }
                    HStack {
                        TextField("App name or bundle id (e.g. Bitwarden)", text: Binding(
                            get: { model.newExclusion },
                            set: { model.newExclusion = $0 }
                        ))
                        Button("Add") {
                            let name = model.newExclusion.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty,
                                  !Settings.excludedApps.contains(where: {
                                      $0.caseInsensitiveCompare(name) == .orderedSame })
                            else { return }
                            Settings.excludedApps.append(name)
                            model.newExclusion = ""
                            model.objectWillChange.send()
                        }
                        .disabled(model.newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Dictation still pastes normally — the text just isn't kept in History or the Scratchpad.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(history.entries.count) dictations stored")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Delete all \(history.entries.count) dictations?"
                        alert.informativeText = "This removes every entry from History and the Recent Dictations menu. It can't be undone."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        alert.alertStyle = .warning
                        if alert.runModal() == .alertFirstButtonReturn {
                            history.clearAll()
                        }
                    }
                    .disabled(history.entries.isEmpty)
                }
            }

            Section("Shortcuts") {
                HStack {
                    Text("Dictation hotkey")
                    Spacer()
                    if model.capturingHotkey {
                        Text("Press keys… (Esc to cancel)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.hotkeyDisplay)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(FlowColor.indigo.opacity(0.14)))
                    }
                    Button(model.capturingHotkey ? "Cancel" : "Change…") {
                        if model.capturingHotkey {
                            model.hotkeyRecorder.cancel()
                            model.capturingHotkey = false
                        } else {
                            model.capturingHotkey = true
                            model.hotkeyRecorder.begin { spec in
                                DispatchQueue.main.async {
                                    model.capturingHotkey = false
                                    if let spec {
                                        Settings.hotkey = spec
                                        model.hotkeyDisplay = spec.displayString
                                        model.updateHotkey?()
                                    }
                                }
                            }
                        }
                    }
                    if Settings.hotkey != .rightOption {
                        Button("Reset") {
                            Settings.hotkey = .rightOption
                            model.hotkeyDisplay = Settings.hotkeyDisplay
                            model.updateHotkey?()
                            model.objectWillChange.send()
                        }
                    }
                }
                Text("Hold to dictate, release to paste. Esc cancels. Double-tap-hold transforms selected text.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Sound feedback (record, paste, errors)", isOn: Binding(
                    get: { Settings.soundFeedback },
                    set: { Settings.soundFeedback = $0; model.objectWillChange.send() }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                        model.objectWillChange.send()
                    }
                ))
                HStack {
                    Text("Dictation pill position")
                    Spacer()
                    Button("Reset to bottom-center") { model.resetPillPosition?() }
                }
            }

            Section("Permissions") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        PermissionRow(
                            name: "Accessibility",
                            granted: AXIsProcessTrusted(),
                            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )
                        PermissionRow(
                            name: "Microphone",
                            granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Let the aurora canvas run behind the grouped sections — the form's
        // default opaque backdrop cuts a hard seam under the page header.
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
    }
}

struct PermissionRow: View {
    let name: String
    let granted: Bool
    let settingsURL: String

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .yellow)
                .accessibilityHidden(true)
            Text(name)
            Text(granted ? "Granted" : "Not granted")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !granted {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: settingsURL)!)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(granted ? "granted" : "not granted")")
    }
}
