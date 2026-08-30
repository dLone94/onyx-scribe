# Onyx Scribe — Licensing, Trial & Free-Tier Gating

**Date:** 2026-07-09
**Status:** Approved direction (subscription / 14-day trial / degrade-to-free-tier)
**Goal:** Turn the app from a giveaway into a product that can be sold, without
breaking the "nothing leaves your Mac" thesis.

## Why this first

The app is feature-complete and polished. The literal blocker to selling is that
there is no way to charge: no trial gate, no license, no entitlement. This spec
covers the one sub-system that is fully buildable and testable today. Sparkle
auto-update and hardened-runtime/notarization are deferred — they depend on the
owner's Apple Developer enrollment and become mechanical afterward; hook points
are noted so they drop in cleanly.

## Decisions (owner-confirmed)

- **Pricing:** subscription (monthly/yearly) with a hard expiry embedded in the license.
- **Trial:** 14 days, all features unlocked, from first launch.
- **Post-trial / lapsed subscription:** degrade to a **free tier** — verbatim
  dictation stays free forever; the "intelligence" is paid.

## Entitlement model (single source of truth)

Three states resolved purely from `(trialStart, now, license)`:

| State | Condition | Capabilities |
|---|---|---|
| `.subscribed(until:)` | verified license & `expiresAt > now` | everything |
| `.trial(endsAt:)` | `now < trialStart + 14d` | everything |
| `.free` | otherwise | verbatim dictation only |

```
Entitlement.resolve(now, trialStart, license):
  if let l = license, l.verified, l.expiresAt > now → .subscribed(until: l.expiresAt)
  if now < trialStart + 14d                          → .trial(endsAt: trialStart+14d)
  else                                               → .free

hasPro = (state is .trial or .subscribed)
```

**Gate line.** When `!hasPro`, these are locked:
- **Cleanup** — LLM cleanup skipped; text is injected verbatim (reuse the existing
  verbatim/`<5-word` fast path so behavior is already proven).
- **Tones** — tone forced to Verbatim; non-verbatim tones locked in the Style page
  picker, the menu-bar tone submenu, and the voice tone-switch command.
- **Voice-edit commands** — `CommandDetector` ("scratch that", etc.) is a no-op.

**Stays free** (deliberately, as an upgrade funnel and to keep the app useful):
raw dictation, history, insights, dictionary, configurable hotkey, privacy
exclusions, EN⇄BG auto-detect.

## Licensing mechanism — offline Ed25519, no phone-home

- **Key format:** `base64url(claimsJSON) + "." + base64url(signature)`.
  `claims = { email, plan: "monthly"|"yearly", issuedAt, expiresAt, v: 1 }`.
- **Verification:** app embeds an **Ed25519 public key**; verifies the signature
  over the exact claims bytes via CryptoKit, entirely on-device. No network on the
  hot path — consistent with the product thesis and itself a marketing line
  ("even licensing is offline").
- **Renewal (the offline-subscription wrinkle):** a monthly key carries a ~30-day
  `expiresAt`. Near/after expiry the app offers **"Refresh License"**, which fetches
  a fresh signed key from the store. That refresh is the **only** network call,
  touches **no voice/text**, and is built behind a `LicenseRefresher` protocol with
  a **stub** now (real Paddle / Lemon Squeezy endpoint wired when the store account
  exists). Day-to-day stays fully offline (local signature check only).
- **Accepted tradeoff:** keys cannot be remotely revoked and are shareable — the
  standard honest-customer model. Embedded `expiresAt` enforces subscription lapse.

## Trial clock (tamper-honest, not tamper-proof)

- First-launch timestamp stored in **both** UserDefaults and a receipt file under
  Application Support; the **earliest** wins (survives a `defaults delete`).
- Track `lastSeen`; if `now < lastSeen`, the clock was set back → do **not** extend
  the trial (clamp). Honest-customer grade; limits documented, not over-engineered.

## Code structure (follows existing conventions)

**FlowCloneCore** (pure, Foundation + CryptoKit only; unit-tested by FlowCloneChecks):
- `LicenseClaims` — Codable payload; `isExpired(now:)`.
- `LicenseKey` — parse `claims.sig` string → claims + raw bytes.
- `LicenseVerifying` protocol + `Ed25519Verifier` (CryptoKit) — verify signature
  against an embedded/injected public key → `VerifiedLicense?`.
- `Entitlement` — resolver + `hasPro` + per-`Feature` gate.
- `Feature` — `.cleanup`, `.tones`, `.voiceCommands`.
- `TrialClock` — pure date math: `state(firstLaunch:lastSeen:now:)`.

**FlowClone** (app target):
- `LicenseStore` — persists license string + trial timestamps (defaults + receipt
  file); exposes `LicenseModel: ObservableObject` with `@Published entitlement`
  (manual `Binding` pattern — `@State` macros don't compile under CLT-only).
- `LicenseRefresher` protocol + `StubLicenseRefresher` (returns `.notConfigured`).
- `DictationController` reads `hasPro` to gate cleanup / tone / command paths.
- **UI:** Hub Settings → **"License"** section (state + days-left, "Enter Key…",
  "Refresh License", "Subscribe" → opens checkout URL); locked tones show a calm
  lock badge on the Style page; a quiet free-tier note in the pill/Hub; onboarding
  gains one honest line ("14-day trial, then verbatim stays free").

**FlowCloneChecks** — new cases:
- claims decode round-trip; expiry boundary.
- Ed25519 verify: valid / wrong-key / tampered-claims / tampered-sig / expired.
- `Entitlement.resolve` truth table across trial/subscribed/free.
- `TrialClock`: countdown, day-14 rollover, clock-setback clamp.
- Gate truth table: which `Feature`s are allowed per state.

## Error / edge handling

- Corrupt or unparseable stored license → treated as no license (fail to trial/free,
  never crash), mirroring `Settings.hotkey`'s validating-getter pattern.
- Missing receipt file on first ever launch → create it, set `firstLaunch = now`.
- CryptoKit unavailable in the checks runner (unlikely) → fallback plan: move
  `Ed25519Verifier` into the FlowClone target and test claims/entitlement/trial
  logic (the parts that matter most) in Core. Verified as an early implementation step.

## Out of scope (noted, deferred)

- Sparkle auto-update (needs notarized build + feed).
- Hardened-runtime / notarization `build-app.sh` changes (needs Developer ID cert).
- Real store webhook that signs keys (needs Paddle/Lemon Squeezy account); the app
  side is channel-agnostic and ready for it.

## Verification

- `swift run FlowCloneChecks` green (existing 59 + new cases).
- `swift build` clean.
- `--hub --snapshot-all <dir>` to confirm the new License settings section and
  locked-tone badges render on the dark canvas.
- Manual: set defaults to force each state (trial / expired-trial / valid-license /
  expired-license) and confirm the pipeline gates correctly via `--test <wav>`.
