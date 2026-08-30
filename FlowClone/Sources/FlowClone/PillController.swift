import AppKit
import SwiftUI

/// Owns the floating panel and pill state; bridges DictationController events
/// to the UI. All entry points are safe to call from any thread.
/// `@unchecked Sendable`: every mutation funnels through `onMain`.
final class PillController: @unchecked Sendable {
    private let model = PillModel()
    private let panel: FloatingPanel
    private var elapsedTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?

    private static let panelSize = NSSize(width: 300, height: 64)
    private static let positionKey = "pillOrigin"

    init() {
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        model.language = Settings.language
        model.onLanguageToggle = { [weak self] in
            guard let self else { return }
            Settings.autoLanguage = false // tapping the badge is a manual override
            let current = Settings.language
            Settings.language = Settings.altLanguage
            Settings.altLanguage = current
            flowAnimate(.easeOut(duration: 0.15)) {
                self.model.autoLanguage = false
                self.model.language = Settings.language
            }
        }
        let root = ZStack { Color.clear; PillView(model: model) }
            .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        panel.contentView = NSHostingView(rootView: root)

        // Persist a user-dragged position.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            let o = self.panel.frame.origin
            UserDefaults.standard.set([o.x, o.y], forKey: Self.positionKey)
        }
    }

    // MARK: - Events (thread-safe)

    func showRecording(locked: Bool = false) {
        onMain {
            self.cancelPendingHide()
            self.model.state = .recording
            self.model.locked = locked
            self.model.elapsed = 0
            self.model.levels = Array(repeating: 0, count: PillView.barCount)
            self.model.liveText = ""
            self.model.language = Settings.language
            self.model.autoLanguage = Settings.autoLanguage
            self.startElapsedTimer()
            self.present()
        }
    }

    /// Updates the rolling live transcript: the partial transcript while
    /// recording, and the streaming cleaned text while processing (the Phase-1
    /// preview — it used to be dropped because only `.recording` accepted it).
    func updateLiveText(_ text: String) {
        onMain {
            guard self.model.state == .recording || self.model.state == .processing else { return }
            flowAnimate(.easeOut(duration: 0.2)) { self.model.liveText = text }
        }
    }

    func setLocked() {
        onMain { flowAnimate(.easeOut(duration: 0.25)) { self.model.locked = true } }
    }

    /// Reflect the detected/selected ASR language on the badge (thread-safe).
    func setLanguage(_ code: String) {
        onMain { flowAnimate(.easeOut(duration: 0.15)) { self.model.language = code } }
    }

    /// Reflect whether auto-detect is active (drives the badge's accent dot).
    func setAuto(_ auto: Bool) {
        onMain { self.model.autoLanguage = auto }
    }

    func updateLevel(_ level: Float) {
        onMain {
            guard self.model.state == .recording else { return }
            self.model.levels.removeFirst()
            self.model.levels.append(level)
        }
    }

    func showProcessing() {
        onMain {
            self.elapsedTimer?.invalidate()
            // Clear the recording partial: "polishing…" shows until (and unless)
            // the streaming preview delivers cleaned text.
            self.model.liveText = ""
            flowAnimate(.easeOut(duration: 0.25)) { self.model.state = .processing }
        }
    }

    func showSuccess() {
        onMain {
            self.model.successAt = Date() // arms the one-shot glint
            flowAnimate(.spring(response: 0.3, dampingFraction: 0.6)) {
                self.model.state = .success
            }
            self.hideAfter(0.7)
        }
    }

    /// Text pasted, but unpolished (e.g. Ollama cleanup unavailable). Yellow
    /// check + message; held longer than success so the message is readable.
    func showDegraded(_ message: String) {
        onMain {
            flowAnimate(.easeOut(duration: 0.25)) { self.model.state = .degraded(message) }
            self.hideAfter(1.8)
        }
    }

    /// A voice command changed a setting (e.g. tone switch): indigo confirmation,
    /// no paste implied.
    func showInfo(_ message: String) {
        onMain {
            self.elapsedTimer?.invalidate()
            flowAnimate(.easeOut(duration: 0.25)) { self.model.state = .info(message) }
            self.present()
            self.hideAfter(1.6)
        }
    }

    func showError(_ message: String) {
        onMain {
            self.elapsedTimer?.invalidate()
            flowAnimate(.easeOut(duration: 0.25)) { self.model.state = .error(message) }
            self.present()
            self.hideAfter(2.5)
        }
    }

    func hide() {
        onMain {
            self.elapsedTimer?.invalidate()
            self.cancelPendingHide()
            self.dismiss()
        }
    }

    func resetPosition() {
        onMain {
            UserDefaults.standard.removeObject(forKey: Self.positionKey)
            if self.panel.isVisible { self.panel.setFrameOrigin(self.defaultOrigin()) }
        }
    }

    // MARK: - Debug snapshots

    /// Renders each pill state to a PNG. Driven by `--pill-snapshot <dir>`.
    func snapshotStates(to dir: String, then completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Plausible waveform + clock so the recording state looks live.
        model.levels = (0..<PillView.barCount).map { Float(0.25 + 0.55 * abs(sin(Double($0) * 0.7))) }
        model.elapsed = 12
        model.language = "en"
        model.entered = true // settled — skip the entrance travel for the capture
        panel.setFrameOrigin(defaultOrigin())
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        var remaining: [(String, PillModel.PillState)] = [
            ("1-recording", .recording),
            ("2-processing", .processing),
            ("3-success", .success),
            ("4-degraded", .degraded("pasted unpolished")),
            ("5-error", .error("no text field focused")),
            ("6-info", .info("Formal tone")),
        ]
        func next() {
            guard !remaining.isEmpty else { completion(); return }
            let (name, state) = remaining.removeFirst()
            model.state = state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.snapshotPanel(to: "\(dir)/\(name).png")
                next()
            }
        }
        next()
    }

    private func snapshotPanel(to path: String) {
        let windowID = CGWindowID(panel.windowNumber)
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
        ) else { print("pill snapshot: capture failed"); return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("pill snapshot written: \(path)")
    }

    // MARK: - Internals (main thread)

    private func present() {
        guard !panel.isVisible else { return }
        model.entered = false
        panel.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        panel.alphaValue = 1 // SwiftUI handles the fade via `entered`
        panel.orderFrontRegardless() // shows without activating us
        // Next tick so the pre-entrance frame renders first, then spring in.
        DispatchQueue.main.async { self.model.entered = true }
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        // Reduce Motion: no exit fade — just take the panel away cleanly.
        if MotionPreferences.shared.reduceMotion {
            model.entered = false
            panel.orderOut(nil)
            model.state = .idle // stop any TimelineView in the hidden panel
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { model.entered = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            // Only hide if nothing re-presented meanwhile.
            if !self.model.entered {
                self.panel.orderOut(nil)
                self.model.state = .idle // stop any TimelineView in the hidden panel
            }
        }
    }

    private func hideAfter(_ delay: TimeInterval) {
        cancelPendingHide()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.elapsed += 1
        }
    }

    /// Bottom-center of the main screen, 24pt above the Dock.
    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let f = screen.visibleFrame
        return NSPoint(x: f.midX - Self.panelSize.width / 2, y: f.minY + 24)
    }

    private func savedOrigin() -> NSPoint? {
        guard let arr = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double],
              arr.count == 2 else { return nil }
        let point = NSPoint(x: arr[0], y: arr[1])
        // Only honor it if still on some screen (displays change).
        let rect = NSRect(origin: point, size: Self.panelSize)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return point
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
