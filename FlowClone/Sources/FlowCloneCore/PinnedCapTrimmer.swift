import Foundation

/// Cap-enforcement for a newest-first history list where pinned entries are
/// never evicted. If everything is pinned, the list is allowed to exceed the
/// cap (pins are a promise; silently breaking one is worse than using disk).
public enum PinnedCapTrimmer {
    /// Returns the indices (into the newest-first array) to remove so that
    /// count ≤ cap, evicting oldest unpinned entries first. Sorted descending
    /// so callers can `remove(at:)` sequentially without index shifting.
    public static func indicesToRemove(pinnedFlags: [Bool], cap: Int) -> [Int] {
        let overflow = pinnedFlags.count - cap
        guard overflow > 0 else { return [] }
        var result: [Int] = []
        var i = pinnedFlags.count - 1 // oldest = last
        while i >= 0 && result.count < overflow {
            if !pinnedFlags[i] { result.append(i) }
            i -= 1
        }
        return result // built from high index to low → already descending
    }
}
