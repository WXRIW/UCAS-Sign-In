import Foundation

/// A multi-value register. Concurrent siblings are retained even after presentation resolves
/// a winner, so another replica can still distinguish concurrency from a later deliberate edit.
public struct SyncRegister: Codable, Equatable, Sendable {
    public private(set) var candidates: [SyncCandidate]
    /// Includes retired dots as well as current candidates. Never replace it with just the winner.
    public private(set) var context: [String: UInt64]

    public init(candidates: [SyncCandidate] = [], context: [String: UInt64] = [:]) {
        self.context = Self.clock(including: candidates, context: context)
        self.candidates = Self.maximal(candidates)
    }

    public func merged(with other: Self) -> Self {
        let left = candidates.filter { candidate in
            other.candidates.contains(where: { $0.version.sameMutation(as: candidate.version) })
                || !other.hasObserved(candidate)
        }
        let right = other.candidates.filter { candidate in
            candidates.contains(where: { $0.version.sameMutation(as: candidate.version) })
                || !hasObserved(candidate)
        }
        return Self(candidates: left + right, context: Self.join(context, other.context))
    }

    public var resolvedCandidate: SyncCandidate? { resolved() }

    public func resolved(deleteWins: Bool = false) -> SyncCandidate? {
        let edits = candidates.filter { !$0.version.isBaseline }
        let eligible = edits.isEmpty ? candidates : edits
        if deleteWins, let deletion = eligible.filter({ $0.value == nil }).max(by: Self.less) { return deletion }
        return eligible.max(by: Self.less)
    }

    public func validate() throws {
        guard context.keys.allSatisfy({ !$0.isEmpty }), context.values.allSatisfy({ $0 < UInt64.max }) else {
            throw SyncModelError.invalidVersion
        }
        for candidate in candidates {
            try candidate.version.validate()
            guard context[candidate.version.deviceID].map({ $0 >= candidate.version.counter }) == true,
                  candidate.version.context.allSatisfy({ device, counter in
                      context[device].map { $0 >= counter } == true
                  }) else {
                throw SyncModelError.invalidVersion
            }
        }
        for (index, candidate) in candidates.enumerated() {
            for other in candidates.dropFirst(index + 1) {
                if candidate.version.deviceID == other.version.deviceID,
                   candidate.version.counter == other.version.counter {
                    throw SyncModelError.conflictingMutation
                }
            }
        }
    }

    private func hasObserved(_ candidate: SyncCandidate) -> Bool {
        // A migrated baseline can never retire an actual user edit.
        if !candidate.version.isBaseline, !candidates.contains(where: { !$0.version.isBaseline }) { return false }
        return context[candidate.version.deviceID].map { $0 >= candidate.version.counter } ?? false
    }

    private static func join(_ lhs: [String: UInt64], _ rhs: [String: UInt64]) -> [String: UInt64] {
        lhs.merging(rhs, uniquingKeysWith: max)
    }

    private static func clock(including candidates: [SyncCandidate], context: [String: UInt64]) -> [String: UInt64] {
        candidates.reduce(into: context) { result, candidate in
            result = join(result, candidate.version.context)
            result[candidate.version.deviceID] = max(result[candidate.version.deviceID] ?? 0, candidate.version.counter)
        }
    }

    private static func maximal(_ values: [SyncCandidate]) -> [SyncCandidate] {
        var unique: [SyncCandidate] = []
        for value in values.sorted(by: less) {
            if let index = unique.firstIndex(where: { $0.version.sameMutation(as: value.version) }) {
                // Valid replicas have identical bytes for one immutable mutation.
                // Keep a deterministic result here; record merging rejects a conflicting mutation.
                unique[index] = value
            } else { unique.append(value) }
        }
        let edits = unique.filter { !$0.version.isBaseline }
        let eligible = edits.isEmpty ? unique : edits
        return eligible.filter { candidate in
            !eligible.contains { $0.version.causallyAfter(candidate.version) }
        }.sorted(by: less)
    }

    private static func less(_ lhs: SyncCandidate, _ rhs: SyncCandidate) -> Bool {
        if lhs.version != rhs.version {
            if lhs.version < rhs.version { return true }
            if rhs.version < lhs.version { return false }
            // Equal mutation identities with inconsistent contexts are invalid at the record boundary.
            let left = lhs.version.context.sorted { $0.key < $1.key }.map { "\($0.key.utf8.count):\($0.key):\($0.value)" }.joined()
            let right = rhs.version.context.sorted { $0.key < $1.key }.map { "\($0.key.utf8.count):\($0.key):\($0.value)" }.joined()
            if left != right { return left < right }
        }
        switch (lhs.value, rhs.value) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left.lexicographicallyPrecedes(right)
        }
    }

    private enum CodingKeys: String, CodingKey { case candidates, context }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decode([SyncCandidate].self, forKey: .candidates)
        context = Self.clock(including: candidates,
                             context: try container.decodeIfPresent([String: UInt64].self, forKey: .context) ?? [:])
        try validate()
        candidates = Self.maximal(candidates)
    }
}

public extension SyncRecord {
    func merged(with other: Self) throws -> Self {
        try validate()
        try other.validate()
        guard id == other.id, kind == other.kind, accountID == other.accountID,
              incarnation == other.incarnation, key == other.key else { throw SyncModelError.identityMismatch }
        // Dot reuse signals a damaged installation clock, not an editable conflict.
        for local in register.candidates {
            for remote in other.register.candidates where local.version.deviceID == remote.version.deviceID
                && local.version.counter == remote.version.counter && local != remote {
                throw SyncModelError.conflictingMutation
            }
        }
        return Self(id: id, kind: kind, accountID: accountID, incarnation: incarnation, key: key,
                    register: register.merged(with: other.register), formatVersion: formatVersion)
    }
}
