# Configurable Dictation Hotkey — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user change the dictation hotkey (default stays Right ⌥) via a press-to-capture recorder in Hub Settings — supporting both modifier-only keys (like today's Right ⌥) and regular keys with modifiers (⌃⇧D, F5) — while preserving hold-to-talk, double-tap-to-lock, and Esc-to-cancel semantics.

**Architecture:** A `HotkeySpec` value type in `FlowCloneCore` (Foundation-only, so `FlowCloneChecks` can test validation/display/codability). `HotkeyManager` gains a second detection path: today it only watches `.flagsChanged` for keyCode 61; it will dispatch on `spec.kind` — `.modifierOnly` keeps the flags path (generalized to any modifier keyCode), `.key` uses `.keyDown`/`.keyUp`. A `HotkeyRecorder` helper captures the next chord in Settings. All the hardcoded "Right ⌥" copy (5 places) reroutes through one `Settings.hotkeyDisplay`.

**Tech Stack:** Swift 6.4 (CommandLineTools only), AppKit NSEvent monitors, SwiftUI Settings pane (no property-wrapper macros).

**Why this is rank 2:** keyCode 61 is hardcoded in `HotkeyManager.swift`. "Ship to others" (PRODUCT.md) breaks immediately: many keyboards have no Right Option; Bulgarian/international layouts use Option for character input; some users need Option for app shortcuts. Also the gesture string "Right ⌥" is baked into **five** separate places that would all silently lie after a hotkey change.

## Global Constraints (apply to every task)

- **Toolchain:** CommandLineTools-only. SwiftUI property-wrapper **macros do not compile**: never use `@State`, `@StateObject`, `@AppStorage`, `@Environment`, `@FocusState`. Use `final class X: ObservableObject` + `@Published`, `@ObservedObject`, and manual `Binding(get:set:)`. `HubModel` in `HubView.swift` is the reference pattern.
- **Tests:** XCTest and Swift Testing are unavailable. Automated checks live in `FlowClone/Sources/FlowCloneChecks/main.swift` (plain `check(condition, name)` runner). Run with `cd FlowClone && swift run FlowCloneChecks`. **FlowCloneChecks can only import FlowCloneCore** — testable logic must go in `FlowClone/Sources/FlowCloneCore/` (Foundation-only; no AppKit — so `HotkeySpec` stores raw `UInt` modifier masks, not `NSEvent.ModifierFlags`).
- **Build gate:** `cd "/Users/todortopalov/Documents/wispr flow clone/FlowClone" && swift build` must end `Build complete!`. Pre-existing warnings (Sendable, ld search-path, CGWindowListCreateImage) are expected — do NOT fix them.
- **Defaults domains:** debug binary `.build/debug/FlowClone` reads domain `FlowClone`; installed app reads `com.todor.flowclone`.
- **Animations:** use `MotionPreferences.shared.anim(...)` / `flowAnimate(...)`, never raw `withAnimation`.
- **Hub UI quirks (macOS 27):** no `.frame(maxHeight: .infinity)` inside ScrollView; no `TimelineView(.animation)` in a bare VStack detail pane. After ANY Hub-visible change run `.build/debug/FlowClone --hub --snapshot-all <dir>` and READ the PNGs.
- **Onboarding-visible changes:** verify with `defaults write FlowClone hasOnboarded -bool true && .build/debug/FlowClone --onboard --snapshot-onboard <dir>`, then `defaults delete FlowClone hasOnboarded`.
- Commit after each task.

---

### Task 1: `HotkeySpec` in FlowCloneCore (+ checks)

**Files:**
- Create: `FlowClone/Sources/FlowCloneCore/HotkeySpec.swift`
- Modify: `FlowClone/Sources/FlowCloneChecks/main.swift`

**Interfaces:**
- Produces: `HotkeySpec` (Codable, Equatable), `.rightOption` default, `displayString`, `validationError`, modifier raw-value constants.

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// A dictation hotkey. Two kinds:
/// - `.modifierOnly`: a single modifier key held alone (the classic Right ⌥).
///   Detected via flagsChanged; `modifiers` is 0.
/// - `.key`: a regular key, optionally with required modifiers (⌃⇧D, F5).
///   Detected via keyDown/keyUp.
///
/// Foundation-only on purpose: FlowCloneChecks can't import AppKit, so
/// modifier masks are stored as raw UInt matching NSEvent.ModifierFlags.
public struct HotkeySpec: Codable, Equatable {
    public enum Kind: String, Codable { case modifierOnly, key }

    public let kind: Kind
    public let keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue restricted to deviceIndependentFlagsMask.
    /// Always 0 for .modifierOnly.
    public let modifiers: UInt

    public init(kind: Kind, keyCode: UInt16, modifiers: UInt) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = kind == .modifierOnly ? 0 : modifiers
    }

    /// The shipping default.
    public static let rightOption = HotkeySpec(kind: .modifierOnly, keyCode: 61, modifiers: 0)

    // Raw values of NSEvent.ModifierFlags (AppKit), usable without AppKit.
    public static let commandMask: UInt = 1 << 20
    public static let optionMask: UInt = 1 << 19
    public static let controlMask: UInt = 1 << 18
    public static let shiftMask: UInt = 1 << 17

    /// keyCodes of the modifier keys themselves (for .modifierOnly capture).
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    /// Bare function keys that are allowed with no modifiers.
    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100,
                                                       101, 109, 103, 111, 105, 107, 113, 106]

    /// nil = valid; otherwise a user-facing reason the spec is rejected.
    public var validationError: String? {
        if keyCode == 53 { return "Esc cancels dictation and can't be the hotkey." }
        if keyCode == 63 { return "The fn/globe key is reserved by macOS." }
        switch kind {
        case .modifierOnly:
            guard Self.modifierKeyCodes.contains(keyCode) else {
                return "Not a modifier key."
            }
            if keyCode == 57 { return "Caps Lock can't be held — pick another key." }
            return nil
        case .key:
            if Self.modifierKeyCodes.contains(keyCode) { return "Not a regular key." }
            if modifiers == 0 && !Self.functionKeyCodes.contains(keyCode) {
                return "A bare letter/number would trigger while typing — add a modifier or use an F-key."
            }
            return nil
        }
    }

    public var displayString: String {
        var prefix = ""
        if modifiers & Self.controlMask != 0 { prefix += "⌃" }
        if modifiers & Self.optionMask != 0 { prefix += "⌥" }
        if modifiers & Self.shiftMask != 0 { prefix += "⇧" }
        if modifiers & Self.commandMask != 0 { prefix += "⌘" }
        return prefix + Self.keyName(keyCode)
    }

    public static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            // Modifier keys (for .modifierOnly display)
            54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 60: "Right ⇧",
            58: "Left ⌥", 61: "Right ⌥", 59: "Left ⌃", 62: "Right ⌃",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16",
            // Letters (ANSI layout keycodes)
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            // Digits
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0",
            // Misc
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "key \(code)"
    }
}
```

- [ ] **Step 2: Checks** — append to `FlowCloneChecks/main.swift` before the final tally:

```swift
print("HotkeySpec")
check(HotkeySpec.rightOption.displayString == "Right ⌥", "default displays Right ⌥")
check(HotkeySpec.rightOption.validationError == nil, "default is valid")
check(HotkeySpec(kind: .key, keyCode: 2, modifiers: HotkeySpec.controlMask | HotkeySpec.shiftMask)
        .displayString == "⌃⇧D", "chord displays ⌃⇧D")
check(HotkeySpec(kind: .key, keyCode: 96, modifiers: 0).validationError == nil,
      "bare F5 allowed")
check(HotkeySpec(kind: .key, keyCode: 2, modifiers: 0).validationError != nil,
      "bare letter rejected")
check(HotkeySpec(kind: .key, keyCode: 53, modifiers: HotkeySpec.commandMask).validationError != nil,
      "Esc rejected")
check(HotkeySpec(kind: .modifierOnly, keyCode: 63, modifiers: 0).validationError != nil,
      "fn rejected")
check(HotkeySpec(kind: .modifierOnly, keyCode: 2, modifiers: 0).validationError != nil,
      "letter as modifierOnly rejected")
if let data = try? JSONEncoder().encode(HotkeySpec.rightOption),
   let back = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
    check(back == HotkeySpec.rightOption, "codable roundtrip")
} else {
    check(false, "codable roundtrip")
}
check(HotkeySpec(kind: .modifierOnly, keyCode: 61, modifiers: 999).modifiers == 0,
      "modifierOnly init zeroes modifiers")
```

- [ ] **Step 3:** `swift run FlowCloneChecks` → all pass. **Commit.**

---

### Task 2: Persist the spec in Settings

**Files:**
- Modify: `FlowClone/Sources/FlowClone/AppDelegate.swift` (the `Settings` enum near the bottom; `FlowCloneCore` is already imported? — check the top of the file: if `import FlowCloneCore` is missing, add it)

- [ ] **Step 1:** Add to the `Settings` enum (next to `asrEngine`):

```swift
    /// The dictation hotkey. JSON-encoded HotkeySpec; absent = Right ⌥ default.
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
    /// One source of truth for every "Hold Right ⌥ …" string in the UI.
    static var hotkeyDisplay: String { hotkey.displayString }
```

Note the getter re-validates — a corrupted/hand-edited default can never brick the hotkey (falls back to Right ⌥).

- [ ] **Step 2: Build. Commit.**

---

### Task 3: Generalize `HotkeyManager`

**Files:**
- Modify: `FlowClone/Sources/FlowClone/HotkeyManager.swift` (whole-file rewrite below; current file is 68 lines)

- [ ] **Step 1:** Replace the class body (keep the Esc-monitor section untouched — copy it verbatim from the current file):

```swift
import AppKit
import FlowCloneCore

/// Push-to-talk on a configurable hotkey (default: hold RIGHT OPTION, keyCode 61).
/// Global monitor covers other apps; local monitor covers our own windows.
final class HotkeyManager {
    private var monitors: [Any] = []
    private var isDown = false
    private var spec: HotkeySpec = Settings.hotkey

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when Esc is pressed while the escape monitor is active
    /// (only during recording/processing — cancels the dictation).
    var onEscape: (() -> Void)?

    private var escapeMonitors: [Any] = []
    private static let escapeKeyCode: UInt16 = 53

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isDown = false
    }

    /// Re-read Settings.hotkey after the user changes it in Settings.
    func reload() {
        spec = Settings.hotkey
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        switch spec.kind {
        case .modifierOnly:
            guard event.type == .flagsChanged, event.keyCode == spec.keyCode,
                  let flag = Self.modifierFlag(for: spec.keyCode) else { return }
            let pressed = event.modifierFlags.contains(flag)
            if pressed && !isDown {
                isDown = true
                onPress?()
            } else if !pressed && isDown {
                isDown = false
                onRelease?()
            }

        case .key:
            if event.type == .keyDown {
                guard !event.isARepeat,                       // holding a key autorepeats!
                      !isDown,
                      event.keyCode == spec.keyCode,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                          .isSuperset(of: NSEvent.ModifierFlags(rawValue: spec.modifiers))
                else { return }
                isDown = true
                onPress?()
            } else if event.type == .keyUp {
                // Match on keyCode ONLY: users often release the modifier
                // before the key, so requiring modifiers here would miss
                // the release and leave recording stuck on.
                guard isDown, event.keyCode == spec.keyCode else { return }
                isDown = false
                onRelease?()
            }
        }
    }

    /// Which ModifierFlags bit a given modifier keyCode toggles.
    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }

    // MARK: - Esc cancel monitor (unchanged)
    // …copy startEscapeMonitor()/stopEscapeMonitor() verbatim from the current file…
}
```

**Edge cases encoded above — do not remove them:**
- `event.isARepeat` guard: holding a regular key fires repeating keyDowns; without the guard, hold-to-talk would fire `onPress` dozens of times.
- keyUp matched on keyCode only (modifier-first release order).
- keyCode disambiguates Left vs Right modifiers (61 vs 58) — `modifierFlags` alone cannot.
- `.deviceIndependentFlagsMask` intersection: raw flags carry device-dependent bits that would break `isSuperset` equality against the stored mask.
- The double-tap-lock / suppressNextRelease logic lives in `DictationController` on top of onPress/onRelease and is hotkey-agnostic — it needs **zero** changes.

- [ ] **Step 2:** `DictationController` needs a reload hook. Add to `DictationController`:

```swift
    /// Called after the user changes the hotkey in Settings.
    func updateHotkey() {
        hotkey.reload()
    }
```

- [ ] **Step 3: Build. Test manually:** run the debug binary, hold Right ⌥ → still dictates (default path unchanged). **Commit.**

---

### Task 4: Recorder UI in Hub Settings

**Files:**
- Create: `FlowClone/Sources/FlowClone/HotkeyRecorder.swift`
- Modify: `FlowClone/Sources/FlowClone/HubView.swift` (HubModel)
- Modify: `FlowClone/Sources/FlowClone/DictionarySettingsViews.swift` (SettingsPane)
- Modify: `FlowClone/Sources/FlowClone/AppDelegate.swift` (wiring)

- [ ] **Step 1:** `HotkeyRecorder.swift` — captures the next chord via LOCAL monitors only (the Hub is the key window during capture; global monitors would also capture and NOT be swallowable):

```swift
import AppKit
import FlowCloneCore

/// One-shot capture of the next hotkey chord, used by the Settings recorder.
/// Local monitors only: the Hub window is key while recording, and local
/// monitors can swallow the event (return nil) so the captured chord doesn't
/// also type into the UI.
final class HotkeyRecorder {
    private var monitors: [Any] = []
    /// Modifier keyCode seen going DOWN, pending release (modifierOnly capture).
    private var pendingModifier: UInt16?

    /// Starts capturing. Calls completion exactly once with the captured spec
    /// (validated) or nil if capture was cancelled (Esc).
    func begin(completion: @escaping (HotkeySpec?) -> Void) {
        cancel()
        let finish: (HotkeySpec?) -> Void = { [weak self] spec in
            self?.cancel()
            completion(spec)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged],
                                                    handler: { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { finish(nil); return nil } // Esc = cancel capture
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                let spec = HotkeySpec(kind: .key, keyCode: event.keyCode, modifiers: mods)
                finish(spec.validationError == nil ? spec : nil)
                return nil // swallow
            case .flagsChanged:
                guard HotkeySpec.modifierKeyCodes.contains(event.keyCode) else { return event }
                if let flag = Self.flag(for: event.keyCode),
                   event.modifierFlags.contains(flag) {
                    // Modifier went down — remember it; a keyDown before its
                    // release means it was part of a chord, not modifierOnly.
                    self.pendingModifier = event.keyCode
                } else if self.pendingModifier == event.keyCode {
                    // Same modifier released with no key in between → modifierOnly.
                    let spec = HotkeySpec(kind: .modifierOnly, keyCode: event.keyCode, modifiers: 0)
                    finish(spec.validationError == nil ? spec : nil)
                }
                return event
            default:
                return event
            }
        }) { monitors.append(m) }
    }

    func cancel() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pendingModifier = nil
    }

    private static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }
}
```

Note the pendingModifier dance: pressing ⌃⇧D fires flagsChanged(⌃ down), flagsChanged(⇧ down), keyDown(D). The keyDown wins and captures the chord. Only a modifier that goes down and comes back UP with no keyDown in between is a modifierOnly capture. A weaker model that captures on modifier-down would make chords impossible to record.

- [ ] **Step 2:** `HubModel` additions (in `HubView.swift`):

```swift
    @Published var capturingHotkey = false
    @Published var hotkeyDisplay = Settings.hotkeyDisplay
    let hotkeyRecorder = HotkeyRecorder()
    var updateHotkey: (() -> Void)?
```

(`updateHotkey` sits next to the existing `reloadEngine` / `resetPillPosition` closure pattern.)

- [ ] **Step 3:** Wire it in `AppDelegate` where `HubWindowController` is created — `HubWindowController.init` currently takes `reloadEngine:` and `resetPillPosition:` closures and assigns them onto its private model. Add a third parameter the same way:

In `HubWindowController.swift`:

```swift
    init(reloadEngine: @escaping () -> Void, resetPillPosition: @escaping () -> Void,
         updateHotkey: @escaping () -> Void) {
        model.reloadEngine = reloadEngine
        model.resetPillPosition = resetPillPosition
        model.updateHotkey = updateHotkey
    }
```

In `AppDelegate.swift` at the `HubWindowController(` call site:

```swift
        hubController = HubWindowController(
            reloadEngine: { [weak self] in self?.controller.reloadEngine() },
            resetPillPosition: { [weak self] in self?.pillController.resetPosition() },
            updateHotkey: { [weak self] in self?.controller.updateHotkey() }
        )
```

- [ ] **Step 4:** Settings UI. In `SettingsPane` (DictionarySettingsViews.swift), inside `Section("General")` ABOVE the launch-at-login toggle, add:

```swift
                HStack {
                    Text("Dictation hotkey")
                    Spacer()
                    if model.capturingHotkey {
                        Text("Press keys… (Esc to cancel)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.hotkeyDisplay)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(flowAccent.opacity(0.12)))
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
```

- [ ] **Step 5: Build**, snapshot (`--hub --snapshot-all`), READ `settings.png` — row renders, window not blank. **Commit.**

---

### Task 5: Replace every hardcoded "Right ⌥" string

**All five sites — a grep for `Right ⌥` and `RIGHT OPTION` must come back empty in Sources afterwards (except HotkeySpec.keyName's table entry, which is the display name of keyCode 61 and must stay):**

- [ ] **Step 1:** `AppDelegate.swift` — the menu hint is currently a local in `buildMenu()`: `NSMenuItem(title: "Hold Right ⌥ to dictate", …)`. Promote it to a stored property `private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")`, add it in `buildMenu()` where the old one was, and refresh it in `menuWillOpen(_:)`:

```swift
        hintItem.title = "Hold \(Settings.hotkeyDisplay) to dictate"
```

- [ ] **Step 2:** `main.swift` — the startup print `"FlowClone running. Hold RIGHT OPTION (⌥) to dictate…"` becomes:

```swift
print("FlowClone running. Hold \(Settings.hotkeyDisplay) to dictate, release to transcribe & paste.")
```

- [ ] **Step 3:** `HubView.swift` — `EmptyHistoryHint` has `Text("Hold Right ⌥ anywhere to dictate")` → `Text("Hold \(Settings.hotkeyDisplay) anywhere to dictate")`.

- [ ] **Step 4:** `OnboardingView.swift` — TWO sites:
  - the `accessibility` step's granted text: `"Click into any text field, hold Right ⌥, and speak. Double-tap for hands-free mode."` → `"Click into any text field, hold \(Settings.hotkeyDisplay), and speak. Double-tap for hands-free mode."`
  - `gestureHint`: the literal `Text("Right ⌥")` → `Text(Settings.hotkeyDisplay)`.

- [ ] **Step 5:** `DictationController.swift` — the hands-free print `"🔒 Hands-free recording — tap Right ⌥ to stop."` → `"🔒 Hands-free recording — tap \(Settings.hotkeyDisplay) to stop."`

- [ ] **Step 6: Verify:** `grep -rn "Right ⌥\|RIGHT OPTION" FlowClone/Sources --include='*.swift' | grep -v HotkeySpec` → no output.
- [ ] **Step 7: Build. Snapshot onboarding** (`--onboard --snapshot-onboard`) — gesture hint reads correctly. **Commit.**

---

### Task 6: End-to-end acceptance

- [ ] **A.** `swift build && swift run FlowCloneChecks` → clean, all checks pass.
- [ ] **B. Default preserved:** fresh defaults (no `hotkeySpec` key) → holding Right ⌥ dictates, double-tap locks, Esc cancels. Menu hint reads "Hold Right ⌥ to dictate".
- [ ] **C. Chord hotkey:** install the app, in Settings press Change… then ⌃⇧D → chip shows `⌃⇧D`. Hold ⌃⇧D in TextEdit → dictation runs, release pastes. **Typing plain `d` must NOT trigger.** Holding ⌃⇧D down for 3+ seconds must produce exactly ONE pill (autorepeat guard).
- [ ] **D. Bare F-key:** set F5 → hold-to-talk works; double-tap F5 → hands-free lock engages, single tap stops.
- [ ] **E. Modifier capture:** set Right ⌘ (press and release Right ⌘ alone in the recorder) → works as hold-to-talk.
- [ ] **F. Rejections:** in the recorder, pressing plain `d` (no modifiers) does not change the hotkey (validation rejects; capture returns nil). Esc cancels capture, hotkey unchanged.
- [ ] **G. Copy propagation:** with F5 set — menu hint, Settings chip, History empty state, and onboarding (`--onboard` snapshots) all show F5. Startup log line shows F5.
- [ ] **H. Reset:** the Reset button restores Right ⌥ everywhere without relaunching.
- [ ] **I. Corruption safety:** `defaults write com.todor.flowclone hotkeySpec -data 00ff00` → app launches, hotkey silently falls back to Right ⌥. Clean up the default afterwards.

**Definition of done:** A–I pass; grep in Task 5 Step 6 stays empty.
