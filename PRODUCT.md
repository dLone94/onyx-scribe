# Product

## Register

product

## Users

Privacy-conscious macOS power users on Apple Silicon who dictate a lot — writing
email, notes, code comments, and chat across many apps — and don't want their
voice or text touching the cloud. They install Onyx Scribe expecting a menu-bar
utility that gets out of the way: grant two permissions, learn one gesture (hold
Right ⌥, speak, release), and trust that cleaned text lands at the caret in
whatever app they're in.

Because Onyx Scribe is meant to **ship to others** (a direct-distribution
commercial track exists, currently parked), the bar is that a stranger can
install, onboard, and come to trust it with no author present — and with
**nothing else to install**. That puts weight on the first-run flow, permission
clarity, live status (mic, cleanup engine, model health), zero-setup defaults,
and legible failure states — not just the happy path the author already knows by
muscle memory.

## Product Purpose

Onyx Scribe (codebase/internals keep the working name *FlowClone*) is fully-local
dictation for macOS: a two-stage voice pipeline — CoreML ASR on the Neural Engine,
then on-device LLM cleanup — that turns held-key speech into cleaned, formatted,
pasted text anywhere. Cleanup runs on **Apple Intelligence by default (zero
install)** with a local **Ollama** model as the quality-first option; auto mode
picks the best engine available. **Audio and text never leave the Mac** — that
promise is the product, not a feature bullet.

Surfaces: the floating **pill** (the signature always-on element: live waveform →
processing → success/degraded/error/info), the **Hub** window (Insights, Style,
Scratchpad, History, Dictionary, Settings), **onboarding** (dark, mascot-led
permission flow + live mic demo), and the **menu-bar** control surface (cat
silhouette at rest). The **Onyx Cat** mascot is the face of all of it.

Success looks like: dictation feels instantaneous and reliable, the UI is calm
enough to forget until needed, permissions and health are never a mystery, and
the local-first promise is legible throughout.

## Brand Personality

Three words: **calm, private, precise.** The emotional north star is **calm
confidence** — a quiet, trustworthy tool you forget is running until you need it.
Voice is plainspoken and reassuring, never chirpy or salesy.

The visual identity is **dark luxury**: near-black indigo-tinted surfaces lit by
an ambient aurora, edges caught in indigo light, an editorial display serif
(Fraunces) reserved for moments, SF Pro for everything functional. "Less SaaS
dashboard, more editorial Sunday" remains the register — now printed on black.
Premium restraint over flourish; motion is alive but never noisy, and ambient
animation runs only while actually visible.

The **Onyx Cat** — a faceted black cat head with glowing slit-pupil indigo eyes —
is the single brandmark: app icon, sidebar (where it blinks), menu bar
(monochrome silhouette), onboarding greeter. One mascot, one source of truth,
used sparingly; it has presence, never cartoon noise. The app also has a quiet
sound identity (soft pop on record, a purr when text lands), switchable off.

Identity anchors: indigo `#5957D6` with bright `#948CFF` edge-light on near-black
`#0E0E16`; amber `#EBA33D` as a graphic-only secondary; recording red; success
green. The entire app is committed dark — not themed, *built* dark.

## Anti-references

- **The SaaS analytics dashboard.** Dense metric grids, gradient hero numbers,
  card-on-card layouts. Insights should read as editorial, not as a Mixpanel
  export.
- **Cloud-AI product theater.** Sparkle icons, "AI magic" gradient copy,
  chat-bubble skeuomorphism. The intelligence is local and quiet; don't dress it
  up as a cloud assistant.
- **Noisy utility chrome.** Spinner-heavy states, aggressive toasts, neon status
  dots, a pill that shouts. The floating element must feel calm at rest.
- **Generic "modern SaaS" indigo template.** Rounded-everything, drop-shadow
  cards, one-accent-on-white sameness. Use native macOS materials with intent,
  not a web design kit transplanted onto AppKit.
- **Emoji as iconography.** Emoji cheapen the luxury register; product UI uses
  typography, custom glyphs, or SF Symbols. (Learned the hard way on the Style
  page.)

## Design Principles

1. **The tool disappears.** Every surface earns its pixels by serving dictation.
   At rest, Onyx Scribe is quiet; it becomes present only when the user acts.
   Calm is the default state, not a mode — and idle means idle: no invisible
   animation, no background CPU.
2. **Local-first is legible.** The "nothing leaves your Mac" promise shows up in
   the design — health/status you can see, no cloud-assistant cosplay — because
   trust is the product for a stranger installing it.
3. **Native, not transplanted.** Lean on macOS materials, SF Pro, system
   behaviors and a11y affordances. Settings stays a native form; custom luxury
   is layered where it earns its place.
4. **Status is never a mystery.** Permissions, engine, and model health are
   always visible and their failure states are legible and recoverable — a
   shipped tool can't assume the author is watching. Degradation is honest:
   unpolished text says so.
5. **Motion with intent.** Animation communicates state (listening, thinking,
   done) or carries the brand's living-surface feel (aurora, blink) — never
   decorates idly. Honor Reduce Motion as a real path, and pause ambience the
   moment it isn't visible.

## Accessibility & Inclusion

Treated as a first-class requirement (rigorous / VoiceOver-first):

- **VoiceOver:** every control, state, and the pill's status changes carry
  meaningful labels/announcements; the Hub is fully navigable and operable by
  VoiceOver. (A human runtime pass is still owed.)
- **Keyboard:** full keyboard operation of the Hub and menu surfaces; no
  mouse-only affordances.
- **Contrast:** target AAA where feasible (AA is the floor) on all custom UI,
  including the dark pill and status colors; verify indigo/green/red/amber
  against their dark backgrounds.
- **Motion:** honor Reduce Motion with genuine static/crossfade alternatives to
  the aurora, waveform, blink, and glint — never disabled animation that ships
  blank.
- **System settings:** respect Increase Contrast and Dynamic Type where the
  SwiftUI/AppKit surface allows.
- **Language:** English and Bulgarian are first-class (ASR auto-detect, cleanup
  routing, and UI affordances like the pill language badge).
