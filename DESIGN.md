---
name: Onyx Scribe
description: Fully-local macOS dictation — dark luxury surfaces, edge-lit in indigo, fronted by the Onyx Cat.
colors:
  indigo: "#5957D6"
  indigo-deep: "#3C3999"
  indigo-bright: "#948CFF"
  crystal: "#CCC9FF"
  amber: "#EBA33D"
  amber-ink: "#9E660F"
  recording-red: "#FF453B"
  success-green: "#33C759"
  ink: "#F2F2FA"
  ink-soft: "#A1A3BA"
  canvas: "#0E0E16"
  panel: "#1B1B26"
  hairline: "#3D3D52"
  pill-ink: "#1C1C1F"
  onyx-mid: "#1F1F36"
  onyx-deep: "#0D0D1A"
  blackberry: "#332B57"
typography:
  display:
    fontFamily: "Fraunces, New York, serif"
    fontSize: "44pt"
    fontWeight: 360
    lineHeight: 1.05
    fontVariation: "opsz 144, SOFT 40, WONK 0"
  title:
    fontFamily: "Fraunces, New York, serif"
    fontSize: "26pt"
    fontWeight: 420
    fontVariation: "opsz 96, SOFT 30"
  body:
    fontFamily: "SF Pro Text, -apple-system, sans-serif"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "SF Pro Text, -apple-system, sans-serif"
    fontSize: "11pt"
    fontWeight: 600
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "12pt"
    fontWeight: 500
rounded:
  row: "9px"
  card: "14px"
  section: "16px"
  nav: "13px"
spacing:
  row: "12px"
  card: "16px"
  section: "18px"
  page: "28px"
components:
  button-primary:
    backgroundColor: "{colors.indigo}"
    textColor: "#FFFFFF"
    rounded: "999px"
    padding: "10px 28px"
  card-luxury:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.section}"
    padding: "{spacing.section}"
  nav-row-active:
    backgroundColor: "{colors.blackberry}"
    textColor: "{colors.ink}"
    rounded: "7px"
    height: "32px"
  row-token:
    backgroundColor: "#FFFFFF0B"
    rounded: "{rounded.row}"
    padding: "8px 12px"
  pill:
    backgroundColor: "{colors.pill-ink}"
    rounded: "999px"
    height: "36px"
---

# Design System: Onyx Scribe

## 1. Overview

**Creative North Star: "Edge-Lit Onyx"**

Every surface in Onyx Scribe is a dark stone catching indigo light at its edges.
Depth never comes from lifting things off the page — it comes from where the
light lands: a gradient hairline on a card's top edge, the rim of the pill, the
facet tracery of the gem-cut cat, the glow behind whatever is currently alive.
The canvas itself breathes: a near-black, indigo-tinted field under a slow
ambient aurora that drifts only while you're looking at it. On top of that
darkness, an editorial display serif (Fraunces) marks the *moments* — heroes,
page titles, day markers — while SF Pro does all the work. The register is
"editorial Sunday, printed on black": calm, private, precise, luxurious through
restraint rather than ornament.

The system explicitly rejects the SaaS analytics dashboard (metric grids,
card-on-card), cloud-AI product theater (sparkles, gradient "magic" copy),
noisy utility chrome (spinners, shouting toasts), the generic indigo-on-white
SaaS template, and emoji-as-iconography. The mascot — the Onyx Cat — is the one
figurative element, and it appears at most once per surface.

**Key Characteristics:**
- Committed dark: built dark, not themed dark (`#0E0E16` canvas everywhere)
- Depth by light: hairlines, rims, glows — not stacked drop shadows
- Fraunces for moments, SF Pro for work, mono for the machine's own voice
- Ambient life (aurora drift, cat blink, breathing glow) that pauses when unseen
- One mascot, one accent family, one graphic secondary (amber)

## 2. Colors

A single indigo family carries the brand on near-black neutrals; amber is a
graphic-only counterpoint; red and green speak only for recording and success.

### Primary
- **Onyx Indigo** (#5957D6): the brand color — selection fills, active nav,
  primary buttons, the accent everywhere interaction lives.
- **Edge-Light Indigo** (#948CFF): the light that catches edges — facet tracery,
  rims, glowing eyes, selected-title text, small accents on dark. Never a fill
  for large areas.
- **Deep Indigo** (#3C3999): gradient partner for indigo fills; the shadowed
  side of lit surfaces.
- **Crystal** (#CCC9FF): the light-struck extreme — gem facets catching full
  light, and the top-edge hairline of every Hub panel (`FlowColor.crystal`).
  Only ever a 1px line or a facet; never a fill, never text.

### Secondary
- **Onyx Amber** (#EBA33D): graphic-only warmth — chart peaks, the degraded
  state's honest yellow, one wave in a duet. **Never body text**; use
  **Amber Ink** (#9E660F) when amber must be read.

### Tertiary
- **Recording Red** (#FF453B): the recording dot and nothing else.
- **Success Green** (#33C759): the success check and granted-permission marks.

### Neutral
- **Ink** (#F2F2FA): primary text on dark.
- **Soft Ink** (#A1A3BA): secondary text, captions, wordmark subtitles.
- **Canvas** (#0E0E16): the app's ground — near-black with an indigo tint.
- **Panel** (#1B1B26): raised surface fill for luxury cards.
- **Hairline** (#3D3D52): 1px separators at ~50% opacity.
- **Pill Ink** (#1C1C1F): the pill's own capsule fill (deliberately more neutral
  than canvas — it floats over *other* apps, not over our canvas).
- **Onyx Mid / Onyx Deep** (#1F1F36 / #0D0D1A): the stone itself — mascot facets
  and gem fills.

### Named Rules
**The Edge-Lit Rule.** Indigo light belongs on edges and in glows — hairlines,
rims, tracery, eyes. If you're about to flood a large area with saturated
indigo, stop; the surface stays onyx and the light stays on the edge.

**The Amber-Is-Graphic Rule.** Amber appears only as graphic accent (bars,
waves, degraded-state marks). Text in amber territory uses Amber Ink or Ink.

## 3. Typography

**Display Font:** Fraunces variable (bundled; falls back to system serif)
**Body Font:** SF Pro Text (system)
**Label/Mono Font:** SF Mono (system mono) — the machine's own voice

**Character:** A wonky, high-contrast editorial serif against the OS's own
workhorse sans. Fraunces must always be pushed to its display cut — `opsz` 96–144
with `SOFT` 20–40 — never left at its text default. Mono marks things the
machine says or hears verbatim: the Verbatim tone, spoken-command phrases.

### Hierarchy
- **Display** (wght 360, 44pt, opsz 144, SOFT 40): the Insights hero greeting
  and onboarding welcome. One per surface, maximum.
- **Title** (wght 420, 26pt, opsz 96, SOFT 30): page headers (Style, Scratchpad,
  Dictionary, Settings).
- **Small display** (wght 480–500, 16–20pt, opsz 60–80): wordmark, section
  moments, History day markers, brochure titles.
- **Body** (regular, 12–13.5pt): all reading text, SF Pro.
- **Label** (semibold, 9–12pt, tracking up to 1.5 for the rare caps moment like
  "LOCAL DICTATION"): controls, meta rows, badges.

### Named Rules
**The Fraunces-Is-For-Moments Rule.** The serif appears on heroes, titles, day
markers, and the wordmark — never on labels, buttons, data, or body copy. If
information is functional, it's SF Pro; if it's a *moment*, it may be Fraunces.

**The Typography-Is-The-Icon Rule.** Where a concept has a voice, set its name
in that voice instead of adding an icon: `Verbatim` in mono, gentlemanly in
wonky Fraunces, super casual in lowercase rounded. Never emoji.

## 4. Elevation

Lit, not lifted. Surfaces are flat panels distinguished by fill (#1B1B26 on
#0E0E16), a light-catching gradient hairline on the top edge, and shadows that
read as *glow* rather than height: an indigo bloom under
whatever is alive, a soft black depth shadow only where a surface floats over
foreign content (the pill). There is no shadow ramp and no z-stack of cards —
nested cards are forbidden.

### The Edge-Lit Surface
One shared treatment (`edgeLit` in `HubChrome.swift`) lights every Hub panel
and row group, so six pages read as one material:
- **Hairline:** 1px gradient stroke — Crystal 34% at the top edge → white 9% by
  45% of the height → white 3.5% at the bottom. The light lands on top and
  fades down the sides.
- **Wash:** Edge-Light Indigo 7% → clear, top to ~55% of the height, just
  inside the edge.
- **No shadow, no glow.** Quiet panels (`quietPanel`, fill Panel at 72%) and
  row groups (fill white 4%) are lit only; the floating luxury card below is
  the one surface that also carries a shadow.

### The Canvas
`FlowCanvasBackground`: Canvas (#0E0E16) under three blurred pools that drift
slowly — Onyx Indigo 42% upper-left (the main light), Edge-Light Indigo 10%
right of centre (keeps wide pages from falling to flat black), Onyx Amber 9%
lower-right. Shared by the Hub and onboarding; static under Reduce Motion and
whenever no brand window is visible.

### Shadow Vocabulary
- **Card float** (`0 8px 18px rgba(0,0,0,0.35)` equivalent): the luxury card's
  single resting shadow.
- **Indigo glow** (`0 0 22px rgba(89,87,214,0.40)`): the "alive" marker —
  selected cards, the pill's rim, the mascot's breathing halo. Radius and
  opacity may breathe ±25% on ambient timelines.
- **Depth over strangers** (`0 3px 10px rgba(0,0,0,0.35)`): only on the pill,
  which floats over other apps and must separate from unknown backgrounds.

### Named Rules
**The Lit-Not-Lifted Rule.** If a surface needs more presence, give it light
(hairline, glow, brighter edge) — not a bigger drop shadow.

## 5. Components

### Buttons
- **Shape:** full capsule (999px)
- **Primary:** Onyx Indigo fill, white semibold 14pt label, 28px horizontal
  padding, indigo glow shadow when enabled
- **Hover / Focus:** quick ease-out (180ms); disabled state falls to 40% gray
- **Secondary:** plain text buttons in Soft Ink, 12pt — quiet by design
- **Quiet capsule** (`QuietCapsuleButtonStyle`): the secondary action that
  needs a hit target — Scratchpad's Export / Copy All / Clear, Dictionary's
  Add. 26px tall, 13px horizontal padding, white 6.5% fill (13% pressed), the
  same Crystal-topped hairline as panels, Ink 12pt medium label; disabled
  drops the label to 38%. Destructive roles stay quiet — the confirmation
  dialog carries the weight. Never ship a stock grey push button on the canvas.

### Cards / Containers ("luxury cards")
- **Corner Style:** continuous 14–16px
- **Background:** Panel (#1B1B26)
- **Shadow Strategy:** card float; indigo glow only while selected/hovered
- **Border:** the top-edge light — a gradient strokeBorder white 14% → 2%
- **Internal Padding:** 16–18px
- **Hover:** scale 1.008–1.025 with the quick curve; never a color flash

### Quiet panels (Hub)
- **Use:** wherever content genuinely needs a frame — a chart, an editor, the
  tone preview, grouped rows. Never as decoration, never nested.
- **Treatment:** the Edge-Lit Surface above; 10–12px continuous corners;
  16px internal padding.

### Rhythm panel (Insights centrepiece)
One surface, not a grid: thirty days of words-per-day on the left, top three
destination apps on the right behind a vertical hairline.
- **Bars:** an onyx column per day — Onyx Indigo fading to 32% at the base,
  with a 1.5px Crystal cap (the lit top edge). An empty day is a 2px hairline
  tick; today's tick is Edge-Light Indigo.
- **Peak:** Onyx Amber with its value above it — only when at least two days
  have words (nothing to single out otherwise).
- **Empty state:** the ticks stay; one centred Soft Ink sentence teaches the
  gesture. Never a blank card.

### Tone preview (Style)
The tone panel shows the user's own recent dictation, not a canned sentence:
- **YOU SAID** — caps label (9pt semibold, tracking 1.3), then the transcript
  in mono 12pt Soft Ink (mono = what the machine heard).
- **LANDS AS** — same label, then the result in SF 14pt Ink beside a 2px
  Edge-Light Indigo bar. While the local engine works: "polishing your words…"
  in Soft Ink — text, never a spinner.
- **Fallbacks:** engine unreachable → the canned example, labelled as a sample;
  no history or a locked tone → the canned example as before.

### Motion moments
Two, both state-carrying, both silent under Reduce Motion:
- **Insights reveal** (`InsightsReveal`): once per app launch the headline
  figures count up (0.9s ease-out) and the rhythm columns rise left to right
  (spring, 12ms stagger). Every later visit settles instantly — the page never
  performs for a daily user.
- **The cat notices** (`CatPulse`): when a dictation lands, the visible mascot
  gives a quick double blink on its existing timeline. No new animation loop.

### Term chips (Dictionary)
Single words are tokens, not rows (`TermChip` in a wrapping `FlowLayout`).
- **Vocabulary chip:** 26px capsule, white 6.5% fill, Crystal-topped hairline,
  Ink 12pt medium label, a small × to remove.
- **Suggested chip** (auto-learned, not yet accepted): Onyx Indigo 13% fill and
  42% stroke, with **+** (keep in Vocabulary) before the ×. The tint is the
  only signal needed — no sparkle, no badge.
- Multi-part entries (corrections, app profiles) stay as rows in a row group.

### History rows
- **Time gutter:** the time in mono 11pt Soft Ink in a fixed 44pt column, so
  times read down one edge and the text starts on a clean line.
- **Meta line:** destination app (medium) · pipeline duration. The engine name
  appears only when stored history mixes engines; a label that is identical on
  every row is noise.
- **Day marker:** Fraunces date, hairline, then the day at a glance
  ("11 dictations · 487 words") in Soft Ink 11pt.
- **Original transcript** (expanded): mono 11pt beside a hairline bar.

### Inputs / Fields
- **Style:** native macOS rounded fields on dark (darkAqua), or token rows
  (white 4.5% fill, 9px radius, 1px white 5% border) for list entries
- **Focus:** system focus ring — native, not custom
- **Tint:** the Hub sets `.tint` to Onyx Indigo, so native switches, pickers
  and focus rings speak the brand color instead of the system accent

### Navigation (Hub sidebar)
- **Style:** quiet, narrow rail (176pt) on the aurora canvas; brandmark block
  (cat 30 + Fraunces wordmark 16) above 32px nav rows; Settings pinned at the
  bottom past a hairline; ⌘1–⌘6 shortcuts. Positioned from the window's top
  (ignores the top safe area), so a page that adds a native toolbar (History)
  cannot shift the rail
- **Active:** a restrained dark-blackberry fill (#332B57, 7px radius) — no
  glow, no traveling capsule; icon+label in Ink. Bright violet stays reserved
  for focus, recording, and primary actions
- **Hover:** white 5% wash behind the row

### The Pill (signature)
A 36px-tall dark capsule (#1C1C1F at 94% over ultra-thin material) floating over
other apps — compact enough to disappear, crafted enough to be ours: indigo-bright
rim gradient (85% top → 30% bottom) over an inner top hairline (white 12% → clear,
the luxury-card DNA), a faint indigo pool glowing behind the live edge, and a dual
glow+depth shadow. Spring entrance (rise + scale + fade). States: recording (red
pulsing dot + 14-bar live waveform, max 17px), processing (shimmer sweep), success
(green check + a one-shot edge-light glint sweeping the capsule, 0.7s), degraded
(amber check + message), error (amber triangle + message), info (indigo paintbrush
+ message). At idle it renders nothing at all. Every state
change is also spoken to VoiceOver ("Recording", "Polishing", "Text inserted",
or the error/info message) — the pill never takes focus, so it must announce.

### The Onyx Cat (brandmark)
A faceted black cat head — gem-cut silhouette, lit inner ears, glowing
slit-pupil indigo-bright eyes, diamond nose — built from shared vector geometry
so the app icon and in-app mark can never drift. In the sidebar it blinks every
~4.7s and its glow breathes; in the menu bar it's a monochrome template
silhouette with punched-out eyes; everywhere it freezes politely under Reduce
Motion and when its window isn't visible.

## 6. Do's and Don'ts

### Do:
- **Do** keep every surface on the committed dark canvas (#0E0E16) with panel
  cards (#1B1B26) — the app is *built* dark.
- **Do** put indigo light on edges: hairlines, rims, tracery, glows (the
  Edge-Lit Rule).
- **Do** push Fraunces to its display cut (opsz ≥ 96) and reserve it for
  moments (the Fraunces-Is-For-Moments Rule).
- **Do** gate every continuous animation on both Reduce Motion and actual
  window visibility (AmbientGate) — ambient motion must cost nothing unseen.
- **Do** use typography as the icon where a concept has a voice; mono for what
  the machine hears or says verbatim.
- **Do** keep the mascot singular: at most one Onyx Cat per surface.
- **Do** build every new Hub container from `quietPanel` / `RowGroup` so it
  inherits the Edge-Lit Surface, and every secondary button from the quiet
  capsule.

### Don't:
- **Don't** build "the SaaS analytics dashboard" — dense metric grids, gradient
  hero numbers, card-on-card layouts (PRODUCT.md anti-reference, verbatim).
- **Don't** ship "cloud-AI product theater" — sparkle icons, AI-magic gradient
  copy, chat-bubble skeuomorphism.
- **Don't** add "noisy utility chrome" — spinners, aggressive toasts, neon
  status dots, a pill that shouts.
- **Don't** transplant the "generic modern-SaaS indigo template" — rounded-
  everything drop-shadow cards on white.
- **Don't** use emoji as iconography anywhere in product UI.
- **Don't** leave native controls on the system accent or ship stock grey
  push buttons on the dark canvas.
- **Don't** nest cards, stack drop shadows for depth, or use gradient text.
- **Don't** flood large areas with saturated indigo or set body text in amber.
- **Don't** leave a TimelineView reachable in a hidden window — every hide path
  must land in a state that renders no timeline (the 9%-idle-CPU lesson).
