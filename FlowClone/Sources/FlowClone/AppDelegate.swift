import AppKit
import AVFoundation
import FlowCloneCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var pillController: PillController!
    private var hubController: HubWindowController!

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("bg", "Български"), ("de", "Deutsch"), ("es", "Español"),
        ("fr", "Français"), ("it", "Italiano"), ("pt", "Português"), ("nl", "Nederlands"),
        ("pl", "Polski"), ("uk", "Українська"), ("ru", "Русский"), ("ja", "日本語"),
    ]

    /// English language names — for the translate voice command ("translate to
    /// Bulgarian") and the translation prompt, which speak English regardless of
    /// the native display names above.
    static let englishNames: [String: String] = [
        "en": "English", "bg": "Bulgarian", "de": "German", "es": "Spanish",
        "fr": "French", "it": "Italian", "pt": "Portuguese", "nl": "Dutch",
        "pl": "Polish", "uk": "Ukrainian", "ru": "Russian", "ja": "Japanese",
    ]
    static func englishName(_ code: String) -> String { englishNames[code] ?? code }
    static var translateLanguages: [(code: String, name: String)] {
        languages.map { ($0.code, englishName($0.code)) }
    }

    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LicenseStore.recordLaunch()   // establish/repair trial clock before anything reads it
        LicenseModel.shared.refresh()
        // Local style memory: learn the user's own words from history (off the hot path).
        DispatchQueue.global(qos: .utility).async { LearnedStore.shared.refresh() }
        FontLoader.registerBundledFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic.fill")
        Self.bootstrapVocabulary()
        Self.bootstrapProfiles()
        buildMenu()

        if !OnboardingWindowController.needed {
            // Normal launch: prompt if permissions are missing.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                print("⚠️  Grant Accessibility permission (System Settings → Privacy & Security → Accessibility), then relaunch.")
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { print("⚠️  Microphone access denied — dictation cannot work.") }
            }
        }

        controller = DictationController { [weak self] state in
            DispatchQueue.main.async { self?.updateStatus(state) }
        }
        pillController = PillController()
        controller.pill = pillController
        hubController = HubWindowController(
            reloadEngine: { [weak self] in self?.controller.reloadEngine() },
            resetPillPosition: { [weak self] in self?.pillController.resetPosition() },
            updateHotkey: { [weak self] in self?.controller.updateHotkey() }
        )
        controller.start()

        if OnboardingWindowController.needed {
            // First run: onboarding walks through mic + accessibility. It borrows
            // the pipeline's ASR engine (loading now via controller.start()) rather
            // than loading a second copy.
            onboarding = OnboardingWindowController(
                borrowEngine: { [weak self] in self?.controller.sharedEngine })
            onboarding?.show()
        }

        // Debug: `open FlowClone.app --args --hub` opens the Hub immediately.
        // `--snapshot-hub <path>` additionally renders it to a PNG and quits.
        if CommandLine.arguments.contains("--hub") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hubController.show() }
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot-hub"),
               CommandLine.arguments.count > i + 1 {
                let path = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.hubController.snapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
            // `--snapshot-all <dir>`: capture every Hub page, then quit.
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot-all"),
               CommandLine.arguments.count > i + 1 {
                let dir = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.hubController.snapshotAll(to: dir) { NSApp.terminate(nil) }
                }
            }
        }

        // Debug: `--icon-snapshot <path>` renders the app icon offscreen to a PNG
        // (1024²) via ImageRenderer, ready to pack into AppIcon.icns.
        if let i = CommandLine.arguments.firstIndex(of: "--icon-snapshot"),
           CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            let renderer = ImageRenderer(content: AppIconView(size: 1024))
            renderer.scale = 1
            if let cg = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
                print("icon snapshot written: \(path)")
            }
            NSApp.terminate(nil)
        }

        // Debug: `--pill-snapshot <dir>` renders every pill state to PNGs, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--pill-snapshot"),
           CommandLine.arguments.count > i + 1 {
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.pillController.snapshotStates(to: dir) { NSApp.terminate(nil) }
            }
        }

        // Debug: `--onboard` forces the first-run flow (regardless of
        // hasOnboarded); `--snapshot-onboard <dir>` walks its states to PNGs.
        if CommandLine.arguments.contains("--onboard") {
            let ob = onboarding ?? OnboardingWindowController(
                borrowEngine: { [weak self] in self?.controller.sharedEngine })
            onboarding = ob
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ob.show() }
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot-onboard"),
               CommandLine.arguments.count > i + 1 {
                let dir = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    ob.snapshotSteps(to: dir) { NSApp.terminate(nil) }
                }
            }
        }
        print("Onyx Scribe running. Hold \(Settings.hotkeyDisplay) to dictate, release to transcribe & paste.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The Scratchpad save is debounced; a quit inside the debounce window
        // must not drop the last dictation.
        ScratchpadStore.shared.flushNow()
    }

    /// The dropdown is rebuilt fresh on every open (menuWillOpen), so every
    /// checkmark and status row is always current — no stale item juggling.
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A lightweight control center: open, status, hands-free, quick controls,
    /// recents, utilities, quit. Healthy systems occupy ONE quiet row; only
    /// problems earn actionable rows.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Onyx Scribe…", action: #selector(openHub), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        // Status summary — same source of truth as the Hub's readiness line.
        OllamaHealth.shared.checkIfStale(olderThan: 5)
        let state = ReadinessSummary.compute()
        let summary = NSMenuItem(
            title: state.ready ? "Ready — \(state.summary)" : "Needs attention",
            action: nil, keyEquivalent: "")
        summary.isEnabled = false
        summary.image = Self.statusDot(state.ready ? .systemGreen : .systemOrange)
        menu.addItem(summary)
        for problem in state.problems {
            let item = NSMenuItem(title: problem.text, action: #selector(fixProblem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = problem.action.rawValue
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let hint = NSMenuItem(title: "Hold \(Settings.hotkeyDisplay) to dictate · Esc cancels",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        // Quick controls.
        let handsFreeItem = NSMenuItem(title: "Hands-Free Next Dictation",
                                       action: #selector(armHandsFree), keyEquivalent: "")
        handsFreeItem.target = self
        menu.addItem(handsFreeItem)

        let cleanupItem = NSMenuItem(title: "AI Cleanup", action: #selector(toggleCleanup),
                                     keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = Settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = buildEngineMenu()
        menu.addItem(engineItem)

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = buildLanguageMenu()
        menu.addItem(languageItem)

        let toneItem = NSMenuItem(title: "Tone", action: nil, keyEquivalent: "")
        toneItem.submenu = buildToneMenu()
        menu.addItem(toneItem)
        menu.addItem(.separator())

        // Recents.
        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentItem.submenu = buildRecentMenu()
        menu.addItem(recentItem)
        menu.addItem(.separator())

        // Startup + utilities.
        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.isEnabled = Bundle.main.bundleIdentifier != nil // needs a real .app bundle
        menu.addItem(loginItem)

        let utilities = NSMenu()
        let commandsItem = NSMenuItem(title: "Voice Commands…",
                                      action: #selector(openVoiceCommands), keyEquivalent: "")
        commandsItem.target = self
        utilities.addItem(commandsItem)
        let vocabItem = NSMenuItem(title: "Edit Vocabulary File…",
                                   action: #selector(openVocabulary), keyEquivalent: "")
        vocabItem.target = self
        utilities.addItem(vocabItem)
        let profilesItem = NSMenuItem(title: "Edit App Profiles File…",
                                      action: #selector(openProfiles), keyEquivalent: "")
        profilesItem.target = self
        utilities.addItem(profilesItem)
        let resetPillItem = NSMenuItem(title: "Reset Pill Position",
                                       action: #selector(resetPillPosition), keyEquivalent: "")
        resetPillItem.target = self
        utilities.addItem(resetPillItem)
        let utilitiesItem = NSMenuItem(title: "Utilities", action: nil, keyEquivalent: "")
        utilitiesItem.submenu = utilities
        menu.addItem(utilitiesItem)

        menu.addItem(NSMenuItem(title: "Quit Onyx Scribe",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func buildEngineMenu() -> NSMenu {
        let submenu = NSMenu()
        for (title, tag) in [("Parakeet — fast", "parakeet"),
                             ("Whisper — most accurate", "whisper")] {
            let item = NSMenuItem(title: title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            item.state = Settings.asrEngine == tag ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildLanguageMenu() -> NSMenu {
        let submenu = NSMenu()
        // Whisper has no trustworthy per-utterance detection, so auto-detect is
        // disabled there and the row says why (same state as pill + Settings).
        let autoAvailable = Settings.autoLanguageAvailable
        let autoItem = NSMenuItem(
            title: autoAvailable ? "Auto-Detect (EN ⇄ BG)" : "Auto-Detect — needs Parakeet",
            action: autoAvailable ? #selector(toggleAutoLanguage) : nil,
            keyEquivalent: "")
        autoItem.target = self
        autoItem.isEnabled = autoAvailable
        autoItem.state = (autoAvailable && Settings.autoLanguage) ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(.separator())
        for lang in Self.languages {
            let item = NSMenuItem(title: lang.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            // With auto on, no single language is "the" pin — check none.
            item.state = (!Settings.autoLanguage && Settings.language == lang.code) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildToneMenu() -> NSMenu {
        let submenu = NSMenu()
        for tone in Tone.all {
            let item = NSMenuItem(title: tone.name, action: #selector(pickTone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tone.id
            item.state = Settings.tone == tone.id ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let usItem = NSMenuItem(title: "American English",
                                action: #selector(toggleUSEnglish), keyEquivalent: "")
        usItem.target = self
        usItem.state = Settings.usEnglish ? .on : .off
        submenu.addItem(usItem)
        return submenu
    }

    private func buildRecentMenu() -> NSMenu {
        let submenu = NSMenu()
        let recents = HistoryStore.shared.entries.prefix(10).map(\.text)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for text in recents {
            let title = text.count > 60 ? String(text.prefix(57)) + "…" : text
            let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = "Copy to clipboard"
            submenu.addItem(item)
        }
        return submenu
    }

    /// A small filled status dot; the row's WORDS carry the state, the color
    /// only reinforces it.
    private static func statusDot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc private func toggleCleanup() {
        Settings.cleanupEnabled.toggle()
    }

    @objc private func fixProblem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = ReadinessSummary.Problem.Action(rawValue: raw) else { return }
        switch action {
        case .openAccessibility: openAccessibilitySettings()
        case .openMicrophone: openMicSettings()
        case .fixOllama: ollamaStatusClicked()
        }
    }

    @objc @MainActor private func pickEngine(_ sender: NSMenuItem) {
        guard let engine = sender.representedObject as? String,
              engine != Settings.asrEngine else { return }
        Settings.setASREngine(engine)
        // The switch may have pinned the language (Whisper has no auto-detect);
        // keep the pill badge in sync.
        pillController?.setAuto(Settings.autoLanguage)
        pillController?.setLanguage(Settings.language)
        controller?.reloadEngine()
    }

    /// Arm hands-free: the next dictation locks on so the user can speak without
    /// holding the key; the next press stops it.
    /// `@MainActor`: AppKit only ever sends menu actions on the main thread, but
    /// `@objc` methods aren't covered by the delegate's isolation inference, so
    /// the annotation is what lets this reach the main-actor-isolated controller.
    @objc @MainActor private func armHandsFree() {
        controller?.armHandsFree()
    }

    @objc private func pickTone(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            Settings.tone = id
            // Rebuild the warm Apple FM session with the new tone's prompt so the
            // FIRST dictation after switching isn't cold (matches the spoken
            // "switch to X tone" path in DictationController).
            AppleCleanup.prewarm()
        }
    }

    @objc private func toggleUSEnglish() {
        Settings.usEnglish.toggle()
        // US English is part of the stable prompt too — re-prewarm so the next
        // dictation stays warm.
        AppleCleanup.prewarm()
    }

    /// The spoken-command cheat sheet lives on the Style page.
    @objc private func openVoiceCommands() {
        hubController?.show(page: .style)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        if code != Settings.language {
            Settings.altLanguage = Settings.language // old primary becomes the pill-toggle alternate
            Settings.language = code
        }
        Settings.autoLanguage = false // choosing a specific language is a manual override
        pillController?.setLanguage(code)
        pillController?.setAuto(false)
    }

    @objc private func toggleAutoLanguage() {
        Settings.autoLanguage.toggle()
        pillController?.setAuto(Settings.autoLanguage)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            // The menu rebuilds on every open, so the checkmark self-corrects.
        } catch {
            print("⚠️  Launch-at-login toggle failed: \(error)")
        }
    }

    /// Rebuilt fresh on every open, so permissions, engine routes, checkmarks
    /// and recents are always live — the #1 failure mode after rebuilds is a
    /// silently-invalidated Accessibility grant, and the menu must show it.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openProfiles() {
        NSWorkspace.shared.open(Self.profilesURL)
    }

    private static var profilesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/profiles.json")
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func ollamaStatusClicked() {
        switch OllamaHealth.shared.status {
        case .offline:
            // Try launching the Ollama app; fall back to the download page.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
            }
        case .modelMissing:
            // Put the fix on the clipboard and take the user to Settings.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("ollama pull \(Settings.ollamaModel)", forType: .string)
            hubController?.show(page: .settings)
        default:
            hubController?.show(page: .settings)
        }
    }

    @objc private func resetPillPosition() {
        pillController?.resetPosition()
    }

    @objc private func openHub() {
        hubController?.show()
    }

    @objc private func openVocabulary() {
        NSWorkspace.shared.open(Self.vocabularyURL)
    }

    private static var vocabularyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/vocabulary.txt")
    }

    /// Creates ~/.flowclone/vocabulary.txt with a template on first launch.
    private static func bootstrapVocabulary() {
        let url = vocabularyURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        # FlowClone personal dictionary — one entry per line, # lines are ignored.
        #
        # Plain lines are hints for the AI cleanup (names, jargon, products):
        # Todor Topalov
        # Kubernetes
        #
        # "wrong => right" lines are literal replacements applied to the raw
        # transcript before the AI sees it (case-insensitive):
        # cube er netties => Kubernetes
        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Creates ~/.flowclone/profiles.json with a template on first launch.
    private static func bootstrapProfiles() {
        let url = profilesURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        {
          "_comment": "Per-app cleanup instructions, keyed by app name (as shown in the menu bar). Remove the leading underscores to activate.",
          "_Slack": "Casual tone is fine. Keep it short. Lowercase greetings are okay.",
          "_Mail": "Proper email prose: full sentences, courteous, no slang."
        }
        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    private func updateStatus(_ state: DictationController.State) {
        switch state {
        case .loadingModel: setIcon("hourglass")
        case .idle:         setCatIcon()
        case .recording:    setIcon("mic.fill", tint: .systemRed)
        case .processing:   setIcon("ellipsis")
        }
    }

    /// Resting state wears the mascot — instantly findable in a crowded menu bar.
    private func setCatIcon() {
        let image = OnyxCatStatusIcon.image()
        image.accessibilityDescription = "Onyx Scribe"
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
    }

    /// Template SF-symbol menu-bar icon (adapts to menu-bar appearance);
    /// optional tint for the recording state.
    private func setIcon(_ name: String, tint: NSColor? = nil) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Onyx Scribe")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = tint
    }
}

enum Settings {
    /// Cleanup engine: "auto" (Apple Intelligence when possible, Ollama for
    /// non-English), "apple", or "ollama".
    static var cleanupEngine: String {
        get { UserDefaults.standard.string(forKey: "cleanupEngine") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEngine") }
    }

    /// Quiet audio feedback on record start/stop, paste, and errors.
    static var soundFeedback: Bool {
        get { UserDefaults.standard.object(forKey: "soundFeedback") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundFeedback") }
    }

    static var cleanupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEnabled") }
    }
    /// Phase-1 streaming: live pill preview of Apple FM cleanup output as it
    /// generates. No injection risk — the document still gets ONE validated
    /// paste at the end. Default on (the perceived-latency win).
    static var streamingPreview: Bool {
        get { UserDefaults.standard.object(forKey: "streamingPreview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "streamingPreview") }
    }
    /// Phase-2 streaming (ADVANCED, opt-in): paste one confirmed sentence into
    /// the document before cleanup finishes. Document-mutating and only
    /// manually verifiable, so it defaults OFF per PLAN.md's safety contract —
    /// the Settings toggle explains the risk. (Supersedes the retired
    /// "streamingInjection" key, which wrongly defaulted early landing on.)
    static var streamingEarlyInject: Bool {
        get { UserDefaults.standard.object(forKey: "streamingEarlyInject") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "streamingEarlyInject") }
    }
    static var asrEngine: String {
        get { UserDefaults.standard.string(forKey: "asrEngine") ?? "parakeet" }
        set { UserDefaults.standard.set(newValue, forKey: "asrEngine") }
    }
    /// Auto-language needs comparable per-decode confidence, which only
    /// Parakeet provides — Whisper's transcribeAuto just relabels the first
    /// candidate, so "auto" there would silently mislabel the language and
    /// misroute cleanup. Every surface (menu, pill, Settings) keys off this.
    static var autoLanguageAvailable: Bool { asrEngine != "whisper" }
    /// Switch the ASR engine, keeping the language configuration valid:
    /// choosing Whisper moves an auto-language setup to the pinned primary
    /// language (the menu/pill/Settings all reflect the pin immediately).
    static func setASREngine(_ engine: String) {
        asrEngine = engine
        if engine == "whisper", autoLanguage {
            autoLanguage = false
        }
    }
    /// The dictation hotkey. JSON-encoded HotkeySpec; absent = Right Option default.
    /// The getter re-validates, so a corrupt/hand-edited value can't brick the
    /// hotkey — it falls back to the Right Option default.
    static var hotkey: HotkeySpec {
        get {
            guard let data = UserDefaults.standard.data(forKey: "hotkeySpec"),
                  let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data),
                  spec.validationError == nil
            else { return .rightOption }
            return spec
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "hotkeySpec")
            }
        }
    }
    /// One source of truth for every "Hold <hotkey> …" string in the UI.
    static var hotkeyDisplay: String { hotkey.displayString }
    /// Optional second hotkey that arms hands-free for the next dictation. nil =
    /// unset (hands-free is still reachable from the menu). The getter rejects a
    /// spec that is invalid OR duplicates the dictation hotkey, so a stale value
    /// can never create an ambiguous double-monitor.
    static var handsFreeHotkey: HotkeySpec? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "handsFreeHotkeySpec"),
                  let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data),
                  spec.validationError(against: hotkey) == nil
            else { return nil }
            return spec
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "handsFreeHotkeySpec")
            } else {
                UserDefaults.standard.removeObject(forKey: "handsFreeHotkeySpec")
            }
        }
    }
    /// Master switch: when true, no dictation text is persisted anywhere.
    static var historyPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "historyPaused") }
        set { UserDefaults.standard.set(newValue, forKey: "historyPaused") }
    }
    /// Apps (bundle id or name, case-insensitive) whose dictations are never persisted.
    static var excludedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "excludedApps") }
    }
    /// ASR language pin. Read per transcribe call, so changes apply even to
    /// the next partial pass mid-recording.
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }
    /// Second language for the pill's one-click toggle.
    static var altLanguage: String {
        get { UserDefaults.standard.string(forKey: "altLanguage") ?? "bg" }
        set { UserDefaults.standard.set(newValue, forKey: "altLanguage") }
    }
    /// Auto-detect the ASR language per utterance via confidence arbitration
    /// between `language` and `altLanguage`. When off, `language` is a hard pin.
    /// Default on — a bilingual user shouldn't have to keep a manual pin in sync.
    static var autoLanguage: Bool {
        get { UserDefaults.standard.object(forKey: "autoLanguage") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoLanguage") }
    }
    /// Writing-tone preset id (see Tones.swift).
    static var tone: String {
        get { UserDefaults.standard.string(forKey: "tone") ?? "default" }
        set { UserDefaults.standard.set(newValue, forKey: "tone") }
    }
    /// "Speak one language, type another": when set to a language code, dictations
    /// in a different language are translated into it before paste. nil = off.
    static var translateTo: String? {
        get {
            let v = UserDefaults.standard.string(forKey: "translateTo")
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "translateTo") }
    }
    /// Americanize spelling/vocabulary/idioms. Composes with any tone.
    static var usEnglish: Bool {
        get { UserDefaults.standard.bool(forKey: "usEnglish") }
        set { UserDefaults.standard.set(newValue, forKey: "usEnglish") }
    }
    /// Read text around the caret (AX) so cleanup fits insertions seamlessly.
    static var contextAware: Bool {
        get { UserDefaults.standard.object(forKey: "contextAware") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "contextAware") }
    }
    static var ollamaModel: String {
        // gemma4 8B: benchmarked 2026-07-05 — passes all cleanup traps (incl. verbatim
        // injection transcription, which 4b and 12b fumbled) at ~0.9s warm vs 1.8s for 12b.
        get { UserDefaults.standard.string(forKey: "ollamaModel") ?? "gemma4:latest" }
        set { UserDefaults.standard.set(newValue, forKey: "ollamaModel") }
    }
}
