import Foundation
import CryptoKit
import FlowCloneCore

// App-side licensing: persistence, the embedded public key, entitlement state
// for the UI and pipeline, and the (stubbed) online refresh. All verification is
// offline (see FlowCloneCore/Licensing.swift) — the only thing that ever touches
// the network is an explicit "Refresh License", and it carries no voice/text.

// MARK: - Embedded public key

enum LicenseKeychain {
    /// Ed25519 public key that matches the store's signing key. The private half
    /// lives only on the signer (store webhook / `--sign-license`), never here.
    static let publicKeyBase64 = "gHMx1cqyxSyER18wJyhHct4ZqWWiqNbGcbt/zwXR8Uo="

    static let verifier: LicenseVerifying = {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let v = Ed25519Verifier(publicKeyRaw: raw) else {
            // A bad embedded key would mean no license ever verifies; make it loud
            // in debug but never crash a shipped build — users fall back to trial/free.
            assertionFailure("Embedded license public key is invalid")
            return NeverVerifier()
        }
        return v
    }()
}

/// Fallback verifier used only if the embedded key is somehow corrupt.
private struct NeverVerifier: LicenseVerifying {
    func verify(_ key: LicenseKey) -> VerifiedLicense? { nil }
}

// MARK: - Persistence

/// UserDefaults + a receipt file for the trial clock, plus the stored license.
enum LicenseStore {
    private static let d = UserDefaults.standard

    // License key string (nil = none). Corrupt values are treated as absent.
    static var licenseString: String? {
        get {
            let s = d.string(forKey: "licenseKey")
            return (s?.isEmpty ?? true) ? nil : s
        }
        set { d.set(newValue, forKey: "licenseKey") }
    }

    // Trial timestamps live in defaults AND a receipt file; earliest first-launch
    // wins so a `defaults delete` doesn't silently restart the trial.
    static var firstLaunch: Date {
        d.object(forKey: "trialFirstLaunch") as? Date ?? Date()
    }
    static var lastSeen: Date? {
        d.object(forKey: "trialLastSeen") as? Date
    }

    private static var receiptURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowClone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("receipt.json")
    }

    private struct Receipt: Codable { var firstLaunch: Date }

    /// Call once at startup. Establishes/repairs the trial start (earliest of
    /// defaults + receipt file) and advances `lastSeen` monotonically.
    static func recordLaunch(now: Date = Date()) {
        let fromDefaults = d.object(forKey: "trialFirstLaunch") as? Date
        let fromReceipt: Date? = (try? Data(contentsOf: receiptURL))
            .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }?.firstLaunch

        let start = [fromDefaults, fromReceipt, now].compactMap { $0 }.min() ?? now
        d.set(start, forKey: "trialFirstLaunch")
        if fromReceipt != start {
            try? JSONEncoder().encode(Receipt(firstLaunch: start)).write(to: receiptURL)
        }

        // lastSeen only moves forward — used to clamp clock-setback cheats.
        let prevSeen = d.object(forKey: "trialLastSeen") as? Date ?? .distantPast
        d.set(max(prevSeen, now), forKey: "trialLastSeen")
    }

    #if DEBUG
    /// Debug/test only: force the trial start (defaults + receipt) so every
    /// entitlement state can be exercised without waiting. Compiled out of
    /// release builds — a shipped binary must have no trial-reset path.
    static func debugForceFirstLaunch(_ date: Date) {
        d.set(date, forKey: "trialFirstLaunch")
        d.set(Date(), forKey: "trialLastSeen")
        try? JSONEncoder().encode(Receipt(firstLaunch: date)).write(to: receiptURL)
    }
    #endif
}

// MARK: - Online refresh (stubbed)

enum RefreshResult { case updated(String), unchanged, notConfigured, failed(String) }

/// Fetches a fresh signed key from the store for an existing subscriber. The real
/// implementation calls the merchant's license endpoint; wired when the store
/// account exists. Never sends voice or text.
protocol LicenseRefresher {
    func refresh(currentLicense: String?) async -> RefreshResult
}

struct StubLicenseRefresher: LicenseRefresher {
    func refresh(currentLicense: String?) async -> RefreshResult { .notConfigured }
}

// MARK: - Model

/// Single source of truth for entitlement. UI observes `entitlement`; the
/// pipeline reads `snapshot()` off the main thread (a cheap, race-free recompute).
final class LicenseModel: ObservableObject {
    static let shared = LicenseModel()

    /// Owner build: the subscription gate is OFF and every feature is
    /// permanently unlocked — no trial, no lockout, no Subscribe UI.
    /// Flip to true to restore the full trial/subscription machinery for a
    /// commercial build (the Settings License section and the entitlement
    /// resolution come back with it; nothing else changes). The pure licensing
    /// code in FlowCloneCore stays compiled and tested either way.
    static let licensingEnabled = false

    @Published private(set) var entitlement: Entitlement = .free
    @Published private(set) var licenseEmail: String?
    @Published private(set) var lastRefreshMessage: String?

    // Transient UI state for the Settings "License" section.
    @Published var draftKey = ""
    @Published var activationError: String?

    /// Where the "Subscribe" button sends people. Landing page is a follow-up;
    /// keep this the single source of truth for the checkout URL.
    static let subscribeURL = URL(string: "https://onyxscribe.app/subscribe")!

    /// True only for a paid, unexpired subscription (not trial) — gates the
    /// "Remove license" affordance.
    var isSubscribed: Bool { if case .subscribed = entitlement { return true }; return false }

    private let verifier: LicenseVerifying
    private var refresher: LicenseRefresher

    init(verifier: LicenseVerifying = LicenseKeychain.verifier,
         refresher: LicenseRefresher = StubLicenseRefresher()) {
        self.verifier = verifier
        self.refresher = refresher
        // Synchronous initial state so the very first render is correct (the
        // snapshot harness renders without spinning the main runloop).
        self.entitlement = snapshot()
        self.licenseEmail = LicenseStore.licenseString
            .flatMap { verifier.verify(string: $0)?.claims.email }
    }

    /// Race-free recompute from persisted state. Safe to call from any thread —
    /// reads UserDefaults + verifies (sub-millisecond) with an immutable verifier.
    /// With licensing disabled (owner build) this is unconditionally subscribed.
    func snapshot(now: Date = Date()) -> Entitlement {
        guard Self.licensingEnabled else { return .subscribed(until: .distantFuture) }
        let eff = TrialClock.effectiveNow(now: now, lastSeen: LicenseStore.lastSeen)
        let lic = LicenseStore.licenseString.flatMap { verifier.verify(string: $0) }
        return Entitlement.resolve(now: eff, trialStart: LicenseStore.firstLaunch, license: lic)
    }

    /// Recompute the published state (call after any change / periodically).
    func refresh() {
        let ent = snapshot()
        let email = LicenseStore.licenseString
            .flatMap { verifier.verify(string: $0) }?.claims.email
        if Thread.isMainThread {
            entitlement = ent
            licenseEmail = email
        } else {
            DispatchQueue.main.async {
                self.entitlement = ent
                self.licenseEmail = email
            }
        }
    }

    /// Validate and store a pasted key. Returns nil on success, else a reason.
    @discardableResult
    func applyLicense(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty key." }
        guard let key = try? LicenseKey.parse(trimmed) else { return "That doesn't look like a valid key." }
        guard verifier.verify(key) != nil else { return "This key's signature isn't valid." }
        if key.claims.isExpired(now: Date()) { return "This license has expired — try Refresh, or renew." }
        LicenseStore.licenseString = trimmed
        refresh()
        return nil
    }

    func clearLicense() {
        LicenseStore.licenseString = nil
        refresh()
    }

    /// UI action: validate + store the pasted draft key, surfacing any error.
    func activateDraft() {
        let err = applyLicense(draftKey)
        DispatchQueue.main.async {
            self.activationError = err
            if err == nil { self.draftKey = "" }
        }
    }

    /// Pull a fresh key from the store (online, the only network call).
    func refreshFromStore() async {
        let result = await refresher.refresh(currentLicense: LicenseStore.licenseString)
        let msg: String
        switch result {
        case .updated(let key):
            if let err = applyLicense(key) { msg = "Refresh failed: \(err)" }
            else { msg = "License refreshed." }
        case .unchanged: msg = "Your license is up to date."
        case .notConfigured: msg = "Online refresh isn't set up yet."
        case .failed(let e): msg = "Couldn't reach the license server: \(e)"
        }
        DispatchQueue.main.async { self.lastRefreshMessage = msg }
    }
}
