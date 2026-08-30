# Onyx Scribe

*A black cat that turns your voice into text.*

Fully local dictation for macOS (Apple Silicon), inspired by
[Wispr Flow](https://wisprflow.ai). Hold a hotkey anywhere, speak, release —
cleaned, formatted text is pasted into whatever app you're in.
**No cloud. Audio and text never leave your Mac.**

> Internals note: the codebase, bundle id (`com.todor.flowclone`) and installed
> app path (`/Applications/FlowClone.app`) keep the working name **FlowClone** —
> renaming them would orphan user data and TCC permission grants. Everything
> user-facing says Onyx Scribe.

```
Hotkey ▸ Mic ▸ [Parakeet/Whisper ASR · Neural Engine] ▸ raw text ▸ [Ollama LLM] ▸ clean text ▸ paste
         ~110ms ASR                                              ~1s cleanup
```

Two-stage pipeline (same shape as Wispr Flow's ASR → fine-tuned-Llama cloud stack,
but local): a CoreML ASR engine transcribes, a local LLM served by Ollama cleans
up — fillers, false starts, grammar, punctuation, formatting. **Ollama does not do
ASR**; the two stages are independent engines.

## Requirements

- Apple Silicon Mac, macOS 14+
- [Ollama](https://ollama.com) running with a ≥8B model pulled (default: `gemma4:latest`)
  — models under ~9B tend to *answer* the transcript instead of cleaning it
- Xcode Command Line Tools (`swift build` is enough; no Xcode needed)

## Build & install

```bash
cd FlowClone
./scripts/build-app.sh    # builds release, signs, installs /Applications/FlowClone.app
open /Applications/FlowClone.app
```

Grant **Accessibility** (hotkey + paste) and **Microphone** when prompted.
After granting Accessibility, quit and relaunch the app.

The 🎤 menu shows live permission status (✅/❌ with click-through to Settings).

### Signing / the permission gotcha

Ad-hoc signatures change every build, and macOS then *silently* invalidates the
Accessibility grant while still showing it checked. Fix: remove FlowClone from the
Accessibility list (−), re-add it (+). Permanent fix: create a self-signed
codesigning certificate named **FlowClone Dev** (Keychain Access → Certificate
Assistant → Create a Certificate → Code Signing) — `build-app.sh` picks it up
automatically and grants then survive rebuilds.

## Usage

| Gesture | Action |
|---|---|
| **Hold Right ⌥**, speak, release | Dictate → cleaned text pastes at the caret |
| **Double-tap Right ⌥** | Lock hands-free recording; tap again to stop & paste |
| Say **"scratch that"** / "delete that" | Removes the last dictation |
| Say **"make that a bullet list" / "make it more formal" / "all caps" / …** | Rewrites the last dictation in place |

Voice commands only fire on short, unambiguous phrases while you're still in the
same app with the caret untouched — ambiguous input is always treated as dictation.

Menu bar: AI cleanup on/off, engine switch, launch at login, recent dictations
(click to copy), vocabulary and per-app profile editors.

## Configuration

Settings persist via `defaults` under `com.todor.flowclone`:

```bash
defaults write com.todor.flowclone ollamaModel gemma4:12b   # cleanup model
defaults write com.todor.flowclone language bg              # ASR language pin (default en)
defaults write com.todor.flowclone asrEngine whisper        # parakeet (default) | whisper
```

**ASR engines** (menu-switchable):
- `parakeet` — NVIDIA Parakeet TDT 0.6B v3 via FluidAudio, ~110ms, best for natural/disfluent speech
- `whisper` — Whisper large-v3-turbo via WhisperKit, max accuracy (5.2% WER), ~0.6GB download on first switch

**`~/.flowclone/vocabulary.txt`** — personal dictionary, one entry per line:
- plain lines (`Kubernetes`) are hints to the cleanup LLM
- `wrong => right` lines are literal case-insensitive replacements applied to the
  raw transcript before the LLM sees it

**`~/.flowclone/profiles.json`** — per-app cleanup instructions keyed by app name:
`{"Slack": "Casual tone is fine. Keep it short."}`

## Testing

```bash
# Headless pipeline test (no permissions needed)
say -v Samantha -o /tmp/t.aiff "um so like send me the uh report by friday"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/t.aiff /tmp/t.wav
./.build/debug/FlowClone --test /tmp/t.wav
```

## Repo layout

- `FlowClone/` — the Swift app (SPM package)
- `PLAN.md` — research-backed technical plan this was built from
- `prompts/cleanup_system_prompt.md` — the LLM cleanup prompt, with design rationale
- `docs/` — benchmark results (cleanup model bake-off)

## Acknowledgments

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet CoreML),
[WhisperKit](https://github.com/argmaxinc/WhisperKit), [whisper.cpp](https://github.com/ggml-org/whisper.cpp)-era
research, and [Ollama](https://ollama.com). Architecture informed by open-source
dictation apps: [Handy](https://github.com/cjpais/Handy), [VoiceInk](https://github.com/Beingpax/VoiceInk),
[FoxSay](https://github.com/skulkworks/foxsay), [Whispering](https://github.com/EpicenterHQ/epicenter).
