import Foundation
import CryptoKit

public struct CloudSyncLocalSnapshot: Sendable {
    public var accounts: [StoredAccount]
    public var applicationPreferences: [String: Data]
    public var attendance: [String: [SyncAttendanceRecord]]
    public var executions: [String: [AutoSignExecution]]

    public init(accounts: [StoredAccount] = [], applicationPreferences: [String: Data] = [:],
                attendance: [String: [SyncAttendanceRecord]] = [:], executions: [String: [AutoSignExecution]] = [:]) {
        self.accounts = accounts; self.applicationPreferences = applicationPreferences
        self.attendance = attendance; self.executions = executions
    }
}

public struct SyncedSessionCandidate: Sendable {
    public let reference: SyncCredentialReference
    public let session: SchoolSession
}

public enum SyncedPassword: Sendable {
    case unchanged, clear, value(StoredCredentials)
}

public struct SyncedAccountChanges: Sendable {
    public let profile: SyncAccountProfile
    public let preferences: [String: Data]
    public let courses: [String: [String: Data]]
    public let attendance: [SyncAttendanceRecord]
    public let history: [SyncAutoSignHistory]
    public var deletedAttendanceIDs: Set<UUID> = []
    public var deletedHistoryIDs: Set<String> = []
    public let sessions: [SyncedSessionCandidate]
    public var invalidSessionFingerprints: Set<String> = []
    public let password: SyncedPassword
}

public struct CloudSyncIncoming: Sendable {
    public var applicationPreferences: [String: Data] = [:]
    public var accounts: [SyncedAccountChanges] = []
    public var deletedAccountIDs: Set<String> = []
    public var waitingForCredentials = false
}

public enum CloudSyncStatus: Equatable, Sendable {
    case disabled, ready, syncing, waitingForAccount, waitingForCredentials, unconfigured
    case failed(String)

    public var message: String {
        switch self {
        case .disabled: "已关闭"
        case .ready: "已同步"
        case .syncing: "正在同步"
        case .waitingForAccount: "请在系统设置中登录 iCloud"
        case .waitingForCredentials: "等待登录信息；请检查系统 iCloud 钥匙串设置"
        case .unconfigured: "此构建未配置 iCloud"
        case .failed(let message): message
        }
    }
}

/// This journal contains projections and references, never session tokens or passwords.
public struct CloudSyncReplica: Codable, Equatable, Sendable {
    public var records: [String: SyncRecord] = [:]
    public var systemFields: [String: Data] = [:]
    public var pending: Set<String> = []
    public var cursor: Data?
    public var observations: [String: String] = [:]
    public var localIncarnations: [String: String] = [:]
    public var suppressedAccounts: [String: String] = [:]
    public var quarantinedAccounts: Set<String> = []
    public var initialized = false
    public var lastSuccessfulSync: Date?
    /// Exact references observed in CloudKit, retained even after their register retires them.
    /// Unobserved synchronizable Keychain items may belong to a newer metadata update.
    public var knownCredentials: [String: CloudSyncKnownCredential] = [:]
    public init() { }

    private enum CodingKeys: String, CodingKey {
        case records, systemFields, pending, cursor, observations, localIncarnations
        case suppressedAccounts, quarantinedAccounts, initialized, lastSuccessfulSync, knownCredentials
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decode([String: SyncRecord].self, forKey: .records)
        systemFields = try values.decode([String: Data].self, forKey: .systemFields)
        pending = try values.decode(Set<String>.self, forKey: .pending)
        cursor = try values.decodeIfPresent(Data.self, forKey: .cursor)
        observations = try values.decode([String: String].self, forKey: .observations)
        localIncarnations = try values.decode([String: String].self, forKey: .localIncarnations)
        suppressedAccounts = try values.decode([String: String].self, forKey: .suppressedAccounts)
        quarantinedAccounts = try values.decode(Set<String>.self, forKey: .quarantinedAccounts)
        initialized = try values.decode(Bool.self, forKey: .initialized)
        lastSuccessfulSync = try values.decodeIfPresent(Date.self, forKey: .lastSuccessfulSync)
        knownCredentials = try values.decodeIfPresent([String: CloudSyncKnownCredential].self, forKey: .knownCredentials) ?? [:]
    }
}

public struct CloudSyncKnownCredential: Codable, Equatable, Sendable {
    public let recordID: String
    public let accountID: String
    public let incarnation: String
    public let kind: SyncRecordKind
    public let reference: SyncCredentialReference
}

public struct CloudSyncState: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var deviceID: String
    public var counter: UInt64 = 0
    public var context: [String: UInt64] = [:]
    public var identity: String?
    public var replicas: [String: CloudSyncReplica] = [:]
    public init(deviceID: String) { self.deviceID = deviceID }
}

@MainActor
public protocol CloudSyncStateStore {
    func load() throws -> CloudSyncState?
    func save(_ state: CloudSyncState) throws
}

@MainActor
public final class FileCloudSyncStateStore: CloudSyncStateStore {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UCASSignIn/iCloudSync/state.json")
    }
    public func load() throws -> CloudSyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(CloudSyncState.self, from: Data(contentsOf: url))
        guard state.formatVersion == 1 else { throw CloudSyncStateError.unsupportedVersion }
        return state
    }
    public func save(_ state: CloudSyncState) throws {
        // Refuse to overwrite corrupt or future-version state, including on the first failed load.
        _ = try load()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = url.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
public final class MemoryCloudSyncStateStore: CloudSyncStateStore {
    public var state: CloudSyncState?
    public var saveError: Error?
    public init(state: CloudSyncState? = nil) { self.state = state }
    public func load() throws -> CloudSyncState? { state }
    public func save(_ state: CloudSyncState) throws {
        if let saveError { throw saveError }
        self.state = state
    }
}

public enum CloudSyncStateError: Error, LocalizedError {
    case unsupportedVersion, invalidData, unavailable, deferred
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "同步数据版本较新，请更新 App 后重试"
        case .invalidData: "同步数据无法读取，本机数据已保留"
        case .unavailable: "同步暂不可用，本机数据已保留"
        case .deferred: "等待当前账户操作完成"
        }
    }
}

enum SyncIdentity {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ string: String) -> String { hash(Data(string.utf8)) }
    static func record(_ kind: SyncRecordKind, account: String? = nil, incarnation: String? = nil, key: String = "") -> String {
        hash([kind.rawValue, account ?? "", incarnation ?? "", key].map { "\($0.utf8.count):\($0)" }.joined())
    }
}

struct SyncedSessionSecret: Codable {
    let accountID: String
    let incarnation: String
    let session: SchoolSession
}

struct SyncedPasswordSecret: Codable {
    let accountID: String
    let incarnation: String
    let credentials: StoredCredentials
}
