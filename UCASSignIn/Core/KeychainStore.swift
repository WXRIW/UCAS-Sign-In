import Foundation
#if canImport(Security)
import Security
#endif

public struct StoredCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// The small storage boundary used to test account persistence without real credentials.
public protocol KeychainDataStorage {
    func data(for account: String) throws -> Data?
    func setData(_ data: Data, for account: String) throws
    func removeData(for account: String) throws
}

/// Sessions and explicitly remembered passwords stay in this device's Keychain.
/// The default UI should not persist passwords without the user's choice.
public struct KeychainStore: KeychainDataStorage, Sendable {
    private let service: String

    public init(service: String = "cn.ucas.signin.credentials") {
        self.service = service
    }

    public func save(session: SchoolSession) throws { try save(session, account: "session") }
    public func loadSession() throws -> SchoolSession? { try load(SchoolSession.self, account: "session") }
    public func save(credentials: StoredCredentials) throws { try save(credentials, account: "credentials") }
    public func loadCredentials() throws -> StoredCredentials? { try load(StoredCredentials.self, account: "credentials") }
    public func clearCredentials() throws { try delete(account: "credentials") }
    public func clear() throws {
        // File-based macOS keychains delete one match by default. Delete both
        // owned accounts explicitly, without a broad service-only query.
        try delete(account: "credentials")
        try delete(account: "session")
    }

    private func save<T: Encodable>(_ value: T, account: String) throws {
        try setData(JSONEncoder().encode(value), for: account)
    }

    public func setData(_ data: Data, for account: String) throws {
        #if canImport(Security)
        let query = baseQuery(account: account)
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if !os(macOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        // macOS uses the user's default keychain and its access controls. The
        // iOS accessibility attribute only applies to Data Protection keychains.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw storageError(status) }
        #else
        throw APIError(code: "KEYCHAIN_UNAVAILABLE", message: "当前系统不支持安全凭据存储")
        #endif
    }

    private func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try data(for: account) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError(code: "KEYCHAIN_INVALID_DATA", message: "已保存的登录信息无法读取，请重新登录") }
    }

    public func data(for account: String) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError(status) }
        return data
        #else
        throw APIError(code: "KEYCHAIN_UNAVAILABLE", message: "当前系统不支持安全凭据存储")
        #endif
    }

    private func delete(account: String) throws {
        try removeData(for: account)
    }

    public func removeData(for account: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError(status) }
        #else
        throw APIError(code: "KEYCHAIN_UNAVAILABLE", message: "当前系统不支持安全凭据存储")
        #endif
    }

    #if canImport(Security)
    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func storageError(_ status: OSStatus) -> APIError {
        APIError(code: "KEYCHAIN_\(status)", message: "无法访问安全存储，请解锁设备后重试")
    }
    #endif
}
