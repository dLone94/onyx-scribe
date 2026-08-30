# Onyx Scribe — go-to-market plan

Written plan only — no accounts created, no notarization run, no merchant signup, no
landing-page redeploy. This is the ordered path from "works on my Mac" to "first paid
download." Price: **$9/month**, single tier.

## The product in one line
A menu-bar dictation app that is **100% local** — your voice, the text you dictate, and
even the on-screen content it reads for drafting never leave your Mac. No account, no
cloud, no telemetry.

## Who it's for
Mac users who dictate a lot and can't (or won't) send their words to a cloud service:
- **Privacy-bound professionals** — lawyers, clinicians, therapists, journalists, people
  under NDA. For them "local-only" isn't a nicety, it's a requirement.
- **Developers / power users** — already on Apple silicon, comfortable with Ollama, want
  a fast push-to-talk that works in every app.
- **Bilingual users** — EN/BG (and more) with speak-one-language-type-another.

## The wedge — why us over Wispr Flow / Superwhisper / Apple Dictation
The differentiator is not "dictation," it's **"dictation that physically cannot leak."**
Everything cloud tools do server-side, we do on-device:
- **Context-aware drafting** reads the on-screen thread locally (Accessibility) and writes
  the reply — a cloud tool can't offer this without uploading your screen.
- **Local style memory** learns your names/jargon from your own history, on-device.
- **Transform selected text by voice** — select, double-tap-hold, speak; rewritten in place.
- **Speak one language, type another** — fully offline translation.
None of these send a byte off the Mac. That's the whole pitch, and it's defensible.

## Pricing
- **$9/month**, 14-day full trial, then degrade to a genuinely-useful free tier (raw
  local dictation stays free; cleanup / tones / voice commands / transform are paid).
- No yearly tier at launch (revisit once churn/renewal data exists).
- Licensing is offline Ed25519 (already built): no phone-home, works on air-gapped Macs.

## Distribution reality
The Mac App Store is **out** — the app needs the Accessibility API, a non-sandboxed
process, and library-validation disabled for the local model. So: **direct distribution**,
Developer-ID-signed + notarized, auto-updating via Sparkle. (Build script already has the
3-tier signing path; `docs/SPARKLE.md` covers the updater.)

## Ordered technical sell-sequence (each step's prerequisite in parens)
1. **Apple Developer Program enrollment** ($99/yr) — prerequisite for a Developer ID cert.
2. **Developer ID Application cert** (needs #1) → real signing instead of ad-hoc.
3. **Notarize + staple** the build (needs #2) → Gatekeeper opens it with no scary prompt.
4. **Sparkle appcast** (needs #3, a hosting URL, and the EdDSA update key) → auto-updates.
   `web/appcast.xml` is scaffolded.
5. **Merchant + license webhook** (needs a store: Paddle/Lemon Squeezy as merchant-of-record
   so we don't handle VAT). On purchase, the webhook signs a license with the private
   Ed25519 key (kept OUT of the repo, at `~/.flowclone/signing-key.b64`) — the app already
   verifies these offline. `FlowClone --sign-license` is the reference minting command.
6. **Landing page redeploy** (needs #5 for the buy link) — the page exists (`web/`), priced
   at $9/mo; only the checkout URL is missing.

## Launch channels (once #1–6 are true)
- **Show HN / Hacker News** — the "100% local, no cloud" angle is native to that audience.
- **r/macapps, r/MacOS** — demo GIF of transform-in-place + drafting.
- **Product Hunt** — the privacy wedge + the Onyx Cat mascot.
- **X / indie-Mac dev circles** — short screen-recordings of each unique feature.
Lead every channel with the demo, not the feature list: select → double-tap-hold → speak →
watch it rewrite in place, with a visible "nothing left this Mac" framing.

## Pre-launch checklist (all must be true before the first paid download)
- [ ] `swift run FlowCloneChecks` green; `docs/SMOKE-TEST.md` fully passed on-device.
- [ ] Developer-ID-signed + notarized build; installs cleanly on a second Mac with no
      Gatekeeper override.
- [ ] Sparkle update from vN → vN+1 verified end-to-end.
- [ ] Purchase → webhook → signed license → in-app activation verified with a real
      (sandbox) checkout.
- [ ] Trial → expiry → free-tier degrade verified (`--trial-set-days-ago`).
- [ ] Signing key backed up securely and confirmed NOT in the repo or the shipped app.
- [ ] Landing page live with the working checkout link and honest privacy claims.
- [ ] A crash/oops feedback path (email or form) exists.

## Deliberately deferred
Yearly pricing, teams/volume licensing, Windows, iOS, a hosted account system. None are
needed to sell v1; all can follow real usage data.
