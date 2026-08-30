# History Privacy: Per-App Exclusion, Pause, Clear — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user control over what dictation *text* is persisted: a per-app exclusion list (dictations into those apps are never written to history or the scratchpad), a global "pause history" toggle, and a confirmed "clear all history" action — enforced at capture time, not display time.

**Architecture:** A pure `PrivacyFilter.shouldRecord(...)` in `FlowCloneCore` (checked by `FlowCloneChecks`) decides; `DictationController` captures the frontmost app's *bundle identifier* alongside the localized name at recording start and consults the filter before any persistence. Settings UI mirrors the existing profiles-editor pattern. One onboarding copy fix keeps the trust claims honest.

**Tech Stack:** Swift 6.4 (CommandLineTools only), SwiftUI (no property-wrapper macros), AppKit (NSAlert).

**Why this is rank 4:** The onboarding Welcome screen literally promises "Nothing stored" — while `history.json` stores the full text of every dictation, including anything spoken into password managers, journals, or private chats. Secure *context reading* is already skipped (`ContextReader` refuses `AXSecureTextField`), but the dictated text itself is still persisted. For a "ship to others" product (PRODUCT.md), that's a trust gap with a factual copy contradiction. **This plan touches the same Settings/History surfaces as PLAN-history-raw-cleaned — do it right after that one while the files are fresh.**

## Global Constraints (apply to every task)

- **Toolchain:** CommandLineTools-only. SwiftUI property-wrapper **macros do not compile**: never use `@State`, `@StateObject`, `@AppStorage`, `@Environment`, `@FocusState`. Use `final class X: ObservableObject` + `@Published`, `@ObservedObject`, and manual `Binding(get:set:)`. `HubModel` in `HubView.swift` is the reference pattern.
- **Tests:** XCTest and Swift Testing are unavailable. Automated checks live in `FlowClone/Sources/FlowCloneChecks/main.swift`. Run with `cd FlowClone && swift run FlowCloneChecks`. **FlowCloneChecks can only import FlowCloneCore** — testable logic goes in `FlowClone/Sources/FlowCloneCore/` (Foundation-only).
- **Build gate:** `cd "/Users/todortopalov/Documents/wispr flow clone/FlowClone" && swift build` → `Build complete!`. Pre-existing warnings are expected — do NOT fix.
- **Defaults domains:** debug binary reads domain `FlowClone`; installed app reads `com.todor.flowclone`.
- **Animations:** `MotionPreferences.shared.anim(...)` / `flowAnimate(...)` only.
- **Hub UI quirks (macOS 27):** no `.frame(maxHeight: .infinity)` inside ScrollView; no `TimelineView(.animation)` in a bare VStack detail pane. After ANY Hub-visible change run `.build/debug/FlowClone --hub --snapshot-all <dir>` and READ the PNGs.
- **Onboarding-visible changes:** verify with `defaults write FlowClone hasOnboarded -bool true && .build/debug/FlowClone --onboard --snapshot-onboard <dir>`, then delete that default.
- Commit after each task.

---

### Task 1: `PrivacyFilter` in FlowCloneCore (+ checks)

**Files:**
- Create: `FlowClone/Sources/FlowCloneCore/PrivacyFilter.swift`
- Modify: `FlowClone/Sources/FlowCloneChecks/main.swift`

**Interfaces:**
- Produces: `PrivacyFilter.shouldRecord(bundleID: String?, appName: String?, excluded: [String], paused: Bool) -> Bool`

- [ ] **Step 1: Write it**

```swift
import Foundation

/// Decides whether a dictation's TEXT may be persisted (history, scratchpad).
/// Matching is case-insensitive against either the bundle identifier
/// ("com.apple.TextEdit") or the localized app name ("TextEdit") so users can
/// type whichever they know. Never affects pasting — only persistence.
public enum PrivacyFilter {
    public static func shouldRecord(bundleID: String?, appName: String?,
                                    excluded: [String], paused: Bool) -> Bool {
        if paused { return false }
        guard !excluded.isEmpty else { return true }
        let ex = Set(excluded.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if let b = bundleID?.lowercased(), ex.contains(b) { return false }
        if let n = appName?.lowercased(), ex.contains(n) { return false }
        return true
    }
}
```

- [ ] **Step 2: Checks** — append before the final tally:

```swift
print("PrivacyFilter")
check(!PrivacyFilter.shouldRecord(bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                  excluded: [], paused: true),
      "paused blocks everything")
check(PrivacyFilter.shouldRecord(bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                 excluded: [], paused: false),
      "no exclusions records")
check(!PrivacyFilter.shouldRecord(bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                  excluded: ["COM.APPLE.TEXTEDIT"], paused: false),
      "bundle id matches case-insensitively")
check(!PrivacyFilter.shouldRecord(bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                  excluded: ["textedit"], paused: false),
      "app name matches case-insensitively")
check(!PrivacyFilter.shouldRecord(bundleID: nil, appName: "Bitwarden",
                                  excluded: [" bitwarden "], paused: false),
      "nil bundle id still matches by name; exclusion whitespace trimmed")
check(PrivacyFilter.shouldRecord(bundleID: nil, appName: nil,
                                 excluded: ["textedit"], paused: false),
      "unknown app with exclusions still records (fail open — don't lose text on identity gaps)")
```

- [ ] **Step 3:** `swift run FlowCloneChecks` → all pass. **Commit.**

**Design note (deliberate):** unknown app identity fails OPEN (records). Failing closed would silently drop text whenever macOS can't identify the frontmost app — losing user words is worse than a privacy miss for an app the user never listed. Do not "harden" this.

---

### Task 2: Settings storage + capture-time enforcement

**Files:**
- Modify: `FlowClone/Sources/FlowClone/AppDelegate.swift` (Settings enum)
- Modify: `FlowClone/Sources/FlowClone/DictationController.swift`
- Modify: `FlowClone/Sources/FlowClone/Stores.swift` (clearAll)

- [ ] **Step 1:** Add to the `Settings` enum:

```swift
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
```

- [ ] **Step 2:** `DictationController` — capture the bundle id at the same moment the name is captured. Add the property next to `private var frontApp: String?`:

```swift
    private var frontBundleID: String?
```

In `beginRecording()`, find `frontApp = NSWorkspace.shared.frontmostApplication?.localizedName` and add directly below:

```swift
            frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
```

**Why at beginRecording:** that's when the user chose their target; by injection time, focus is (still) there, but a *failed/slow* pipeline could see a different frontmost app — the identity captured at start is the honest one, and it's the same moment `frontApp` is already captured.

- [ ] **Step 3:** Enforce in `endRecording()`. Add ONE decision variable right where the Task closure starts using persistence — compute it before the `HistoryStore.shared.add(` call:

```swift
                let mayPersist = PrivacyFilter.shouldRecord(
                    bundleID: frontBundleID, appName: frontApp,
                    excluded: Settings.excludedApps, paused: Settings.historyPaused)
```

Then wrap the history add:

```swift
                if mayPersist {
                    HistoryStore.shared.add(
                        text: textToInject, app: frontApp,
                        engine: engine is WhisperEngine ? "Whisper" : "Parakeet",
                        durationMs: totalMs, audioSec: duration, tone: Tone.current.id)
                }
```

(If PLAN-history-raw-cleaned landed first, keep its `raw:` argument — just wrap the call.)

`StatsStore.shared.record(...)` stays UNCONDITIONAL — it persists aggregate numbers (word count, latency), no text. Document with a comment:

```swift
                // Stats are aggregate-only (counts, latency — no text): always allowed.
```

- [ ] **Step 4:** The Scratchpad leak. In the same function, the no-editable-target branch appends the full text to `ScratchpadStore` (which writes `scratchpad.txt` to disk). Find:

```swift
                } else {
                    // No editable field was focused — the paste likely went
                    // nowhere. Keep the words safe in the Scratchpad.
                    ScratchpadStore.shared.append(textToInject)
                    pill?.showError("saved to Scratchpad")
                    print("🗒️ No editable target — saved to Scratchpad.")
                }
```

Replace with:

```swift
                } else if mayPersist {
                    // No editable field was focused — the paste likely went
                    // nowhere. Keep the words safe in the Scratchpad.
                    ScratchpadStore.shared.append(textToInject)
                    pill?.showError("saved to Scratchpad")
                    print("🗒️ No editable target — saved to Scratchpad.")
                } else {
                    // Excluded app / paused: honoring privacy means NOT
                    // writing the text anywhere — tell the user it's gone.
                    pill?.showError("no text field — not saved (private)")
                    print("🔒 No editable target and persistence is off — text discarded.")
                }
```

**This is the edge a weaker model misses:** filtering history but leaving the scratchpad safety-net writing excluded text to disk would defeat the whole feature.

**Also deliberately unchanged:** `lastInjected` / `lastInjectedApp` are still set for excluded apps — they're in-memory only and power "scratch that"; privacy governs *disk*, not the live session.

- [ ] **Step 5:** `HistoryStore.clearAll()` in Stores.swift:

```swift
    func clearAll() {
        DispatchQueue.main.async {
            self.entries = []
            self.save()
        }
    }
```

- [ ] **Step 6: Build. Commit.**

---

### Task 3: Privacy section in Hub Settings

**Files:**
- Modify: `FlowClone/Sources/FlowClone/HubView.swift` (HubModel)
- Modify: `FlowClone/Sources/FlowClone/DictionarySettingsViews.swift` (SettingsPane)

- [ ] **Step 1:** `HubModel` gains the input field state (the profiles editor's `newProfileApp` is the pattern):

```swift
    @Published var newExclusion = ""
```

- [ ] **Step 2:** Add a `Section("Privacy")` to `SettingsPane`'s `Form`, after the "AI Cleanup" section:

```swift
            Section("Privacy") {
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(HistoryStore.shared.entries.count) dictations stored")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Delete all \(HistoryStore.shared.entries.count) dictations?"
                        alert.informativeText = "This removes every entry from History and the Recent Dictations menu. It can't be undone."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        alert.alertStyle = .warning
                        if alert.runModal() == .alertFirstButtonReturn {
                            HistoryStore.shared.clearAll()
                            model.objectWillChange.send()
                        }
                    }
                    .disabled(HistoryStore.shared.entries.isEmpty)
                }
            }
```

Notes: `Settings.excludedApps.removeAll`/`append` work because the computed property's setter writes the whole array back (`Settings.excludedApps = modified` happens via the mutating accessor). If the compiler rejects in-place mutation of the computed property, use the explicit form: `var list = Settings.excludedApps; list.append(name); Settings.excludedApps = list` — same for removeAll.

- [ ] **Step 3:** Paused banner on the History page. In `HistoryView` (HubView.swift), at the top of the non-empty branch's `VStack` (and above `EmptyHistoryHint` in the empty branch if simple), add:

```swift
                        if Settings.historyPaused {
                            HStack(spacing: 6) {
                                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                                Text("History is paused — new dictations aren't being saved.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(.quaternary.opacity(0.4)))
                        }
```

- [ ] **Step 4: Build**, snapshot (`--hub --snapshot-all`), READ `settings.png` + `history.png`. **Commit.**

---

### Task 4: Honest onboarding copy

**Files:**
- Modify: `FlowClone/Sources/FlowClone/OnboardingView.swift`

The Welcome trust row currently claims `"Nothing stored"` — false for text (history). Make it precise:

- [ ] **Step 1:** Find `trustItem("lock.fill", "Nothing stored")` and replace with:

```swift
            trustItem("lock.fill", "Audio never stored")
```

(Audio truly is discarded after transcription; text persistence is now user-governed via this plan's controls.)

- [ ] **Step 2:** Snapshot onboarding (`defaults write FlowClone hasOnboarded -bool true; .build/debug/FlowClone --onboard --snapshot-onboard /tmp/priv-onboard`, kill after ~16s, delete the default). READ `1-welcome.png` — label fits on one line in the 92pt-wide trust item; if it wraps ugly, use `"Audio discarded"`.
- [ ] **Step 3: Build. Commit.**

---

### Task 5: End-to-end acceptance

- [ ] **A.** `swift build && swift run FlowCloneChecks` → clean; PrivacyFilter checks pass.
- [ ] **B. Exclusion:** install; add `TextEdit` to the exclusion list. Note the history count. Dictate into TextEdit → **text pastes normally**, pill success as usual, but History count is unchanged and the Recent Dictations menu doesn't show it. Dictate into Notes (not excluded) → recorded normally.
- [ ] **C. Bundle-id form:** replace the exclusion with `com.apple.TextEdit` → same behavior (bundle-id matching).
- [ ] **D. Pause:** toggle Pause on → dictations into ANY app paste but aren't recorded; History page shows the paused banner. Toggle off → recording resumes.
- [ ] **E. Scratchpad leak closed:** with TextEdit excluded, focus the desktop (no text field), dictate → pill shows "no text field — not saved (private)" and `~/Library/Application Support/FlowClone/scratchpad.txt` does NOT gain the text. Repeat with a non-excluded no-target dictation → scratchpad DOES receive it (safety net intact).
- [ ] **F. Voice edit unaffected:** dictate into excluded TextEdit, then say "scratch that" → the pasted text is deleted (in-memory `lastInjected` chain still works for excluded apps).
- [ ] **G. Clear:** Clear History… → confirm dialog shows the right count; after Delete All, `cat ~/Library/"Application Support"/FlowClone/history.json` prints `[]` and the Hub History page shows the empty state.
- [ ] **H. Stats decision visible:** after B/D, Insights total-words still increased (aggregate stats are text-free by design — this is intended, not a bug).
- [ ] **I. Snapshots:** `--hub --snapshot-all` and `--onboard --snapshot-onboard` all render.

**Definition of done:** A–I pass.
