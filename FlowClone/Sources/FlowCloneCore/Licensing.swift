import Foundation
import CryptoKit

// Offline, phone-home-free licensing for Onyx Scribe.
//
// A license key is `base64url(claimsJSON).base64url(signature)`. The app embeds
// only an Ed25519 *public* key and verifies the signature over the exact claims
// bytes on-device — no network on the hot path. That keeps licensing consistent
// with the product thesis ("nothing leaves your Mac") and is itself a selling
// point. Trade-off (accepted): keys can't be remotely revoked and are shareable;
// the embedded `expiresAt` enforces subscription lapse. Honest-customer model.

// MARK: - Claims

/// The signed payload. Kept tiny and stable so the signature is reproducible.
public struct LicenseClaims: Codable, Equatable {
    public let email: String
    public let plan: String        // "monthly" | "yearly"
    public let issuedAt: Date
    public let expiresAt: Date
    public let v: Int

    public init(email: String, plan: String, issuedAt: Date, expiresAt: Date, v: Int = 1) {
        self.email = email
        self.plan = plan
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.v = v
    }

    public func isExpired(now: Date) -> Bool { now >= expiresAt }

    /// Canonical bytes the signer signs and the verifier checks. Sorted keys +
    /// integer-seconds dates keep this deterministic across encoder runs.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(self)
    }
}

// MARK: - Key parsing

/// A parsed (not yet cryptographically verified) license key.
public struct LicenseKey: Equatable {
    public let claimsData: Data     // exact bytes that were signed
    public let signature: Data
    public let claims: LicenseClaims

    public enum ParseError: Error, Equatable { case malformed, badBase64, badJSON }

    public static func parse(_ string: String) throws -> LicenseKey {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ParseError.malformed
        }
        guard let claimsData = Data(base64URLEncoded: String(parts[0])),
              let sig = Data(base64URLEncoded: String(parts[1])) else {
            throw ParseError.badBase64
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        guard let claims = try? d.decode(LicenseClaims.self, from: claimsData) else {
            throw ParseError.badJSON
        }
        return LicenseKey(claimsData: claimsData, signature: sig, claims: claims)
    }

    /// Assemble a key string from raw signed bytes + signature (used by the
    /// store-side signer and by tests).
    public static func string(claimsData: Data, signature: Data) -> String {
        claimsData.base64URLEncodedString() + "." + signature.base64URLEncodedString()
    }
}

// MARK: - Verification

/// The result of a successful signature check.
public struct VerifiedLicense: Equatable {
    public let claims: LicenseClaims
    public init(claims: LicenseClaims) { self.claims = claims }
    public var expiresAt: Date { claims.expiresAt }
    public func isExpired(now: Date) -> Bool { claims.isExpired(now: now) }
}

public protocol LicenseVerifying {
    func verify(_ key: LicenseKey) -> VerifiedLicense?
    /// Convenience: parse then verify. Returns nil on any parse or signature failure.
    func verify(string: String) -> VerifiedLicense?
}

public extension LicenseVerifying {
    func verify(string: String) -> VerifiedLicense? {
        guard let key = try? LicenseKey.parse(string) else { return nil }
        return verify(key)
    }
}

/// Verifies Ed25519 signatures with an embedded public key (CryptoKit).
public struct Ed25519Verifier: LicenseVerifying {
    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// - Parameter publicKeyRaw: 32-byte raw Ed25519 public key.
    public init?(publicKeyRaw: Data) {
        guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return nil
        }
        self.publicKey = k
    }

    public func verify(_ key: LicenseKey) -> VerifiedLicense? {
        guard publicKey.isValidSignature(key.signature, for: key.claimsData) else { return nil }
        return VerifiedLicense(claims: key.claims)
    }
}

// MARK: - Entitlement

/// What the current install is allowed to do. Single source of truth, resolved
/// purely from (now, trialStart, verified license).
public enum Entitlement: Equatable {
    case trial(endsAt: Date)
    case subscribed(until: Date)
    case free

    /// 14-day full-feature trial.
    public static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    public static func resolve(now: Date,
                               trialStart: Date,
                               license: VerifiedLicense?) -> Entitlement {
        if let l = license, !l.isExpired(now: now) {
            return .subscribed(until: l.expiresAt)
        }
        let trialEnd = trialStart.addingTimeInterval(trialDuration)
        if now < trialEnd { return .trial(endsAt: trialEnd) }
        return .free
    }

    /// True while the paid experience is unlocked (trial or active subscription).
    public var hasPro: Bool {
        switch self {
        case .trial, .subscribed: return true
        case .free: return false
        }
    }

    /// The gate line: cleanup, tones, and voice-edit commands are paid.
    public func allows(_ feature: Feature) -> Bool { hasPro }

    /// Whole days remaining in the trial (rounded up), or nil when not trialing.
    public func trialDaysLeft(now: Date) -> Int? {
        guard case .trial(let endsAt) = self else { return nil }
        let secs = endsAt.timeIntervalSince(now)
        return max(0, Int((secs / 86_400).rounded(.up)))
    }
}

/// Capabilities gated behind `hasPro`. Everything else (raw dictation, history,
/// insights, dictionary, hotkey, privacy, auto-language) stays free.
public enum Feature: String, CaseIterable {
    case cleanup           // LLM cleanup; free tier injects verbatim
    case tones             // non-verbatim tones
    case voiceCommands     // voice-edit + tone-switch commands
    case selectionTransform // transform selected text by voice (double-tap-hold)
}

// MARK: - Trial clock

/// Tamper-honest trial timing. Can't stop a determined user, but resists the
/// two common cheats: `defaults delete` (receipt file backstops it, handled by
/// the store) and setting the clock back (clamped here).
public enum TrialClock {
    /// The clock can't rewind earlier than the last time we saw the app run, so
    /// setting the system clock back doesn't extend the trial.
    public static func effectiveNow(now: Date, lastSeen: Date?) -> Date {
        guard let ls = lastSeen else { return now }
        return max(now, ls)
    }
}

// MARK: - base64url

extension Data {
    init?(base64URLEncoded s: String) {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: str)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
