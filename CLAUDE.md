# Onyx Scribe (codebase: FlowClone)

## Design Context

- **PRODUCT.md** (repo root) is the strategic design brief — register, users,
  brand personality, anti-references. **DESIGN.md** is the visual system
  (North Star: "Edge-Lit Onyx"; tokens mirror `FlowClone/Sources/FlowClone/Theme.swift`).
  Both are binding for any UI work; read them before designing or restyling.
- The user-facing name is **Onyx Scribe**; internals (SPM target, bundle id
  `com.todor.flowclone`, data dir, `/Applications/FlowClone.app`) deliberately
  keep **FlowClone** — renaming them orphans user data and TCC grants.
- Verify UI changes with the snapshot harness (run from `FlowClone/`):
  `--hub --snapshot-all <dir>`, `--onboard --snapshot-onboard <dir>`,
  `--pill-snapshot <dir>`, `--icon-snapshot <path>`; pipeline changes with
  `--test <wav>` and `swift run FlowCloneChecks`.

## Shared with iOS (Onyx Scribe Mobile)

- `FlowClone/Sources/FlowCloneCore` is consumed by the iOS port at
  `../Onyx Scribe Mobile` (ScribeKit depends on `../../Onyx Scribe/FlowClone`
  by relative path). Do not rename or move the `FlowClone` folder or this repo.
- Treat FlowCloneCore's public API as a contract used by the iPhone app:
  `CleanupPromptBuilder`, `CleanupPromptInputs`, `CaretContext`, `TonePreset`,
  `CleanupPassPolicy`, `LanguageCleanupGuidance`, `VocabularyCorrector`,
  `CommandDetector`, `TextCleanup`. Keep additions additive; if a signature
  must change, update the iOS package in the same change.
- Prompt text lives only in `FlowCloneCore/CleanupPromptBuilder.swift`; the
  macOS `CleanupPrompt.swift` is a thin adapter that gathers settings.
- After changing FlowCloneCore, verify both sides:
  `cd FlowClone && swift build && swift run FlowCloneChecks`, then
  `cd "../Onyx Scribe Mobile" && scripts/test.sh` (needs the Xcode 27 beta;
  `scripts/env.sh` there points at it).
