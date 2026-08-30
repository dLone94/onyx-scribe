# Plan Review Log: Streaming injection for Apple FM cleanup
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Context: user asked to make the Work/professional tone dictation faster. Grill
established (a) the tone itself isn't the bottleneck — any non-verbatim tone
triggers the on-device LLM cleanup pass; (b) a real prewarm gap makes the first
dictation after a UI tone-change cold (fixed in source); (c) the every-time ~0.9s
pause needs streaming injection, which is non-trivial because the injector is
pasteboard + Cmd+V with a per-call clipboard-restore timer. User chose to go
straight at streaming (skip the measurement detour). Plan locked; handing to Codex.

## Round 1 — Reviewer (Codex unavailable — config pins `gpt-5.6-sol`, rejected 400 on ChatGPT account; user chose an independent Opus reviewer in a fresh cold context. NOTE: Claude-reviewing-Claude, not a true cross-model check.)

VERDICT: REVISE. 14 findings, all concrete:

- F1 Double-injection: streaming branch never bypasses the shared `TextInjector.inject` at DictationController.swift:639 → whole cleaned string pasted a second time after the chunks.
- F2 Clipboard clobbered when the FM stream throws (guardrails throw mid-gen, treated as normal at :589) — `endStream()` restore never runs.
- F3 Inter-chunk delay is mandatory, not a tuning knob: rapid synchronous Cmd+V into an app that hasn't consumed the prior paste drops/duplicates chunks.
- F4 `endStream` restore races the final paste — restoring before the last Cmd+V is consumed pastes the *restored original clipboard* instead of the last sentence.
- F5 No per-chunk cancellation check: the only `gen == generation` guard is at :627 (after cleanup); chunks keep pasting after Esc.
- F6 Esc mid-stream leaves `lastInjected` stale (Task returns before :640) → later voice-edit `replaceLast` backspaces the wrong location.
- F7 `lastInjected` must equal the exact bytes pasted (incl. mechanical leading space / untrimmed model output) or `replaceLast`'s char count is off.
- F8 First snapshot's leading whitespace/newline never trimmed (non-streaming trims at :107) → stray leading space/line break at the caret.
- F9 Sentence chunking on bare `. ! ? \n` mis-fires on "Dr.", "e.g.", "v3.5", URLs → premature, unrecoverable commits of non-sentences.
- F10 Focus change mid-stream: the multi-paste window spans the whole ~1s generation; user clicking another app scatters sentences across apps; `frontApp` recorded once at end is wrong.
- F11 Non-monotonic FM partials: a later snapshot revising an already-committed sentence ("3"→"three") can't be undone — inherent to committing before generation is final.
- F12 The Ollama→Apple fallback Apple call (:600–606) would also route through streaming on a rarely-tested branch — restrict streaming to the primary Apple attempt (:585–587).
- F13 Empty/noise output → zero committed chunks, but `final` is still `raw` → risk of falling through to a raw paste at :639.
- F14 Streaming path must also `FMSessionPool.refillAsync()` (parity with :100) or the NEXT dictation is cold — silently defeating the paired prewarm win.
- Simpler alternative (strongly recommended for v1): stream FM output into the **pill live preview only** (words form at time-to-first-token — captures the *perceived*-latency goal) and keep the existing single atomic paste at end → zero pasteboard races / clipboard-clobber / focus-scatter / abbreviation hazard. If real in-document early landing is wanted, bound it to exactly ONE early confirmed sentence then the whole remainder in one paste (max two pastes).

### Claude's response
Accepting the critique's core conclusion and ALL 14 findings. Unbounded 1–4-chunk
in-document streaming has a document-corrupting blast radius, and there is no
automated test for real paste — so shipping it as v1 is irresponsible. Restructured
the plan into two phases:

- **Phase 1 (v1, recommended, ships now): pill-preview streaming.** Stream FM output
  into the pill's live preview; keep the single atomic `inject` at end untouched.
  Captures the perceived-latency goal (user sees words forming immediately) at
  near-zero correctness risk. Sidesteps F1–F13 entirely (no incremental paste).
  Only F14 (refill parity) and the prewarm fix still apply.
- **Phase 2 (opt-in, only if real in-document early landing is still wanted):**
  BOUNDED to one early confirmed sentence + one final paste (max two pastes), with
  every guard folded in: F1 didStream flag bypassing :632–639; F2 `defer` endStream
  on all exits; F3 required ≥100ms serialized inter-commit gap; F4 restore ≥0.5s
  after the final Cmd+V; F5 `gen==generation` check before each commit; F6/F7
  lastInjected = exact concatenated committed bytes, set even on Esc; F8 left-trim
  first chunk; F9 confirmed-stable boundary w/ lookahead margin + abbrev/decimal
  guard; F10 capture frontmost PID at beginStream, re-verify before each commit;
  F11 lookahead margin mitigates (documented residual); F12 primary-Apple-attempt
  only; F13 explicit zero-chunk path.

The pill-vs-document scope choice is user-facing (does text land in the doc earlier,
or only appear in the pill), so it goes to the user at sign-off rather than being
decided unilaterally. Did not re-run a second review round: the true cross-model
tool is down, and the revision adopts the reviewer's own recommended safer
architecture — a second Claude round would be a weak check. Offered to the user.

## Build — Phase 0+1+2 (Claude implemented, user chose full build)

Shipped:
- `FlowCloneCore/StreamChunker.swift` — pure, bounded one-early-sentence chunker
  (F9/F11). 14 unit tests in FlowCloneChecks (abbreviations, decimals, URLs,
  lookahead, single-chunk bound, divergence). 177/177 checks pass.
- `TextInjector` streaming mode — `beginStream`/`commitStream`/`endStream`
  (F2 defer-restore, F3 ≥100ms settle gap, F4 ≥0.5s post-commit restore, F10 PID
  re-check per commit).
- `FoundationModelCleanup.cleanupStreaming` — `streamResponse` cumulative
  snapshots (verified against the SDK swiftinterface: `Snapshot.content: String`),
  F14 refillAsync on exit.
- `DictationController.runStreamingCleanup` — the whole guarded flow: F1 didStream
  flag bypasses the shared inject; F5 gen-check before each commit; F6/F7
  lastInjected = exact committed bytes, set on cancel too; F8 first-chunk trim;
  F12 primary-Apple-only (fallback/Ollama non-streaming); F13 zero-chunk single
  paste; degrade on F10/F11.
- `Settings.streamingInjection` (default on) to toggle it off per-app if paste
  misbehaves. Phase 0 prewarm fix folded in.
- `--stream-test <wav>` diagnostic.

Verification: release build clean; `--stream-test jfk.wav` shows cumulative
snapshots (600→885ms) and correctly NO early-commit on a single-sentence utterance.
Installed to /Applications; Pro license intact (hasPro=true). REMAINING GATE:
real-paste behavior (F1–F10) has no automated test — user must verify incremental
paste in a plain field, a rich editor (Mail), and a code editor, incl. mid-stream
focus change and Esc, before this is trusted for release.
