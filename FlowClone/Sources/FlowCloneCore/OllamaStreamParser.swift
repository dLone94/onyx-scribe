import Foundation

/// Decodes one newline-delimited event from Ollama's streaming `/api/chat`
/// response. Kept in Core so the wire format has a deterministic regression
/// test without starting the local model server.
public enum OllamaStreamParser {
    public enum Event: Equatable, Sendable {
        case token(String, done: Bool)
        case failure(String)
    }

    private struct Response: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let done: Bool?
        let error: String?
    }

    public static func decode(_ line: String) throws -> Event {
        let response = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        if let error = response.error { return .failure(error) }
        return .token(response.message?.content ?? "", done: response.done ?? false)
    }
}
