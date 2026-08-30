# SwiftUI Build-Spec Prompt — FlowClone Frontend

An implementation prompt for building the Wispr Flow-style UI into the
existing FlowClone codebase. Hand this (plus repo access) to any capable
coding agent — or use it as the working spec ourselves. Grounded in verified
research: the NSPanel recipe below is the documented, multi-source-confirmed
pattern; design tokens are ours (see UI-PLAN.md §2).

---

## PROMPT

You are working in the FlowClone repo — a working local dictation app for
macOS 14+ (Swift 5.10 SPM package in `FlowClone/`, AppKit + programmatic
menu bar, no storyboard). Existing architecture you must integrate with, not
replace:

- `DictationController.swift` — pipeline orchestrator; has
  `enum State { loadingModel, idle, recording, processing }`, an
  `onStateChange: (State) -> Void` callback (currently drives menu-bar emoji),
  `recentDictations: [String]` (last 10, in memory), hands-free lock flag
  (`handsFreeLocked`, private — expose as needed).
- `AudioRecorder.swift` — AVAudioEngine tap producing 16kHz mono `[Float]`.
- `AppDelegate.swift` — NSStatusItem menu, `Settings` enum over UserDefaults
  (keys: cleanupEnabled, ollamaModel, asrEngine, language).
- `HotkeyManager.swift`, `TextInjector.swift`, `OllamaClient.swift`,
  `Transcriber.swift` / `WhisperEngine.swift` — leave untouched.
- Vocabulary at `~/.flowclone/vocabulary.txt`, profiles at
  `~/.flowclone/profiles.json`.

Build three surfaces in this order. Keep every existing behavior working.
`swift build` must stay green after each step; app is installed via
`FlowClone/scripts/build-app.sh`.

### Design tokens (use everywhere)
Accent indigo #5957D6; recording red #FF453A; success #34C759; pill background
#1C1C1E at 0.92 opacity over `.ultraThinMaterial`; pill is always dark; Hub
windows follow system light/dark with standard materials. Corner radius 12 for
cards; capsule for the pill. Animations 250ms easeOut. Font: system (SF Pro);
use `.fontDesign(.serif)` only for the Hub welcome headline.

### Surface 1 — Floating dictation pill

**FloatingPanel.swift** — `final class FloatingPanel: NSPanel`. The exact
recipe (verified against Apple docs; do not deviate):
```swift
init(contentRect: NSRect) {
    super.init(contentRect: contentRect,
               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    becomesKeyOnlyIfNeeded = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false            // SwiftUI view draws its own shadow
    isMovableByWindowBackground = true   // user-draggable (unlike Wispr)
    hidesOnDeactivate = false
}
override var canBecomeKey: Bool { false }
override var canBecomeMain: Bool { false }
```
Set the styleMask at init only — flipping `.nonactivatingPanel` later triggers
macOS bug FB16484811. `.nonactivatingPanel` is load-bearing: clicking the pill
must never steal focus from the app receiving dictation.

**Audio level feed** — in `AudioRecorder`, compute RMS per tap buffer
(before/independent of the sample accumulation), map to 0…1 with a soft-knee
(`min(1, rms * 18)` is a fine start), and publish. Add
`var onLevel: ((Float) -> Void)?` called on the main thread. Keep a rolling
buffer of the last 24 levels for the waveform.

**PillView.swift** (SwiftUI) — one view, five states, driven by an
`ObservableObject PillModel { state, levels: [Float], elapsed, locked }`:
- idle/hidden: pill not shown (panel `orderOut`) — pill appears on recording start
- recording: capsule ~200×44 — red dot (6pt), 24 rounded-rect bars (2.5pt wide,
  3pt gap, heights 4–24pt from levels, indigo-to-white gradient), elapsed time
  `monospacedDigit` 11pt at right; lock badge (SF `lock.fill`, 9pt) when
  hands-free
- processing: bars flatten to 4pt, three dots pulse in sequence, caption
  "polishing…" 11pt secondary
- success: brief ✓ in success green, then fade+shrink out over 300ms
- error: amber `exclamationmark.triangle.fill` + short caption ("mic access" /
  "Ollama offline"), auto-hides after 2.5s
All state changes animate with `.animation(.easeOut(duration: 0.25))` on
width/opacity.

**PillController.swift** — owns the panel + `NSHostingView(rootView:
PillView(model:))`. Subscribes to `DictationController` (extend
`onStateChange` or add a second callback for level/lock/error detail — do NOT
break the existing menu-bar state updates). Position: bottom-center of the
screen with the frontmost window (`NSScreen.main` fallback), 24pt above the
Dock; persist a user-dragged offset in UserDefaults (`pillOffset`) and restore
it; reset via menu item "Reset Pill Position". Multi-display: recompute on
`NSApplication.didChangeScreenParametersNotification`.

Wire an error path: `DictationController` currently only prints on failures
(Ollama down, ASR fail, missing Accessibility) — surface those to the pill.

### Surface 2 — Flow Hub window

SwiftUI `NSWindow` (960×640 min, unified toolbar style, standard light/dark),
opened via new menu item "Open FlowClone…" (and on app icon click if
activation policy allows). `NavigationSplitView` sidebar: **Home, History,
Dictionary, Settings** (SF symbols: house, clock.arrow.circlepath,
character.book.closed, gearshape).

- **Home**: serif headline "Welcome back" + first name from `NSFullUserName()`;
  three stat cards: total words dictated, average cleanup latency, day streak.
  Add a lightweight `StatsStore` (UserDefaults-backed counters updated by
  `DictationController` after each injection: words += word count, record date
  for streak, rolling latency average). Below: last 5 dictations (reuse
  History card component).
- **History**: replace the in-memory `recentDictations` cap-10 array with a
  `HistoryStore` persisting JSON to
  `~/Library/Application Support/FlowClone/history.json`, cap 100 entries:
  `{text, date, app, engine, durationMs}`. Card list grouped by day, searchable
  (`.searchable`), hover actions: Copy, Delete. Keep the menu-bar "Recent
  Dictations" submenu working off the same store.
- **Dictionary**: two sections editing the real files. Vocabulary: list +
  add/remove of plain terms and `wrong => right` rows (two text fields),
  writing back to `~/.flowclone/vocabulary.txt` preserving `#` comments.
  Profiles: app-name → instruction rows over `profiles.json`.
- **Settings**: engine picker (Parakeet/Whisper — calls
  `controller.reloadEngine()`), cleanup toggle + Ollama model name field,
  language field, launch-at-login toggle, pill position reset, permission
  status rows (reuse the live AX/mic checks from `AppDelegate.menuWillOpen`).
  Menu bar keeps quick toggles; Settings is the full surface.

### Surface 3 — Onboarding + menu-bar polish

- First run (`UserDefaults.hasOnboarded` false): 560×640 centered window,
  3 cards with slide transitions: Welcome ("Dictate anywhere. 100% local.") →
  Microphone (explain, "Allow Microphone" button triggering
  `AVCaptureDevice.requestAccess`, live 16-bar mic test once granted, driven by
  the same `onLevel` feed) → Accessibility (explain paste injection, button
  opens the Settings pane deep-link, live status flips to ✅ via a 1s
  `AXIsProcessTrusted()` poll timer, "Continue" enables when granted). Finish
  with a "try it now" hint card pointing at Right ⌥.
- Menu bar: replace emoji with a template SF-symbol mic
  (`NSImage(systemSymbolName: "mic.fill")`, `isTemplate = true`); recording →
  tint red via attributed title or symbol swap to `mic.badge.plus`; processing
  → `ellipsis` badge. Add "Open FlowClone…" item at top.

### Acceptance checks
1. Pill appears over a full-screen app while dictating; clicking/dragging it
   never removes focus from the target text field (type-through verified).
2. `--test` headless mode still runs (no UI dependency in that path).
3. History survives relaunch; stats accumulate; dictionary edits round-trip
   the text files without clobbering comments.
4. All existing hotkey/command behavior unchanged; menu quick toggles work.
5. `./scripts/build-app.sh` installs; permissions persist (FlowClone Dev cert).
