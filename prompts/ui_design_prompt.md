# AI Design-Tool Prompt — FlowClone UI Mock-ups

Paste into v0 / Figma AI / Galileo / any UI generator. Generates mock-ups for
all four surfaces. Grounded in verified Wispr Flow research (see UI-PLAN.md);
palette and radii are our own tokens since Wispr's exact values are unpublished.

---

## PROMPT

Design a macOS voice-dictation app UI called **FlowClone**. Design language:
calm and editorial, not SaaS-dashboard — gentle curves, soft corners, generous
whitespace, quiet confidence. Feels native to macOS (system materials,
translucency), minimal chrome. Accent color: indigo #5957D6. Recording
red #FF453A, success green #34C759. Neutral darks #1C1C1E, light surfaces use
soft warm neutrals, not clinical white. Typography: SF Pro for UI; a serif
display face (Garamond-like) ONLY for large welcome headlines — the one
editorial flourish. Both light and dark mode for windows; the floating pill is
always dark.

Create these four screens:

**1. Floating dictation pill (hero element)** — a small always-on-top capsule
floating at bottom-center of the screen over other apps, like a slim dark
island. Dark translucent background (#1C1C1E at ~92% over background blur),
capsule shape (fully rounded), subtle 1px white/10% inner border, soft shadow.
Show its five states side by side:
- Idle: compact 72×32, single white mic glyph, dimmed 70% opacity
- Recording: expanded 200×44, a live waveform of ~24 thin rounded vertical
  bars in indigo→white gradient dancing to voice level, tiny red recording dot
  at left, elapsed time "0:07" in 11px medium at right
- Recording (hands-free locked): same + a small lock badge top-right
- Processing: 200×44, waveform frozen flat, three dots pulsing in sequence
  center, label "polishing…" in 11px
- Error: compact, amber warning triangle + text "mic access" in 11px
Transitions between states should read as smooth width/opacity morphs (250ms
ease-out).

**2. Flow Hub main window (1040×680)** — left sidebar (200pt, sidebar
material): app logo + name top, nav items with SF-symbol icons: Home, History,
Dictionary, Settings; subtle indigo pill highlight on the active item. Content
area, Home selected: large serif headline "Welcome back, Todor" (~34px, serif),
subline with today's date; a row of three stat cards (rounded 12, quiet
borders, big numerals): "12,480 words dictated", "142 wpm average", "6-day
streak"; below, "Recent" section with 3 transcript cards — each rounded 12,
shows 2-line transcript preview in 13px, timestamp + app icon it was pasted
into (Slack, Notes), a copy icon appearing on hover.

**3. History view (same window)** — search field top right; vertical list of
transcript cards grouped by day ("Today", "Yesterday"); each card: transcript
text, meta row (time · target app · engine badge "Parakeet" or "Whisper" ·
duration "4.2s"), hover actions: copy, re-inject, delete. Empty-state variant:
centered soft illustration of a mic with the caption "Hold Right ⌥ anywhere to
dictate".

**4. Onboarding (560×640 centered card window)** — step 2 of 3, "Microphone"
card: big rounded card on soft neutral background, mic SF-symbol in an indigo
soft circle, title "Let FlowClone hear you" (serif, 28px), one-line
explanation, a LIVE mic-test visual: a row of ~16 audio bars that sit low and
rise with speech (show them mid-rise), primary indigo pill button "Allow
Microphone", quiet "Skip for now" text button, 3-dot step indicator bottom.
Show the same layout's step 3 variant for Accessibility with a ✅ granted
state and the button morphed to "Continue".

Overall: no gradients except the waveform, no glassmorphism excess, restrained
shadows, everything breathes. It should look like Apple designed a calm voice
tool with one indigo brand note and one serif flourish.

---

## Usage notes
- Generate screens 1 and 2 first — they carry the design system; 3 and 4 reuse it.
- If the tool supports components, ask for the pill states as variants of one
  component (they share geometry).
- Iterate the waveform until it reads "alive" — it is the brand moment.
