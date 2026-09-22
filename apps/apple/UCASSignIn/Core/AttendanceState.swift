import Foundation

public enum CachePolicy {
    public static let referenceLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static func isFresh(_ updated: Date?, at now: Date, lifetime: TimeInterval = referenceLifetime) -> Bool {
        guard let updated else { return false }
        return now >= updated && now.timeIntervalSince(updated) < lifetime
    }
}

public enum AttendanceStatus: String, Codable, Sendable { case unknown, unsigned, signed }
public enum AttendanceSource: String, Codable, Sendable { case cache, daily, detail, submission }

public struct AttendanceEvidence: Codable, Equatable, Sendable {
    public var status: AttendanceStatus
    public var source: AttendanceSource
    public var observedAt: Date
    public var lastSuccessfulSignAt: Date?
    public var pendingVerification = false
    public var negativeSource: AttendanceSource?

    public init(status: AttendanceStatus = .unknown, source: AttendanceSource = .cache, observedAt: Date) {
        self.status = status; self.source = source; self.observedAt = observedAt
    }
    public func observing(_ value: AttendanceStatus, source: AttendanceSource, now: Date) -> Self {
        var next = self
        if source == .submission {
            next = Self(status: .signed, source: source, observedAt: now)
            next.lastSuccessfulSignAt = now; next.pendingVerification = true
            return next
        }
        if value == .unknown {
            if status != .signed {
                next = Self(status: .unknown, source: source, observedAt: now)
                next.lastSuccessfulSignAt = lastSuccessfulSignAt
                return next
            }
            next.negativeSource = nil
            return next
        }
        if value == .signed || status != .signed {
            next = Self(status: value, source: source, observedAt: now)
            next.lastSuccessfulSignAt = lastSuccessfulSignAt
            return next
        }
        // Only a later independent read from the same source can confirm a correction.
        if negativeSource == source {
            next = Self(status: .unsigned, source: source, observedAt: now)
            next.lastSuccessfulSignAt = lastSuccessfulSignAt
            return next
        }
        next.pendingVerification = true
        next.negativeSource = source
        return next
    }
}

public struct AttendanceEvidenceCache: Codable {
    public var version = 1
    public let accountID: String
    public var states: [String: AttendanceEvidence]
    public var invalidatedCourses: Set<String>
    public init(accountID: String, states: [String: AttendanceEvidence], invalidatedCourses: Set<String>) {
        self.accountID = accountID; self.states = states; self.invalidatedCourses = invalidatedCourses
    }
}
