import FlowCloneCore
import Foundation

/// Sends the raw ASR transcript to a local Ollama model for cleanup/formatting.
/// System prompt is the one designed in ../prompts/cleanup_system_prompt.md.
final class OllamaClient: Sendable {
    private let endpoint = URL(string: "http://localhost:11434/api/chat")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120 // first call may cold-load the model
        session = URLSession(configuration: config)
    }

    func cleanup(_ transcript: String, app: String? = nil,
                 context: ContextReader.Context? = nil,
                 languageCode: String? = nil) async throws -> String {
        let request = try cleanupRequest(
            transcript, app: app, context: context,
            languageCode: languageCode, stream: false)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams Gemma's token deltas and reports cumulative cleaned text. The
    /// request is otherwise identical to `cleanup`, so enabling live preview
    /// changes latency perception without changing prompt or output policy.
    func cleanupStreaming(
        _ transcript: String,
        app: String? = nil,
        context: ContextReader.Context? = nil,
        languageCode: String? = nil,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let request = try cleanupRequest(
            transcript, app: app, context: context,
            languageCode: languageCode, stream: true)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        var cumulative = ""
        var lastEmitted = ""
        var lastEmissionAt = Date.distantPast
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            switch try OllamaStreamParser.decode(line) {
            case .token(let delta, _):
                guard !delta.isEmpty else { continue }
                cumulative += delta
                // Gemma can emit dozens of tokens per second. The Pill needs
                // the newest cumulative text, not a layout pass per token.
                if Date().timeIntervalSince(lastEmissionAt) >= 0.08 {
                    await onPartial(cumulative)
                    lastEmitted = cumulative
                    lastEmissionAt = Date()
                }
            case .failure(let message):
                throw OllamaError.badResponse(message)
            }
        }
        if cumulative != lastEmitted { await onPartial(cumulative) }
        return cumulative.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupRequest(_ transcript: String, app: String?,
                                context: ContextReader.Context?,
                                languageCode: String?,
                                stream: Bool) throws -> URLRequest {
        let body = ChatRequest(
            model: Settings.ollamaModel,
            stream: stream,
            think: false,
            keep_alive: "10m",
            options: .init(temperature: 0.2, top_p: 0.9),
            messages: [
                .init(role: "system", content: CleanupPrompt.system(
                    app: app, context: context, languageCode: languageCode)),
                .init(role: "user", content: CleanupPrompt.transcriptUserTurn(transcript)),
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Preloads/renews the model in Ollama's memory so cleanup never cold-starts.
    /// An empty-prompt /api/generate call just loads the model and returns.
    func keepWarm() async {
        struct WarmRequest: Encodable { let model: String; let keep_alive: String }
        guard let body = try? JSONEncoder().encode(
            WarmRequest(model: Settings.ollamaModel, keep_alive: "15m")) else { return }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await session.data(for: request)
    }

    /// Applies a spoken edit command ("make it more formal", "make that a bullet
    /// list", …) to previously injected text. Returns the full replacement text.
    func rewrite(original: String, command: String) async throws -> String {
        let system = CleanupPrompt.rewriteSystem
        let body = ChatRequest(
            model: Settings.ollamaModel,
            stream: false,
            think: false,
            keep_alive: "10m",
            options: .init(temperature: 0.2, top_p: 0.9),
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: CleanupPrompt.rewriteUserTurn(original: original, command: command)),
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Context-aware drafting: given on-screen CONTEXT + a spoken INTENT, write the
    /// finished message. Same request shape as cleanup/rewrite, draft system prompt.
    func draft(context: String, intent: String, app: String? = nil) async throws -> String {
        let body = ChatRequest(
            model: Settings.ollamaModel,
            stream: false,
            think: false,
            keep_alive: "10m",
            options: .init(temperature: 0.4, top_p: 0.9),
            messages: [
                .init(role: "system", content: CleanupPrompt.draftSystem(app: app)),
                .init(role: "user", content: CleanupPrompt.draftUserTurn(context: context, intent: intent)),
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Speak one language, type another": translate + clean into `toName`.
    func translate(_ transcript: String, toName: String) async throws -> String {
        let body = ChatRequest(
            model: Settings.ollamaModel,
            stream: false,
            think: false,
            keep_alive: "10m",
            options: .init(temperature: 0.2, top_p: 0.9),
            messages: [
                .init(role: "system", content: CleanupPrompt.translateSystem(toName: toName)),
                .init(role: "user", content: CleanupPrompt.transcriptUserTurn(transcript)),
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transforms a user-selected passage (formal/casual/concise/bullets/grammar/
    /// summarize/translate/freeform). Selection travels as a JSON payload so it
    /// can't break out of its field; the system prompt treats it as inert text.
    func transform(selection: String, kind: TransformKind, command: String) async throws -> String {
        let body = ChatRequest(
            model: Settings.ollamaModel,
            stream: false,
            think: false,
            keep_alive: "10m",
            options: .init(temperature: 0.2, top_p: 0.9),
            messages: [
                .init(role: "system", content: CleanupPrompt.transformSystem(kind: kind)),
                .init(role: "user", content: CleanupPrompt.transformUserTurn(
                    selection: selection, kind: kind, command: command)),
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debug: the exact composed system prompt for the current settings
    /// (tone/US/app) — used by `FlowClone --print-prompt` for prompt testing.
    func composedSystemPrompt(app: String? = nil) -> String {
        CleanupPrompt.system(app: app)
    }

    enum OllamaError: Error {
        case badResponse(String)
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double; let top_p: Double }
        let model: String
        let stream: Bool
        let think: Bool
        let keep_alive: String
        let options: Options
        let messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
}
