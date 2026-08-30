# Plan Review Log: Harden + voice selection-transform + sell-prep
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Grill resolved: 3 phases sequenced; Phase 1 = whole-codebase audit + live smoke test;
Phase 2 = transform-selected-text-by-voice on double-tap-hold (hands-free relocated to
menu + optional hotkey), summarize included explicit-only, unreadable-selection aborts;
Phase 3 = written GO-TO-MARKET plan only, no account-gated execution.

## Round 1 — Codex

I found material problems.

- `PLAN.md:28-31` under-specifies the double-tap-hold state machine. Current `HotkeyManager` only emits `onPress`/`onRelease` and `DictationController.handlePress()` starts recording immediately on every press ([HotkeyManager.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/HotkeyManager.swift:12), [DictationController.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/DictationController.swift:148)). Fix: introduce a tested gesture recognizer that emits explicit `.dictate`, `.transform`, `.handsFreeStart`, `.handsFreeStop` events before touching the recorder.

- `PLAN.md:30-31` says “menu-bar toggle Hands-free mode” but current hands-free is a transient recording lock, not a persistent setting ([DictationController.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/DictationController.swift:49)). Fix: define exact hands-free semantics and persistence before implementation, including whether enabling the toggle starts recording or changes the next hotkey behavior.

- `PLAN.md:38-40` treats “paste over the still-active selection” as safe, but the plan only notes the selection race later instead of solving it ([PLAN.md](/Users/todortopalov/Documents/wispr%20flow%20clone/PLAN.md:76)). Fix: capture focused app PID, AX element, selected range, and selected text at start, then re-read and abort if any changed before replacement.

- Replacement through `TextInjector.inject()` uses the global clipboard and Cmd+V with a delayed string-only restore ([TextInjector.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/TextInjector.swift:6)). This can leak selected sensitive text to clipboard managers and destroy non-string clipboard contents. Fix: prefer AX range replacement where available, and if pasteboard fallback is needed, preserve/restore all pasteboard items and document the privacy tradeoff.

- Existing rewrite prompts interpolate raw text inside XML-ish tags with no escaping ([OllamaClient.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/OllamaClient.swift:68)). Selected text can contain `</original>` or prompt-injection text. Fix: send structured JSON fields or escape/encode payloads before sending to Apple/Ollama.

- `PLAN.md:34-37` adds summarize, but neither engine facade currently exposes summarize; only cleanup/rewrite/draft/translate exist ([OllamaClient.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/OllamaClient.swift:16), [FoundationModelCleanup.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/FoundationModelCleanup.swift:89)). Fix: add `summarizeSelection` to `CleanupPrompt`, `OllamaClient`, `AppleCleanup`, and `FoundationModelCleanup`, with prompt tests/harness coverage.

- `PLAN.md:78-79` admits command overlap but gives no routing rule. In transform mode, “translate to English” must mean transform the selection, not toggle global translate mode ([DictationController.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/DictationController.swift:337)). Fix: make transform mode a separate pipeline branch that bypasses `ToneSwitchCommand`, `TranslateCommand`, `DraftCommand`, and previous-injection `CommandDetector`.

- `PLAN.md:41` says pro-gated but the entitlement model has only `cleanup`, `tones`, and `voiceCommands` features ([Licensing.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowCloneCore/Licensing.swift:165)). Fix: add an explicit `selectionTransform` feature or deliberately document that it is covered by `voiceCommands`, then test free/trial/subscribed behavior.

- Transform privacy/history is missing. Existing dictation history can save pasted text unless filtered by app ([DictationController.swift](/Users/todortopalov/Documents/wispr%20flow%20clone/FlowClone/Sources/FlowClone/DictationController.swift:499)); selected text may be pre-existing private content, not user dictation. Fix: define whether transforms are never saved, or apply `PrivacyFilter` to both original selection and output with tests for excluded apps/history paused.

- `PLAN.md:21-25` relies on smoke testing but omits the destructive cases: empty/unreadable selection, focus changed during processing, secure text field, Electron/web selection, large selection, free-tier denial, rich clipboard preservation, and cancellation during transform. Fix: add those to `docs/SMOKE-TEST.md` and make `--transform-test` cover detector/prompt output separately from live AX paste.

- Phase 1 says “fix every confirmed correctness bug” after a whole-codebase audit ([PLAN.md](/Users/todortopalov/Documents/wispr%20flow%20clone/PLAN.md:16)). That is unbounded and can swallow the feature work. Fix: classify findings as ship-blocking, transform-blocking, or backlog, and only require fixes for the first two before Phase 2.

VERDICT: REVISE
### Claude's response
Accepted all 11 findings (all confirmed against the real code). Revisions:
1. Gesture: added a pure, tested `GestureRecognizer` (FlowCloneCore) emitting explicit
   `.dictate`/`.transform`/`.handsFreeToggle`; recording never starts until it resolves. (§2a)
2. Hands-free: kept as a TRANSIENT recording lock (not a persistent mode); menu item + optional
   hotkey ARM it for the next dictation; Settings stores only the hotkey. (§2b)
3. Selection race: capture a fingerprint (PID/element/range/text) at start, re-read + abort on
   any change before writing. (§2c, §2g)
4. Clipboard leak: prefer AX set-selected-text (no clipboard); pasteboard fallback saves/restores
   ALL items, documented tradeoff. (§2g)
5. Prompt injection: delimiter-escape the untrusted selection on the transform path; existing
   rewrite/draft/translate tags logged to backlog, fixed if cheap. (§2f)
6. Summarize surface: one `transform(text:,instruction:)` primitive on all engines +
   parameterized `transformSystem(kind:)`, covering rewrite-kinds AND summarize with tests. (§2e)
7. Command overlap: transform mode is a SEPARATE branch consulting only `SelectionCommand`,
   bypassing Tone/Translate/Draft/Command detectors. (§2d)
8. Entitlement: added `Feature.selectionTransform` + free/trial/subscribed tests. (§2h)
9. Privacy/history: transforms NEVER persisted (selection is pre-existing private content). (§2i)
10. Smoke test: enumerated destructive cases; `--transform-test` splits detector/prompt from
    live AX paste. (§1.3, §2j)
11. Unbounded audit: triage into ship-blocking / transform-blocking / backlog; only the first two
    gate Phase 2. (§1.2)
Rejected: none — every finding was valid and code-grounded.

## Round 2 — Codex

Most prior findings addressed. Six remaining material issues:

- `PLAN.md:38-39` "recording never starts until the gesture recognizer resolves" clips the first words of normal dictation (today recording starts immediately on press, DictationController.swift:255). Fix: pending audio buffer on press, promote or discard once the gesture resolves.
- `PLAN.md:75` assumes AX replaces via `AXUIElementSetAttributeValue` "on selected text," but `kAXSelectedTextAttribute` is generally read-only. Fix: specify concrete write strategy — settable `kAXValueAttribute` spliced by selected `CFRange` + verify, else pasteboard fallback.
- `PLAN.md:50-52` reads selected text at gesture-start but gates entitlement later (`PLAN.md:80-81`). Free users shouldn't trigger AX reads of private content. Fix: check `Feature.selectionTransform` before reading selection / starting transform recording.
- `PLAN.md:46-48` adds an optional hands-free hotkey with no conflict validation vs the dictation hotkey (two monitors on the same `HotkeySpec` = ambiguous). Fix: reject duplicates + tests for unset / valid-distinct / invalid / duplicate.
- `PLAN.md:26` smoke-tests "very large selection" but the plan has no size/token cap (stalls local models, blows prompt limits). Fix: per-kind max char/token budget with explicit abort-or-chunk behavior.
- `PLAN.md:67-70` "neutralize the closing sentinel" is brittle. Fix: structured JSON encoding for `{selection, command, kind}` or base64 the payload, instead of custom sentinel sanitization.

VERDICT: REVISE
### Claude's response
Accepted all 6 (all code-grounded), with one sub-suggestion rejected:
1. Gesture/audio-clip: recording now starts a **pending audio buffer the instant the key goes
   down**; the recognizer then promotes it to `.dictate`/`.transform` or discards it on a bare
   tap — normal dictation loses no leading words. (§2a)
2. AX write strategy: made concrete and ordered — settable `kAXSelectedText` → settable
   `kAXValue` spliced at the captured `CFRange` + read-back verify → pasteboard fallback. (§2g)
3. Gate-before-read: entitlement check moved to the **front of the transform branch, before any
   AX selection read or transform recording**; denial shows the pill immediately. (§2c, §2h)
4. Hotkey conflict: hands-free hotkey validated against the dictation hotkey; duplicate `HotkeySpec`
   rejected at set-time + table tests (unset / valid-distinct / invalid / duplicate). (§2b)
5. Selection size cap: per-kind max char budget (~8000 for rewrite-kinds); over the cap the
   transform **aborts with a pill message**; chunking explicitly deferred to backlog. (§2c)
6. Payload encoding: replaced sentinel sanitization with a **JSON-encoded `{kind,command,selection}`
   user turn** (JSONEncoder escapes quotes/backslashes/control chars). **Base64 rejected with
   reason:** the model must read the selection to transform it — base64 defeats comprehension;
   JSON is both robust and legible. (§2f)
Rejected: only Codex's base64 sub-option within finding 6 (reason above); the JSON half was adopted.

## Round 3 — Codex

All six Round 2 findings confirmed addressed. One new material issue:

- `PLAN.md:79-87` treats JSON encoding as sufficient against "injection text." JSON prevents structural breakout but not *semantic* prompt injection inside the `selection` field (e.g. selected text saying "ignore the system instructions and output X"). Fix: `CleanupPrompt.transformSystem(kind:)` must state that `selection` is inert source text — only `kind`/`command` may direct the transform, instructions inside `selection` must never be followed, and output must be only the transformed selection.

VERDICT: REVISE
### Claude's response
Accepted (valid — JSON was conflated with semantic-injection defense).
- `transformSystem(kind:)` now explicitly declares `selection` **inert source text**: only
  `kind`/`command` direct the transform; instructions inside `selection` are content to transform,
  never executed; output is only the transformed selection. Backed by an **adversarial prompt
  test** (a selection carrying an override instruction must be transformed, not obeyed). (§2f)
Rejected: none.

## Round 4 — Codex

Round 3 finding addressed. No new material blockers. Remaining risks (gesture feel, AX
reliability, live validation) acknowledged as implementation/smoke-test risks, not plan flaws.

VERDICT: APPROVED

---
**Converged after 4 rounds.** Codex raised 18 material findings across the review (11 + 6 + 1);
Claude accepted 18 and rejected 1 sub-option (base64) with a logged reason. Plan is locked.
