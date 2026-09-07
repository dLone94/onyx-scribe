import Foundation
import FoundationModels
import FlowCloneCore

/// Availability-safe facade over the Apple Intelligence cleanup engine.
/// The app's deployment target predates macOS 26, so every call funnels
/// through here; on older systems it reports unavailable and the pipeline
/// stays on Ollama.
enum AppleCleanup {
    struct Unavailable: Error {}

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return FoundationModelCleanup.isAvailable }
        return false
    }

    static var unavailableReason: String? {
        if #available(macOS 26.0, *) { return FoundationModelCleanup.unavailableReason }
        return "Requires macOS 26 or newer"
    }

    static func prewarm() {
        if #available(macOS 26.0, *) { FoundationModelCleanup.prewarm() }
    }

    static func cleanup(_ transcript: String, app: String? = nil,
                        context: ContextReader.Context? = nil,
                        languageCode: String? = nil) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.cleanup(
            transcript, app: app, context: context, languageCode: languageCode)
    }

    /// Streaming cleanup: identical output to `cleanup`, but invokes `onPartial`
    /// with each cumulative snapshot so the caller can preview / early-inject.
    static func cleanupStreaming(_ transcript: String, app: String? = nil,
                                 context: ContextReader.Context? = nil,
                                 languageCode: String? = nil,
                                 onPartial: @Sendable (String) async -> Void) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.cleanupStreaming(
            transcript, app: app, context: context, languageCode: languageCode,
            onPartial: onPartial)
    }

    static func rewrite(original: String, command: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.rewrite(original: original, command: command)
    }

    static func draft(context: String, intent: String, app: String? = nil) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.draft(context: context, intent: intent, app: app)
    }

    static func translate(_ transcript: String, toName: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.translate(transcript, toName: toName)
    }

    static func transform(selection: String, kind: TransformKind, command: String) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        return try await FoundationModelCleanup.transform(selection: selection, kind: kind, command: command)
    }
}

/// Cleanup engine backed by Apple's on-device Foundation Models — the zero-
/// install path: nothing to download, nothing to run, fully local. Mirrors
/// OllamaClient's cleanup/rewrite contract and shares CleanupPrompt.
///
/// Caveats vs Ollama:
/// - Requires Apple Intelligence to be enabled (Apple silicon, supported region).
/// - The built-in model's guardrails can refuse some content; callers treat a
///   throw exactly like an Ollama failure (degrade to the raw transcript).
/// - Bulgarian isn't an officially supported model language — the pipeline
///   routes non-English transcripts to Ollama when it's ready.
@available(macOS 26.0, *)
enum FoundationModelCleanup {

    /// Availability is a device/settings fact, cheap to read.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Human-readable reason when unavailable (for Settings/menu surfaces).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is still downloading"
        case .unavailable:
            return "Apple Intelligence isn't available"
        }
    }

    /// Build + prewarm the next session with the REAL instructions so the
    /// first dictation doesn't pay the ~1.8k-token prompt prefill.
    static func prewarm() {
        guard isAvailable else { return }
        FMSessionPool.shared.refillAsync()
    }

    static func cleanup(_ transcript: String, app: String? = nil,
                        context: ContextReader.Context? = nil,
                        languageCode: String? = nil) async throws -> String {
        // Stable prompt lives in the (prewarmed) session instructions; the
        // per-dictation bits ride along in the user turn.
        let session = FMSessionPool.shared.take(instructions: CleanupPrompt.stableSystem())
        defer { FMSessionPool.shared.refillAsync() } // next dictation stays warm
        let situational = CleanupPrompt.situational(
            app: app, context: context, languageCode: languageCode)
        let prompt = (situational.isEmpty ? "" : situational + "\n\n")
            + CleanupPrompt.transcriptUserTurn(transcript)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streaming variant of `cleanup`. Streams cumulative snapshots to `onPartial`
    /// and returns the final trimmed text — same result `cleanup` would produce.
    static func cleanupStreaming(_ transcript: String, app: String? = nil,
                                 context: ContextReader.Context? = nil,
                                 languageCode: String? = nil,
                                 onPartial: @Sendable (String) async -> Void) async throws -> String {
        let session = FMSessionPool.shared.take(instructions: CleanupPrompt.stableSystem())
        defer { FMSessionPool.shared.refillAsync() } // F14: keep the next dictation warm
        let situational = CleanupPrompt.situational(
            app: app, context: context, languageCode: languageCode)
        let prompt = (situational.isEmpty ? "" : situational + "\n\n")
            + CleanupPrompt.transcriptUserTurn(transcript)
        let stream = session.streamResponse(to: prompt, options: GenerationOptions(sampling: .greedy))
        var latest = ""
        for try await snapshot in stream {
            latest = snapshot.content // cumulative partial (String.PartiallyGenerated == String)
            await onPartial(latest)
        }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rewrite(original: String, command: String) async throws -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.rewriteSystem)
        let response = try await session.respond(
            to: CleanupPrompt.rewriteUserTurn(original: original, command: command),
            options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func draft(context: String, intent: String, app: String? = nil) async throws -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.draftSystem(app: app))
        let response = try await session.respond(
            to: CleanupPrompt.draftUserTurn(context: context, intent: intent),
            options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func translate(_ transcript: String, toName: String) async throws -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.translateSystem(toName: toName))
        let response = try await session.respond(
            to: CleanupPrompt.transcriptUserTurn(transcript),
            options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transform(selection: String, kind: TransformKind, command: String) async throws -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.transformSystem(kind: kind))
        let response = try await session.respond(
            to: CleanupPrompt.transformUserTurn(selection: selection, kind: kind, command: command),
            options: GenerationOptions(sampling: .greedy))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Single-slot pool of prewarmed sessions. Each session is used for exactly
/// one respond() (fresh context per dictation — no cross-dictation bleed);
/// the next one is built and prewarmed off the hot path, so the ~1.8k-token
/// instruction prefill is already computed when the user stops speaking.
@available(macOS 26.0, *)
final class FMSessionPool: @unchecked Sendable {
    static let shared = FMSessionPool()
    private var next: LanguageModelSession?
    private var nextKey = ""
    private let lock = NSLock()

    /// Hand out the prewarmed session when its instructions still match
    /// (tone/vocab/US setting unchanged); otherwise build a cold one.
    func take(instructions: String) -> LanguageModelSession {
        lock.lock(); defer { lock.unlock() }
        if nextKey == instructions, let session = next {
            next = nil
            return session
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// Build + prewarm the next session in the background. The lock is taken
    /// only inside the synchronous `store` — never directly in the async
    /// context, and never held across a suspension point.
    func refillAsync() {
        Task.detached(priority: .utility) {
            let instructions = CleanupPrompt.stableSystem()
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            self.store(session, key: instructions)
        }
    }

    private func store(_ session: LanguageModelSession, key: String) {
        lock.lock()
        defer { lock.unlock() }
        next = session
        nextKey = key
    }
}
