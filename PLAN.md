# Plan: Faster-feeling cleanup for non-verbatim tones (streaming) — REVISED after Round 1
_Locked via grill — by Claude + Todor. Revised after adversarial review (Opus, Round 1: REVISE, 14 findings)._

## Goal
Cut the *perceived* pause between "I stopped speaking" and text appearing for
non-verbatim tones (the Work/professional tone). Today `FoundationModelCleanup.cleanup`
calls `session.respond(...)` and waits for the ENTIRE cleaned string (~0.9s median
on-device) before a single pasteboard+Cmd+V. Make it *feel* immediate by streaming
the model output as it generates. Also ship the already-built prewarm fix so the
first dictation after a tone change isn't a cold start.

Round-1 review established that unbounded incremental *paste into the document* via
the pasteboard+Cmd+V injector is document-corrupting and has no automated test — so
the plan is now phased: a low-risk perceived-latency win first, real in-document
early landing only as an explicit opt-in.

## Phase 0 — prewarm fix (done, in source; ship with this build)
`AppleCleanup.prewarm()` now fires after menu tone-pick (`AppDelegate.pickTone`),
Hub tone card (`HubView`), and the US-English toggle. Compiles. Reinstall the app
bundle as part of this work so it takes effect.

## Phase 1 — pill-preview streaming (v1, RECOMMENDED, ships now)
Stream the FM output into the pill's live preview; the final injection is UNCHANGED
(single atomic `TextInjector.inject` at end). The user sees words forming at
time-to-first-token — the perceived-latency goal — with zero new injection risk.

1. `FoundationModelCleanup.cleanupStreaming(...)` uses `session.streamResponse(to:options:.greedy)`,
   awaits to completion, and on each partial snapshot calls a `onPartial(String)`
   closure with the cumulative text. Returns the final trimmed string exactly like
   `cleanup` does today (same trimming at FoundationModelCleanup.swift:107).
2. `DictationController`'s primary Apple cleanup attempt (the `else` branch,
   ~:585–587) passes `onPartial: { pill?.setLiveText($0) }` (marshalled to MainActor,
   throttled to ≤~10 updates/sec). Everything else — leading-space block, the single
   `inject` at :639, history at :640–651 — stays exactly as-is.
3. **F14:** `cleanupStreaming` must `FMSessionPool.refillAsync()` on exit, parity with
   `cleanup` (:100), so the next dictation stays warm.
4. Scope: primary Apple FM attempt only, English only. The Ollama→Apple *fallback*
   call (:600–606) stays non-streaming (**F12**). Draft/translate/transform/rewrite,
   Ollama, verbatim, free-tier: untouched.
5. Verify: `--stream-test <wav>` prints each partial snapshot with a timestamp
   (proves time-to-first-token and that the final equals today's `--test` output).
   Snapshot-harness check that the pill renders live text without layout breakage.

Phase 1 does NOT make text land in the target document any earlier — only the
*preview* is immediate. If that's enough (it usually is for "it feels slow"), stop here.

## Phase 2 — bounded in-document early landing (OPT-IN, only if Phase 1 isn't enough)
Real early landing in the document, BOUNDED to at most two pastes: commit exactly ONE
early confirmed sentence, then the entire remainder in one paste at end. Every Round-1
finding is folded in; this is the only way the pasteboard+Cmd+V model tolerates it.

- New `TextInjector` streaming mode (existing `inject`/`replaceLast` untouched):
  `beginStream()` saves clipboard + captures frontmost PID once; `commit(_:)`
  serializes on MainActor, `setString`+Cmd+V with a **required ≥100ms** settle gap
  (**F3**); `endStream()` restores the original clipboard **≥0.5s after the final
  commit's Cmd+V** (**F4**, reuse the existing 0.5s constant).
- **F2:** whole stream wrapped so `endStream()` runs on EVERY exit (success, throw,
  Esc, guard) via `defer` — clipboard never left clobbered.
- **F1/F13:** a `didStream` flag guards the leading-space block AND the `inject` at
  :639 so nothing double-pastes; zero-chunk/empty output is an explicit path that
  injects `raw` once, normally.
- **F5:** `guard gen == generation else { break }` before every `commit`.
- **F6/F7:** `lastInjected`/`lastInjectedApp` built from the EXACT concatenated bytes
  passed to `commit` (incl. any mechanical leading space), and set even when Esc stops
  mid-stream — so a later `replaceLast` voice-edit targets the right span.
- **F8:** left-trim the first committed chunk before applying `needsLeadingSpace`.
- **F9:** commit a boundary only when it's confirmed stable — period+whitespace, a
  lookahead margin (never commit the trailing boundary of the current snapshot), and
  an abbreviation/decimal/URL guard — so "Dr. Smith", "v3.5", URLs don't mis-commit.
- **F10:** before each commit, verify frontmost PID == the one captured at
  `beginStream`; if it changed, stop + `cleanupDegraded` (no scatter across apps).
- **F11:** residual, documented — a late FM revision to the one already-committed
  sentence can't be undone; the F9 lookahead margin minimizes it by only committing a
  well-settled prefix. Accepted risk of any early-landing scheme.
- Verify: `--stream-test` shows the single early chunk + boundary decisions; MANUAL
  paste verification by the user in 3 apps (plain field, Mail/rich, code editor),
  including mid-stream focus change and Esc. This manual gate is why Phase 2 is opt-in.

## Key decisions & tradeoffs
- **Perceived vs. actual latency.** Phase 1 buys perceived speed (immediate preview)
  at ~zero risk. Only Phase 2 makes text appear in the document sooner, and it costs
  real complexity + a manual-only test gate. Recommendation: ship Phase 0+1, evaluate
  whether Phase 2 is even wanted.
- **Bounded, not unbounded.** If Phase 2 happens, one early sentence + one final paste
  (≤2 pastes, one settle gap) — never the original "1–4 interleaved pastes", which the
  review showed multiplies every failure mode.
- **Streaming stays on the primary Apple path only.** Fallback Apple + Ollama unchanged.

## Risks / open questions
- Exact shape of `streamResponse` partials on macOS 26 (cumulative vs delta) confirmed
  at implementation; Phase 1's `onPartial` is safe either way (it just shows latest).
- `pill?.setLiveText` API: the pill already shows live partial transcripts during
  recording; confirm the same surface can render cleaned text post-recording without
  fighting the partial-loop state.
- No automated end-to-end paste test — the reason Phase 2 (and only Phase 2) requires a
  manual verification gate.

## Out of scope
- Streaming the Ollama path (`/api/chat` is `stream:false`) — separate work.
- Streaming draft / translate / transform / rewrite.
- Non-English cleanup (routes to Ollama).
- Any change to free-tier / verbatim behavior.
