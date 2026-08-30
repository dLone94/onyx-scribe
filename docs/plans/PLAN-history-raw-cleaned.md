# History 2.0: Raw ↔ Cleaned Pairs, Pin, Re-insert, Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each history entry keeps both what you *said* (raw ASR after vocabulary correction) and what got *pasted* (after LLM cleanup); the Hub History page shows the pair on demand and gains three actions — pin (survives the cap-100 trim), re-insert into the previous app, and export-all to Markdown.

**Architecture:** `HistoryEntry` grows two **optional** fields (`raw`, `pinned`) — optionality is load-bearing: the store decodes the whole array with `try?`, so one non-optional new field silently wipes every existing entry. Trim logic that respects pins is a pure function in `FlowCloneCore` (`PinnedCapTrimmer`) so `FlowCloneChecks` covers it. UI extends the existing `HistoryCard` hover-action pattern.

**Tech Stack:** Swift 6.4 (CommandLineTools only), SwiftUI (no property-wrapper macros), AppKit (NSSavePanel, NSApp.hide).

**Why this is rank 3:** Highest daily-use value of the backlog — it makes the cleanup stage inspectable (trust: "what did the LLM change?"), recoverable (re-insert), and durable (pin, export). Named as the "History 2.0 raw+cleaned pairs" backlog item.

## Global Constraints (apply to every task)

- **Toolchain:** CommandLineTools-only. SwiftUI property-wrapper **macros do not compile**: never use `@State`, `@StateObject`, `@AppStorage`, `@Environment`, `@FocusState`. Use `final class X: ObservableObject` + `@Published`, `@ObservedObject`, and manual `Binding(get:set:)`. `HubModel` in `HubView.swift` is the reference pattern (its `hoveredEntry`/`expandedEntry`-style published fields replace `@State`).
- **Tests:** XCTest and Swift Testing are unavailable. Automated checks live in `FlowClone/Sources/FlowCloneChecks/main.swift`. Run with `cd FlowClone && swift run FlowCloneChecks`. **FlowCloneChecks can only import FlowCloneCore** — pure logic to be tested goes in `FlowClone/Sources/FlowCloneCore/` (Foundation-only).
- **Build gate:** `cd "/Users/todortopalov/Documents/wispr flow clone/FlowClone" && swift build` → `Build complete!`. Pre-existing warnings (Sendable, ld search-path, CGWindowListCreateImage) are expected — do NOT fix.
- **Defaults domains:** debug binary reads domain `FlowClone`; installed app reads `com.todor.flowclone`.
- **Animations:** `MotionPreferences.shared.anim(...)` / `flowAnimate(...)` only.
- **Hub UI quirks (macOS 27):** no `.frame(maxHeight: .infinity)` inside ScrollView; no `TimelineView(.animation)` in a bare VStack detail pane. After ANY Hub-visible change run `.build/debug/FlowClone --hub --snapshot-all <dir>` and READ the PNGs.
- **History data location:** `~/Library/Application Support/FlowClone/history.json`, cap 100, newest-first.
- Commit after each task.

---

### Task 0: Back up the user's history (do this FIRST)

- [ ] `cp ~/Library/"Application Support"/FlowClone/history.json ~/Library/"Application Support"/FlowClone/history.json.bak-history2`

Every later acceptance step compares against this backup. If the file doesn't exist (fresh machine), note that and skip compatibility checks.

---

### Task 1: `PinnedCapTrimmer` in FlowCloneCore (+ checks)

**Files:**
- Create: `FlowClone/Sources/FlowCloneCore/PinnedCapTrimmer.swift`
- Modify: `FlowClone/Sources/FlowCloneChecks/main.swift`

**Interfaces:**
- Produces: `PinnedCapTrimmer.indicesToRemove(pinnedFlags: [Bool], cap: Int) -> [Int]` — indices are into a **newest-first** array; result is sorted descending (safe to `remove(at:)` in order).

- [ ] **Step 1: Write it**

```swift
import Foundation

/// Cap-enforcement for a newest-first history list where pinned entries are
/// never evicted. If everything is pinned, the list is allowed to exceed the
/// cap (pins are a promise; silently breaking one is worse than using disk).
public enum PinnedCapTrimmer {
    /// Returns the indices (into the newest-first array) to remove so that
    /// count ≤ cap, evicting oldest unpinned entries first. Sorted descending
    /// so callers can `remove(at:)` sequentially without index shifting.
    public static func indicesToRemove(pinnedFlags: [Bool], cap: Int) -> [Int] {
        let overflow = pinnedFlags.count - cap
        guard overflow > 0 else { return [] }
        var result: [Int] = []
        var i = pinnedFlags.count - 1 // oldest = last
        while i >= 0 && result.count < overflow {
            if !pinnedFlags[i] { result.append(i) }
            i -= 1
        }
        return result // built from high index to low → already descending
    }
}
```

- [ ] **Step 2: Checks** — append before the final tally in `FlowCloneChecks/main.swift`:

```swift
print("PinnedCapTrimmer")
check(PinnedCapTrimmer.indicesToRemove(pinnedFlags: [false, false], cap: 5).isEmpty,
      "under cap: nothing removed")
check(PinnedCapTrimmer.indicesToRemove(pinnedFlags: [false, false, false], cap: 2) == [2],
      "overflow 1: oldest removed")
check(PinnedCapTrimmer.indicesToRemove(pinnedFlags: [false, false, true], cap: 2) == [1],
      "pinned oldest survives; next-oldest goes")
check(PinnedCapTrimmer.indicesToRemove(pinnedFlags: [true, true, true], cap: 1).isEmpty,
      "all pinned: cap exceeded, nothing removed")
check(PinnedCapTrimmer.indicesToRemove(pinnedFlags: [false, true, false, true, false], cap: 2)
        == [4, 2],
      "interleaved: oldest unpinned first, descending order")
```

- [ ] **Step 3:** `swift run FlowCloneChecks` → all pass. **Commit.**

---

### Task 2: Data model + store

**Files:**
- Modify: `FlowClone/Sources/FlowClone/Stores.swift`

- [ ] **Step 1:** Extend `HistoryEntry`. Both new fields **MUST be optional `let`s** — the store decodes with `try? JSONDecoder().decode([HistoryEntry].self, …)`; a required field would fail the WHOLE array on the user's existing file and silently wipe their history:

```swift
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let app: String?
    let engine: String
    let durationMs: Int
    /// Recording length in seconds (nil in pre-Insights entries).
    let audioSec: Double?
    /// Tone preset id active for this dictation (nil in older entries).
    let tone: String?
    /// What the user actually said (post-vocabulary, pre-LLM). nil in older
    /// entries and when identical to `text` isn't distinct enough to matter.
    let raw: String?
    /// Pinned entries survive the cap-100 trim. nil (old entries) = false.
    let pinned: Bool?

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    var isPinned: Bool { pinned ?? false }
    /// Show the raw section only when it adds information.
    var hasDistinctRaw: Bool {
        guard let raw else { return false }
        return raw != text
    }
}
```

- [ ] **Step 2:** Update `HistoryStore.add` — new `raw:` parameter (defaulted, so the single existing call site keeps compiling until Task 3 updates it) and pin-aware trim. `FlowCloneCore` must be imported in Stores.swift (add `import FlowCloneCore` at the top if absent):

```swift
    func add(text: String, app: String?, engine: String, durationMs: Int,
             audioSec: Double? = nil, tone: String? = nil, raw: String? = nil) {
        DispatchQueue.main.async {
            self.entries.insert(
                HistoryEntry(id: UUID(), text: text, date: Date(), app: app,
                             engine: engine, durationMs: durationMs,
                             audioSec: audioSec, tone: tone,
                             raw: raw, pinned: nil),
                at: 0)
            for i in PinnedCapTrimmer.indicesToRemove(
                pinnedFlags: self.entries.map(\.isPinned), cap: 100) {
                self.entries.remove(at: i)
            }
            self.save()
        }
    }
```

- [ ] **Step 3:** Add `togglePin`. `HistoryEntry` fields are `let`, so rebuild the value — **copy every field**; dropping one silently loses data:

```swift
    func togglePin(_ id: UUID) {
        DispatchQueue.main.async {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let e = self.entries[i]
            self.entries[i] = HistoryEntry(
                id: e.id, text: e.text, date: e.date, app: e.app,
                engine: e.engine, durationMs: e.durationMs,
                audioSec: e.audioSec, tone: e.tone,
                raw: e.raw, pinned: !e.isPinned)
            self.save()
        }
    }
```

- [ ] **Step 4:** Add export:

```swift
    /// Markdown export of everything currently in history (newest first).
    func exportMarkdown() -> String {
        var out = "# FlowClone dictation history\n"
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        var currentDay = ""
        for e in entries {
            let d = day.string(from: e.date)
            if d != currentDay {
                currentDay = d
                out += "\n## \(d)\n"
            }
            var meta = "\(time.string(from: e.date)) · \(e.engine)"
            if let app = e.app { meta += " · \(app)" }
            if e.isPinned { meta += " · 📌" }
            out += "\n- **\(meta)**\n  \(e.text.replacingOccurrences(of: "\n", with: "\n  "))\n"
            if e.hasDistinctRaw, let raw = e.raw {
                out += "  - _you said:_ \(raw.replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        return out
    }
```

- [ ] **Step 5: Build** (`swift build`) — must succeed with the old `add(...)` call site untouched (the `raw:` default covers it). **Run checks.**
- [ ] **Step 6: Backward-compat proof:** run the debug binary once with the Hub (`defaults write FlowClone hasOnboarded -bool true; .build/debug/FlowClone --hub --snapshot-all /tmp/h2-compat`, kill after ~20s), then:
  `python3 -c "import json;a=json.load(open('$HOME/Library/Application Support/FlowClone/history.json'));b=json.load(open('$HOME/Library/Application Support/FlowClone/history.json.bak-history2'));print(len(a),len(b))"` — counts must be equal (old entries survived decoding).
- [ ] **Step 7: Commit.**

---

### Task 3: Pipeline records the raw text

**Files:**
- Modify: `FlowClone/Sources/FlowClone/DictationController.swift`

- [ ] **Step 1:** In `endRecording()`, the variable `raw` is the post-vocabulary pre-LLM transcript, but the fast path REASSIGNS `final` from it while `raw` stays intact — so `raw` is exactly what we want at add-time. Find the history call:

```swift
                HistoryStore.shared.add(
                    text: textToInject, app: frontApp,
                    engine: engine is WhisperEngine ? "Whisper" : "Parakeet",
                    durationMs: totalMs, audioSec: duration, tone: Tone.current.id)
```

Replace with:

```swift
                HistoryStore.shared.add(
                    text: textToInject, app: frontApp,
                    engine: engine is WhisperEngine ? "Whisper" : "Parakeet",
                    durationMs: totalMs, audioSec: duration, tone: Tone.current.id,
                    raw: raw == textToInject ? nil : raw)
```

**Why `nil` when identical:** verbatim tone and the no-change cleanup path produce `text == raw`; storing the duplicate doubles the file for zero information. `hasDistinctRaw` guards the UI, but not writing it at all keeps `history.json` lean.

**Edge case:** `textToInject` may have a leading space added by the `needsLeadingSpace` mechanical-spacing step — that makes `raw != textToInject` even when the LLM did nothing. Accept this (the raw section will show; it IS technically different) — do NOT try to trim/normalize before comparing, that path has burned people before.

- [ ] **Step 2: Build. Commit.**

---

### Task 4: History card UI — expand, pin, insert

**Files:**
- Modify: `FlowClone/Sources/FlowClone/HubView.swift`

- [ ] **Step 1:** `HubModel` gains one field (next to `hoveredEntry`):

```swift
    @Published var expandedEntry: UUID?
```

(No `@State` allowed — this is the established substitute.)

- [ ] **Step 2:** In `HistoryCard`, extend the hover-action `HStack(spacing: 10)` (currently Copy + Delete). Insert a pin button BEFORE Copy, and an Insert button AFTER Copy:

```swift
                    Button {
                        flowAnimate(.easeOut(duration: 0.15)) { history.togglePin(entry.id) }
                    } label: {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .foregroundStyle(entry.isPinned ? AnyShapeStyle(flowAccent)
                                                            : AnyShapeStyle(.secondary))
                    }
                        .buttonStyle(.borderless)
                        .help(entry.isPinned ? "Unpin" : "Pin (survives the 100-entry limit)")
```

and

```swift
                    Button {
                        let text = entry.text
                        NSApp.hide(nil) // give focus back to the previous app…
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            TextInjector.inject(text) // …then paste into it
                        }
                    } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless)
                        .help("Insert into the previous app")
```

**Why `NSApp.hide` + 0.35s:** clicking the button makes the *Hub* the frontmost app — pasting immediately would paste into the Hub itself. Hiding returns focus to the previously active app; the delay lets macOS finish the app switch before Cmd-V fires. Do NOT call `TextInjector.inject` synchronously here. Also deliberately do NOT touch `DictationController.lastInjected` — re-insert must not hijack the voice-edit ("scratch that") chain.

- [ ] **Step 3:** Pin visibility: pinned entries should show their pin even without hover. The action HStack currently has `.opacity(hovered ? 1 : 0)` — split the pin OUT of that group (place it just before the group) with its own opacity:

```swift
                // Pin is visible when pinned, hover-revealed otherwise.
                Button { flowAnimate(.easeOut(duration: 0.15)) { history.togglePin(entry.id) } }
                    label: { Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(entry.isPinned ? AnyShapeStyle(flowAccent)
                                                        : AnyShapeStyle(.secondary)) }
                    .buttonStyle(.borderless)
                    .help(entry.isPinned ? "Unpin" : "Pin (survives the 100-entry limit)")
                    .opacity(entry.isPinned || hovered ? 1 : 0)
```

(That replaces the Step 2 pin placement — final layout: pin with its own opacity, then the hover group containing Copy / Insert / Delete.)

- [ ] **Step 4:** Raw disclosure. After the `Text(entry.text)` block in `HistoryCard`, add:

```swift
            if entry.hasDistinctRaw, model.expandedEntry == entry.id, let raw = entry.raw {
                Text("you said: \(raw)")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
```

And in the metadata `HStack`, right after the engine capsule, add the disclosure toggle (only when there's something to disclose):

```swift
                if entry.hasDistinctRaw {
                    Button {
                        flowAnimate(.easeOut(duration: 0.18)) {
                            model.expandedEntry = model.expandedEntry == entry.id ? nil : entry.id
                        }
                    } label: {
                        Image(systemName: model.expandedEntry == entry.id
                              ? "chevron.up" : "text.quote")
                    }
                        .buttonStyle(.borderless)
                        .help("Show what you said before cleanup")
                }
```

- [ ] **Step 5:** Search must match raw too. In `HistoryView.filtered`, replace the filter line:

```swift
            : history.entries.filter {
                $0.text.localizedCaseInsensitiveContains(model.query)
                    || ($0.raw?.localizedCaseInsensitiveContains(model.query) ?? false)
            }
```

- [ ] **Step 6: Build**, snapshot (`--hub --snapshot-all`), READ `history.png` and `home.png` (HomeView reuses HistoryCard for "Recent" — it must not have broken). **Commit.**

---

### Task 5: Export button

**Files:**
- Modify: `FlowClone/Sources/FlowClone/HubView.swift` (HistoryView)

- [ ] **Step 1:** Add a toolbar to `HistoryView`'s outer `Group`, after `.navigationTitle("History")`:

```swift
        .toolbar {
            ToolbarItem {
                Button {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "flowclone-history.md"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? history.exportMarkdown()
                            .write(to: url, atomically: true, encoding: .utf8)
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(history.entries.isEmpty)
                    .help("Export all history as Markdown")
            }
        }
```

`NSSavePanel.runModal()` from a button action on the main thread is correct here; the Hub window is already key when the user clicks (the app is `.accessory` policy, but the Hub activates the app on `show()`).

- [ ] **Step 2: Build, snapshot, commit.**

---

### Task 6: End-to-end acceptance

- [ ] **A.** `swift build && swift run FlowCloneChecks` → clean; PinnedCapTrimmer checks pass.
- [ ] **B. Old data survives:** history count in the Hub equals the count in `history.json.bak-history2`; old entries render with no raw disclosure button (raw is nil) and no pin highlight.
- [ ] **C. Raw pair:** install (`FlowClone/scripts/build-app.sh`), dictate ≥5 words with fillers ("um so basically…") with Ollama running → new History card shows the quote-toggle; expanding shows the filler-y raw under the cleaned text. Search for a filler word present only in the raw ("basically") finds the entry.
- [ ] **D. No noise:** switch Tone to Verbatim, dictate → the new entry has NO disclosure button (raw==text was stored as nil).
- [ ] **E. Pin + trim:** pin an old entry near the bottom of the list. (Trim correctness at the boundary is covered by the FlowCloneChecks cases — no need to generate 100 real dictations.) Pin icon stays visible without hover; unpin works.
- [ ] **F. Insert:** open TextEdit, then open the Hub, click Insert on an entry → Hub hides, text pastes into TextEdit ~a third of a second later. Saying "scratch that" immediately after must NOT delete it (re-insert doesn't join the voice-edit chain) — it should be treated as normal dictation or target the last *dictated* text only.
- [ ] **G. Export:** Export button writes a .md file; spot-check it contains day headers, times, pinned marker, and "you said:" lines only for distinct-raw entries.
- [ ] **H. Snapshots:** `--hub --snapshot-all` — `history.png` and `home.png` render correctly (no blank window).

**Definition of done:** A–H pass. Delete the backup only after B passes.
