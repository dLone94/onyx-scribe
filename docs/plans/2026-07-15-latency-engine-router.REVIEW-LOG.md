# Plan Review Log: Reduce dictation latency — route English cleanup to Apple
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Grill resolved:
- Latency is POST-speech (release → text), not the start-side gesture delay.
- Config: Parakeet (fast ASR) + Ollama cleanup; the slow step is Ollama/gemma cleanup.
- Shape: CONSISTENTLY ~1s slower than "used to be" (not cold-start spikes) → warm Ollama is
  steadily slower than the prewarmed Apple engine.
- Preference: SPEED for English → route English cleanup to Apple Intelligence; keep Ollama for
  non-English (Bulgarian).
- Root cause: `DictationController.cleanupEngine(for:)` L25 prefers a ready Ollama for every
  language; the Ollama daemon was started this session, so English silently rerouted off Apple.

Reviewer model: gpt-5.6-sol (medium) — codex-cli 0.144.1.

## Round 1 — Codex

9 findings (VERDICT: REVISE); root cause confirmed (L25 from commit 1d52909 replaced
English→Apple with prefer-warm-Ollama):
1. Conflicts with the pending Bulgarian routing — explicit "apple" sends bg to Apple FM, so
   "no conflict" is false. Fix: build the pure EngineRouter now; decide bg outranks apple.
2. Auto-language doesn't preserve bg→Ollama under Whisper (default transcribeAuto reports
   first candidate; Whisper decodes with Settings.language) — bg can be labeled en → Apple.
   Fix: forced-candidate Whisper arbitration, or keep Whisper English on Ollama.
3. Menu doesn't follow routing — resolves against Settings.language, not per-utterance detected;
   under auto it can advertise Apple while bg uses Ollama. Fix: show both routes.
4. Menu falsely reports Apple healthy under explicit-apple even when Apple unavailable. Fix:
   gate on AppleCleanup.isAvailable; show fallback.
5. Settings picker auto label stale ("Ollama when running, else built-in"). Fix: relabel.
6. Failover observability wrong — logs originally-selected engine + combined latency. Fix:
   track/log the engine that produced the output + its own timing.
7. --test inconsistent with live path (no failover). Fix: shared cleanup-with-failover fn.
8. Latency comparison asymmetric (Apple gets a warmed 2nd pass; changing Settings mutates
   state). Fix: non-persistent --cleanup-engine override; warmed median over identical input.
9. No routing regression test; a future edit could restore L25. Fix: pure EngineRouter + tests.

### Claude's response
Accepted all 9; #1 reshaped the plan (build the shared pure EngineRouter now):
- #1/#9: pure `EngineRouter.cleanupEngine(languageCode:preference:appleAvailable:ollamaReady:
  detectionReliable:)` in FlowCloneCore, subsuming the Bulgarian plan's router step; truth-table
  tested. `non-English → Ollama` outranks the explicit "apple" preference (fixes bg→Apple). (§1,§6)
- #2: `detectionReliable = !autoLanguage || engine is Transcriber`; auto English→Apple only when
  reliable, so Whisper+auto English stays on Ollama (safe for en+bg). Real Whisper arbitration
  stays the Bulgarian plan's deferred fallback. (§1)
- #3/#4: menu shows both routes under auto-language + gates Apple health on isAvailable with a
  fallback. (§3)
- #5: relabel the picker's auto description. (§4)
- #6: track+log the engine that actually produced the cleaned text + its timing. (§5)
- #8: non-persistent `--cleanup-engine` override; N warmed passes, median, identical transcript. (§2)
- #7: partial — the benchmark INTENTIONALLY isolates a single engine (fair A/B needs no failover);
  --test/override labeled isolated diagnostics; full shared-failover extraction tracked as a
  backlog refactor (out of scope) with logged rationale.
Rejected: none (only #7 partially scoped, with reason).

## Round 2 — Codex

4 findings + 1 low (VERDICT: REVISE):
1. High — static `cleanupEngine(for:)` can't access instance `engine`, so `engine is Transcriber`
   is impossible as written. Fix: make reliability an explicit param the caller supplies.
2. High — `detectionReliable` protects only auto, not explicit Apple; Whisper+auto bg mislabeled
   `en` then hits Apple via the explicit-apple rule. Fix: put `!detectionReliable → .ollama`
   before the explicit-Apple rule.
3. Medium — menu text still false for Whisper+auto / explicit Ollama / Apple unavailable. Fix:
   compute displayed routes by calling EngineRouter with actual inputs.
4. Medium — "N warmed passes" not guaranteed for Apple's async session pool; a pass can grab a
   cold session before prewarm finishes. Fix: awaitable warm barrier before each recorded Apple pass.
Low — `ollamaReady` is an unused router input/dimension. Fix: remove it.

### Claude's response
Accepted all:
- #1: `detectionReliable = !Settings.autoLanguage || Settings.asrEngine != "whisper"` — derived
  from Settings, so the router stays pure and every caller can compute it (no instance access). (§1)
- #2: reordered — `!detectionReliable → .ollama` now precedes the Apple rules, so it overrides even
  an explicit Apple preference (safety in the niche Whisper+auto config). Rules simplify to 4. (§1)
- #3: menu computes route(s) via EngineRouter with real inputs (twice under auto-language). (§3)
- #4: benchmark inserts an awaitable warm/settling barrier before every recorded Apple pass. (§2)
- low: dropped `ollamaReady` from the router signature + truth table. (§1,§6)
Rejected: none.

## Round 3 — Codex

3 inconsistencies (VERDICT: REVISE):
1. High — `--cleanup-engine apple` isn't a forced benchmark: under Whisper+auto, rule 3 overrides
   explicit Apple → Ollama, contradicting the isolated Apple benchmark. Fix: the override must
   bypass routing.
2. Medium — CLI reliability can't come from `Settings.asrEngine`: `--test` picks Whisper from a
   CLI arg independent of the persisted setting. Fix: `--test` derives reliability from the engine
   instance it constructs.
3. Medium — picker label still false for Whisper+auto English ("Apple for English"). Fix:
   "Apple for reliably detected English; otherwise Ollama."

### Claude's response
Accepted all 3:
- #1: `--cleanup-engine` now BYPASSES EngineRouter and invokes the named engine directly (after
  validating availability), so a forced-Apple benchmark can't be rerouted. (§2)
- #2: reliability is computed by each caller from its ACTUAL engine — live/menu from Settings
  (valid: live engine tracks Settings, swaps block dictation), `--test` from its CLI-constructed
  engine (`!useWhisper`), calling EngineRouter directly. (§1)
- #3: label → "Auto — Apple for reliably-detected English (Parakeet); Ollama for other languages
  or Whisper." (§4)
Rejected: none.

## Round 4 — Codex

2 doc inconsistencies (VERDICT: REVISE):
1. Medium — picker label false for PINNED English + Whisper: `autoLanguage==false` ⇒
   `detectionReliable` true ⇒ Apple, but the label said Whisper→Ollama unconditionally. Fix:
   "Apple for pinned English or Parakeet-detected English; Ollama otherwise."
2. Low — key-decision bullet said reliability is derived from Settings for every caller,
   contradicting §1 (`--test` uses its constructed engine). Fix: state live/menu use Settings,
   CLI uses its constructed engine.

### Claude's response
Accepted both (internal-consistency fixes to my own prose):
- #1: label corrected to "Auto — Apple for pinned English or Parakeet-detected English; Ollama
  otherwise." (§4)
- #2: key-decision bullet now says live/menu derive reliability from Settings, CLI/`--test` from
  its constructed engine. (Key decisions)
Rejected: none.

## Round 5 — Codex

No remaining plan-level blockers. "Routing precedence, caller-specific reliability, menu and
picker messaging, isolated benchmark, warm-session control, failover observability, Bulgarian
compatibility, and truth-table verification are now internally consistent with the actual code."

VERDICT: APPROVED

---
**Converged at round 5 (the MAX_ROUNDS cap).** Codex raised 18 findings across 5 rounds
(9 + 4 + 3 + 2, plus 1 low); Claude accepted all, rejected none (only #7-R1 partially scoped
with rationale). It verified the root cause via `git blame` (commit `1d52909`), turned a
one-line hack into a pure, tested `EngineRouter` that unifies with the pending Bulgarian plan,
and closed real correctness holes (explicit-apple sending Bulgarian to Apple FM;
Whisper+auto mis-routing) plus a skewed benchmark.
