# Ollama Health Indicator + Honest Degradation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The cleanup engine's health (Ollama running? model pulled? warm?) is always visible in the menu bar and Hub Settings, and when cleanup fails the pill says so honestly instead of showing a green success check over an unpolished paste.

**Architecture:** A new `OllamaHealth` ObservableObject singleton probes `localhost:11434/api/tags` and `/api/ps` with a 2-second timeout and publishes an `OllamaStatus` enum. The menu, the Hub Settings pane, and a new pill "degraded" state all read it. The dictation pipeline reports failures into it. Pure model-name matching logic goes in `FlowCloneCore` so it's covered by `FlowCloneChecks`.

**Tech Stack:** Swift 6.4 (CommandLineTools only), SwiftUI (no property-wrapper macros), AppKit menus, URLSession.

**Why this is rank 1:** Today `DictationController.endRecording`'s catch block around `ollama.cleanup` falls back to injecting the raw transcript **and then shows `pill?.showSuccess()`** — the user gets filler-ridden text with a green checkmark and no explanation. This violates PRODUCT.md principle #4 ("Status is never a mystery") on the most common failure path a stranger will hit (Ollama not running / model not pulled).

## Global Constraints (apply to every task)

- **Toolchain:** CommandLineTools-only. SwiftUI property-wrapper **macros do not compile**: never use `@State`, `@StateObject`, `@AppStorage`, `@Environment`, `@FocusState`. Use `final class X: ObservableObject` + `@Published`, `@ObservedObject`, and manual `Binding(get:set:)`. `HubModel` in `HubView.swift` is the reference pattern.
- **Tests:** XCTest and Swift Testing are unavailable. Automated checks live in `FlowClone/Sources/FlowCloneChecks/main.swift` (plain `check(condition, name)` runner). Run with `cd FlowClone && swift run FlowCloneChecks`. **FlowCloneChecks can only import FlowCloneCore** — any logic you want checked must be added under `FlowClone/Sources/FlowCloneCore/` (Foundation-only; no AppKit/SwiftUI there).
- **Build gate:** `cd "/Users/todortopalov/Documents/wispr flow clone/FlowClone" && swift build` must end `Build complete!`. Pre-existing warnings (Sendable in DictationController, `ld` search-path, `CGWindowListCreateImage` deprecation) are expected — do NOT try to fix them.
- **Defaults domains:** the debug binary `.build/debug/FlowClone` reads defaults domain `FlowClone`; the installed app reads `com.todor.flowclone`. Write test defaults into the domain of the binary you are actually running.
- **Animations:** any new animation must use `MotionPreferences.shared.anim(...)` for `.animation(_:value:)` or the global `flowAnimate(...)` instead of `withAnimation` (see `MotionPreferences.swift`). Never `@Environment(\.accessibilityReduceMotion)`.
- **Hub UI quirks (macOS 27):** never `.frame(maxHeight: .infinity)` inside a `ScrollView`; never put a `TimelineView(.animation)` directly in a bare `VStack` detail pane (wrap it in a fixed-height `.scrollDisabled(true)` `ScrollView`). After ANY Hub-visible change, run `.build/debug/FlowClone --hub --snapshot-all <dir>` and READ the PNGs to confirm nothing blanked.
- **Pill:** the pill window is a nonactivating `NSPanel` — pill content must never require keyboard focus.
- Commit after each task.

---

### Task 1: Model-name matching in FlowCloneCore (+ checks)

Ollama's `/api/tags` returns names like `"gemma4:latest"`, `"gemma4:12b"`. The user's `Settings.ollamaModel` may be `"gemma4"` (which Ollama resolves to `gemma4:latest`) or an explicit `"gemma4:12b"`. Matching must mirror Ollama's resolution: a bare name matches only its `:latest` tag.

**Files:**
- Create: `FlowClone/Sources/FlowCloneCore/OllamaModelMatch.swift`
- Modify: `FlowClone/Sources/FlowCloneChecks/main.swift`

**Interfaces:**
- Produces: `OllamaModelMatch.isAvailable(setting: String, tags: [String]) -> Bool`

- [ ] **Step 1: Write the matcher**

```swift
import Foundation

/// Mirrors Ollama's model-name resolution for health checks.
/// A bare name ("gemma4") resolves to its ":latest" tag only —
/// "gemma4:12b" being pulled does NOT make bare "gemma4" available.
public enum OllamaModelMatch {
    public static func isAvailable(setting: String, tags: [String]) -> Bool {
        let s = setting.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        return tags.contains { tag in
            tag == s || (!s.contains(":") && tag == s + ":latest")
        }
    }
}
```

- [ ] **Step 2: Add checks** — append to `FlowCloneChecks/main.swift` before the final `print("\n\(passed) passed…")` line:

```swift
print("OllamaModelMatch")
check(OllamaModelMatch.isAvailable(setting: "gemma4:12b", tags: ["gemma4:12b", "gemma3:4b"]),
      "exact tag matches")
check(OllamaModelMatch.isAvailable(setting: "gemma4", tags: ["gemma4:latest"]),
      "bare name matches :latest")
check(!OllamaModelMatch.isAvailable(setting: "gemma4", tags: ["gemma4:12b"]),
      "bare name does NOT match other tags (Ollama would 404)")
check(!OllamaModelMatch.isAvailable(setting: "llama3", tags: ["gemma4:latest"]),
      "missing model")
check(!OllamaModelMatch.isAvailable(setting: "  ", tags: ["gemma4:latest"]),
      "blank setting is never available")
```

- [ ] **Step 3: Run** `cd FlowClone && swift run FlowCloneChecks` — expect all new checks ✅, exit 0.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "Add OllamaModelMatch to FlowCloneCore with checks"`

---

### Task 2: OllamaHealth singleton

**Files:**
- Create: `FlowClone/Sources/FlowClone/OllamaHealth.swift`

**Interfaces:**
- Produces: `OllamaHealth.shared`, `OllamaStatus`, `.check()`, `.checkIfStale(olderThan:)`, `.noteFailure()`, published `status`.
- Consumes: `OllamaModelMatch` (Task 1), `Settings.ollamaModel` (exists in `AppDelegate.swift`).

- [ ] **Step 1: Write the file**

```swift
import Foundation
import FlowCloneCore

/// Health of the local Ollama cleanup engine.
enum OllamaStatus: Equatable {
    case unknown
    /// Server unreachable on localhost:11434.
    case offline
    /// Server up but Settings.ollamaModel isn't pulled.
    case modelMissing(available: [String])
    /// Model available; `warm` = currently loaded in memory (/api/ps).
    case ready(warm: Bool)

    var menuTitle: String {
        switch self {
        case .unknown: "Ollama: checking…"
        case .offline: "Ollama: ❌ not running — click for help"
        case .modelMissing: "Ollama: ⚠️ model \"\(Settings.ollamaModel)\" not pulled"
        case .ready(true): "Ollama: ✅ \(Settings.ollamaModel) (warm)"
        case .ready(false): "Ollama: ✅ \(Settings.ollamaModel)"
        }
    }
}

/// Singleton probe. Deliberately uses its OWN URLSession with a 2s timeout:
/// OllamaClient's session is configured with timeoutIntervalForRequest = 120
/// (cold model loads) and would hang a health check for two minutes.
final class OllamaHealth: ObservableObject {
    static let shared = OllamaHealth()

    @Published private(set) var status: OllamaStatus = .unknown

    private var lastCheck = Date.distantPast
    private var checking = false
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config)
    }

    /// Cheap to call from periodic UI (menuWillOpen, Settings TimelineView):
    /// only actually probes when the cached status is older than `seconds`.
    func checkIfStale(olderThan seconds: TimeInterval = 5) {
        guard Date().timeIntervalSince(lastCheck) > seconds else { return }
        check()
    }

    func check() {
        guard !checking else { return }
        checking = true
        lastCheck = Date()
        Task { [session] in
            let new = await Self.probe(session: session, model: Settings.ollamaModel)
            await MainActor.run {
                self.checking = false
                if new != self.status { self.status = new }
            }
        }
    }

    /// Pipeline calls this when a cleanup request throws: reflect the outage
    /// immediately (don't wait for the next poll), then re-probe to refine
    /// (offline vs model-missing).
    func noteFailure() {
        DispatchQueue.main.async {
            self.status = .offline
            self.lastCheck = .distantPast
            self.check()
        }
    }

    private static func probe(session: URLSession, model: String) async -> OllamaStatus {
        struct ModelList: Decodable {
            struct M: Decodable { let name: String }
            let models: [M]
        }
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(ModelList.self, from: data)
        else { return .offline }

        let names = tags.models.map(\.name)
        guard OllamaModelMatch.isAvailable(setting: model, tags: names) else {
            return .modelMissing(available: names)
        }

        // Warm = the model shows up in /api/ps (currently resident).
        if let psURL = URL(string: "http://localhost:11434/api/ps"),
           let (psData, psResp) = try? await session.data(from: psURL),
           (psResp as? HTTPURLResponse)?.statusCode == 200,
           let ps = try? JSONDecoder().decode(ModelList.self, from: psData),
           OllamaModelMatch.isAvailable(setting: model, tags: ps.models.map(\.name)) {
            return .ready(warm: true)
        }
        return .ready(warm: false)
    }
}
```

- [ ] **Step 2: Build** — `swift build`, expect `Build complete!`.
- [ ] **Step 3: Commit** — `git commit -am "Add OllamaHealth status probe"`

**Edge cases handled here that a weaker model would miss:**
- The 2s timeout session (OllamaClient's 120s session would freeze the health UI).
- `/api/ps` shares the same JSON shape as `/api/tags` (`models[].name`) — one Decodable.
- `noteFailure` resets `lastCheck` so the follow-up `check()` isn't debounced away.
- Status writes happen on the main actor (it's `@Published`, observed by SwiftUI).

---

### Task 3: Honest pill state — `degraded`

**Files:**
- Modify: `FlowClone/Sources/FlowClone/PillView.swift`
- Modify: `FlowClone/Sources/FlowClone/PillController.swift`

- [ ] **Step 1:** In `PillView.swift`, extend the state enum. Find:

```swift
    enum PillState: Equatable {
        case recording
        case processing
        case success
        case error(String)
    }
```

Replace with:

```swift
    enum PillState: Equatable {
        case recording
        case processing
        case success
        /// Text WAS pasted, but a pipeline stage failed (e.g. Ollama cleanup
        /// unavailable) so it went in unpolished. Distinct from `error`
        /// (nothing pasted) and `success` (everything worked).
        case degraded(String)
        case error(String)
    }
```

- [ ] **Step 2:** In `PillView.swift`'s `content` switch, add a case directly after the `.success` case (before `case .error`):

```swift
        case .degraded(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
```

(Yellow checkmark: the paste DID happen — that's why it's not the warning triangle used by `.error`.)

- [ ] **Step 3:** In `PillController.swift`, add next to `showSuccess()`:

```swift
    func showDegraded(_ message: String) {
        onMain {
            flowAnimate(.easeOut(duration: 0.25)) { self.model.state = .degraded(message) }
            self.hideAfter(1.8)
        }
    }
```

Note: use `flowAnimate` (Reduce Motion-aware), NOT `withAnimation`. `hideAfter(1.8)` — longer than success's 0.7s because there's a message to read.

- [ ] **Step 4: Build.** Expect `Build complete!`.
- [ ] **Step 5: Commit.**

---

### Task 4: Pipeline reports honestly

**Files:**
- Modify: `FlowClone/Sources/FlowClone/DictationController.swift`

- [ ] **Step 1:** In `endRecording()`, find the cleanup block:

```swift
                } else {
                    do {
                        let t1 = Date()
                        let cleaned = try await ollama.cleanup(raw, app: frontApp,
                                                               context: insertionContext)
                        let llmMs = Int(Date().timeIntervalSince(t1) * 1000)
                        if !cleaned.isEmpty {
                            final = cleaned
                            print("✨ Cleaned (\(llmMs)ms): \(cleaned)")
                        }
                    } catch {
                        print("⚠️  Ollama cleanup failed (\(error)) — injecting raw transcript.")
                    }
                }
```

Replace with (adds a flag + health report):

```swift
                } else {
                    do {
                        let t1 = Date()
                        let cleaned = try await ollama.cleanup(raw, app: frontApp,
                                                               context: insertionContext)
                        let llmMs = Int(Date().timeIntervalSince(t1) * 1000)
                        if !cleaned.isEmpty {
                            final = cleaned
                            print("✨ Cleaned (\(llmMs)ms): \(cleaned)")
                        }
                    } catch {
                        print("⚠️  Ollama cleanup failed (\(error)) — injecting raw transcript.")
                        cleanupDegraded = true
                        OllamaHealth.shared.noteFailure()
                    }
                }
```

- [ ] **Step 2:** Declare the flag. In the same `Task { … }` closure, immediately after `do {` (before `let t0 = Date()`), add:

```swift
                var cleanupDegraded = false
```

**Critical:** the flag must be INSIDE the Task's `do` block, local per dictation. Do NOT make it an instance property (two overlapping dictations would cross-contaminate).

- [ ] **Step 3:** Change the success display. Find:

```swift
                if hadEditableTarget {
                    pill?.showSuccess()
                } else {
```

Replace with:

```swift
                if hadEditableTarget {
                    if cleanupDegraded {
                        pill?.showDegraded("pasted unpolished")
                    } else {
                        pill?.showSuccess()
                    }
                } else {
```

**Edge case a weaker model would miss:** the Verbatim tone, cleanup-disabled, and `<5 words` fast paths intentionally skip the LLM — those are NOT degraded and must keep showing plain success. The flag is only set inside the catch, so this falls out correctly — do not "improve" it by checking `Settings.cleanupEnabled` at display time.

- [ ] **Step 4:** Piggyback health on the existing keep-warm loop. In `start()`, find:

```swift
        // Keep the cleanup model resident in Ollama so it never cold-starts.
        Task { await ollama.keepWarm() }
```

Replace with:

```swift
        // Keep the cleanup model resident in Ollama so it never cold-starts.
        Task {
            await ollama.keepWarm()
            OllamaHealth.shared.check()
        }
```

And in the `keepWarmTimer` body, change `Task { await self.ollama.keepWarm() }` to:

```swift
            Task {
                await self.ollama.keepWarm()
                OllamaHealth.shared.check()
            }
```

- [ ] **Step 5: Build. Commit.**

---

### Task 5: Menu-bar status line

**Files:**
- Modify: `FlowClone/Sources/FlowClone/AppDelegate.swift`
- Modify: `FlowClone/Sources/FlowClone/HubWindowController.swift`

- [ ] **Step 1:** Add a stored menu item near the other status items (top of `AppDelegate`, alongside `axStatusItem` / `micStatusItem` declarations — find them with grep). Add:

```swift
    private let ollamaStatusItem = NSMenuItem(title: "Ollama: checking…",
                                              action: #selector(ollamaStatusClicked), keyEquivalent: "")
```

- [ ] **Step 2:** In `buildMenu()`, insert it right after `menu.addItem(micStatusItem)`:

```swift
        ollamaStatusItem.target = self
        menu.addItem(ollamaStatusItem)
```

- [ ] **Step 3:** In `menuWillOpen(_:)` (it already refreshes ax/mic status), add:

```swift
        OllamaHealth.shared.checkIfStale(olderThan: 5)
        ollamaStatusItem.title = OllamaHealth.shared.status.menuTitle
```

Note `menuWillOpen` fires before the probe returns — the title shows the *cached* status, refreshed for next open. That's fine; the Settings pane (Task 6) is the live view.

- [ ] **Step 4:** Add the click handler in `AppDelegate`:

```swift
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
            hubController.show(page: .settings)
        default:
            hubController.show(page: .settings)
        }
    }
```

- [ ] **Step 5:** Add page-targeted opening to `HubWindowController.swift`. The `model` property is private; add this method to the class:

```swift
    /// Open the Hub directly on a specific page (used by menu shortcuts).
    func show(page: HubModel.Page) {
        model.page = page
        UserDefaults.standard.set(page.rawValue, forKey: "hubPage")
        show()
    }
```

- [ ] **Step 6: Build. Commit.**

---

### Task 6: Live health row in Hub Settings

**Files:**
- Modify: `FlowClone/Sources/FlowClone/DictionarySettingsViews.swift`

- [ ] **Step 1:** In `SettingsPane`, add an observer property (macro-free pattern):

```swift
struct SettingsPane: View {
    @ObservedObject var model: HubModel
    @ObservedObject private var ollamaHealth = OllamaHealth.shared
```

- [ ] **Step 2:** In the `Section("AI Cleanup")`, add a health row as the FIRST element (before the cleanup toggle). The Permissions section's `TimelineView(.periodic(from: .now, by: 2))` is the established polling pattern — reuse it:

```swift
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
```

**Why this shape:** the `TimelineView` re-renders every 2s; `checkIfStale(olderThan: 5)` inside means at most one real network probe per 5s while Settings is visible — the TimelineView does NOT probe on every tick. (`onAppear` fires per TimelineView content identity change; combined with the stale-guard this is safe. If in doubt, call `checkIfStale` unconditionally in the builder body — the 5s guard makes it cheap.)

This TimelineView is inside a `Form` Section, matching the existing Permissions section exactly — this placement is proven safe on macOS 27 (do NOT move it into a bare VStack detail pane).

- [ ] **Step 3: Build**, then snapshot: `defaults write FlowClone hasOnboarded -bool true; .build/debug/FlowClone --hub --snapshot-all /tmp/health-snap` (kill after ~20s), READ `/tmp/health-snap/settings.png`, confirm the row renders and the window isn't blank. Then `defaults delete FlowClone hasOnboarded`.
- [ ] **Step 4: Commit.**

---

### Task 7: End-to-end acceptance

Run these on the dev machine. Ollama.app normally runs as a menu-bar app; quit/start it via its own menu icon (or `osascript -e 'quit app "Ollama"'` / `open -a Ollama`).

- [ ] **A. Checks & build:** `cd FlowClone && swift build && swift run FlowCloneChecks` → `Build complete!`, all checks pass, exit 0.
- [ ] **B. Healthy path:** with Ollama running, install (`./scripts/build-app.sh`), open the menu → shows `Ollama: ✅ …`. Dictate ≥5 words → normal green success.
- [ ] **C. Offline path:** quit Ollama. Open menu (twice — first open triggers the probe, second shows result) → `Ollama: ❌ not running`. Dictate ≥5 words → **text still pastes** (raw) and the pill shows the yellow-check `pasted unpolished`, NOT green success. Hub Settings shows the offline row with the Get Ollama button.
- [ ] **D. Model-missing path:** with Ollama running, set a bogus model: `defaults write com.todor.flowclone ollamaModel bogus-model` and relaunch the app. Settings row shows `Model "bogus-model" isn't pulled` with the copy button; menu shows the ⚠️ line. Dictation still pastes raw with `pasted unpolished`. Restore: `defaults delete com.todor.flowclone ollamaModel`.
- [ ] **E. Recovery:** restart Ollama → within one keep-warm cycle (or on next menu open) status returns to ✅ and dictation shows green success again.
- [ ] **F. Fast paths unaffected:** with Ollama STOPPED, dictate a short (<5 words) utterance → plain green success (fast path never touched Ollama; it is not "degraded").

**Definition of done:** all of A–F pass; no new build warnings beyond the pre-existing ones listed in Global Constraints.
