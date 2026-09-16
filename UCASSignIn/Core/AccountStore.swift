import Foundation

public struct AccountPreferences: Codable, Equatable, Sendable {
    public var autoSignEnabled: Bool
    public var remindersEnabled: Bool

    public init(autoSignEnabled: Bool = false, remindersEnabled: Bool = false) {
        self.autoSignEnabled = autoSignEnabled
        self.remindersEnabled = remindersEnabled
    }
}

public struct StoredAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String { session.studentNo }
    public var session: SchoolSession
    public var credentials: StoredCredentials?
    public var loginUsername: String
    public var lastUsedAt: Date
    public var requiresLogin: Bool
    public var preferences: AccountPreferences

    public init(session: SchoolSession, credentials: StoredCredentials? = nil,
                loginUsername: String = "", lastUsedAt: Date = Date(), requiresLogin: Bool = false,
                preferences: AccountPreferences = AccountPreferences()) {
        self.session = session
        self.credentials = credentials
        let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        self.loginUsername = username.isEmpty ? credentials?.username ?? session.studentNo : username
        self.lastUsedAt = lastUsedAt
        self.requiresLogin = requiresLogin
        self.preferences = preferences
    }
}

public struct AccountVault: Codable, Equatable, Sendable {
    public var version: Int
    public var accounts: [StoredAccount]
    public var activeAccountID: String?

    public init(version: Int = 1, accounts: [StoredAccount] = [], activeAccountID: String? = nil) {
        self.version = version
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }

    /// The school's student number identifies an account regardless of login alias.
    public mutating func upsert(_ account: StoredAccount, makeActive: Bool = true) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        if makeActive { activeAccountID = account.id }
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountID == id { activeAccountID = nil }
    }
}

@MainActor
public protocol AccountStore {
    func load() throws -> AccountVault
    func save(_ vault: AccountVault) throws
    func legacyCredentials() throws -> StoredCredentials?
}

public extension AccountStore {
    func legacyCredentials() throws -> StoredCredentials? { nil }
}

/// One Keychain item commits all account sessions, optional passwords and selection together.
@MainActor
public final class KeychainAccountStore: AccountStore {
    private static let vaultKey = "accounts.v1"
    private let storage: any KeychainDataStorage
    private let defaults: UserDefaults

    public convenience init(keychain: KeychainStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.init(storage: keychain, defaults: defaults)
    }

    public init(storage: any KeychainDataStorage, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
    }

    public func load() throws -> AccountVault {
        if let data = try storage.data(for: Self.vaultKey) {
            let vault = try decodeVault(data)
            clearLegacyItems()
            return vault
        }
        // A password without a validated session is only an autofill suggestion.
        guard let session: SchoolSession = try legacyValue(for: "session") else { return AccountVault() }
        let credentials: StoredCredentials? = try legacyValue(for: "credentials")
        let account = StoredAccount(session: session, credentials: credentials,
                                    preferences: AccountPreferences(
                                        autoSignEnabled: defaults.bool(forKey: "autoSignEnabled"),
                                        remindersEnabled: defaults.bool(forKey: "remindersEnabled")))
        let vault = AccountVault(accounts: [account], activeAccountID: account.id)
        // Never delete legacy data until the complete replacement is committed.
        try save(vault)
        return vault
    }

    public func save(_ vault: AccountVault) throws {
        try validate(vault)
        // A corrupt or newer store must not be silently overwritten by an empty UI state.
        if let existing = try storage.data(for: Self.vaultKey) { _ = try decodeVault(existing) }
        try storage.setData(JSONEncoder().encode(vault), for: Self.vaultKey)
        clearLegacyItems()
    }

    public func legacyCredentials() throws -> StoredCredentials? {
        // Failed cleanup must never offer another account's old password.
        if try storage.data(for: Self.vaultKey) != nil { return nil }
        return try legacyValue(for: "credentials")
    }

    private func legacyValue<Value: Decodable>(for key: String) throws -> Value? {
        guard let data = try storage.data(for: key) else { return nil }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw invalidData }
    }

    private func decodeVault(_ data: Data) throws -> AccountVault {
        let vault: AccountVault
        do { vault = try JSONDecoder().decode(AccountVault.self, from: data) }
        catch { throw invalidData }
        try validate(vault)
        return vault
    }

    private func validate(_ vault: AccountVault) throws {
        guard vault.version == 1 else {
            throw APIError(code: "ACCOUNT_STORE_VERSION", message: "本机账户数据版本不受支持，请更新 App 后重试")
        }
        let ids = vault.accounts.map(\.id)
        guard Set(ids).count == ids.count,
              vault.accounts.allSatisfy({ !$0.id.isEmpty && !$0.session.userId.isEmpty && !$0.session.sessionId.isEmpty }),
              vault.activeAccountID.map({ ids.contains($0) }) ?? true else { throw invalidData }
    }

    private func clearLegacyItems() {
        // The new item is authoritative even if the system temporarily refuses deletion.
        // Retry cleanup on future loads without rolling back or resurrecting an account.
        try? storage.removeData(for: "session")
        try? storage.removeData(for: "credentials")
        defaults.removeObject(forKey: "autoSignEnabled")
        defaults.removeObject(forKey: "remindersEnabled")
    }

    private var invalidData: APIError {
        APIError(code: "KEYCHAIN_INVALID_DATA", message: "已保存的账户信息无法读取，请重试或检查本机安全存储")
    }
}
