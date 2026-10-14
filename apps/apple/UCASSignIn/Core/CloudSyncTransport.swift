import Foundation
#if canImport(Security)
import Security
#endif

public struct CloudSyncRecord: Equatable, Sendable {
    public let id: String
    public let data: Data
    /// CloudKit metadata only; the encrypted payload is never archived here.
    public let systemFields: Data?

    public init(id: String, data: Data, systemFields: Data? = nil) {
        self.id = id
        self.data = data
        self.systemFields = systemFields
    }
}

public struct CloudSyncChanges: Equatable, Sendable {
    public let records: [CloudSyncRecord]
    public let deletedRecordIDs: [String]
    public let cursor: Data?

    public init(records: [CloudSyncRecord] = [], deletedRecordIDs: [String] = [], cursor: Data? = nil) {
        self.records = records
        self.deletedRecordIDs = deletedRecordIDs
        self.cursor = cursor
    }
}

public struct CloudSyncRecordFailure: Equatable, Sendable {
    public let id: String
    public let error: CloudSyncError

    public init(id: String, error: CloudSyncError) {
        self.id = id
        self.error = error
    }
}

public struct CloudSyncSaveResult: Equatable, Sendable {
    public let saved: [CloudSyncRecord]
    public let conflicts: [CloudSyncRecord]
    /// Successful writes remain available even when other records in a batch fail.
    public let failures: [CloudSyncRecordFailure]

    public init(saved: [CloudSyncRecord] = [], conflicts: [CloudSyncRecord] = [],
                failures: [CloudSyncRecordFailure] = []) {
        self.saved = saved
        self.conflicts = conflicts
        self.failures = failures
    }
}

public enum CloudSyncError: Error, LocalizedError, Equatable, Sendable {
    case unavailable, unconfigured, noAccount, restricted, temporarilyUnavailable
    case tokenExpired, zoneMissing, zoneDeletedByUser, encryptedDataReset, invalidData, recordMissing
    case network, service(retryAfter: TimeInterval?), quotaExceeded, cancelled
    case keychainLocked, keychain(Int32), immutableCredential
    /// Keep only a numeric CloudKit code. NSError descriptions and userInfo may
    /// contain account identifiers, record contents, or credential references.
    case cloudKitRequest(code: Int)

    public var shouldRetryAutomatically: Bool {
        switch self {
        case .network, .service, .temporarilyUnavailable, .tokenExpired, .zoneMissing,
             .recordMissing, .keychainLocked, .keychain:
            true
        case .unavailable, .unconfigured, .noAccount, .restricted, .quotaExceeded,
             .invalidData, .zoneDeletedByUser, .encryptedDataReset, .cancelled,
             .immutableCredential, .cloudKitRequest:
            false
        }
    }

    /// Partial failures must not depend on dictionary/record ordering. Preserve an
    /// actionable cause ahead of collateral batch errors or temporary failures.
    public static func preferredFailure(in errors: [CloudSyncError]) -> CloudSyncError? {
        guard let selected = errors.min(by: { $0.failureOrder < $1.failureOrder }) else { return nil }
        if case .service = selected {
            let delays = errors.compactMap { error -> TimeInterval? in
                guard case .service(let delay) = error, let delay, delay.isFinite, delay >= 0 else { return nil }
                return delay
            }
            return .service(retryAfter: delays.max())
        }
        return selected
    }

    private var failureOrder: (Int, Int) {
        switch self {
        case .encryptedDataReset: (0, 0)
        case .zoneDeletedByUser: (1, 0)
        case .unconfigured: (2, 0)
        case .cloudKitRequest(let code): (code == 2 || code == 22 ? 40 : 3, code)
        case .restricted: (4, 0)
        case .noAccount: (5, 0)
        case .quotaExceeded: (6, 0)
        case .invalidData: (7, 0)
        case .immutableCredential: (8, 0)
        case .unavailable: (9, 0)
        case .cancelled: (13, 0)
        case .zoneMissing: (20, 0)
        case .tokenExpired: (21, 0)
        case .recordMissing: (22, 0)
        case .keychainLocked: (23, 0)
        case .keychain(let code): (24, Int(code))
        case .service: (25, 0)
        case .network: (26, 0)
        case .temporarilyUnavailable: (27, 0)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable: "当前环境不支持 iCloud 同步"
        case .unconfigured: "此构建未配置 iCloud 同步权限"
        case .noAccount: "请先在系统设置中登录 iCloud"
        case .restricted: "系统限制了此设备的 iCloud 访问"
        case .temporarilyUnavailable: "iCloud 暂时不可用，请稍后重试"
        case .tokenExpired: "需要重新读取 iCloud 同步记录"
        case .zoneMissing: "iCloud 同步区域已被移除，请重新开启同步以恢复本机数据"
        case .zoneDeletedByUser: "iCloud 中的数据已被删除，请重新开启同步以恢复本机数据"
        case .encryptedDataReset: "iCloud 加密数据已被重置，本机数据仍然保留"
        case .invalidData: "iCloud 同步数据无法读取，请更新 App 后重试"
        case .recordMissing: "iCloud 记录已被移除，需要重新读取"
        case .network: "网络不可用，连接恢复后将继续同步"
        case .service: "iCloud 服务暂时繁忙，请稍后重试"
        case .quotaExceeded: "iCloud 储存空间不足"
        case .cancelled: "同步已暂停"
        case .keychainLocked: "请解锁设备后继续同步登录信息"
        case .keychain: "无法访问 iCloud 钥匙串，登录信息仍保留在本机"
        case .immutableCredential: "登录信息版本冲突，需要重新读取同步状态"
        case .cloudKitRequest(let code): Self.cloudKitRequestDescription(code)
        }
    }

    private static func cloudKitRequestDescription(_ code: Int) -> String {
        let symbols = [1: "internalError", 2: "partialFailure", 5: "badContainer",
            8: "missingEntitlement", 12: "invalidArguments", 14: "serverRecordChanged",
            15: "serverRejectedRequest", 16: "assetFileNotFound", 17: "assetFileModified",
            18: "incompatibleVersion", 19: "constraintViolation", 22: "batchRequestFailed",
            24: "badDatabase", 27: "limitExceeded", 29: "tooManyParticipants",
            30: "alreadyShared", 31: "referenceViolation", 33: "participantMayNeedVerification",
            35: "assetNotAvailable"]
        let diagnostic = symbols[code].map { "CKError.\($0) (\(code))" } ?? "CKError (\(code))"
        let message: String
        switch code {
        case 5, 8, 24: message = "iCloud 配置未通过验证，请检查 App 的同步权限与容器配置"
        case 12, 15, 19: message = "iCloud 拒绝了同步请求，请检查容器与字段配置"
        case 18: message = "当前 App 版本无法完成 iCloud 同步，请更新 App"
        case 27: message = "同步请求超过 iCloud 限制，需要调整请求大小后重试"
        case 2, 22: message = "iCloud 批量请求失败，请检查具体请求错误后重试"
        default: message = "iCloud 无法处理此同步请求，请检查配置或更新 App"
        }
        return "\(message)（\(diagnostic)）"
    }
}

@MainActor
public protocol CloudSyncClient {
    func accountIdentifier() async throws -> String
    func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges
    func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult
}

@MainActor
public struct DisabledCloudSyncClient: CloudSyncClient {
    public init() {}
    public func accountIdentifier() async throws -> String { throw CloudSyncError.unavailable }
    public func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges { throw CloudSyncError.unavailable }
    public func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult { throw CloudSyncError.unavailable }
}

/// Deterministic CAS store. It never creates a CloudKit container or accesses an Apple account.
@MainActor
public final class MemoryCloudSyncClient: CloudSyncClient {
    public var accountID: String
    public var error: CloudSyncError?
    public private(set) var records: [String: CloudSyncRecord] = [:]
    private var revision = 0
    private var changes: [(revision: Int, id: String)] = []

    public init(accountID: String = "test-icloud-account") { self.accountID = accountID }

    public func accountIdentifier() async throws -> String {
        if let error { throw error }
        return accountID
    }

    public func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges {
        if let error { throw error }
        let previous: Int
        if let cursor {
            guard let value = String(data: cursor, encoding: .utf8).flatMap(Int.init),
                  value >= 0, value <= revision else { throw CloudSyncError.tokenExpired }
            previous = value
        } else { previous = 0 }
        let ids = Set(changes.filter { $0.revision > previous }.map(\.id)).sorted()
        return CloudSyncChanges(records: ids.compactMap { records[$0] },
                                deletedRecordIDs: ids.filter { records[$0] == nil },
                                cursor: Data(String(revision).utf8))
    }

    public func save(_ incoming: [CloudSyncRecord]) async throws -> CloudSyncSaveResult {
        if let error { throw error }
        guard Set(incoming.map(\.id)).count == incoming.count,
              incoming.allSatisfy({ !$0.id.isEmpty }) else { throw CloudSyncError.invalidData }
        var saved: [CloudSyncRecord] = []
        var conflicts: [CloudSyncRecord] = []
        var failures: [CloudSyncRecordFailure] = []
        for record in incoming {
            if let current = records[record.id], current.systemFields != record.systemFields {
                conflicts.append(current)
            } else if records[record.id] == nil, record.systemFields != nil {
                failures.append(.init(id: record.id, error: .recordMissing))
            } else {
                revision += 1
                let stored = CloudSyncRecord(id: record.id, data: record.data,
                                             systemFields: Data(String(revision).utf8))
                records[record.id] = stored
                changes.append((revision, record.id))
                saved.append(stored)
            }
        }
        return .init(saved: saved, conflicts: conflicts, failures: failures)
    }

    public func deleteRecord(id: String) {
        records.removeValue(forKey: id)
        revision += 1
        changes.append((revision, id))
    }
}

/// Read signed process entitlements, never a mutable Info.plist declaration of capability.
enum CloudSyncEntitlements {
    static func values(for key: String) -> [String] {
        #if os(macOS) && canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? [String] ?? []
        #elseif os(iOS)
        return executableEntitlements[key] ?? []
        #else
        return []
        #endif
    }

    static func string(for key: String) -> String? {
        #if os(macOS) && canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? String
        #elseif os(iOS)
        return executableStringEntitlements[key]
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static let executableEntitlements: [String: [String]] = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        return SignedEntitlementReader.stringArrays(from: data)
    }()

    private static let executableStringEntitlements: [String: String] = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        return SignedEntitlementReader.strings(from: data)
    }()
    #endif

    static func permitsCloudContainer(_ identifier: String) -> Bool {
        !identifier.isEmpty && !identifier.contains("$(")
            && values(for: "com.apple.developer.icloud-services").contains("CloudKit")
            && values(for: "com.apple.developer.icloud-container-identifiers").contains(identifier)
    }

    static func permitsKeychainGroup(_ group: String) -> Bool {
        !group.isEmpty && !group.contains("$(") && values(for: "keychain-access-groups").contains(group)
    }

    static var permitsRemoteNotifications: Bool {
        #if os(macOS)
        let key = "com.apple.developer.aps-environment"
        #else
        let key = "aps-environment"
        #endif
        guard let environment = string(for: key) else { return false }
        return environment == "development" || environment == "production"
    }
}

/// iOS has no public SecTask API. Read the actual signed executable, not the profile's
/// broader allowlist. The OS validates that signature; this only prevents unsupported
/// unsigned builds from invoking CloudKit. Unknown encodings fail closed.
enum SignedEntitlementReader {
    static func stringArrays(from data: Data) -> [String: [String]] {
        values(from: data).compactMapValues { $0 as? [String] }
    }

    static func strings(from data: Data) -> [String: String] {
        values(from: data).compactMapValues { $0 as? String }
    }

    private static func values(from data: Data) -> [String: Any] {
        let reader = Bytes(data: data)
        let slice: Int
        if reader.uint32(0, bigEndian: true) == 0xcafebabe {
            guard let count = reader.uint32(4, bigEndian: true), count <= 32 else { return [:] }
            #if arch(arm64)
            let cpu: UInt32 = 0x0100000c
            #else
            let cpu: UInt32 = 0x01000007
            #endif
            var selected: Int?
            for index in 0..<Int(count) {
                let entry = 8 + index * 20
                if reader.uint32(entry, bigEndian: true) == cpu,
                   let offset = reader.uint32(entry + 8, bigEndian: true) { selected = Int(offset); break }
            }
            guard let selected else { return [:] }
            slice = selected
        } else { slice = 0 }
        guard reader.uint32(slice, bigEndian: false) == 0xfeedfacf,
              let count = reader.uint32(slice + 16, bigEndian: false), count <= 4096,
              let commandsSize = reader.uint32(slice + 20, bigEndian: false) else { return [:] }
        var command = slice + 32
        let commandsEnd = command + Int(commandsSize)
        guard commandsEnd <= data.count else { return [:] }
        for _ in 0..<Int(count) {
            guard let kind = reader.uint32(command, bigEndian: false),
                  let size = reader.uint32(command + 4, bigEndian: false), size >= 8,
                  command + Int(size) <= commandsEnd else { return [:] }
            if kind == 0x1d {
                guard size >= 16, let offset = reader.uint32(command + 8, bigEndian: false),
                      let length = reader.uint32(command + 12, bigEndian: false) else { return [:] }
                return signatureValues(reader: reader, start: slice + Int(offset), length: Int(length))
            }
            command += Int(size)
        }
        return [:]
    }

    private static func signatureValues(reader: Bytes, start: Int, length: Int) -> [String: Any] {
        guard length >= 12, start >= 0, start + length <= reader.data.count,
              reader.uint32(start, bigEndian: true) == 0xfade0cc0,
              let size = reader.uint32(start + 4, bigEndian: true), size <= length,
              let count = reader.uint32(start + 8, bigEndian: true), count <= 128,
              12 + Int(count) * 8 <= size else { return [:] }
        var xml: Data?
        var der: Data?
        for index in 0..<Int(count) {
            let entry = start + 12 + index * 8
            guard let slot = reader.uint32(entry, bigEndian: true),
                  let offset = reader.uint32(entry + 4, bigEndian: true), Int(offset) + 8 <= Int(size) else { return [:] }
            let blob = start + Int(offset)
            guard let magic = reader.uint32(blob, bigEndian: true),
                  let blobSize = reader.uint32(blob + 4, bigEndian: true), blobSize >= 8,
                  Int(offset) + Int(blobSize) <= Int(size) else { return [:] }
            if slot == 5 && magic == 0xfade7171 { xml = reader.data.subdata(in: blob + 8..<blob + Int(blobSize)) }
            if slot == 7 && magic == 0xfade7172 { der = reader.data.subdata(in: blob + 8..<blob + Int(blobSize)) }
        }
        // Modern signatures authorize the DER representation when it is present.
        if let der { return derValues(der) ?? [:] }
        guard let xml, let dictionary = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { return [:] }
        return dictionary
    }

    static func derStringArrays(_ data: Data) -> [String: [String]]? {
        derValues(data)?.compactMapValues { $0 as? [String] }
    }

    static func derStrings(_ data: Data) -> [String: String]? {
        derValues(data)?.compactMapValues { $0 as? String }
    }

    private static func derValues(_ data: Data) -> [String: Any]? {
        let reader = Bytes(data: data)
        guard let root = reader.node(at: 0, limit: data.count), root.end == data.count else { return nil }
        let dictionary: DERNode
        if root.tag == 0x70 {
            guard let children = reader.children(root), children.count == 2,
                  children[0].tag == 2, data.subdata(in: children[0].body) == Data([1]),
                  children[1].tag == 0xb0 else { return nil }
            dictionary = children[1]
        } else if root.tag == 0x31 { dictionary = root }
        else { return nil }
        guard let entries = reader.children(dictionary) else { return nil }
        var result: [String: Any] = [:]
        var seen: Set<String> = []
        for entry in entries {
            guard entry.tag == 0x30, let pair = reader.children(entry), pair.count == 2,
                  pair[0].tag == 0x0c, let key = String(data: data.subdata(in: pair[0].body), encoding: .utf8),
                  seen.insert(key).inserted else { return nil }
            if pair[1].tag == 0x0c {
                guard let value = String(data: data.subdata(in: pair[1].body), encoding: .utf8) else { return nil }
                result[key] = value
                continue
            }
            guard pair[1].tag == 0x30, let array = reader.children(pair[1]) else { continue }
            let strings = array.compactMap { node -> String? in
                guard node.tag == 0x0c else { return nil }
                return String(data: data.subdata(in: node.body), encoding: .utf8)
            }
            if strings.count == array.count { result[key] = strings }
        }
        return result
    }

    private struct DERNode { let tag: UInt8; let body: Range<Int>; var end: Int { body.upperBound } }
    private struct Bytes {
        let data: Data
        func uint32(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let values = (0..<4).map { UInt32(data[offset + $0]) }
            let bytes = bigEndian ? values : values.reversed().map { $0 }
            return bytes.reduce(0) { ($0 << 8) | $1 }
        }
        func node(at offset: Int, limit: Int) -> DERNode? {
            guard offset >= 0, offset + 2 <= limit, limit <= data.count else { return nil }
            let tag = data[offset]
            let sizeByte = data[offset + 1]
            var body = offset + 2
            var size = Int(sizeByte)
            if sizeByte & 0x80 != 0 {
                let count = Int(sizeByte & 0x7f)
                guard count > 0, count <= 4, body + count <= limit else { return nil }
                size = 0
                for index in 0..<count { size = (size << 8) | Int(data[body + index]) }
                body += count
            }
            guard size <= limit - body else { return nil }
            return DERNode(tag: tag, body: body..<body + size)
        }
        func children(_ node: DERNode) -> [DERNode]? {
            var offset = node.body.lowerBound
            var result: [DERNode] = []
            while offset < node.end {
                guard let child = self.node(at: offset, limit: node.end), result.count < 4096 else { return nil }
                result.append(child)
                offset = child.end
            }
            return result
        }
    }
}
