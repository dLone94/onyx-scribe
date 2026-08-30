import Foundation

/// Pure logic for the per-app cleanup-instruction profiles.
public enum AppProfiles {
    public struct Entry: Equatable, Sendable {
        public let app: String
        public let instruction: String
        public init(app: String, instruction: String) {
            self.app = app
            self.instruction = instruction
        }
    }

    /// Case-insensitive upsert: adding an app that already exists UPDATES the
    /// existing entry (keeping its original casing) instead of appending a
    /// duplicate — which used to crash `Dictionary(uniqueKeysWithValues:)` on
    /// the next save.
    public static func upsert(_ entries: [Entry], app: String, instruction: String) -> [Entry] {
        if let i = entries.firstIndex(where: { $0.app.caseInsensitiveCompare(app) == .orderedSame }) {
            var out = entries
            out[i] = Entry(app: out[i].app, instruction: instruction)
            return out
        }
        return entries + [Entry(app: app, instruction: instruction)]
    }

    /// Serialization dictionary. Later entries win on exact-duplicate keys, so
    /// a legacy list that already contains duplicates can never crash the save.
    public static func dictionary(_ entries: [Entry]) -> [String: String] {
        Dictionary(entries.map { ($0.app, $0.instruction) },
                   uniquingKeysWith: { _, last in last })
    }
}
