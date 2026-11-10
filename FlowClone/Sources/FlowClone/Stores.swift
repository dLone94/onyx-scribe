import Foundation
import Combine
import SwiftUI
import FlowCloneCore

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let app: String?
    let engine: String
    let durationMs: Int
    /// Recording length in seconds (nil in pre-Insights entries).
    let audioSec: Double?
    /// Tone preset id active for this dictation (nil in older entries).
    let tone: String?
    /// What the user actually said (post-vocabulary, pre-LLM). nil in older
    /// entries and when identical to `text` isn't distinct enough to matter.
    let raw: String?
    /// Pinned entries survive the cap-100 trim. nil (old entries) = false.
    let pinned: Bool?

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    var isPinned: Bool { pinned ?? false }
    /// Show the raw section only when it adds information.
    var hasDistinctRaw: Bool {
        guard let raw else { return false }
        return raw != text
    }
}

/// Persistent dictation history (JSON on disk, cap 100). Replaces the old
/// in-memory cap-10 array; the menu-bar submenu and Hub both read from here.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowClone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            // Malformed history: quarantine the file next to the live one
            // instead of silently replacing the user's data with an empty list
            // on the next save. The backup keeps every byte for manual rescue.
            let backup = Self.fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.fileURL, to: backup)
            Diag.event("history.json malformed — quarantined as \(backup.lastPathComponent)",
                       logger: Diag.store)
        }
    }

    func add(text: String, app: String?, engine: String, durationMs: Int,
             audioSec: Double? = nil, tone: String? = nil, raw: String? = nil) {
        DispatchQueue.main.async {
            self.entries.insert(
                HistoryEntry(id: UUID(), text: text, date: Date(), app: app,
                             engine: engine, durationMs: durationMs,
                             audioSec: audioSec, tone: tone,
                             raw: raw, pinned: nil),
                at: 0)
            for i in PinnedCapTrimmer.indicesToRemove(
                pinnedFlags: self.entries.map(\.isPinned), cap: 100) {
                self.entries.remove(at: i)
            }
            self.save()
        }
    }

    func delete(_ id: UUID) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == id }
            self.save()
        }
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.entries = []
            self.save()
        }
    }

    func togglePin(_ id: UUID) {
        DispatchQueue.main.async {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let e = self.entries[i]
            self.entries[i] = HistoryEntry(
                id: e.id, text: e.text, date: e.date, app: e.app,
                engine: e.engine, durationMs: e.durationMs,
                audioSec: e.audioSec, tone: e.tone,
                raw: e.raw, pinned: !e.isPinned)
            self.save()
        }
    }

    /// True when stored entries come from more than one ASR engine — the only
    /// time a per-row engine label carries information.
    var usesMultipleEngines: Bool {
        guard let first = entries.first?.engine else { return false }
        return entries.contains { $0.engine != first }
    }

    /// Markdown export of everything currently in history (newest first).
    func exportMarkdown() -> String {
        var out = "# Onyx Scribe dictation history\n"
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        var currentDay = ""
        for e in entries {
            let d = day.string(from: e.date)
            if d != currentDay {
                currentDay = d
                out += "\n## \(d)\n"
            }
            var meta = "\(time.string(from: e.date)) · \(e.engine)"
            if let app = e.app { meta += " · \(app)" }
            if e.isPinned { meta += " · 📌" }
            out += "\n- **\(meta)**\n  \(e.text.replacingOccurrences(of: "\n", with: "\n  "))\n"
            if e.hasDistinctRaw, let raw = e.raw {
                out += "  - _you said:_ \(raw.replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

// MARK: - Stats

/// Lightweight usage stats (UserDefaults-backed): total words, day streak,
/// rolling average pipeline latency, and a capped text-free timing history.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var totalWords: Int
    @Published private(set) var streakDays: Int
    @Published private(set) var avgLatencyMs: Int
    @Published private(set) var recentLatencies: [PipelineLatencySample]

    private var latencyCount: Int
    private let defaults = UserDefaults.standard

    private init() {
        totalWords = defaults.integer(forKey: "stats.totalWords")
        streakDays = defaults.integer(forKey: "stats.streak")
        avgLatencyMs = defaults.integer(forKey: "stats.avgLatencyMs")
        latencyCount = defaults.integer(forKey: "stats.latencyCount")
        recentLatencies = defaults.data(forKey: "stats.recentLatencies")
            .flatMap { try? JSONDecoder().decode([PipelineLatencySample].self, from: $0) } ?? []
    }

    func record(words: Int, latency: PipelineLatencySample,
                includeInRecent: Bool = true) {
        DispatchQueue.main.async {
            // flowAnimate pairs with .contentTransition(.numericText()) on stat
            // cards; the number settles instantly under Reduce Motion.
            flowAnimate(.easeOut(duration: 0.4)) { self.totalWords += words }

            // Streak: consecutive calendar days with at least one dictation.
            let now = Date()
            let today = Self.dayString(now)
            let lastDay = self.defaults.string(forKey: "stats.lastDay")
            if lastDay != today {
                // Calendar days are not always 86,400 seconds across daylight-
                // saving transitions. Subtract a civil day in the user's
                // current calendar so a valid streak does not reset at DST.
                let yesterdayDate = Calendar.current.date(
                    byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
                let yesterday = Self.dayString(yesterdayDate)
                self.streakDays = (lastDay == yesterday) ? self.streakDays + 1 : 1
                self.defaults.set(today, forKey: "stats.lastDay")
            }

            // Rolling average latency.
            let total = self.avgLatencyMs * self.latencyCount + latency.totalMs
            self.latencyCount += 1
            self.avgLatencyMs = total / self.latencyCount
            self.recentLatencies = PipelineLatencyHistory.appending(
                latency, to: self.recentLatencies,
                writeSucceeded: includeInRecent, cap: 50)

            self.defaults.set(self.totalWords, forKey: "stats.totalWords")
            self.defaults.set(self.streakDays, forKey: "stats.streak")
            self.defaults.set(self.avgLatencyMs, forKey: "stats.avgLatencyMs")
            self.defaults.set(self.latencyCount, forKey: "stats.latencyCount")
            if includeInRecent,
               let data = try? JSONEncoder().encode(self.recentLatencies) {
                self.defaults.set(data, forKey: "stats.recentLatencies")
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Vocabulary (dictionary file editing)

/// Structured editor over ~/.flowclone/vocabulary.txt — preserves # comment
/// lines, separates plain terms from "wrong => right" replacement rules.
final class VocabStore: ObservableObject {
    @Published var terms: [String] = []
    @Published var rules: [(wrong: String, right: String)] = []
    private var commentLines: [String] = []

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/vocabulary.txt")
    }

    init() { load() }

    func load() {
        terms = []; rules = []; commentLines = []
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.isEmpty {
                commentLines.append(String(line))
            } else if t.contains("=>") {
                let parts = t.components(separatedBy: "=>")
                if parts.count == 2 {
                    rules.append((parts[0].trimmingCharacters(in: .whitespaces),
                                  parts[1].trimmingCharacters(in: .whitespaces)))
                }
            } else {
                terms.append(t)
            }
        }
    }

    func save() {
        var lines = commentLines
        lines.append(contentsOf: terms)
        lines.append(contentsOf: rules.map { "\($0.wrong) => \($0.right)" })
        try? lines.joined(separator: "\n").write(to: Self.fileURL, atomically: true, encoding: .utf8)
        objectWillChange.send()
    }
}

// MARK: - Scratchpad

/// Free-form dictation notepad. Also the safety net: dictations made with no
/// editable target focused get appended here instead of vanishing.
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()

    @Published var text: String {
        didSet { scheduleSave() }
    }

    private var saveWork: DispatchWorkItem?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowClone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scratchpad.txt")
    }

    private init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    func append(_ entry: String) {
        DispatchQueue.main.async {
            self.text += (self.text.isEmpty ? "" : "\n\n") + entry
        }
    }

    func clear() {
        DispatchQueue.main.async { self.text = "" }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [text] in
            try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Synchronous write for app termination — the debounced save above can
    /// still be pending when the process exits, which would drop the last
    /// dictation. Called from applicationWillTerminate.
    func flushNow() {
        saveWork?.cancel()
        saveWork = nil
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Per-app profiles

final class ProfilesStore: ObservableObject {
    @Published var profiles: [(app: String, instruction: String)] = []

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flowclone/profiles.json")
    }

    init() { load() }

    func load() {
        profiles = []
        guard let data = try? Data(contentsOf: Self.fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        profiles = dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Adds or updates by app name, case-insensitively (pure logic + tests in
    /// FlowCloneCore.AppProfiles) — adding "slack" when "Slack" exists updates
    /// the existing entry instead of creating a duplicate.
    func upsert(app: String, instruction: String) {
        let entries = AppProfiles.upsert(
            profiles.map { AppProfiles.Entry(app: $0.app, instruction: $0.instruction) },
            app: app, instruction: instruction)
        profiles = entries.map { ($0.app, $0.instruction) }
        save()
    }

    func save() {
        // uniquingKeysWith: a legacy list that already contains exact-duplicate
        // names must never crash the save (uniqueKeysWithValues trapped here).
        let dict = AppProfiles.dictionary(
            profiles.map { AppProfiles.Entry(app: $0.app, instruction: $0.instruction) })
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        objectWillChange.send()
    }
}
