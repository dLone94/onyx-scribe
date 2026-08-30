# Plan: Reduce dictation latency — route English cleanup to Apple via a pure EngineRouter
_Locked via grill — by Claude + Todor. Revised after Codex Rounds 1–2._

## Goal
English dictation is ~1s slower after speaking because cleanup routes to Ollama/gemma: the
`cleanupEngine(for:)` "auto" branch prefers a ready Ollama for **every** language
(`DictationController.swift:25`, introduced by commit `1d52909`), and the Ollama daemon is now
running. Restore the "used to be" behavior — **English → prewarmed Apple Intelligence** — by
extracting the whole routing decision into a **pure, unit-tested `EngineRouter`** in
FlowCloneCore, where `non-English → Ollama` and unreliable detection both outrank an explicit
Apple preference (Apple FM can't do Bulgarian). Confirm the win with a symmetric warmed
benchmark, and fix the now-stale menu/label/observability surfaces so nothing lies about the
effective engine.

## Approach
1. **Extract a pure `EngineRouter.cleanupEngine(languageCode:preference:appleAvailable:
   detectionReliable:) -> Kind` into FlowCloneCore** (Codex R1 #1,#9) — SUBSUMES the pending
   Bulgarian plan's router. No `ollamaReady` input (Codex R2 low: readiness/failover is handled
   at call time, not routing). Rules, in order:
   1. `preference == "ollama"` → `.ollama`.
   2. `languageCode != "en"` → `.ollama` — Apple FM only trusted for English; **outranks explicit
      `apple`** (fixes the real bg→Apple bug — Codex R1 #1,#4; matches the Bulgarian bg→Ollama rule).
   3. `!detectionReliable` → `.ollama` — placed BEFORE the Apple rules (Codex R2 #2) so a
      possibly-mislabeled `en` (Whisper+auto) never reaches Apple; safe for en AND bg.
   4. `appleAvailable ? .apple : .ollama` — covers explicit-apple AND auto for reliable English.
   **Each caller computes `detectionReliable` from the ASR engine it ACTUALLY uses** (Codex R2 #1,
   R3 #2): live + menu derive it from `Settings` (`!Settings.autoLanguage || Settings.asrEngine !=
   "whisper"`) — valid because the live engine tracks `Settings.asrEngine` and an engine swap
   sets `modelReady=false`, which blocks dictation during the transient mismatch — so
   `DictationController.cleanupEngine(for:)` stays a static facade delegating to `EngineRouter`.
   **`--test` derives it from the engine it constructs from its CLI arg** (`!Settings.autoLanguage
   || !useWhisper`), NOT from `Settings.asrEngine`, and calls `EngineRouter` directly. Removing
   L25's readiness-first branch yields the intended auto rule (English→Apple when available).
2. **Benchmark the premise symmetrically** (Codex R1 #8, R2 #4, R3 #1). Add a NON-persistent
   `--cleanup-engine apple|ollama` override that **BYPASSES `EngineRouter` entirely** and invokes
   the named engine directly (after validating an English sample + that engine's availability) —
   so a forced-Apple benchmark can't be silently rerouted to Ollama by the reliability rule. Run
   **N warmed passes over the identical raw transcript** per engine and report **median** cleanup
   ms; before every recorded Apple pass, insert an awaitable warm/settling barrier so the async
   session-pool refill (`FoundationModelCleanup` refill vs. prewarm) has completed — otherwise a
   pass can grab a cold session. These are explicitly ISOLATED per-engine diagnostics (no
   failover — that isolation is what a fair A/B needs). Stop and reconsider if Apple isn't faster.
3. **Fix the menu truthfully** (Codex R1 #3,#4; R2 #3): do NOT hardcode "English → Apple".
   Compute the displayed route(s) by calling `EngineRouter` with the ACTUAL inputs — twice
   (`en` and `bg`) when auto-language is on ("English → <router(en)>; Bulgarian → <router(bg)>"),
   once for the pinned language otherwise — and gate the Apple "healthy ✅" line on
   `AppleCleanup.isAvailable`, showing the unavailable reason + effective Ollama fallback.
4. **Fix the Settings picker auto label** (Codex R1 #5, R3 #3): `DictionarySettingsViews.swift:376`
   "Ollama when running, else built-in" → "Auto — Apple for pinned English or Parakeet-detected
   English; Ollama otherwise" (accurate: pinned English on Whisper is reliable and still routes to
   Apple; only Whisper+auto English falls to Ollama).
5. **Fix failover observability** (Codex R1 #6): track the engine that ACTUALLY produced the
   cleaned text and its own timing; log that, not the originally-selected engine with combined
   latency.
6. **Verify:** `EngineRouter` truth-table tests in `FlowCloneChecks` — preference (auto/apple/
   ollama) × language (en/bg) × `appleAvailable` × `detectionReliable`, including the two
   safety cases (explicit-apple+bg → Ollama; explicit-apple+en+!reliable → Ollama); `swift
   build`; `FlowCloneChecks` green; menu shows the real routes.

## Key decisions & tradeoffs
- **`non-English → Ollama` AND `!detectionReliable → Ollama` both outrank an explicit Apple
  preference** — Apple FM can't do Bulgarian, and a possibly-mislabeled `en` (Whisper+auto)
  must not reach it. Safety over honoring an ambiguous explicit choice in a niche config.
- **`detectionReliable` is computed by each caller from its ACTUAL engine** — live/menu from
  `Settings` (`!autoLanguage || asrEngine != "whisper"`), CLI/`--test` from the engine it
  constructs (`!autoLanguage || !useWhisper`) — keeping the router a pure function.
- **Auto English → Apple only when reliable** — Parakeet (the user's engine) and a pinned
  language are reliable; Whisper+auto English stays on Ollama (slower cleanup acceptable on the
  accuracy engine).
- **Speed over the 8B's cleanup judgment for English** (explicit user choice); quality-seekers
  pin `cleanupEngine = "ollama"`.
- **Routing is pure + tested** so a future "prefer warm Ollama" edit can't silently restore the
  regression (exactly how `1d52909` slipped in).
- **Benchmark: non-persistent override + warmed median + a warm barrier before each Apple pass**
  so the premise-check is symmetric, side-effect-free, and not skewed by a cold Apple session.

## Risks / open questions
- **The `EngineRouter` is the single source shared with the Bulgarian plan** — that plan's router
  step folds into this one (noted, so it isn't built twice).
- **Whisper+auto+bg can't be perfectly detected**; keeping Whisper's English on Ollama avoids
  mis-routing bg to Apple. Real Whisper per-candidate arbitration remains the Bulgarian plan's
  deferred fallback (cross-referenced, not built here).
- **Needs an English sample wav** for the benchmark (existing test wav or user-provided).
- **First English cleanup after launch** may be slow until the Apple session prewarms (startup +
  after each use) — separate from steady-state latency.

## Out of scope
- Full shared cleanup-with-failover extraction so `--test` mirrors the live retry path (backlog
  refactor; the benchmark intentionally isolates a single engine).
- The ~0.35s start-side feedback delay from the uncommitted transform work (separate regression,
  not raised by the user).
- Whisper per-candidate language arbitration (Bulgarian plan's deferred fallback).
- The pending Bulgarian and transform plans (compatible; Bulgarian's router step is subsumed here).
