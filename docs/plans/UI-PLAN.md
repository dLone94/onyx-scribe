# FlowClone UI Plan — Wispr Flow-style Frontend

> Based on deep research of Wispr Flow's interface (2026 post-rebrand, 105-agent
> verified run). Companion prompts: `prompts/ui_design_prompt.md` (mock-up
> generation) and `prompts/ui_build_spec.md` (SwiftUI implementation).

---

## 1. What the research verified about Wispr Flow's UI

### The Flow Bar (floating dictation pill) — the signature element
- Slim, minimal **dark floating pill locked to bottom-center** of the screen,
  re-anchoring relative to the macOS Dock. Rendered inside a ~440×300px
  transparent window with a ~70px visible pill (single-source, approximate).
- **Visual states**: static mic icon (idle) → live audio-reactive waveform while
  listening (flattens after silence) → pulsing spinner (reconnecting) → warning
  triangle (permission lost) → retry icon (unresponsive). Spinner/warning/retry
  are documented on Android's "Flow Bubble"; mic + waveform are confirmed on macOS.
- Hosts an inline **hover language picker** and an opt-in Scratchpad button.
- Not user-movable (Wispr re-pins it every ~400ms — people wrote a utility,
  PillFloat, just to move it; we should make position a setting instead).

### Flow Hub (main window)
- **Left sidebar**: Insights · Style · Scratchpad · Transforms · History.
- Personalized "Welcome back, [name]" header; usage stats (words dictated, WPM,
  streak); **History = transcript cards with tap-to-copy**.

### Onboarding
- **Card-based permission prompts** (microphone, accessibility) + a **mic test
  with animated audio bars** that rise as you speak.

### Design language
- "**Voice in Motion**": gentle curves, soft corners, generous whitespace, wide
  margins — "less SaaS dashboard, more editorial Sunday."
- Accent: **soft green** (officially just "soft green"; one source suggests
  forest teal ≈ #034f46 — not authoritative).
- Typography (from marketing site CSS): **Figtree** sans for body/UI
  (400–700, 14–32px, lh 1.3) + **EB Garamond** serif display (400, up to 120px).
  In-app chrome may differ.

### Technical recipe (verified, Apple docs + multiple sources)
- Floating pill = **NSPanel subclass**: `isFloatingPanel = true`,
  `level = .floating`, styleMask `[.nonactivatingPanel, .titled, .resizable,
  .closable, .fullSizeContentView]`, `becomesKeyOnlyIfNeeded = true`,
  `contentView = NSHostingView(rootView:)`. **Set styleMask at init** —
  flipping `.nonactivatingPanel` dynamically hits macOS bug FB16484811.
- `.nonactivatingPanel` is the crux: the pill floats over every app and clicks
  never steal focus — dictation still lands in the frontmost app.

### Known gaps (we decide these ourselves)
No official hex values, corner radii, animation curves, or dark/light pill
specs were recoverable. Three plausible-sounding palette/style claims were
**refuted** in verification — so any pixel-exact "Wispr palette" you see online
is likely invented. This makes a faithful clone impossible to source-verify.

---

## 2. Recommended direction: **structurally faithful, visually adapted**

Clone what's verified and load-bearing — the **structure and interaction
model** (bottom-center pill + states + waveform, sidebar Hub, card onboarding,
tap-to-copy history). Adapt the **visual skin** to FlowClone's existing
identity (indigo, from our app icon) with Wispr's *feel*: calm, soft-cornered,
editorial, generous whitespace.

Why: (a) exact Wispr visuals aren't verifiable, so "faithful" would mean
guessing; (b) we already ship an indigo brand; (c) the interaction model is
what makes Wispr feel great — that part we can copy exactly.

**FlowClone design tokens** (our decisions, filling the gaps):
- Accent: indigo `#5957D6` (matches app icon gradient); success green `#34C759`;
  recording red `#FF453A`.
- Pill: dark regardless of system theme (`#1C1C1E` @ 92% opacity over
  `.ultraThinMaterial`), white/secondary content; capsule (corner radius =
  height/2). Idle ~72×32pt, expands to ~200×44pt while recording.
- Hub: system materials, SF Pro (Figtree optional later), serif display via
  `.fontDesign(.serif)` for the welcome header — the editorial nod.
- Motion: 250ms ease-out expansions; waveform 24 bars @ 60fps from mic RMS;
  processing = 3-dot pulse (no spinner clichés).

---

## 3. Build plan

### Phase A — Floating pill (the payoff)
1. `FloatingPanel.swift` — NSPanel subclass per verified recipe.
2. Expose live audio level: `AudioRecorder` publishes RMS per tap buffer.
3. `PillView.swift` (SwiftUI): state-driven — idle mic glyph / waveform bars
   (recording) / 3-dot pulse (processing) / ✓ flash (injected) / ⚠️ (error,
   also shown when Accessibility is missing — reuse our live TCC check).
4. `PillController` — bridges `DictationController.State` → panel show/hide +
   view state. Pill visible while recording/processing; auto-hides after done.
   Position: bottom-center default, **user-draggable + persisted** (fixing
   Wispr's #1 pill complaint), multi-display aware.
5. Hands-free lock indicator (🔒 badge) — our double-tap mode, shown in pill.

### Phase B — Flow Hub window
1. SwiftUI window (openable from menu bar): sidebar **Home · History ·
   Dictionary · Settings** (Insights/Style/Transforms have no backend yet;
   Dictionary/Settings do).
2. Home: "Welcome back" serif header, stats (words dictated, avg latency,
   streak) — persist counters in UserDefaults; recent activity list.
3. History: card list, tap-to-copy, search field; persists last N=100 to disk
   (currently 10 in memory).
4. Dictionary: editable vocabulary + `wrong => right` rules UI over
   `~/.flowclone/vocabulary.txt`; per-app profiles editor over `profiles.json`.
5. Settings: hotkey display, engine picker, cleanup model, language, launch at
   login — replacing the menu-bar toggles with a real pane (menu keeps quick
   toggles).

### Phase C — Onboarding + menu bar polish
1. First-run window: 3 cards (Welcome → Microphone → Accessibility) with live
   permission status and a **mic test with animated bars**, then "try it"
   dictation playground.
2. Menu bar: template mic icon (proper `NSImage.isTemplate`, not emoji) with
   recording tint; dropdown gains "Open Flow Hub".

Sequencing: A → B → C, shippable after each phase.

---

## 4. Sources & confidence notes
High-confidence: pill anatomy/states/position, Hub sidebar structure,
onboarding flow, NSPanel recipe (Apple docs), design-language descriptions
(official rebrand write-ups). Medium: pill pixel dimensions (single
reverse-engineering source). Refuted/avoid: lavender-#f0d7ff/ember-#ffa946
palettes, "flat 2px-border shadowless" style claims, forest-teal hex as
official. Typography specs are marketing-site CSS, not app chrome.
