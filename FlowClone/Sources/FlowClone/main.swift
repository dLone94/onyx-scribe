import AppKit
import AVFoundation
import CryptoKit
import FlowCloneCore

// FlowClone — local Wispr Flow clone.
// Pipeline: Hotkey (hold Right Option by default) → AVAudioEngine (16kHz mono) → Parakeet ASR
//           → Ollama cleanup → paste into focused app.

// Line-buffer stdout so prints reach log files immediately (not just TTYs).
setvbuf(stdout, nil, _IOLBF, 0)

// Debug: print the composed cleanup system prompt for current settings.
if CommandLine.arguments.contains("--print-prompt") {
    print(OllamaClient().composedSystemPrompt())
    exit(0)
}

// Store-side license minting (and the reference for the eventual webhook):
// `FlowClone --sign-license <email> <monthly|yearly> <days>` signs a key with
// the private half of the embedded public key. Private key from env
// ONYX_SIGNING_KEY (base64) or ~/.flowclone/signing-key.b64. Never ship this key.
//
// DEBUG-ONLY: signing belongs to the store side, never to a shipped binary.
// `scripts/check-release-safety.sh` fails the release if this string survives.
#if DEBUG
if let idx = CommandLine.arguments.firstIndex(of: "--sign-license"),
   CommandLine.arguments.count > idx + 3 {
    let email = CommandLine.arguments[idx + 1]
    let plan = CommandLine.arguments[idx + 2]
    let days = Double(CommandLine.arguments[idx + 3]) ?? 30
    let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".flowclone/signing-key.b64")
    let keyB64 = ProcessInfo.processInfo.environment["ONYX_SIGNING_KEY"]
        ?? (try? String(contentsOf: keyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let b64 = keyB64, let rawKey = Data(base64Encoded: b64),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
        print("❌ No signing key (set ONYX_SIGNING_KEY or ~/.flowclone/signing-key.b64)")
        exit(1)
    }
    let now = Date()
    let claims = LicenseClaims(email: email, plan: plan, issuedAt: now,
                               expiresAt: now.addingTimeInterval(days * 86_400))
    do {
        let data = try claims.encoded()
        let sig = try priv.signature(for: data)
        print(LicenseKey.string(claimsData: data, signature: sig))
    } catch { print("❌ \(error)"); exit(1) }
    exit(0)
}
#endif

// License inspection + activation (legitimate in every build: a user can check
// their entitlement or apply/remove a purchased key from the terminal).
if CommandLine.arguments.contains("--license-info") {
    let e = LicenseModel.shared.snapshot()
    let days = e.trialDaysLeft(now: Date()).map(String.init) ?? "-"
    print("entitlement=\(e)  hasPro=\(e.hasPro)  trialDaysLeft=\(days)  email=\(LicenseStore.licenseString.flatMap { LicenseKeychain.verifier.verify(string: $0)?.claims.email } ?? "-")")
    exit(0)
}
if let idx = CommandLine.arguments.firstIndex(of: "--license-set"),
   CommandLine.arguments.count > idx + 1 {
    let err = LicenseModel.shared.applyLicense(CommandLine.arguments[idx + 1])
    print(err == nil ? "✅ license stored → \(LicenseModel.shared.snapshot())" : "❌ \(err!)")
    exit(err == nil ? 0 : 1)
}
if CommandLine.arguments.contains("--license-clear") {
    LicenseModel.shared.clearLicense()
    print("✅ license cleared → \(LicenseModel.shared.snapshot())")
    exit(0)
}
// Trial-clock manipulation is a test helper ONLY — it must not exist in a
// shipped binary, where it would be a free-trial reset for anyone with a
// terminal. Compiled out of release; the release-safety check enforces it.
#if DEBUG
if let idx = CommandLine.arguments.firstIndex(of: "--trial-set-days-ago"),
   CommandLine.arguments.count > idx + 1 {
    let n = Double(CommandLine.arguments[idx + 1]) ?? 0
    LicenseStore.debugForceFirstLaunch(Date().addingTimeInterval(-n * 86_400))
    print("✅ trial first-launch set \(n) days ago → \(LicenseModel.shared.snapshot())")
    exit(0)
}
#endif

// Diagnostic: `FlowClone --lang-probe audio.wav` transcribes the file forcing
// each script (en=Latin, bg=Cyrillic) and prints text + confidence, to check
// whether confidence discriminates the correct language for auto-detect.
if let idx = CommandLine.arguments.firstIndex(of: "--lang-probe"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let t = Transcriber()
            try await t.load()
            let samples = try loadSamples(URL(fileURLWithPath: path))
            for code in ["en", "bg", "de", "es"] {
                let r = try await t.transcribeDetailed(samples, languageCode: code)
                print(String(format: "[%@] conf=%.4f  text=%@", code, r.confidence, r.text))
            }
            let auto = try await t.transcribeDetailed(samples, languageCode: nil)
            print(String(format: "[auto] conf=%.4f  text=%@", auto.confidence, auto.text))
        } catch { print("❌ \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Local style memory: re-scan history and print what it learned + how it appears
// in the cleanup vocabulary. `FlowClone --learn-dump`
if CommandLine.arguments.contains("--learn-dump") {
    LearnedStore.shared.refresh()   // writes learned.txt synchronously
    let terms = LearnedStore.currentTerms()
    print("Learned \(terms.count) term(s): \(terms.joined(separator: ", "))")
    let vocabSection = OllamaClient().composedSystemPrompt()
        .components(separatedBy: "## Custom vocabulary").last ?? ""
    print("--- cleanup 'Custom vocabulary' section (first 400 chars) ---")
    print(String(vocabSection.prefix(400)))
    exit(0)
}

// Headless translate test: `FlowClone --translate-test <targetCode> "<transcript>"`
if let idx = CommandLine.arguments.firstIndex(of: "--translate-test"),
   CommandLine.arguments.count > idx + 2 {
    let target = CommandLine.arguments[idx + 1]
    let transcript = CommandLine.arguments[idx + 2]
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await OllamaHealth.shared.refreshNow()
        let ek = DictationController.cleanupEngine(for: target == "bg" ? "bg" : target)
        do {
            let name = AppDelegate.englishName(target)
            let out = try await (ek == .apple
                ? AppleCleanup.translate(transcript, toName: name)
                : OllamaClient().translate(transcript, toName: name))
            print("🌍 → \(name) [\(ek == .apple ? "Apple" : "Ollama")]:\n\(out)")
        } catch { print("❌ \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Headless draft test: `FlowClone --draft-test "<on-screen context>" "<spoken intent>"`
// exercises the context-aware drafting prompt + engine (the AX-read half needs a
// real app, but this proves the message the model writes).
if let idx = CommandLine.arguments.firstIndex(of: "--draft-test"),
   CommandLine.arguments.count > idx + 2 {
    let context = CommandLine.arguments[idx + 1]
    let intent = CommandLine.arguments[idx + 2]
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await OllamaHealth.shared.refreshNow()
        let ek = DictationController.cleanupEngine(for: Settings.language)
        do {
            let out = try await (ek == .apple
                ? AppleCleanup.draft(context: context, intent: intent)
                : OllamaClient().draft(context: context, intent: intent))
            print("✍️  Draft [\(ek == .apple ? "Apple" : "Ollama")]:\n\(out)")
        } catch { print("❌ \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Headless transform test: `FlowClone --transform-test "<selection>" "<spoken command>"`
// exercises the SelectionCommand detector + transform prompt + engine, separately
// from live AX read/paste (which needs a real focused app). Prints the detected
// kind and the transformed text.
if let idx = CommandLine.arguments.firstIndex(of: "--transform-test"),
   CommandLine.arguments.count > idx + 2 {
    let selection = CommandLine.arguments[idx + 1]
    let command = CommandLine.arguments[idx + 2]
    let kind = SelectionCommand.detect(command, languages: AppDelegate.translateLanguages)
    print("🎯 command=\"\(command)\" → kind=\(kind.id) (\(kind.label))")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await OllamaHealth.shared.refreshNow()
        let langHint: String = { if case .translate(let code, _) = kind { return code }; return "en" }()
        let ek = DictationController.cleanupEngine(for: langHint)
        do {
            let out = try await (ek == .apple
                ? AppleCleanup.transform(selection: selection, kind: kind, command: command)
                : OllamaClient().transform(selection: selection, kind: kind, command: command))
            print("🎯 Transform [\(ek == .apple ? "Apple" : "Ollama")]:\n\(out)")
        } catch { print("❌ \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Cleanup latency benchmark: `FlowClone --cleanup-bench <wav> [passes]`.
// Transcribes ONCE (Parakeet, English-forced — the identical raw transcript
// feeds both engines), then per engine: one unrecorded warm-up + N recorded
// passes, median reported. ISOLATED per-engine diagnostic by design — bypasses
// EngineRouter, no failover, never writes Settings. Before every recorded
// Apple pass a settling interval lets the async session-pool refill finish
// prewarming (otherwise a pass can grab a cold session and skew the median).
if let idx = CommandLine.arguments.firstIndex(of: "--cleanup-bench"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let passes = CommandLine.arguments.count > idx + 2
        ? max(1, Int(CommandLine.arguments[idx + 2]) ?? 5) : 5
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let t = Transcriber()
            try await t.load()
            let samples = try loadSamples(URL(fileURLWithPath: path))
            let raw = try await t.transcribeDetailed(samples, languageCode: "en").text
            guard !raw.isEmpty else { print("❌ empty transcript"); exit(1) }
            print("📝 raw (en-forced): \(raw)")
            func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }
            var report: [String] = []

            if AppleCleanup.isAvailable {
                AppleCleanup.prewarm()
                _ = try? await AppleCleanup.cleanup(raw) // unrecorded warm-up
                var ms: [Int] = []
                for _ in 0..<passes {
                    // Settling barrier: the pool refills asynchronously after
                    // each take; give the next session time to prewarm.
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    let t0 = Date()
                    _ = try await AppleCleanup.cleanup(raw)
                    ms.append(Int(Date().timeIntervalSince(t0) * 1000))
                }
                print("🍎 Apple passes: \(ms)ms → median \(median(ms))ms")
                report.append("Apple median \(median(ms))ms")
            } else {
                print("🍎 Apple unavailable (\(AppleCleanup.unavailableReason ?? "?")) — skipped")
            }

            await OllamaHealth.shared.refreshNow()
            if case .ready = OllamaHealth.shared.status {
                let client = OllamaClient()
                _ = try? await client.cleanup(raw) // unrecorded warm-up
                var ms: [Int] = []
                for _ in 0..<passes {
                    let t0 = Date()
                    _ = try await client.cleanup(raw)
                    ms.append(Int(Date().timeIntervalSince(t0) * 1000))
                }
                print("🦙 Ollama passes: \(ms)ms → median \(median(ms))ms")
                report.append("Ollama (\(Settings.ollamaModel)) median \(median(ms))ms")
            } else {
                print("🦙 Ollama not ready — skipped")
            }
            print("📊 \(report.joined(separator: " | "))")
        } catch {
            print("❌ \(error)")
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Streaming cleanup diagnostic: `FlowClone --stream-test <wav> [apple|ollama]`.
// Transcribes (Parakeet, en-forced), then prints cumulative snapshots with a
// timestamp — proves time-to-first-text and which sentence the StreamChunker
// would commit early. Does NOT paste (no TextInjector).
/// Bookkeeping for `--stream-test`'s streaming callback, which is `@Sendable`
/// and runs off this context — so its state cannot live in captured `var`s.
///
/// A plain `actor`, deliberately NOT `@MainActor` like the app's StreamState:
/// this CLI blocks the main thread on `semaphore.wait()`, so any hop to the
/// main actor from inside the callback would deadlock. The app has a live
/// runloop and no such constraint.
actor StreamProbe {
    private(set) var chunker = StreamChunker()
    private(set) var early: String?
    private(set) var lastSnap = ""

    func record(_ snap: String, atMs ms: Int) {
        lastSnap = snap
        print("  [\(ms)ms] \(snap.count) chars")
        if early == nil, let c = chunker.earlyChunk(snap) {
            early = c
            print("  → EARLY CHUNK @\(ms)ms: \"\(c)\"")
        }
    }
}

if let idx = CommandLine.arguments.firstIndex(of: "--stream-test"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let useOllama = CommandLine.arguments.count > idx + 2
        && CommandLine.arguments[idx + 2] == "ollama"
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            guard useOllama || AppleCleanup.isAvailable else {
                print("❌ Apple Intelligence unavailable: \(AppleCleanup.unavailableReason ?? "?")"); exit(1)
            }
            let t = Transcriber()
            try await t.load()
            let samples = try loadSamples(URL(fileURLWithPath: path))
            let raw = try await t.transcribeDetailed(samples, languageCode: "en").text
            guard !raw.isEmpty else { print("❌ empty transcript"); exit(1) }
            print("📝 raw: \(raw)")
            if useOllama {
                await OllamaHealth.shared.refreshNow()
            } else {
                AppleCleanup.prewarm()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // let the pool prewarm
            }
            // The streaming callback is `@Sendable` — it is invoked from the
            // model's own context, not this one — so its bookkeeping lives in a
            // main-actor box rather than in captured `var`s, mirroring
            // DictationController.StreamState. (Captured-var mutation here was a
            // real race; it just never had a guard rail.)
            let probe = StreamProbe()
            let t0 = Date()
            let final: String
            if useOllama {
                final = try await OllamaClient().cleanupStreaming(raw) { snap in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    await probe.record(snap, atMs: ms)
                }
            } else {
                final = try await AppleCleanup.cleanupStreaming(raw) { snap in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    await probe.record(snap, atMs: ms)
                }
            }
            print("✨ final [\(useOllama ? "Ollama" : "Apple")]: \(final)")
            if let e = await probe.early {
                let rem = StreamChunker.remainder(finalText: await probe.lastSnap, earlyChunk: e)
                print("   remainder: \(rem.map { "\"\($0)\"" } ?? "DIVERGED (would degrade)")")
            } else {
                print("   (no early chunk — single paste at end)")
            }
        } catch { print("❌ \(error)"); exit(1) }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Headless test mode: `FlowClone --test audio.wav [whisper|parakeet]` runs the
// full ASR → cleanup pipeline on a file and prints the results (no mic/hotkey).
// `--cleanup-engine apple|ollama` forces one engine, BYPASSING the router
// (validated availability, never persisted) — for isolated diagnostics.
if let testIndex = CommandLine.arguments.firstIndex(of: "--test"),
   CommandLine.arguments.count > testIndex + 1 {
    let path = CommandLine.arguments[testIndex + 1]
    let useWhisper = CommandLine.arguments.contains("whisper")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let engine: any ASREngine = useWhisper ? WhisperEngine() : Transcriber()
            print("Loading \(engine.displayName) (downloads on first run)…")
            try await engine.load()

            let samples = try loadSamples(URL(fileURLWithPath: path))
            let t0 = Date()
            let raw: String
            var lang = Settings.language
            if Settings.autoLanguage {
                let cands = Settings.language == Settings.altLanguage
                    ? [Settings.language] : [Settings.language, Settings.altLanguage]
                let r = try await engine.transcribeAuto(samples, candidates: cands)
                print("🌐 auto-detected: \(r.code) (conf \(String(format: "%.2f", r.confidence)))")
                raw = r.text
                lang = r.code // engine dispatch must follow the DETECTED language
            } else {
                raw = try await engine.transcribe(samples)
            }
            print("📝 ASR (\(Int(Date().timeIntervalSince(t0) * 1000))ms): \(raw)")

            let t1 = Date()
            await OllamaHealth.shared.refreshNow()
            // Forced-engine override: bypasses the router entirely (a forced
            // Apple benchmark must not be re-routed by the reliability rule).
            var forced: DictationController.CleanupEngineKind?
            if let fi = CommandLine.arguments.firstIndex(of: "--cleanup-engine"),
               CommandLine.arguments.count > fi + 1 {
                switch CommandLine.arguments[fi + 1] {
                case "apple":
                    guard AppleCleanup.isAvailable else {
                        print("❌ --cleanup-engine apple: \(AppleCleanup.unavailableReason ?? "unavailable")")
                        exit(1)
                    }
                    forced = .apple
                case "ollama":
                    forced = .ollama
                default:
                    print("❌ --cleanup-engine expects apple|ollama")
                    exit(1)
                }
            }
            // Router dispatch — reliability derived from the engine THIS run
            // constructed (the CLI arg), not Settings.asrEngine: they can differ.
            let reliable = !Settings.autoLanguage || !useWhisper
            let engineKind = forced ?? (EngineRouter.cleanupEngine(
                languageCode: lang,
                preference: Settings.cleanupEngine,
                appleAvailable: AppleCleanup.isAvailable,
                detectionReliable: reliable,
                restyleTone: !Tone.current.instruction.isEmpty) == .apple ? .apple : .ollama)
            let cleaned = try await (engineKind == .apple
                ? AppleCleanup.cleanup(raw)
                : OllamaClient().cleanup(raw))
            print("✨ Cleaned [\(engineKind == .apple ? "Apple" : "Ollama")] "
                  + "(\(Int(Date().timeIntervalSince(t1) * 1000))ms): \(cleaned)")
            if engineKind == .apple {
                // Second pass measures the prewarmed-session path (what a real
                // dictation hits — the app prewarms at startup and after each use).
                try await Task.sleep(nanoseconds: 3_000_000_000) // let prewarm finish
                let t2 = Date()
                let warm = try await AppleCleanup.cleanup(raw)
                print("✨ Warm pass [Apple] (\(Int(Date().timeIntervalSince(t2) * 1000))ms): \(warm)")
            }
        } catch {
            print("❌ \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

/// Reads any audio file as 16 kHz mono Float samples (what both engines expect).
func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                               channels: 1, interleaved: false)!
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                 frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw NSError(domain: "FlowClone", code: 1)
    }
    let ratio = 16000 / file.processingFormat.sampleRate
    let output = AVAudioPCMBuffer(pcmFormat: target,
                                  frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 16)!
    var fed = false
    converter.convert(to: output, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
