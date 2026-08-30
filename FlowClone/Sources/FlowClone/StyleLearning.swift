import Foundation
import FlowCloneCore

/// The app-side of local style memory. Learns the terms you use from your own
/// dictation history (on-device) via StyleMemory, persists them, and feeds them
/// into cleanup so your names and jargon stop getting mangled — quietly better
/// the more you dictate. Dismissed terms are remembered so they don't return.
final class LearnedStore: ObservableObject {
    static let shared = LearnedStore()

    /// Auto-learned terms, most-used first.
    @Published private(set) var terms: [String] = []

    private static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".flowclone")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var learnedURL: URL { dir.appendingPathComponent("learned.txt") }
    private static var ignoreURL: URL { dir.appendingPathComponent("learned-ignore.txt") }
    private static var vocabURL: URL { dir.appendingPathComponent("vocabulary.txt") }

    private init() { terms = Self.readLines(Self.learnedURL) }

    /// Terms the user has dismissed — never re-learn these (lowercased).
    private static func ignored() -> Set<String> {
        Set(readLines(ignoreURL).map { $0.lowercased() })
    }

    /// Plain terms already in the manual dictionary (so we don't relearn them).
    private static func manualVocab() -> Set<String> {
        Set(readLines(vocabURL)
            .filter { !$0.hasPrefix("#") && !$0.contains("=>") })
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The learned terms merged for the cleanup prompt (public read for CleanupPrompt).
    static func currentTerms() -> [String] { readLines(learnedURL) }

    /// Re-scan history and update the learned list. Cheap (≤100 entries); safe to
    /// call off the main thread — publishes the result back on main.
    func refresh() {
        // Learn only from the CLEANED text the user kept — raw ASR is full of
        // mishearings, and learning a wrong spelling would reinforce it.
        //
        // `entries` is a main-thread-mutated value-type array (HistoryStore.add);
        // reading it from this background queue would race. Snapshot on main.
        let history: [String] = Thread.isMainThread
            ? HistoryStore.shared.entries.map { $0.text }
            : DispatchQueue.main.sync { HistoryStore.shared.entries.map { $0.text } }
        let known = Self.manualVocab().union(Self.ignored())
        let learned = StyleMemory.learn(from: history, known: known, minCount: 2, limit: 40)
            .map { $0.text }
        try? learned.joined(separator: "\n").write(to: Self.learnedURL, atomically: true, encoding: .utf8)
        DispatchQueue.main.async { self.terms = learned }
    }

    /// Dismiss a learned term: remove it and never learn it again.
    func dismiss(_ term: String) {
        var ignore = Self.readLines(Self.ignoreURL)
        if !ignore.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            ignore.append(term)
            try? ignore.joined(separator: "\n").write(to: Self.ignoreURL, atomically: true, encoding: .utf8)
        }
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        try? terms.joined(separator: "\n").write(to: Self.learnedURL, atomically: true, encoding: .utf8)
    }
}
