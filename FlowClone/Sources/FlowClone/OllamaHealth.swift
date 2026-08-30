import Foundation
import FlowCloneCore

/// Health of the local Ollama cleanup engine.
enum OllamaStatus: Equatable {
    case unknown
    /// Server unreachable on localhost:11434.
    case offline
    /// Server up but Settings.ollamaModel isn't pulled.
    case modelMissing(available: [String])
    /// Model available; `warm` = currently loaded in memory (/api/ps).
    case ready(warm: Bool)

    var menuTitle: String {
        switch self {
        case .unknown: "Ollama: checking…"
        case .offline: "Ollama: ❌ not running — click for help"
        case .modelMissing: "Ollama: ⚠️ model \"\(Settings.ollamaModel)\" not pulled"
        case .ready(true): "Ollama: ✅ \(Settings.ollamaModel) (warm)"
        case .ready(false): "Ollama: ✅ \(Settings.ollamaModel)"
        }
    }
}

/// Singleton probe. Deliberately uses its OWN URLSession with a 2s timeout:
/// OllamaClient's session is configured with timeoutIntervalForRequest = 120
/// (cold model loads) and would hang a health check for two minutes.
final class OllamaHealth: ObservableObject {
    static let shared = OllamaHealth()

    @Published private(set) var status: OllamaStatus = .unknown

    private var lastCheck = Date.distantPast
    private var checking = false
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config)
    }

    /// Cheap to call from periodic UI (menuWillOpen, Settings TimelineView):
    /// only actually probes when the cached status is older than `seconds`.
    func checkIfStale(olderThan seconds: TimeInterval = 5) {
        guard Date().timeIntervalSince(lastCheck) > seconds else { return }
        check()
    }

    func check() {
        guard !checking else { return }
        checking = true
        lastCheck = Date()
        Task { [session] in
            let new = await Self.probe(session: session, model: Settings.ollamaModel)
            await MainActor.run {
                self.checking = false
                if new != self.status { self.status = new }
            }
        }
    }

    /// Debug harnesses (--test) block the main thread on a semaphore, so
    /// check()'s MainActor status write can never land there. Probe inline
    /// instead — used only by the CLI paths.
    func refreshNow() async {
        let new = await Self.probe(session: session, model: Settings.ollamaModel)
        lastCheck = Date()
        if new != status { status = new }
    }

    /// Pipeline calls this when a cleanup request throws: reflect the outage
    /// immediately (don't wait for the next poll), then re-probe to refine
    /// (offline vs model-missing).
    func noteFailure() {
        DispatchQueue.main.async {
            self.status = .offline
            self.lastCheck = .distantPast
            self.check()
        }
    }

    private static func probe(session: URLSession, model: String) async -> OllamaStatus {
        struct ModelList: Decodable {
            struct M: Decodable { let name: String }
            let models: [M]
        }
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(ModelList.self, from: data)
        else { return .offline }

        let names = tags.models.map(\.name)
        guard OllamaModelMatch.isAvailable(setting: model, tags: names) else {
            return .modelMissing(available: names)
        }

        // Warm = the model shows up in /api/ps (currently resident).
        if let psURL = URL(string: "http://localhost:11434/api/ps"),
           let (psData, psResp) = try? await session.data(from: psURL),
           (psResp as? HTTPURLResponse)?.statusCode == 200,
           let ps = try? JSONDecoder().decode(ModelList.self, from: psData),
           OllamaModelMatch.isAvailable(setting: model, tags: ps.models.map(\.name)) {
            return .ready(warm: true)
        }
        return .ready(warm: false)
    }
}
