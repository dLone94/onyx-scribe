# Onyx Scribe landing page

Self-contained, single-file landing page on the app's "Edge-Lit Onyx" identity
(committed dark; real Fraunces + Onyx Cat inlined — no external requests, CSP-safe).

- `index.template.html` — source, with `__FRAUNCES_B64__` / `__ICON_B64__` placeholders.
- `build.sh` — inlines the font + icon → `index.html` (the deployable file).
- `index.html` — generated; deploy this anywhere static.

## Before launch (owner)
- Set the real price (currently placeholder **$9/mo · $72/yr**).
- Wire the Download and Subscribe links to the notarized DMG + checkout URL.
- Trademark check "Onyx Scribe"; confirm attribution (Parakeet CC-BY-4.0, WhisperKit MIT,
  FluidAudio Apache-2.0, Fraunces OFL).
