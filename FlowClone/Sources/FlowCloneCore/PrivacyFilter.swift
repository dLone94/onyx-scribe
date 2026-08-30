import Foundation

/// Decides whether a dictation's TEXT may be persisted (history, scratchpad).
/// Matching is case-insensitive against either the bundle identifier
/// ("com.apple.TextEdit") or the localized app name ("TextEdit") so users can
/// type whichever they know. Never affects pasting — only persistence.
public enum PrivacyFilter {
    public static func shouldRecord(bundleID: String?, appName: String?,
                                    excluded: [String], paused: Bool) -> Bool {
        if paused { return false }
        guard !excluded.isEmpty else { return true }
        let ex = Set(excluded.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if let b = bundleID?.lowercased(), ex.contains(b) { return false }
        if let n = appName?.lowercased(), ex.contains(n) { return false }
        return true
    }

    /// Secure-target rule: text aimed at a secure (password) field must never be
    /// persisted anywhere — history, scratchpad, learned vocabulary — regardless
    /// of every other setting. Fails closed: `secureTarget: true` always wins.
    public static func shouldRecord(bundleID: String?, appName: String?,
                                    excluded: [String], paused: Bool,
                                    secureTarget: Bool) -> Bool {
        if secureTarget { return false }
        return shouldRecord(bundleID: bundleID, appName: appName,
                            excluded: excluded, paused: paused)
    }
}
