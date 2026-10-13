import Foundation

public enum AutoSignMissedAction: String, Codable, CaseIterable, Sendable {
    case manual, tenMinuteGrace, untilClassEnds
}
public enum AutoSignNotification: String, Codable, CaseIterable, Sendable {
    case problems, all, none
}
public enum AutoSignStage: String, Codable, Sendable {
    case planned, checking, submitting, verifying, retryWaiting, signed, missed, needsAttention, skipped
}

public struct AutoSignPolicy: Codable, Equatable, Sendable {
    public var offsetMinutes: Int
    public var missedAction: AutoSignMissedAction
    public var maxSubmissions: Int
    public var retryMinutes: Int
    public var notification: AutoSignNotification

    public init(offsetMinutes: Int = -5, missedAction: AutoSignMissedAction = .manual,
                maxSubmissions: Int = 3, retryMinutes: Int = 2, notification: AutoSignNotification = .problems) {
        self.offsetMinutes = offsetMinutes
        self.missedAction = missedAction
        self.maxSubmissions = maxSubmissions
        self.retryMinutes = retryMinutes
        self.notification = notification
    }
    public var isValid: Bool {
        (-25...240).contains(offsetMinutes) && (1...3).contains(maxSubmissions) && [1, 2, 5].contains(retryMinutes)
    }
}

public struct AutoSignPolicyOverride: Codable, Equatable, Sendable {
    public var offsetMinutes: Int?
    public var missedAction: AutoSignMissedAction?
    public var maxSubmissions: Int?
    public var retryMinutes: Int?
    public var notification: AutoSignNotification?
    public var hasValues: Bool {
        offsetMinutes != nil || missedAction != nil || maxSubmissions != nil || retryMinutes != nil || notification != nil
    }
    public init(offsetMinutes: Int? = nil, missedAction: AutoSignMissedAction? = nil,
                maxSubmissions: Int? = nil, retryMinutes: Int? = nil, notification: AutoSignNotification? = nil) {
        self.offsetMinutes = offsetMinutes
        self.missedAction = missedAction
        self.maxSubmissions = maxSubmissions
        self.retryMinutes = retryMinutes
        self.notification = notification
    }
    public func resolve(_ parent: AutoSignPolicy) -> AutoSignPolicy {
        AutoSignPolicy(offsetMinutes: offsetMinutes ?? parent.offsetMinutes,
                       missedAction: missedAction ?? parent.missedAction,
                       maxSubmissions: maxSubmissions ?? parent.maxSubmissions,
                       retryMinutes: retryMinutes ?? parent.retryMinutes,
                       notification: notification ?? parent.notification)
    }
}

public struct AutoSignOccurrenceOverride: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var at: Date?
    public var policy: AutoSignPolicyOverride?
    public var enabledSince: Date?
    public init(enabled: Bool? = nil, at: Date? = nil, policy: AutoSignPolicyOverride? = nil, enabledSince: Date? = nil) {
        self.enabled = enabled; self.at = at; self.policy = policy; self.enabledSince = enabledSince
    }
}
public enum AutoSignEventKind: String, Codable, Sendable {
    case executionStarted, verification, submission, result, missed, manualTakeover, planChanged, pause
}
public struct AutoSignEvent: Codable, Equatable, Sendable {
    public let at: Date
    public let stage: AutoSignStage
    public let message: String
    public let kind: AutoSignEventKind?
    public init(at: Date, stage: AutoSignStage, message: String, kind: AutoSignEventKind? = nil) {
        self.at = at; self.stage = stage; self.message = message; self.kind = kind
    }
    fileprivate var isKnownPreview: Bool {
        if let kind { return kind == .planChanged || kind == .pause }
        return message == "计划已生成" || message.hasPrefix("计划已更新：") || message.hasPrefix("计划已暂停或跳过：")
    }
    fileprivate var isManualTakeover: Bool { kind == .manualTakeover || message == "用户已手动接管" }
}
public struct AutoSignExecution: Codable, Equatable, Sendable {
    public let key: String
    public var submissions: Int
    public var stage: AutoSignStage
    public var lastSubmissionAt: Date?
    public var lastSchoolSubmissionAt: Date?
    public var nextAt: Date?
    public var nextSchoolVerificationAt: Date?
    public var firstNegativeAt: Date?
    public var firstSchoolNegativeAt: Date?
    public var negativeReads: Int
    public var message: String
    public var events: [AutoSignEvent]
    public var startedAt: Date?
    public var courseName: String?
    public var classStartAt: Date?
    public var classEndAt: Date?
    public init(key: String, now: Date) {
        self.key = key; submissions = 0; stage = .planned; lastSubmissionAt = nil; lastSchoolSubmissionAt = nil; nextAt = nil; nextSchoolVerificationAt = nil
        firstNegativeAt = nil; firstSchoolNegativeAt = nil; negativeReads = 0; message = "等待计划时间"
        events = []; startedAt = nil; courseName = nil; classStartAt = nil; classEndAt = nil
    }
    public var hasExecutionActivity: Bool {
        startedAt != nil || submissions > 0 || lastSubmissionAt != nil || lastSchoolSubmissionAt != nil
            || firstNegativeAt != nil || firstSchoolNegativeAt != nil || negativeReads > 0
            || events.contains { !$0.isKnownPreview && !$0.isManualTakeover }
            || ![.planned, .skipped].contains(stage)
    }
    public var isPurePreview: Bool {
        !hasExecutionActivity && !events.isEmpty && events.allSatisfy(\.isKnownPreview)
    }
    public mutating func begin(course: Course, now: Date) {
        guard !hasExecutionActivity else { return }
        startedAt = now; courseName = course.name; classStartAt = course.startDate; classEndAt = course.endDate
        transition(.checking, now: now, message: "开始核实学校签到状态", kind: .executionStarted)
    }
    public mutating func transition(_ stage: AutoSignStage, now: Date, message: String, nextAt: Date? = nil,
                                    kind: AutoSignEventKind? = nil) {
        guard self.stage != stage || self.message != message || self.nextAt != nextAt else { return }
        self.stage = stage; self.message = message; self.nextAt = nextAt
        if [.signed, .missed, .skipped].contains(stage) { nextSchoolVerificationAt = nil }
        let resolved = kind ?? {
            switch stage {
            case .checking, .verifying, .retryWaiting: AutoSignEventKind.verification
            case .submitting: .submission
            case .missed: .missed
            case .planned: .planChanged
            case .skipped: .pause
            case .signed, .needsAttention: .result
            }
        }()
        events.append(AutoSignEvent(at: now, stage: stage, message: message, kind: resolved))
    }
}
public struct AutoSignPlan: Sendable {
    public let key: String
    public let course: Course
    public let plannedAt: Date
    public let deadline: Date
    public let policy: AutoSignPolicy
    public let source: String
    public let stage: AutoSignStage
    public let reason: String
    public let nextAt: Date
    public let sources: [String: String]
    public let isParticipating: Bool
    public var stageTitle: String {
        switch stage {
        case .planned: "待执行"
        case .checking: "正在核实"
        case .submitting: "正在提交"
        case .verifying: "等待核实"
        case .retryWaiting: "等待重试"
        case .signed: "已签到"
        case .missed: "已错过"
        case .needsAttention: "需手动处理"
        case .skipped: "未参与"
        }
    }
    public var nextAction: String {
        switch stage {
        case .planned: "到计划时间后核实学校状态"
        case .checking: "等待学校查询结果"
        case .submitting: "等待本次提交结果"
        case .verifying, .retryWaiting: "到重试时间后再次核实；确认未签到才提交"
        case .signed: "已完成，无需操作"
        case .missed, .needsAttention: "请打开课程手动处理"
        case .skipped: "当前不会自动执行"
        }
    }
}
public enum AutoSignPlanner {
    public static func key(account: String, course: Course) -> String {
        "\(account)|\(CourseTime.normalizeDay(course.day) ?? course.day)|\(course.id)"
    }
    public static func plan(account: String, course: Course, accountPolicy: AutoSignPolicy,
                            courseRule: AutoSignPolicyOverride?, occurrence: AutoSignOccurrenceOverride?,
                            running: Bool, courseEnabled: PreferenceOverride,
                            signDisabled: Bool, now: Date, execution: AutoSignExecution? = nil,
                            runningSince: Date? = nil, defaultSince: Date? = nil, courseEnabledSince: Date? = nil,
                            pausedUntil: Date? = nil) -> AutoSignPlan? {
        guard let start = course.startDate, let end = course.endDate, end > start else { return nil }
        let policy = (occurrence?.policy ?? .init()).resolve((courseRule ?? .init()).resolve(accountPolicy))
        guard policy.isValid else { return nil }
        let at = occurrence?.at ?? start.addingTimeInterval(Double(policy.offsetMinutes * 60))
        let participantSince = occurrence?.enabled != nil ? occurrence?.enabledSince
            : courseEnabled == .enabled ? courseEnabledSince : defaultSince
        let activeSince = [runningSince, participantSince, courseEnabledSince, occurrence?.enabledSince, pausedUntil].compactMap { $0 }.max()
        let eligible = activeSince.map { at >= $0 } ?? true
        // The legacy default field remains readable, but inherited courses use the single run switch.
        let participating = !signDisabled && eligible && (occurrence?.enabled ?? courseEnabled.resolve(default: true))
        let enabled = running && participating
        let source = occurrence?.enabled != nil || occurrence?.at != nil || occurrence?.policy?.hasValues == true
            ? "本次调整" : (courseRule?.hasValues == true || courseEnabled != .inherit ? "课程设置" : "账户默认")
        let baseDeadline: Date = switch policy.missedAction {
        case .manual: at.addingTimeInterval(60)
        case .tenMinuteGrace: at.addingTimeInterval(600)
        case .untilClassEnds: end
        }
        let deadline = min(baseDeadline, end)
        var stage = execution?.stage ?? .planned
        var reason = execution?.message ?? "等待计划时间"
        if !enabled {
            stage = .skipped
            reason = signDisabled ? "本课程已禁用签到" : !running ? "自动签到已关闭或暂停"
                : !eligible ? "计划时间早于本次启用时间，已略过" : "自动签到未启用"
        }
        else if at < start.addingTimeInterval(-25 * 60) || at >= end {
            stage = .needsAttention; reason = "计划时间已超出签到窗口，请调整"
        } else if execution == nil && now > deadline { stage = .missed; reason = "已错过计划时间，请手动处理" }
        func sourceOf(_ once: Bool, _ perCourse: Bool) -> String {
            once ? "本次调整" : perCourse ? "课程设置" : "账户默认"
        }
        let sources = [
            "启用": sourceOf(occurrence?.enabled != nil, courseEnabled != .inherit),
            "执行时间": sourceOf(occurrence?.at != nil || occurrence?.policy?.offsetMinutes != nil, courseRule?.offsetMinutes != nil),
            "错过处理": sourceOf(occurrence?.policy?.missedAction != nil, courseRule?.missedAction != nil),
            "提交次数": sourceOf(occurrence?.policy?.maxSubmissions != nil, courseRule?.maxSubmissions != nil),
            "重试间隔": sourceOf(occurrence?.policy?.retryMinutes != nil, courseRule?.retryMinutes != nil),
            "结果通知": sourceOf(occurrence?.policy?.notification != nil, courseRule?.notification != nil)
        ]
        return AutoSignPlan(key: key(account: account, course: course), course: course, plannedAt: at,
                            deadline: deadline, policy: policy, source: source, stage: stage,
                            reason: reason, nextAt: execution?.nextAt ?? at, sources: sources, isParticipating: participating)
    }
}

public struct AutoSignLedger: Codable, Sendable {
    public let version: Int
    public let accountID: String
    public let executions: [String: AutoSignExecution]
    public init(accountID: String, executions: [String: AutoSignExecution]) {
        version = 2; self.accountID = accountID; self.executions = executions
    }
    public func validate(accountID expectedAccount: String) throws {
        guard [1, 2].contains(version), accountID == expectedAccount,
              executions.allSatisfy({ key, value in
                  !key.isEmpty && key == value.key && (0...3).contains(value.submissions)
                      && (0...2).contains(value.negativeReads)
                      && (value.submissions == 0 || value.lastSubmissionAt != nil)
                      && (value.lastSubmissionAt == nil || value.submissions > 0)
                      && (value.lastSchoolSubmissionAt == nil || value.submissions > 0)
                      && (value.nextSchoolVerificationAt == nil || value.submissions > 0)
                      && (value.negativeReads == 0 || value.firstNegativeAt != nil)
              }) else {
            throw NSError(domain: "AutoSignStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "自动签到记录无法读取，已暂停自动提交"])
        }
    }
}

@MainActor
public protocol AutoSignStore {
    func load(accountID: String) throws -> [String: AutoSignExecution]
    func save(accountID: String, executions: [String: AutoSignExecution]) throws
    func remove(accountID: String)
}

@MainActor
public final class UserDefaultsAutoSignStore: AutoSignStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ accountID: String) -> String { "auto-sign-\(accountID)" }
    public func load(accountID: String) throws -> [String: AutoSignExecution] {
        guard let data = defaults.data(forKey: key(accountID)) else { return [:] }
        let value = try JSONDecoder().decode(AutoSignLedger.self, from: data)
        try value.validate(accountID: accountID)
        let cleaned = value.executions.filter { !$0.value.isPurePreview }
        if value.version == 1 || cleaned.count != value.executions.count {
            defaults.set(try JSONEncoder().encode(AutoSignLedger(accountID: accountID, executions: cleaned)), forKey: key(accountID))
            return cleaned
        }
        return value.executions
    }
    public func save(accountID: String, executions: [String: AutoSignExecution]) throws {
        try AutoSignLedger(accountID: accountID, executions: executions).validate(accountID: accountID)
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let retained = executions.filter {
            let last = $0.value.events.last?.at ?? $0.value.lastSubmissionAt ?? $0.value.startedAt ?? $0.value.firstNegativeAt
            return last.map { $0 >= cutoff } ?? true
        }
        defaults.set(try JSONEncoder().encode(AutoSignLedger(accountID: accountID, executions: retained)), forKey: key(accountID))
    }
    public func remove(accountID: String) { defaults.removeObject(forKey: key(accountID)) }
}

@MainActor
public final class FileAutoSignStore: AutoSignStore {
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "UCASSignIn", isDirectory: true)
            .appendingPathComponent("AutoSign", isDirectory: true)
    }
    private func url(_ accountID: String) -> URL {
        let name = accountID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
    public func load(accountID: String) throws -> [String: AutoSignExecution] {
        let path = url(accountID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let value = try JSONDecoder().decode(AutoSignLedger.self, from: Data(contentsOf: path))
        try value.validate(accountID: accountID)
        let cleaned = value.executions.filter { !$0.value.isPurePreview }
        if value.version == 1 || cleaned.count != value.executions.count {
            try JSONEncoder().encode(AutoSignLedger(accountID: accountID, executions: cleaned)).write(to: path, options: .atomic)
            return cleaned
        }
        return value.executions
    }
    public func save(accountID: String, executions: [String: AutoSignExecution]) throws {
        try AutoSignLedger(accountID: accountID, executions: executions).validate(accountID: accountID)
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let retained = executions.filter {
            let last = $0.value.events.last?.at ?? $0.value.lastSubmissionAt ?? $0.value.startedAt ?? $0.value.firstNegativeAt
            return last.map { $0 >= cutoff } ?? true
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AutoSignLedger(accountID: accountID, executions: retained))
            .write(to: url(accountID), options: .atomic)
    }
    public func remove(accountID: String) { try? FileManager.default.removeItem(at: url(accountID)) }
}
