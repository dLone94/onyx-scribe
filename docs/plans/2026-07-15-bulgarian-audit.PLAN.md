# Plan: Fix Bulgarian/Russian language mixing + full re-audit
_Locked via grill — by Claude + Todor. Revised after Codex Rounds 1–2._

## Goal
Fix "Bulgarian dictation comes out mixed with Russian" by **first attributing the stage**
with a diagnostic, then applying a **language-scoped** cleanup normalization (deterministic,
`bg`-only) — pivoting if the diagnostic shows cleanup itself is the culprit. Plus a full
triaged re-audit of the whole app including the uncommitted transform feature (committed
first). Correctness is judged by **Todor (a Bulgarian speaker) reviewing a real sample** plus
expected-transcript fixtures; the `ы/э/ё` script markers are **telemetry, not the oracle**
(common Russian intrusions like это/что/сейчас carry no markers).

## Approach

### Phase 0 — Commit prior work first (literal path manifest, Codex R1 #11 / R2 #6)
1. On `main`, so branch first. The prior session's work is one logically-approved unit (audit
   fixes + the transform feature) that **shares files** (e.g. `CleanupPrompt.swift`,
   `OllamaClient.swift` carry both the sanitizer audit-fix AND transform additions), so it is
   one commit — but from an **explicit, literal repo-root-relative path list**, not a category
   (Codex R3 #2). Stage EXACTLY:
   - Sources (modified): `FlowClone/Sources/FlowClone/AppDelegate.swift`,
     `FlowClone/Sources/FlowClone/AudioRecorder.swift`,
     `FlowClone/Sources/FlowClone/CleanupPrompt.swift`,
     `FlowClone/Sources/FlowClone/DictationController.swift`,
     `FlowClone/Sources/FlowClone/FoundationModelCleanup.swift`,
     `FlowClone/Sources/FlowClone/HotkeyManager.swift`,
     `FlowClone/Sources/FlowClone/OllamaClient.swift`,
     `FlowClone/Sources/FlowClone/StyleLearning.swift`,
     `FlowClone/Sources/FlowClone/TextInjector.swift`,
     `FlowClone/Sources/FlowClone/main.swift`,
     `FlowClone/Sources/FlowCloneChecks/main.swift`,
     `FlowClone/Sources/FlowCloneCore/HotkeySpec.swift`,
     `FlowClone/Sources/FlowCloneCore/Licensing.swift`,
     `FlowClone/Sources/FlowCloneCore/VocabularyCorrector.swift`.
   - Sources (new): `FlowClone/Sources/FlowClone/SelectionEditor.swift`,
     `FlowClone/Sources/FlowCloneCore/GestureRecognizer.swift`,
     `FlowClone/Sources/FlowCloneCore/PromptSanitizer.swift`,
     `FlowClone/Sources/FlowCloneCore/SelectionCommand.swift`.
   - Docs: `docs/AUDIT.md`, `docs/SMOKE-TEST.md`, `docs/GO-TO-MARKET.md`,
     `docs/plans/2026-07-11-transform-feature.PLAN.md`,
     `docs/plans/2026-07-11-transform-feature.REVIEW-LOG.md`.
   - **Exclude:** generated `graphify-out/**`, unrelated `web/**` pricing edits, and this
     task's new root `PLAN.md`/`PLAN-REVIEW-LOG.md`. Inspect `git diff --cached` before commit;
     the message notes it bundles the prior audit fixes + transform feature (shared files).

### Phase 1a — Reproduce & attribute the stage FIRST (the gate, Codex R1 #4)
2. Build the diagnostic before any corrector; the user then supplies a Bulgarian sample
   (`bg.wav`, or a raw-text repro). No BG audio exists in-repo — a real gate, not an assumption.
3. `CyrillicGuard` (pure, FlowCloneCore, unit-tested): flags **Russian-script markers** — the
   letters `ы`, `э`, `ё` (uppercase too; NFC-normalized + case-folded) absent from Bulgarian.
   It only FLAGS (returns markers/positions), never rewrites (bg/ru share nearly every letter).
   **No word list** (dropped — inflection misses + false flags). Markers are a **signal, not a
   correctness oracle**: legit quoted Russian or a Russian name is an *expected* flag.
4. Add a per-call forced-language ASR API so the diagnostic is deterministic and side-effect
   free (Codex R2 #5): `ASREngine.transcribe(_:languageCode:)`. **Both** engines force it —
   Parakeet via `transcribeDetailed(languageCode:)`, **Whisper via `DecodingOptions(language:
   languageCode)`** (it already threads a language there today; only a genuinely-unable engine
   would get the ignoring default) (Codex R3 #1). Then extend `--test`: `--test <wav> --lang
   <code>` uses that API and **never writes `UserDefaults`**; print the forced/detected
   language; run `CyrillicGuard` on **both raw ASR and cleaned** output printing markers for
   each; **exit nonzero** on any engine error (today it exits 0); label it explicitly an
   isolated ASR/LLM diagnostic (Codex R1 #9,#10).
5. Add a **text-only** diagnostic for a raw-text repro (Codex R3 #3): `--cleanup-test <text>
   --lang <code>` runs cleanup on the given text (no ASR), printing `CyrillicGuard` markers on
   the input and the cleaned output — so a text fixture can exercise/attribute the cleanup
   stage. A text repro may only be attributed to Parakeet if its **provenance is captured raw
   ASR output** (stated by the user); otherwise it only tests cleanup.
6. **Attribution decision**: from `--test bg.wav --lang bg` (or `--cleanup-test` on captured
   raw ASR), markers/Russian in RAW → Parakeet is the source (the fix below applies). RAW clean
   but CLEANED has Russian → cleanup is *introducing* it → **pivot** to a restraint prompt
   ("keep Bulgarian, never Russify"). Todor confirms which by reading raw vs cleaned.

### Phase 1b — Language-scoped cleanup normalization (the fix)
7. Thread the captured `detectedLang` into cleanup, not model self-ID (Codex R1 #1). New pure
   `LanguageNormalization.cleanupFragment(forLanguageCode:)` in FlowCloneCore returns the
   Bulgarian fragment ONLY for `"bg"`, empty otherwise — unit-tested for scoping.
   `CleanupPrompt.situational(..., languageCode:)` appends it per-call (keeps Apple's prewarmed
   `stableSystem()` cache key valid); `OllamaClient.cleanup(..., languageCode:)` passes it;
   `DictationController` passes `detectedLang`.
8. **Extract engine routing into a pure FlowCloneCore function** (Codex R2 #3):
   `EngineRouter.cleanupEngine(languageCode:preference:ollamaReady:appleAvailable:)`, which
   returns `.ollama` for `bg` BEFORE honoring the preference (fixes the real latent bug where
   an explicit `"apple"` setting sent Bulgarian to Apple FM — Codex R1 #2).
   `DictationController.cleanupEngine(for:)` delegates to it; the truth table is unit-tested in
   `FlowCloneChecks` (incl. explicit-apple + bg).
9. The Bulgarian fragment is a **restrained normalizer** (Codex R1 #7): fix only words clearly
   meant as Bulgarian that the ASR rendered in Russian; **preserve verbatim** quoted text,
   mixed-language content, code, URLs, numbers, and proper nouns; never translate.
10. Short-utterance BG exception (Codex R1 #3): the `wordCount < 5` fast-path skips the LLM; for
   a paid, cleanup-enabled Bulgarian utterance, do NOT skip. Document that pre-cleanup
   voice-command detection on a corrupted BG command can't be rescued (edge case).
11. Translation scoping by CODE, not name (Codex R2 #4): thread `targetCode` through the
    translate APIs (`OllamaClient.translate(..., targetCode:)`, `CleanupPrompt.translateSystem(
    toName:targetCode:)`) and gate the "standard Bulgarian" restraint on `targetCode == "bg"`;
    keep `targetName` for prose only.

### Phase 2 — Full whole-codebase re-audit (triaged)
12. Adversarial static review of the ENTIRE app including transform code; findings triaged
    **ship-blocking / feature-blocking / backlog**; fix the first two, append backlog to
    `docs/AUDIT.md`. Bounded.
13. Re-run `FlowCloneChecks` + `swift build`; re-verify UI snapshots.

## Key decisions & tradeoffs
- **Attribute the stage before committing to the corrector** — fixing blind can hide/worsen a
  cleanup-introduced fault.
- **Markers are telemetry; the correctness oracle is a Bulgarian speaker + expected-transcript
  fixtures.** Marker-absence alone can't prove standard Bulgarian (Codex R2 #1) and would
  wrongly fail preserved Russian names/quotes (Codex R2 #2).
- **Language scoping is programmatic** (`detectedLang == "bg"`, `targetCode == "bg"`), never
  model-judged — the bug is the model confusing bg/ru.
- **Engine routing + language-fragment selection are pure FlowCloneCore functions** so they're
  testable in the FlowCloneCore-only assertion target (Codex R2 #3).
- **`bg` hard-routes to Ollama** (fixes a real latent Apple-FM bug).
- **Detector = 3 script markers only, diagnostic-only, no rewriting.**
- **Restrained normalizer + preservation fixtures** guard over-correction.
- **Verbatim/free-tier Bulgarian stays raw** (grill decision).
- **Commit prior work first from a literal manifest** excluding generated/unrelated files.

## Risks / open questions
- **Needs a real Bulgarian sample + Todor's review** — no BG audio in-repo; end-to-end
  correctness can't be judged by markers alone.
- **gemma may over/under-correct** — validated on the real sample, prompt tuned if needed.
- **If attribution shows cleanup is the source**, pivot to a restraint prompt (branch defined;
  wording depends on the sample).
- **Verbatim/short-command BG** limits documented, not fully closed.

## Out of scope
- Routing Bulgarian to Whisper (deferred fallback if a raw-decode fault survives cleanup).
- Mechanical auto-correction on the no-LLM path.
- The transform on-device smoke test (separate pending gate — NOT claimed done here).
- New ASR/cleanup engines; re-architecture.

## Verification (honest gates, Codex R1 #12 / R2 #1,#2)
- **Done headlessly this pass:** `CyrillicGuard` marker tests (incl. preserved-name/quote
  cases as *expected* flags), `LanguageNormalization.cleanupFragment` scoping test,
  `EngineRouter` truth-table test (incl. explicit-apple + bg), `swift build`, `FlowCloneChecks`
  green, UI snapshots.
- **Release gates NOT claimed complete:** (a) Todor reviews a real Bulgarian sample and
  confirms cleaned output is standard Bulgarian — markers on ASR-substitution fixtures drop
  raw→cleaned, while markers on preserved-content fixtures remain (expected, compared per
  fixture); (b) the transform on-device smoke checklist.
