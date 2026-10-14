import Foundation
#if canImport(Security)
import Security
#endif

@MainActor
public protocol CredentialSyncStore {
    func data(for id: String) throws -> Data?
    func setData(_ data: Data, for id: String) throws
    func removeData(for id: String) throws
    func allIDs() throws -> [String]
}

@MainActor
public struct DisabledSyncCredentialStore: CredentialSyncStore {
    public init() {}
    public func data(for id: String) throws -> Data? { throw CloudSyncError.unavailable }
    public func setData(_ data: Data, for id: String) throws { throw CloudSyncError.unavailable }
    public func removeData(for id: String) throws { throw CloudSyncError.unavailable }
    public func allIDs() throws -> [String] { throw CloudSyncError.unavailable }
}

@MainActor
public final class MemorySyncCredentialStore: CredentialSyncStore {
    public var error: CloudSyncError?
    public private(set) var items: [String: Data]

    public init(items: [String: Data] = [:]) { self.items = items }
    public func data(for id: String) throws -> Data? {
        if let error { throw error }
        return items[id]
    }
    public func setData(_ data: Data, for id: String) throws {
        if let error { throw error }
        guard !id.isEmpty else { throw CloudSyncError.invalidData }
        if let existing = items[id], existing != data { throw CloudSyncError.immutableCredential }
        items[id] = data
    }
    public func removeData(for id: String) throws {
        if let error { throw error }
        items.removeValue(forKey: id)
    }
    public func allIDs() throws -> [String] {
        if let error { throw error }
        return items.keys.sorted()
    }
}

#if canImport(Security)
/// Small test boundary: tests inject an in-memory backend, never the real keychain.
@MainActor
protocol SyncCredentialStorageBackend {
    func permitsAccessGroup(_ group: String) -> Bool
    func copy(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ item: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor
private struct SystemSyncCredentialStorage: SyncCredentialStorageBackend {
    func permitsAccessGroup(_ group: String) -> Bool { CloudSyncEntitlements.permitsKeychainGroup(group) }
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// A causal writer identity must never restore onto another device through backups or iCloud.
@MainActor
public enum SyncDeviceIdentity {
    public static func loadOrCreate(renew: Bool = false) throws -> String {
        try loadOrCreate(renew: renew, backend: SystemSyncCredentialStorage())
    }

    static func loadOrCreate(renew: Bool = false, backend: any SyncCredentialStorageBackend) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "cn.ucas.signin.icloud-device.v1",
                                    kSecAttrAccount as String: "writer-id",
                                    kSecAttrSynchronizable as String: false]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        func read() throws -> String? {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = backend.copy(request)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw error(status) }
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8),
                  UUID(uuidString: string) != nil else { throw CloudSyncError.invalidData }
            return string
        }
        let existing = try read()
        if let existing, !renew { return existing }
        let identifier = UUID().uuidString.lowercased()
        let attributes: [String: Any] = [kSecValueData as String: Data(identifier.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        // Renew only when the journal is absent; use an atomic update, never delete-then-add.
        var status = existing == nil ? backend.add(item) : backend.update(query, attributes: attributes)
        if status == errSecItemNotFound { status = backend.add(item) }
        if status == errSecDuplicateItem {
            if !renew, let existing = try read() { return existing }
            status = backend.update(query, attributes: attributes)
        }
        guard status == errSecSuccess else { throw error(status) }
        return identifier
    }

    private static func error(_ status: OSStatus) -> CloudSyncError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed: .keychainLocked
        case errSecMissingEntitlement: .unconfigured
        case errSecNotAvailable: .temporarilyUnavailable
        default: .keychain(status)
        }
    }
}

/// Versioned credential items are immutable. Removing an item also removes its remote copies.
@MainActor
public final class LiveSyncCredentialStore: CredentialSyncStore {
    private let accessGroup: String
    private let backend: any SyncCredentialStorageBackend
    static let service = "cn.ucas.signin.icloud.v1"

    public convenience init(accessGroup: String) {
        self.init(accessGroup: accessGroup, backend: SystemSyncCredentialStorage())
    }

    init(accessGroup: String, backend: any SyncCredentialStorageBackend) {
        self.accessGroup = accessGroup
        self.backend = backend
    }

    public func data(for id: String) throws -> Data? {
        var query = try baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw storageError(status) }
        guard let data = result as? Data else { throw CloudSyncError.invalidData }
        return data
    }

    public func setData(_ data: Data, for id: String) throws {
        if let existing = try self.data(for: id) {
            guard existing == data else { throw CloudSyncError.immutableCredential }
            return
        }
        var item = try baseQuery(id: id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = backend.add(item)
        if status == errSecDuplicateItem {
            // A competing device/process may have delivered the same immutable version.
            guard try self.data(for: id) == data else { throw CloudSyncError.immutableCredential }
            return
        }
        guard status == errSecSuccess else { throw storageError(status) }
    }

    public func removeData(for id: String) throws {
        let status = backend.delete(try baseQuery(id: id))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError(status) }
    }

    public func allIDs() throws -> [String] {
        var query = try baseQuery(id: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copy(query)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw storageError(status) }
        guard let attributes = result as? [[String: Any]] else { throw CloudSyncError.invalidData }
        let ids = attributes.compactMap { $0[kSecAttrAccount as String] as? String }
        guard ids.count == attributes.count, ids.allSatisfy({ !$0.isEmpty }) else { throw CloudSyncError.invalidData }
        return ids.sorted()
    }

    private func baseQuery(id: String?) throws -> [String: Any] {
        guard backend.permitsAccessGroup(accessGroup) else { throw CloudSyncError.unconfigured }
        if let id, id.isEmpty { throw CloudSyncError.invalidData }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true
        ]
        if let id { query[kSecAttrAccount as String] = id }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func storageError(_ status: OSStatus) -> CloudSyncError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed: .keychainLocked
        case errSecNotAvailable: .temporarilyUnavailable
        case errSecMissingEntitlement: .unconfigured
        default: .keychain(status)
        }
    }
}
#else
@MainActor
public enum SyncDeviceIdentity {
    public static func loadOrCreate(renew: Bool = false) throws -> String { throw CloudSyncError.unavailable }
}

@MainActor
public struct LiveSyncCredentialStore: CredentialSyncStore {
    public init(accessGroup: String) {}
    public func data(for id: String) throws -> Data? { throw CloudSyncError.unavailable }
    public func setData(_ data: Data, for id: String) throws { throw CloudSyncError.unavailable }
    public func removeData(for id: String) throws { throw CloudSyncError.unavailable }
    public func allIDs() throws -> [String] { throw CloudSyncError.unavailable }
}
#endif
