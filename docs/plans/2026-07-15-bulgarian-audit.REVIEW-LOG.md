# Plan Review Log: Full re-audit + fix Bulgarian/Russian language mixing
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Grill resolved:
- Bulgarian bug stage is UNCONFIRMED (user unsure); engine was Parakeet (fast).
- Fix approach = cleanup-stage normalization (strengthen the Bulgarian cleanup prompt so
  gemma corrects Russian intrusions) + a diagnostic detector wired into `--test`.
- Verbatim/free-tier Bulgarian (no LLM) is out of scope — documented limitation.
- Review scope = FULL whole-codebase re-audit, including the uncommitted transform code,
  triaged (ship/feature-blocking fixed, backlog documented).
- Commit the Codex-approved transform feature FIRST (own branch/commit) for diff hygiene.
- Whisper-for-Bulgarian rejected for now (bigger change, slower) — kept as a flagged
  fallback if the diagnostic shows Russian survives cleanup.

Reviewer model: gpt-5.6-sol (medium) — codex-cli 0.144.1.

## Round 1 — Codex

12 findings (VERDICT: REVISE):
1. The "conditional" Bulgarian prompt isn't conditioned by state — `stableSystem()` has no
   language param; relying on gemma to self-identify the language is the exact failure case,
   and adding it globally taxes every language. Fix: thread `detectedLang` and append the BG
   fragment programmatically only for `bg`.
2. "Bulgarian always routes to Ollama" is FALSE — explicit `cleanupEngine == "apple"` returns
   before the lang check, sending BG to Apple FM. Fix: hard-route `bg → .ollama` first + test.
3. Understates BG paths that bypass normalization — cleanup-disabled and `wordCount < 5`
   skip the LLM; voice commands are detected before cleanup. Fix: route paid short BG through
   cleanup and document command limits, or narrow the goal.
4. Commits to a corrector before locating the fault — if cleanup introduces the Russian,
   strengthening it can hide/worsen it. Fix: reproduction + stage attribution first.
5. Letter set correct but reliability overstated — need uppercase/NFC/case-fold, ё↔е,
   legit Russian names/quotes contain the markers. Fix: call them "script markers", normalize.
6. Word list has a spec error (`спасibo` mixes Latin b) + coverage problems (inflections,
   false flags). Fix: drop the word list for the first diagnostic.
7. "Preserve names and numbers" doesn't control over-correction of quotes/code/URLs/proper
   nouns/bilingual text. Fix: explicit preservation rules + negative fixtures.
8. Detector tests don't test the fix — `FlowCloneChecks` imports only `FlowCloneCore`, but
   `CleanupPrompt` is in the app target. Fix: extract the language-scoping decision into core.
9. `--test` isn't the live pipeline and can report false success — always cleans, catches
   errors then exits 0. Fix: print lang, guard raw+cleaned, nonzero on error, label diagnostic.
10. `--test` has no language arg — a BG file can decode under unrelated settings. Fix: add
    `--test <wav> --lang bg` threaded through ASR/routing/prompt/guard.
11. "Commit transform first" isn't coherent without a manifest — tree also has audit fixes,
    web changes, thousands of generated graphify-out changes. Fix: enumerate exact paths,
    exclude generated/unrelated.
12. Verification promises contradict admitted gaps (no BG sample; transform smoke excluded).
    Fix: make the BG repro + transform smoke real release gates, or drop the "complete
    headless verification" claim.

### Claude's response
Accepted ALL 12 (all code-grounded; #6 caught my literal `спасibo` typo; #2 is a real latent
bug). Revisions:
- #1/#8: thread `detectedLang`; new pure `LanguageNormalization.cleanupFragment(forLanguageCode:)`
  in FlowCloneCore (BG fragment only for "bg", empty otherwise), unit-tested for scoping;
  `situational(...,languageCode:)` appends it per-call (keeps Apple prewarm cache valid). (§1b.6)
- #2: hard-route `bg → .ollama` before the preference switch + truth-table test. (§1b.7)
- #3: don't skip cleanup for paid short BG utterances; document pre-cleanup command limits. (§1b.9)
- #4: reproduction + stage attribution is now the FIRST gate; the fix is validated against the
  diagnostic, with an explicit pivot branch if cleanup is the source. (§1a)
- #5/#6: dropped the word list; markers = `ы/э/ё` only, NFC + case-folded, named "script
  markers", legit-name/quote cases tested as expected flags. (§1a.3)
- #7: restrained normalizer with explicit preserve rules (quotes/code/URLs/names/numbers) +
  positive AND preservation fixtures. (§1b.8)
- #9/#10: `--test <wav> --lang <code>`, print forced/detected lang, guard raw AND cleaned,
  nonzero exit on error, labeled an isolated diagnostic. (§1a.4)
- #11: Phase-0 commits from an enumerated path manifest, excluding generated `graphify-out/**`,
  unrelated `web/**`, and the new root plan files; inspect `git diff --cached`. (§0)
- #12: split verification into "done headlessly this pass" vs "release gates NOT claimed
  complete" (real BG sample + transform on-device smoke). (Verification section)
Rejected: none. [see Round 3 below for continuation]

## Round 2 — Codex

6 remaining (VERDICT: REVISE):
1. Marker absence can't prove standard Bulgarian — это/что/сейчас/хорошо have no ы/э/ё. Fix:
   Bulgarian-speaker review / expected transcript; markers = telemetry, not oracle.
2. Zero-marker criterion conflicts with preservation — a correctly-preserved Russian name/quote
   with Ы would fail. Fix: compare cleaned markers against fixture-specific expected markers.
3. Routing truth-table test not implementable — `cleanupEngine(for:)` is on DictationController
   (app target), FlowCloneChecks imports only FlowCloneCore. Fix: extract a pure routing fn to core.
4. Translation scoping lacks a language-code interface — translate takes only the English name,
   so "target is Bulgarian" becomes brittle string matching. Fix: thread `targetCode`.
5. `--lang` needs an engine contract — ASREngine has no forced-language op; Whisper reads
   UserDefaults. Fix: add per-call `transcribe(_:languageCode:)`, no UserDefaults writes.
6. Phase 0 still a category, not a literal manifest; audit fixes (StyleLearning/VocabularyCorrector/
   TextInjector) inclusion ambiguous. Fix: list every staged path literally.

### Claude's response
Accepted all 6:
- #1/#2: correctness oracle is now Todor's review + expected-transcript fixtures; marker tests
  compare against per-fixture EXPECTED markers (drop on ASR-substitution fixtures, remain on
  preserved names/quotes). Markers reframed as telemetry throughout. (Goal, Verification, §1a.3)
- #3: extract `EngineRouter.cleanupEngine(languageCode:preference:ollamaReady:appleAvailable:)`
  into FlowCloneCore; DictationController delegates; truth table unit-tested (incl. explicit-apple
  + bg hard-route). (§1b.7)
- #4: thread `targetCode` through translate APIs; gate the BG restraint on `targetCode == "bg"`;
  keep `targetName` for prose. (§1b.10)
- #5: add `ASREngine.transcribe(_:languageCode:)`; `--lang` uses it and never writes UserDefaults;
  Whisper's default documents no per-call forcing. (§1a.4)
- #6: Phase 0 now enumerates every staged path literally + explicit excludes; message documents
  the shared-file audit+transform bundle. (§0)
Rejected: none.

## Round 3 — Codex

3 implementation contradictions (VERDICT: REVISE):
1. `--lang` still doesn't force Whisper — Whisper already passes a language into
   `DecodingOptions`, so the "can't force per call" claim is wrong. Fix: implement
   `WhisperEngine.transcribe(_:languageCode:)` via `DecodingOptions(language:)`.
2. Manifest paths not literal from repo root (`AppDelegate.swift` omits `FlowClone/Sources/`).
   Fix: list every entry as an actual repo-relative path.
3. A raw-text repro has no executable diagnostic path — `--test` takes a WAV. Fix: add
   `--cleanup-test <text> --lang bg`; require provenance (captured raw ASR) before attributing
   a text repro to Parakeet.

### Claude's response
Accepted all 3 (all correct; #1 corrected my false assumption — verified Whisper threads a
language into DecodingOptions):
- #1: both engines force language; Whisper via `DecodingOptions(language:)`, only truly-unable
  engines get the ignoring default. (§1a.4)
- #2: every manifest path rewritten literal + repo-root-relative. (§0)
- #3: added `--cleanup-test <text> --lang <code>` (cleanup-only, guards input+cleaned);
  text repro attributed to Parakeet only if provenance is captured raw ASR. (§1a.5)
Rejected: none.

## Round 4 — Codex

No new blocking flaw. "Deterministic language scoping, testable routing, honest diagnostic
boundaries, valid repo-relative commit paths, and appropriate human release gates."

VERDICT: APPROVED

---
**Converged after 4 rounds.** Codex raised 21 material findings (12 + 6 + 3); Claude accepted
all 21 and rejected none. Notably surfaced a real latent bug (explicit `cleanupEngine=apple`
sending Bulgarian to Apple FM), a spec typo (`спасibo`), and a false assumption (Whisper can't
force language). Plan is locked.
