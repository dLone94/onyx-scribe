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
