import Foundation

public enum SyncModelError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(Int)
    case invalidVersion
    case invalidRecord
    case identityMismatch
    case conflictingMutation
    case unsupportedPreference(String)
    case invalidPreference(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "iCloud 数据版本不受支持，请更新 App 后重试"
        case .invalidVersion, .invalidRecord, .conflictingMutation: "iCloud 数据无法验证，本机数据已保留"
        case .identityMismatch: "iCloud 数据标识不匹配，本机数据已保留"
        case .unsupportedPreference, .invalidPreference: "iCloud 偏好数据无法验证，本机设置已保留"
        }
    }
}

/// A write's dot and the writes its author had observed before making it.
/// Counters belong to a persistent installation identity and must never be reused.
public struct SyncVersion: Codable, Equatable, Comparable, Sendable {
    public let deviceID: String
    public let counter: UInt64
    public let mutationID: String
    public let context: [String: UInt64]
    public let isBaseline: Bool

    public init(deviceID: String, counter: UInt64, mutationID: String,
                context: [String: UInt64] = [:], isBaseline: Bool = false) {
        self.deviceID = deviceID
        self.counter = counter
        self.mutationID = mutationID
        self.context = context
        self.isBaseline = isBaseline
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.isBaseline != rhs.isBaseline { return lhs.isBaseline }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        return lhs.mutationID < rhs.mutationID
    }

    public func observes(_ other: Self) -> Bool {
        if sameMutation(as: other) { return true }
        if deviceID == other.deviceID, counter > other.counter { return true }
        return context[other.deviceID].map { $0 >= other.counter } ?? false
    }

    public func causallyAfter(_ other: Self) -> Bool {
        !sameMutation(as: other) && observes(other)
    }

    public func validate() throws {
        guard !deviceID.isEmpty, !mutationID.isEmpty,
              counter < UInt64.max, isBaseline || counter > 0,
              context.keys.allSatisfy({ !$0.isEmpty }),
              context.values.allSatisfy({ $0 < UInt64.max }),
              context[deviceID].map({ $0 < counter }) ?? true else {
            throw SyncModelError.invalidVersion
        }
    }

    func sameMutation(as other: Self) -> Bool {
        deviceID == other.deviceID && counter == other.counter && mutationID == other.mutationID
    }
}

public struct SyncCandidate: Codable, Equatable, Sendable {
    public let version: SyncVersion
    /// A missing value is an explicit deletion, not an absent update.
    public let value: Data?

    public init(version: SyncVersion, value: Data?) {
        self.version = version
        self.value = value
    }
}

public enum SyncRecordKind: String, Codable, CaseIterable, Sendable {
    case appPreference, account, accountPreference, coursePreference
    case attendance, autoHistory, session, password, invalidSession
}

/// The complete payload is encrypted by the transport; identifiers do not contain secrets.
public struct SyncRecord: Codable, Equatable, Sendable, Identifiable {
    public let formatVersion: Int
    public let id: String
    public let kind: SyncRecordKind
    public let accountID: String?
    public let incarnation: String?
    public let key: String
    public var register: SyncRegister

    public init(id: String, kind: SyncRecordKind, accountID: String? = nil,
                incarnation: String? = nil, key: String = "", register: SyncRegister,
                formatVersion: Int = 1) {
        self.formatVersion = formatVersion
        self.id = id
        self.kind = kind
        self.accountID = accountID
        self.incarnation = incarnation
        self.key = key
        self.register = register
    }

    public var resolvedCandidate: SyncCandidate? {
        register.resolved(deleteWins: kind == .account || kind == .password)
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw SyncModelError.unsupportedFormat(formatVersion) }
        guard !id.isEmpty, accountID.map({ !$0.isEmpty }) ?? true,
              incarnation.map({ !$0.isEmpty }) ?? true else { throw SyncModelError.invalidRecord }
        try register.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, kind, accountID, incarnation, key, register
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(SyncRecordKind.self, forKey: .kind)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        incarnation = try container.decodeIfPresent(String.self, forKey: .incarnation)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        register = try container.decode(SyncRegister.self, forKey: .register)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encodeIfPresent(incarnation, forKey: .incarnation)
        try container.encode(key, forKey: .key)
        try container.encode(register, forKey: .register)
    }
}

public enum SyncCodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct SyncAccountProfile: Codable, Equatable, Sendable {
    public let studentNo: String
    public let userID: String
    public let name: String?
    public let loginUsername: String
    public let incarnation: String

    public init(studentNo: String, userID: String, name: String?, loginUsername: String, incarnation: String) {
        self.studentNo = studentNo
        self.userID = userID
        self.name = name
        self.loginUsername = loginUsername
        self.incarnation = incarnation
    }
}

/// References a synchronizable Keychain item; it never includes a session token or password.
public struct SyncCredentialReference: Codable, Equatable, Sendable {
    public let id: String
    public let version: SyncVersion
    public let fingerprint: String

    public init(id: String, version: SyncVersion, fingerprint: String = "") {
        self.id = id
        self.version = version
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey { case id, version, fingerprint }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(SyncVersion.self, forKey: .version)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        try version.validate()
        guard !id.isEmpty else { throw SyncModelError.invalidRecord }
    }
}

public struct SyncAttendanceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public let courseId: String?
    public let courseName: String
    public let date: Date
    public let message: String
    public let succeeded: Bool

    public init(id: UUID = UUID(), courseId: String? = nil, courseName: String,
                date: Date, message: String, succeeded: Bool) {
        self.id = id
        self.courseId = courseId
        self.courseName = courseName
        self.date = date
        self.message = message
        self.succeeded = succeeded
    }
}

/// A display-only copy. This deliberately cannot be decoded as an AutoSignExecution.
public struct SyncAutoSignHistory: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let incarnation: String
    public let sourceDeviceID: String
    public let sourceDeviceName: String
    public let occurrenceKey: String
    public let revision: UInt64
    public let courseName: String?
    public let classStartAt: Date?
    public let classEndAt: Date?
    public let startedAt: Date?
    public let updatedAt: Date
    public let stage: AutoSignStage
    public let message: String
    public let submissions: Int
    public let events: [AutoSignEvent]

    public init(id: String, accountID: String, incarnation: String, sourceDeviceID: String,
                sourceDeviceName: String, occurrenceKey: String, revision: UInt64,
                courseName: String?, classStartAt: Date?, classEndAt: Date?, startedAt: Date?,
                updatedAt: Date, stage: AutoSignStage, message: String, submissions: Int,
                events: [AutoSignEvent]) {
        self.id = id
        self.accountID = accountID
        self.incarnation = incarnation
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.occurrenceKey = occurrenceKey
        self.revision = revision
        self.courseName = courseName
        self.classStartAt = classStartAt
        self.classEndAt = classEndAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stage = stage
        self.message = message
        self.submissions = submissions
        self.events = events
    }

    public init?(execution: AutoSignExecution, accountID: String, incarnation: String,
                 sourceDeviceID: String, sourceDeviceName: String, revision: UInt64) {
        guard execution.historyDiscarded != true, execution.hasExecutionActivity else { return nil }
        // Length-prefixing avoids collisions when an identifier itself contains a separator.
        let id = [accountID, incarnation, sourceDeviceID, execution.key]
            .map { "\($0.utf8.count):\($0)" }.joined()
        self.init(id: id, accountID: accountID, incarnation: incarnation,
                  sourceDeviceID: sourceDeviceID, sourceDeviceName: sourceDeviceName,
                  occurrenceKey: execution.key, revision: revision,
                  courseName: execution.courseName, classStartAt: execution.classStartAt,
                  classEndAt: execution.classEndAt, startedAt: execution.startedAt,
                  updatedAt: execution.events.last?.at ?? execution.lastSubmissionAt
                    ?? execution.startedAt ?? execution.firstNegativeAt ?? .distantPast,
                  stage: execution.stage, message: execution.message,
                  submissions: execution.submissions, events: execution.events)
    }
}

/// Only user preferences that are shared between devices. Automatic attendance stays local.
public enum SyncPreferenceProjection {
    public static let applicationKeys = [
        "appearanceMode", "accountDetailsHidden", "scheduleViewMode",
        "showOutsideWeekCourses", "update.automaticChecks"
    ] + HistoryRetentionSettings.applicationKeys
    public static let accountKeys = ["remindersEnabled", "confirmationEnabled", "reminderLeadMinutes"]
    public static let courseKeys = ["confirmation", "reminders", "reminderLeadMinutes", "signInDisabled"]

    public static func account(_ preferences: AccountPreferences) throws -> [String: Data] {
        ["remindersEnabled": try SyncCodec.encode(preferences.remindersEnabled),
         "confirmationEnabled": try SyncCodec.encode(preferences.confirmationEnabled),
         "reminderLeadMinutes": try SyncCodec.encode(preferences.reminderLeadMinutes)]
    }

    public static func course(_ preferences: CoursePreferences) throws -> [String: Data] {
        ["confirmation": try SyncCodec.encode(preferences.confirmation),
         "reminders": try SyncCodec.encode(preferences.reminders),
         "reminderLeadMinutes": try SyncCodec.encode(preferences.reminderLeadMinutes),
         "signInDisabled": try SyncCodec.encode(preferences.signInDisabled)]
    }

    public static func courses(_ preferences: AccountPreferences) throws -> [String: [String: Data]] {
        try preferences.courses.mapValues(course)
    }

    /// Applies a field patch atomically, retaining all automatic attendance fields.
    public static func applyAccount(_ fields: [String: Data], to preferences: inout AccountPreferences) throws {
        var next = preferences
        for (key, data) in fields {
            switch key {
            case "remindersEnabled": next.remindersEnabled = try SyncCodec.decode(Bool.self, from: data)
            case "confirmationEnabled": next.confirmationEnabled = try SyncCodec.decode(Bool.self, from: data)
            case "reminderLeadMinutes":
                let value = try SyncCodec.decode(Int.self, from: data)
                guard AccountPreferences.validLeadTimes.contains(value) else { throw SyncModelError.invalidPreference(key) }
                next.reminderLeadMinutes = value
            default: throw SyncModelError.unsupportedPreference(key)
            }
        }
        preferences = next
    }

    /// The caller separately enforces the local activation boundary when re-enabling sign-in.
    public static func applyCourse(_ fields: [String: Data], to preferences: inout CoursePreferences) throws {
        var next = preferences
        for (key, data) in fields {
            switch key {
            case "confirmation": next.confirmation = try SyncCodec.decode(PreferenceOverride.self, from: data)
            case "reminders": next.reminders = try SyncCodec.decode(PreferenceOverride.self, from: data)
            case "reminderLeadMinutes":
                let value = try SyncCodec.decode(Int?.self, from: data)
                guard value.map(AccountPreferences.validLeadTimes.contains) ?? true else { throw SyncModelError.invalidPreference(key) }
                next.reminderLeadMinutes = value
            case "signInDisabled": next.signInDisabled = try SyncCodec.decode(Bool.self, from: data)
            default: throw SyncModelError.unsupportedPreference(key)
            }
        }
        preferences = next
    }
}

/// A user's edits relative to the form they saw. Applying it to the latest model does
/// not overwrite fields changed by another screen or by iCloud while the form was open.
public struct CoursePreferencesPatch: Equatable, Sendable {
    private let confirmation: CoursePreferenceChange<PreferenceOverride>
    private let reminders: CoursePreferenceChange<PreferenceOverride>
    private let reminderLeadMinutes: CoursePreferenceChange<Int?>
    private let signInDisabled: CoursePreferenceChange<Bool>
    private let autoSign: CoursePreferenceChange<PreferenceOverride>
    private let offsetMinutes: CoursePreferenceChange<Int?>
    private let missedAction: CoursePreferenceChange<AutoSignMissedAction?>
    private let maxSubmissions: CoursePreferenceChange<Int?>
    private let retryMinutes: CoursePreferenceChange<Int?>
    private let notification: CoursePreferenceChange<AutoSignNotification?>

    public init(previous: CoursePreferences, proposed: CoursePreferences) {
        confirmation = .init(previous.confirmation, proposed.confirmation)
        reminders = .init(previous.reminders, proposed.reminders)
        reminderLeadMinutes = .init(previous.reminderLeadMinutes, proposed.reminderLeadMinutes)
        signInDisabled = .init(previous.signInDisabled, proposed.signInDisabled)
        autoSign = .init(previous.autoSign, proposed.autoSign)
        offsetMinutes = .init(previous.autoSignRule?.offsetMinutes, proposed.autoSignRule?.offsetMinutes)
        missedAction = .init(previous.autoSignRule?.missedAction, proposed.autoSignRule?.missedAction)
        maxSubmissions = .init(previous.autoSignRule?.maxSubmissions, proposed.autoSignRule?.maxSubmissions)
        retryMinutes = .init(previous.autoSignRule?.retryMinutes, proposed.autoSignRule?.retryMinutes)
        notification = .init(previous.autoSignRule?.notification, proposed.autoSignRule?.notification)
        // autoSignEnabledSince is runtime safety state, never editable form state.
    }

    public var isEmpty: Bool {
        confirmation.isEmpty && reminders.isEmpty && reminderLeadMinutes.isEmpty
            && signInDisabled.isEmpty && autoSign.isEmpty && ruleIsEmpty
    }

    public func applying(to current: CoursePreferences) -> CoursePreferences {
        var result = current
        confirmation.apply(to: &result.confirmation)
        reminders.apply(to: &result.reminders)
        reminderLeadMinutes.apply(to: &result.reminderLeadMinutes)
        signInDisabled.apply(to: &result.signInDisabled)
        autoSign.apply(to: &result.autoSign)
        if !ruleIsEmpty {
            var rule = result.autoSignRule ?? AutoSignPolicyOverride()
            offsetMinutes.apply(to: &rule.offsetMinutes)
            missedAction.apply(to: &rule.missedAction)
            maxSubmissions.apply(to: &rule.maxSubmissions)
            retryMinutes.apply(to: &rule.retryMinutes)
            notification.apply(to: &rule.notification)
            result.autoSignRule = rule.hasValues ? rule : nil
        }
        return result
    }

    private var ruleIsEmpty: Bool {
        offsetMinutes.isEmpty && missedAction.isEmpty && maxSubmissions.isEmpty
            && retryMinutes.isEmpty && notification.isEmpty
    }
}

private enum CoursePreferenceChange<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)

    init(_ previous: Value, _ proposed: Value) {
        self = previous == proposed ? .unchanged : .set(proposed)
    }

    var isEmpty: Bool { if case .unchanged = self { true } else { false } }

    func apply(to value: inout Value) {
        if case .set(let replacement) = self { value = replacement }
    }
}
