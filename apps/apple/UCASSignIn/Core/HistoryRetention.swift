import Foundation

public enum HistoryRetentionError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit
    public var errorDescription: String? { "记录保留数量和天数必须为正整数，或设为不限" }
}

/// A missing limit keeps every entry. Limits are user choices, never implicit defaults.
public struct HistoryRetentionPolicy: Codable, Equatable, Sendable {
    public var maxCount: Int?
    public var maxAgeDays: Int?

    public init(maxCount: Int? = nil, maxAgeDays: Int? = nil) {
        self.maxCount = maxCount
        self.maxAgeDays = maxAgeDays
    }

    @discardableResult
    public func validated() throws -> Self {
        guard maxCount.map({ $0 > 0 }) ?? true, maxAgeDays.map({ $0 > 0 }) ?? true else {
            throw HistoryRetentionError.invalidLimit
        }
        return self
    }

    /// Sort newest first, break ties by stable ID, then apply age before count.
    public func retained<Element>(_ values: [Element], now: Date,
                                  date: (Element) -> Date, id: (Element) -> String,
                                  protected: (Element) -> Bool = { _ in false }) throws -> [Element] {
        try validated()
        let cutoff = maxAgeDays.map { now.addingTimeInterval(-TimeInterval($0) * 86_400) }
        let ordered = values.sorted {
            let left = date($0), right = date($1)
            return left == right ? id($0) < id($1) : left > right
        }
        let eligible = ordered.filter { value in cutoff.map { date(value) >= $0 } ?? true }
        let selected = maxCount.map { Array(eligible.prefix($0)) } ?? eligible
        let retainedIDs = Set(selected.map(id))
        // An active operation may temporarily exceed the chosen display limit.
        return ordered.filter { protected($0) || retainedIDs.contains(id($0)) }
    }
}

public struct HistoryRetentionSettings: Codable, Equatable, Sendable {
    public var operations: HistoryRetentionPolicy
    public var automatic: HistoryRetentionPolicy

    public init(operations: HistoryRetentionPolicy = .init(), automatic: HistoryRetentionPolicy = .init()) {
        self.operations = operations
        self.automatic = automatic
    }

    public static let applicationKeys = [
        "history.operations.maxCount", "history.operations.maxAgeDays",
        "history.automatic.maxCount", "history.automatic.maxAgeDays"
    ]

    public func applicationPreferences() throws -> [String: Data] {
        try operations.validated(); try automatic.validated()
        return [
            Self.applicationKeys[0]: try SyncCodec.encode(operations.maxCount),
            Self.applicationKeys[1]: try SyncCodec.encode(operations.maxAgeDays),
            Self.applicationKeys[2]: try SyncCodec.encode(automatic.maxCount),
            Self.applicationKeys[3]: try SyncCodec.encode(automatic.maxAgeDays)
        ]
    }

    public static func from(applicationPreferences fields: [String: Data]) throws -> Self {
        func limit(_ key: String) throws -> Int? {
            guard let data = fields[key] else { return nil }
            let value = try SyncCodec.decode(Int?.self, from: data)
            guard value.map({ $0 > 0 }) ?? true else { throw HistoryRetentionError.invalidLimit }
            return value
        }
        return try Self(
            operations: .init(maxCount: limit(applicationKeys[0]), maxAgeDays: limit(applicationKeys[1])),
            automatic: .init(maxCount: limit(applicationKeys[2]), maxAgeDays: limit(applicationKeys[3])))
    }
}
