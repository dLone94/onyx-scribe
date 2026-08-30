import Foundation
import AppKit
import CoreText

/// Registers the bundled display font (Fraunces) with the process font manager
/// so `FlowType.fraunces` can resolve it. Must run before any view renders.
///
/// Fonts ship as an SPM resource (`Resources/Fonts`), so `Bundle.module` finds
/// them in both the debug binary (`.build/debug/`) and the packaged `.app`
/// (build-app.sh copies the resource bundle into `Contents/Resources`).
enum FontLoader {
    private static var didRegister = false

    static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true

        let urls = ttfURLs()
        guard !urls.isEmpty else {
            print("⚠️  FontLoader: no bundled .ttf found — display serif will fall back to system.")
            return
        }
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let desc = (error?.takeUnretainedValue()).map { CFErrorCopyDescription($0) as String } ?? "unknown"
                print("⚠️  FontLoader: failed to register \(url.lastPathComponent): \(desc)")
            }
        }
        #if DEBUG
        let fraunces = NSFontManager.shared.availableFontFamilies
            .filter { $0.localizedCaseInsensitiveContains("fraunces") }
        print("🔤 FontLoader: registered \(urls.count) font file(s); Fraunces families = \(fraunces)")
        #endif
    }

    /// Every `.ttf` in the module bundle, whether SPM flattened it to the root or
    /// preserved the `Fonts` subdirectory.
    private static func ttfURLs() -> [URL] {
        var found: [URL] = []
        for sub in [nil, "Fonts"] as [String?] {
            if let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: sub) {
                found.append(contentsOf: urls)
            }
        }
        // Dedupe by path in case both lookups hit the same file.
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }
}
