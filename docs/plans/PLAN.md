# Local Wispr Flow Clone — Technical Plan (macOS / Apple Silicon)

> Goal: a fully local, offline dictation app that replicates Wispr Flow's base
> functionality — system-wide dictation, AI cleanup/formatting, voice commands,
> and custom vocabulary — using on-device models only (ASR engine + Ollama LLM).
>
> Based on deep research (23 sources fetched, 22/25 claims adversarially verified).

---

## 0. The core architecture (read this first)

Wispr Flow is **two independent stages**, and so is this clone. Per Baseten's
case study, Wispr Flow runs **ASR (speech→raw text) → a fine-tuned Llama model
that cleans and restructures the text** — but it does the Llama stage *in the
cloud* (100+ tokens in <250ms, always online). This clone keeps the identical
shape and swaps cloud Llama for **local Ollama**:

```
Hotkey ▸ Mic capture ▸ [ASR engine] ▸ raw text ▸ [Ollama LLM] ▸ clean text ▸ inject into focused app
        (16kHz mono)   (Whisper/Parakeet)         (cleanup / format / commands)   (pasteboard + Cmd+V)
```

**Key point: Ollama does NOT do speech-to-text.** ASR is a separate on-device
engine (Whisper-family or Parakeet). Ollama only handles the text→text cleanup,
formatting, and command-parsing stage.

---

## 1. Component choices (all verified)

### 1a. ASR engine — recommend Parakeet default + WhisperKit for max accuracy

Benchmarks on a MacBook Pro M4 (24GB):

| Engine | Speed / latency | WER (clean EN) | Notes |
|---|---|---|---|
| **Parakeet TDT 0.6B** (FluidAudio, CoreML/ANE) | **0.19s / ~80ms** | good | Fastest; best on disfluent speech (um/uh/restarts). Default in FoxSay; used by Handy + VoiceInk. |
| WhisperKit Large-v3-Turbo (ANE) | ~200ms, streams | **5.2% (best)** | 0.6GB compressed (OD-MBP, WER within 1% of full). Dual Confirmed/Hypothesis streaming (~0.45s hyp / ~1.7s confirmed). |
| whisper.cpp (GGML/GGUF) | 200–500ms | good | Most portable, huge model range (Small 487MB … Large 1.1GB). |
| mlx-whisper | ~1.0s | good | MLX-native. |

**Decision:** ship **Parakeet (FluidAudio)** as the balanced default, expose
**WhisperKit Large-v3-Turbo** as a "max accuracy" toggle. Parakeet's edge on
disfluent, natural speech makes it especially good for dictation.

### 1b. Cleanup/command LLM — Ollama

- **Gotcha (verified):** models under ~9B tend to *answer* the transcript
  instead of cleaning it. "Gemma2 9B is reliable; Qwen2.5 7B is borderline;
  anything 9B+ behaves predictably." Start with **Gemma 2 9B** or **Qwen 2.5 14B**.
- Model size is your main **quality vs. latency dial**. Test 7B → 9B → 14B.
- Keep the prompt strict: "Rewrite the text; never respond to it."

### 1c. macOS system integration

- **Global hotkey:** `NSEvent.addGlobalMonitorForEvents()` — no Accessibility
  permission required for the hotkey itself. (Alt: Carbon `RegisterEventHotKey`
  via the `HotKey`/`KeyboardShortcuts` Swift packages.)
- **Text injection:** copy transcript → pasteboard, then simulate **Cmd+V via
  `CGEvent`** into the frontmost app. **Requires Accessibility permission.**
- **Distribution:** MUST ship **outside the Mac App Store** (Developer ID,
  non-sandboxed). `CGEventPost` is blocked in the App Store sandbox. Every real
  clone (Handy, VoiceInk, superwhisper, FoxSay) ships this way.

### 1d. Custom vocabulary / biasing

1. **Zero-training (start here):** feed example spellings into Whisper's
   `initial_prompt` (e.g. "Aimee, Shawn" biases away from "Amy, Sean"). Whisper
   copies the *style* of the prompt — it will NOT follow instructions in it.
   Weaker for bare word-lists than for natural sentences containing the terms.
2. **Post-ASR dictionary pass:** a simple find/replace map for your jargon runs
   regardless of engine (Parakeet/whisper.cpp have weaker built-in biasing).
3. **Advanced:** a trained TCPGen contextual-biasing component cut domain-term
   WER ~60% (27.8% → 11.1%) without fine-tuning Whisper. Only if accuracy on
   proper nouns becomes the bottleneck.

---

## 2. Recommended tech stack

Two viable paths (both proven by real clones):

- **Native Swift/SwiftUI (recommended, macOS-only):** best ANE/CoreML access,
  least friction. Model it on **FoxSay** (97% Swift) or **VoiceInk** (99.7%
  Swift). FoxSay pipeline template:
  `Mic → AVAudioEngine (16kHz mono) → TranscriptionEngine → CorrectionPipeline → TextInjector`.
  Packages: FluidAudio (Parakeet), WhisperKit (Whisper), KeyboardShortcuts,
  LaunchAtLogin, Sparkle (updates).
- **Tauri + Rust + React/TS (if you prefer web tooling / cross-platform later):**
  fork **Handy** (~20k stars, MIT) — whisper.cpp + Parakeet, fully offline,
  closest forkable base.

Ollama runs as a local server; call it over `http://localhost:11434`.

---

## 3. Reference implementations to study/fork

| Repo | Stack | Why |
|---|---|---|
| **Handy** (cjpais/Handy) | Tauri/Rust + whisper.cpp/Parakeet | Most forkable; full offline dictation flow. |
| **FoxSay** (skulkworks/foxsay) | Swift + Parakeet/WhisperKit | Cleanest architecture template. |
| **VoiceInk** (Beingpax/VoiceInk) | Swift/SwiftUI + whisper.cpp/Parakeet | Full-featured native app. |
| **Whispering** (EpicenterHQ/epicenter) | whisper.cpp + optional cloud transform | Transform-layer patterns. |
| **clean-transcribe** (itsmevictor) | ASR + LLM cleanup | Two-stage cleanup pattern in isolation. |
| **FluidAudio** | CoreML Parakeet lib | Powers Parakeet-on-ANE for 20+ apps. |

Commercial peers to benchmark against: **superwhisper**, **Wispr Flow**.

---

## 4. Phased build roadmap

### Phase 1 — Core dictation loop (MVP)
- [ ] Menu-bar Swift app skeleton; request Mic + Accessibility permissions.
- [ ] Global hotkey (push-to-talk) via `NSEvent` / KeyboardShortcuts.
- [ ] Mic capture via AVAudioEngine → 16kHz mono buffer.
- [ ] Integrate Parakeet (FluidAudio) → raw transcript.
- [ ] Text injection: pasteboard + Cmd+V via CGEvent into frontmost app.
- **Exit criteria:** hold hotkey, speak, raw text appears in any app.

### Phase 2 — AI cleanup (the "Wispr feel")
- [ ] Run Ollama locally; wire the raw transcript through it.
- [ ] Strict cleanup prompt: strip filler (um/uh/like), fix grammar/punctuation,
      paragraph structure — preserve meaning, never answer.
- [ ] Pick model by latency budget (Gemma 2 9B start point).
- [ ] Toggle: raw vs. cleaned output.
- **Exit criteria:** spoken rambling → clean, formatted text.

### Phase 3 — Voice commands / editing
- [ ] LLM intent-parse the transcript for commands ("delete that", "make a
      bullet list", "make it more formal") vs. literal dictation.
- [ ] Map edit-commands onto already-injected text (re-select + re-inject, or
      pasteboard diff).
- **Exit criteria:** "make that a bullet list" reformats the last utterance.

### Phase 4 — Custom vocabulary & context
- [ ] Personal dictionary UI (names, jargon, product terms).
- [ ] Inject into Whisper `initial_prompt` + post-ASR replacement map.
- [ ] Optional app-aware context (frontmost app name → prompt hint).
- **Exit criteria:** your names/jargon transcribe correctly.

### Phase 5 — Polish
- [ ] WhisperKit "max accuracy" toggle + streaming partials.
- [ ] Settings, model manager, launch-at-login, Sparkle auto-update.
- [ ] Developer ID signing + notarization (outside Mac App Store).

---

## 5. Open questions to resolve during build

1. Head-to-head accuracy/latency/RAM of Parakeet vs whisper.cpp vs WhisperKit
   on *your specific* Mac (chip + RAM) — pick the default engine empirically.
2. Which Ollama model gives the best cleanup quality within your latency budget,
   and the exact prompt template that minimizes hallucinated edits.
3. Command-parsing mechanism: LLM intent-parse vs. keyword grammar, and how to
   apply edits to already-injected text.

---

## 6. Caveats from the research

- WhisperKit numbers are Argmax's own (peer-reviewed) benchmarks — treat as
  best-case.
- No single source benchmarked all engines' accuracy/latency/RAM head-to-head on
  one Apple Silicon config, nor measured Ollama cleanup latency — validate on
  your hardware.
- "How Wispr Flow works internally" is reconstructed from its Baseten case study
  + open-source analogs (it's closed-source/cloud); the *shape* is confirmed, the
  exact internals are inferred.
- The "ship outside Mac App Store" conclusion is a strong engineering inference:
  the sandbox/`CGEventPost` facts are solid and every real clone does it.
