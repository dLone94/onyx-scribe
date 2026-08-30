import AppKit
import SwiftUI

/// Owns the Flow Hub window (created lazily, reused across opens).
final class HubWindowController {
    private var window: NSWindow?
    private let model = HubModel()

    init(reloadEngine: @escaping () -> Void, resetPillPosition: @escaping () -> Void,
         updateHotkey: @escaping () -> Void) {
        model.reloadEngine = reloadEngine
        model.resetPillPosition = resetPillPosition
        model.updateHotkey = updateHotkey
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Onyx Scribe"
            w.titleVisibility = .hidden // the custom sidebar carries the brandmark
            w.titlebarAppearsTransparent = true
            // The Hub commits to a dark, glowing identity — force dark appearance
            // so the native sidebar, toolbar and Forms render dark to match the
            // custom canvas, instead of a jarring light-chrome/dark-content split.
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            w.isReleasedWhenClosed = false
            // Pause ambient animation when occluded; on close, drop the SwiftUI
            // tree entirely — a closed Hub must cost zero CPU, not "probably
            // paused". Rebuilt on next show().
            AmbientGate.track(w)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                self?.window?.contentView = NSView()
            }
            window = w
        }
        if !(window?.contentView is NSHostingView<HubView>) {
            window?.contentView = NSHostingView(
                rootView: HubView(model: model, vocab: VocabStore(), profiles: ProfilesStore()))
            AmbientGate.shared.set(window!.windowNumber, visible: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open the Hub directly on a specific page (used by menu shortcuts).
    func show(page: HubModel.Page) {
        model.page = page
        UserDefaults.standard.set(page.rawValue, forKey: "hubPage")
        show()
    }

    /// Debug: walk every Hub page and snapshot each one to <dir>/<page>.png.
    func snapshotAll(to dir: String, then completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        var remaining = HubModel.Page.allCases
        func next() {
            guard !remaining.isEmpty else { completion(); return }
            let page = remaining.removeFirst()
            self.model.page = page
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                self.snapshot(to: "\(dir)/\(page.rawValue).png")
                next()
            }
        }
        next()
    }

    /// Debug: capture our own window's actual on-screen pixels (apps may
    /// capture their own windows without Screen Recording permission).
    func snapshot(to path: String) {
        guard let window else { print("snapshot: no window"); return }
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
        ) else {
            print("snapshot: CGWindowListCreateImage failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("snapshot written: \(path)")
    }
}
