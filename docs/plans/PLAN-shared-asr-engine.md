# Shared ASR Engine (Onboarding Borrows the Pipeline's) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First launch loads the Parakeet CoreML models **once**, not twice. Onboarding's live-transcription demo borrows the main pipeline's already-loading engine instead of owning a second `Transcriber` — halving first-run model-load work (~11s cold compile each, racing on the ANE) and the resident memory of a 0.6B model.

**Architecture:** `DictationController` exposes its loaded engine read-only (`sharedEngine`, nil until `modelReady`). `OnboardingModel` gets an injected `borrowEngine` closure, re-evaluated on every transcription pass (so engine swaps propagate), with a private fallback `Transcriber` for the two cases borrowing is wrong: the user's engine is Whisper (whose first-run 0.6 GB download + ~74s CoreML specialization would stall onboarding), or the borrowed engine never becomes available.

**Tech Stack:** Swift 6.4 (CommandLineTools only), FluidAudio Parakeet via the existing `ASREngine` protocol.

**Why this is rank 5:** Real but polish-tier: it only affects first run and `--onboard` sessions. On a 24 GB machine it's contention, not failure — but first run is exactly when a "ship to others" product is judged, and both cold loads currently race the Neural Engine at the same moment (`controller.start()` fires at launch; onboarding shows immediately after and `warmEngine()` starts its own load on the Welcome step).

## Global Constraints (apply to every task)

- **Toolchain:** CommandLineTools-only. SwiftUI property-wrapper **macros do not compile**: never use `@State`, `@StateObject`, `@AppStorage`, `@Environment`, `@FocusState`. Use `final class X: ObservableObject` + `@Published`, `@ObservedObject`, and manual `Binding(get:set:)`.
- **Tests:** XCTest and Swift Testing are unavailable. Automated checks live in `FlowClone/Sources/FlowCloneChecks/main.swift` and can only import `FlowCloneCore`. This plan's logic is engine/AppKit-bound, so verification is behavioral (log-grep + snapshots) — there is no new Core logic to check.
- **Build gate:** `cd "/Users/todortopalov/Documents/wispr flow clone/FlowClone" && swift build` → `Build complete!`. Pre-existing warnings are expected — do NOT fix.
- **Defaults domains:** debug binary `.build/debug/FlowClone` reads domain `FlowClone`; installed app reads `com.todor.flowclone`. **This plan's acceptance uses BOTH** — be careful which you write.
- **Onboarding verification loop:** `defaults write FlowClone hasOnboarded -bool true && .build/debug/FlowClone --onboard --snapshot-onboard <dir>` (kill after ~16s), READ the PNGs, then `defaults delete FlowClone hasOnboarded`.
- **Key background fact:** `OnboardingModel` (in `OnboardingView.swift`) currently declares `private let engine: any ASREngine = Transcriber()` and loads it in `warmEngine()`. `DictationController` (in `DictationController.swift`) has `private var engine: any ASREngine` + `private var modelReady = false`, loaded in `start()`. `AppDelegate.applicationDidFinishLaunching` currently creates the onboarding controller BEFORE `controller = DictationController(...)` — the wiring order must be inverted (Task 2).
- Commit after each task.

---

### Task 1: Expose the pipeline's engine

**Files:**
- Modify: `FlowClone/Sources/FlowClone/DictationController.swift`

- [ ] **Step 1:** Add a read-only accessor near the top of the class (after the `private var modelReady = false` declaration):

```swift
    /// The loaded ASR engine, for borrowing by the onboarding demo.
    /// nil while loading or switching — callers must re-poll, never cache.
    var sharedEngine: (any ASREngine)? { modelReady ? engine : nil }
```

Note `reloadEngine()` already sets `modelReady = false` during a switch, so a mid-switch borrow correctly yields nil. Do not expose `engine` directly and do not expose a setter.

- [ ] **Step 2: Build. Commit.**

---

### Task 2: Onboarding borrows (with a deliberate fallback)

**Files:**
- Modify: `FlowClone/Sources/FlowClone/OnboardingView.swift`
- Modify: `FlowClone/Sources/FlowClone/AppDelegate.swift`

- [ ] **Step 1:** In `OnboardingModel`, replace the owned engine. Find:

```swift
    // Local Parakeet engine, owned only for the demo and torn down on leave.
    private let engine: any ASREngine = Transcriber()
```

Replace with:

```swift
    /// Injected by AppDelegate: returns the main pipeline's engine once it has
    /// loaded (nil while loading/switching). Re-evaluated every pass.
    var borrowEngine: (() -> (any ASREngine)?)?
    /// Fallback owned engine — created ONLY when borrowing is wrong:
    /// the pipeline engine is Whisper (first-run download + ~74s CoreML
    /// specialization would stall the demo) or never became available.
    private var ownEngine: Transcriber?
    private var ownEngineLoading = false
    /// How long we wait for the borrowed engine before giving up (its cold
    /// load is ~11s; 30s covers slow first compiles with margin).
    private var borrowDeadline: Date?

    /// The engine to use for the next demo pass, or nil to skip this pass.
    private func currentEngine() -> (any ASREngine)? {
        if let borrowed = borrowEngine?() {
            if borrowed is Transcriber { return borrowed }
            // Pipeline is on Whisper — fall back to our own Parakeet.
            loadOwnEngineIfNeeded()
            return ownEngine
        }
        return ownEngine // nil while borrow is still pending
    }

    private func loadOwnEngineIfNeeded() {
        guard ownEngine == nil, !ownEngineLoading else { return }
        ownEngineLoading = true
        let engine = Transcriber()
        Task { [weak self] in
            do {
                try await engine.load()
                await MainActor.run {
                    guard let self else { return }
                    self.ownEngine = engine
                    self.ownEngineLoading = false
                    if self.asrState == .warming { self.asrState = .ready }
                }
            } catch {
                await MainActor.run {
                    self?.ownEngineLoading = false
                    if self?.asrState == .warming { self?.asrState = .failed }
                }
            }
        }
    }
```

- [ ] **Step 2:** Rewrite `warmEngine()`. It currently loads the owned engine directly. Replace the whole method with a poll-for-borrow version:

```swift
    /// Called from the Welcome step. Resolves the demo engine as early as
    /// possible: normally by borrowing the pipeline's Parakeet (already
    /// loading since app launch — no second model load), else by loading a
    /// private fallback. Idempotent.
    func warmEngine() {
        guard asrState == .idle else { return }
        asrState = .warming
        borrowDeadline = Date().addingTimeInterval(30)
        pollForEngine()
    }

    private func pollForEngine() {
        // Resolved already?
        if let engine = currentEngine() {
            _ = engine
            asrState = .ready
            if recorder != nil { startLoop() } // mic already running
            return
        }
        // Fallback in flight? Its completion updates asrState.
        if ownEngineLoading { return }
        // Borrow timed out (pipeline load failed/stuck)? Try our own once.
        if let deadline = borrowDeadline, Date() > deadline {
            loadOwnEngineIfNeeded()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pollForEngine()
        }
    }
```

- [ ] **Step 3:** Point the demo loop at `currentEngine()`. In `runLoop()`, the transcription line currently references the old `self.engine`:

```swift
            let text = try? await self.engine.transcribe(samples)
```

Replace the surrounding logic so a nil engine just skips the pass (find the `runLoop` implementation and change the engine acquisition at its top):

```swift
        guard let engine = currentEngine() else {
            scheduleLoop(after: 0.5) // engine still warming — try again shortly
            return
        }
```

…and use `engine.transcribe(samples)` in the Task body instead of `self.engine.transcribe(samples)`.

Also in `startListening()`, the `asrState`-driven branch that previously called `engine.load()` is gone (warmEngine handles resolution); ensure `startListening()` ends with:

```swift
        switch asrState {
        case .ready: startLoop()
        case .idle: warmEngine()
        case .warming, .failed: break // warming completion starts the loop; failed uses levels
        }
```

(If the file already has exactly this switch from the onboarding build, keep it — only the load mechanics moved.)

- [ ] **Step 4:** Release the fallback on finish. In `finish()`, after `stopListening()`, add:

```swift
        ownEngine = nil // free the demo's model memory if we had to own one
```

(The borrowed engine belongs to the pipeline — never unload it from here. There is no unload API on Transcriber anyway; releasing the reference is what frees an *owned* one.)

- [ ] **Step 5:** Inject the closure. `OnboardingWindowController` (bottom of OnboardingView.swift) owns `private let model = OnboardingModel()`. Give it an init:

```swift
    init(borrowEngine: (() -> (any ASREngine)?)? = nil) {
        model.borrowEngine = borrowEngine
    }
```

- [ ] **Step 6:** Rewire `AppDelegate.applicationDidFinishLaunching`. The onboarding block currently runs BEFORE `controller` exists. Move the onboarding creation to AFTER `controller = DictationController(...)` (and after `pillController`/`hubController` setup is fine), preserving the `OnboardingWindowController.needed` check and the else-branch permission prompts exactly as they are. The creation becomes:

```swift
        if OnboardingWindowController.needed {
            // First run: onboarding walks through mic + accessibility.
            // It borrows the pipeline's ASR engine (loading right now via
            // controller.start()) instead of loading a second copy.
            onboarding = OnboardingWindowController(
                borrowEngine: { [weak self] in self?.controller.sharedEngine })
            onboarding?.show()
        } else {
            // …existing permission-prompt else-branch unchanged…
        }
```

**Ordering detail:** `controller.start()` is called a few lines below the current onboarding block — after moving, ensure the final order is: create `controller` → create `pillController`/`hubController` → `controller.start()` → onboarding block → `--hub` debug block → `--onboard` debug block. The closure captures `self` weakly and reads `controller` lazily, so it tolerates any creation order as long as `controller` is set before the first demo pass (~seconds later).

- [ ] **Step 7:** Update the `--onboard` debug path in the same function — it also constructs `OnboardingWindowController()`. Change:

```swift
            let ob = onboarding ?? OnboardingWindowController()
```

to:

```swift
            let ob = onboarding ?? OnboardingWindowController(
                borrowEngine: { [weak self] in self?.controller.sharedEngine })
```

- [ ] **Step 8: Build. Commit.**

**Edge cases encoded above — keep them:**
- **Whisper trap:** borrowed engine `is Transcriber` check. If the user switched to Whisper and re-runs onboarding (`--onboard`), borrowing Whisper would hit its first-run ~0.6 GB download / 74s specialization inside the demo. Fall back to an owned Parakeet instead.
- **Re-evaluate per pass:** `currentEngine()` is called every loop pass, so `reloadEngine()` swaps mid-onboarding propagate; never cache the borrowed reference in a property.
- **Concurrent transcribe:** dictating while onboarding is open now shares one `Transcriber`. Each `transcribe` call builds its own `TdtDecoderState`, so calls are state-independent; CoreML serializes predictions internally. This was previously two separate model instances — the acceptance run (E) exercises the shared path explicitly.
- **Borrow timeout → fallback, not failure:** if the pipeline's load fails (`modelReady` never flips), onboarding still gets a working demo via `loadOwnEngineIfNeeded()`; only if THAT also fails does `asrState` hit `.failed` (which the mic step already degrades for gracefully — level-based "heard you" without live text).

---

### Task 3: End-to-end acceptance

- [ ] **A. Build:** `swift build` → `Build complete!`.
- [ ] **B. Single load (the whole point):** simulate first run with the debug binary:
  `defaults delete FlowClone 2>/dev/null; ( .build/debug/FlowClone --onboard >/tmp/shared-engine.log 2>&1 & ); sleep 25; pkill -f .build/debug/FlowClone`
  then `grep -c "Successfully loaded all ASR models" /tmp/shared-engine.log` → **must print `1`** (previously 2: pipeline + onboarding each loaded).
- [ ] **C. Demo still works:** `defaults write FlowClone hasOnboarded -bool true; .build/debug/FlowClone --onboard --snapshot-onboard /tmp/shared-snap` — all 7 state PNGs render (READ them); `2-mic-heard.png` shows the transcript panel populated. Delete the default after.
- [ ] **D. Whisper fallback:** `defaults write FlowClone asrEngine whisper`, rerun the B command → log shows Whisper loading (pipeline) AND one Parakeet load (onboarding fallback) — `grep -c "Successfully loaded all ASR models" ` → `1` (Parakeet's line; Whisper logs differently) and the mic-step demo still transcribes. Restore: `defaults delete FlowClone asrEngine`.
- [ ] **E. Concurrent use:** install the app (`FlowClone/scripts/build-app.sh`), `defaults delete com.todor.flowclone hasOnboarded`, launch. While the onboarding mic step is listening, click into TextEdit and dictate with the hotkey → paste works, onboarding stays alive, no crash. (Shared-engine concurrency check.)
- [ ] **F. Memory sanity (optional but easy):** in Activity Monitor, first-run FlowClone memory should be roughly one Parakeet lower than before (~hundreds of MB, machine-dependent). Not a hard gate.
- [ ] **G. Regression:** `swift run FlowCloneChecks` → all pass (no Core changes expected; this catches accidental ones).

**Definition of done:** A–E and G pass. Reset any test defaults you wrote (both domains).
