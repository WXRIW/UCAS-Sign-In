import XCTest
import Foundation
@testable import UCASCore

@MainActor
final class AccountStoreTests: XCTestCase {
    func testLegacyPreferencesDecodeWithNewDefaults() throws {
        let data = Data(#"{"autoSignEnabled":true,"remindersEnabled":false}"#.utf8)
        let value = try JSONDecoder().decode(AccountPreferences.self, from: data)
        XCTAssertTrue(value.autoSignEnabled)
        XCTAssertFalse(value.remindersEnabled)
        XCTAssertFalse(value.confirmationEnabled)
        XCTAssertEqual(value.reminderLeadMinutes, 10)
        XCTAssertTrue(value.courses.isEmpty)
    }

    func testLegacyCoursePreferencesKeepSettingsAndAllowSignIn() throws {
        let data = Data(#"{"confirmation":"enabled","autoSign":"enabled","reminders":"disabled","reminderLeadMinutes":15}"#.utf8)
        let value = try JSONDecoder().decode(CoursePreferences.self, from: data)
        XCTAssertFalse(value.signInDisabled)
        XCTAssertEqual(value.confirmation, .enabled)
        XCTAssertEqual(value.autoSign, .enabled)
        XCTAssertEqual(value.reminderLeadMinutes, 15)
        var disabled = value
        disabled.signInDisabled = true
        XCTAssertEqual(try JSONDecoder().decode(CoursePreferences.self, from: JSONEncoder().encode(disabled)), disabled)
    }

    func testCourseOverridesRoundTripAndResolveGlobals() throws {
        let override = CoursePreferences(confirmation: .enabled, autoSign: .disabled,
                                         reminders: .enabled, reminderLeadMinutes: 30)
        let original = AccountPreferences(autoSignEnabled: true, remindersEnabled: false,
                                          confirmationEnabled: false, reminderLeadMinutes: 10,
                                          courses: ["course-a": override])
        let restored = try JSONDecoder().decode(AccountPreferences.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.courses["course-a"]!.confirmation.resolve(default: false))
        XCTAssertFalse(restored.courses["course-a"]!.autoSign.resolve(default: true))
    }

    func testUpsertUsesSchoolIdentityInsteadOfLoginAlias() async throws {
        let original = account("1001", username: "student@ucas.ac.cn")
        let other = account("1002")
        var vault = AccountVault()
        vault.upsert(original)
        vault.upsert(other)
        let renewed = account("1001", token: "renewed", username: "1001")
        vault.upsert(renewed, makeActive: false)

        XCTAssertEqual(vault.accounts, [renewed, other])
        XCTAssertEqual(vault.activeAccountID, other.id)
        vault.remove(id: original.id)
        XCTAssertEqual(vault.accounts, [other])
        XCTAssertEqual(vault.activeAccountID, other.id)
        vault.remove(id: other.id)
        XCTAssertTrue(vault.accounts.isEmpty)
        XCTAssertNil(vault.activeAccountID)
    }

    func testSessionsPasswordsAndPreferencesRoundTripIndependently() async throws {
        try withStore { storage, _, store in
            var first = account("1001", password: "first-secret")
            first.preferences = AccountPreferences(autoSignEnabled: true)
            first.requiresLogin = true
            var second = account("1002", password: "second-secret")
            second.preferences = AccountPreferences(remindersEnabled: true)
            let vault = AccountVault(accounts: [first, second], activeAccountID: second.id)

            try store.save(vault)
            XCTAssertEqual(try store.load(), vault)
            XCTAssertEqual(Set(storage.items.keys), ["accounts.v1"])

            var changed = vault
            changed.accounts[0].credentials = nil
            changed.accounts[0].session = session("1001", token: "new-first-token")
            try store.save(changed)
            let loaded = try store.load()
            XCTAssertNil(loaded.accounts[0].credentials)
            XCTAssertEqual(loaded.accounts[0].session.sessionId, "1001-new-first-token")
            XCTAssertEqual(loaded.accounts[1], second)
            XCTAssertEqual(loaded.activeAccountID, second.id)
        }
    }

    func testMigrationCommitsBeforeDeletingLegacyAndPreservesAccountCaches() async throws {
        try withStore { storage, defaults, store in
            let legacySession = session("1001")
            let credentials = StoredCredentials(username: "student@ucas.ac.cn", password: "secret")
            try storage.seed(legacySession, key: "session")
            try storage.seed(credentials, key: "credentials")
            defaults.set(true, forKey: "autoSignEnabled")
            defaults.set(true, forKey: "remindersEnabled")
            defaults.set(Data([1, 2]), forKey: "courses-1001-20260916")
            defaults.set(Data([3, 4]), forKey: "records-1001")

            let vault = try store.load()
            let migrated = try XCTUnwrap(vault.accounts.first)
            XCTAssertEqual(vault.version, 1)
            XCTAssertEqual(vault.activeAccountID, "1001")
            XCTAssertEqual(migrated.session, legacySession)
            XCTAssertEqual(migrated.credentials, credentials)
            XCTAssertEqual(migrated.loginUsername, credentials.username)
            XCTAssertEqual(migrated.preferences, AccountPreferences(autoSignEnabled: true, remindersEnabled: true))
            XCTAssertFalse(migrated.requiresLogin)
            XCTAssertNil(storage.items["session"])
            XCTAssertNil(storage.items["credentials"])
            XCTAssertEqual(storage.events.filter { $0.hasPrefix("write:") || $0.hasPrefix("remove:") },
                           ["write:accounts.v1", "remove:session", "remove:credentials"])
            XCTAssertNil(defaults.object(forKey: "autoSignEnabled"))
            XCTAssertNil(defaults.object(forKey: "remindersEnabled"))
            XCTAssertEqual(defaults.data(forKey: "courses-1001-20260916"), Data([1, 2]))
            XCTAssertEqual(defaults.data(forKey: "records-1001"), Data([3, 4]))
            XCTAssertEqual(try store.load(), vault)
        }
    }

    func testSessionWithoutRememberedPasswordMigratesWithStudentNumber() async throws {
        try withStore { storage, _, store in
            try storage.seed(session("1001"), key: "session")
            let migrated = try XCTUnwrap(store.load().accounts.first)
            XCTAssertEqual(migrated.loginUsername, "1001")
            XCTAssertNil(migrated.credentials)
            XCTAssertEqual(migrated.preferences, AccountPreferences())
        }
    }

    func testCredentialsOnlyRemainAutofillUntilFirstAccountIsSaved() async throws {
        try withStore { storage, _, store in
            let credentials = StoredCredentials(username: "student@ucas.ac.cn", password: "secret")
            try storage.seed(credentials, key: "credentials")
            XCTAssertEqual(try store.load(), AccountVault())
            XCTAssertNil(storage.items["accounts.v1"])
            XCTAssertEqual(try store.legacyCredentials(), credentials)

            let added = account("1002")
            try store.save(AccountVault(accounts: [added], activeAccountID: added.id))
            XCTAssertNil(try store.legacyCredentials())
            XCTAssertNil(storage.items["credentials"])
            XCTAssertNil(try store.load().accounts.first?.credentials)
        }
    }

    func testMigrationWriteFailurePreservesBothLegacyItemsAndPreferences() async throws {
        try withStore { storage, defaults, store in
            try storage.seed(session("1001"), key: "session")
            try storage.seed(StoredCredentials(username: "1001", password: "secret"), key: "credentials")
            let before = storage.items
            defaults.set(true, forKey: "autoSignEnabled")
            defaults.set(true, forKey: "remindersEnabled")
            storage.failWrites = true

            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(storage.items, before)
            XCTAssertFalse(storage.events.contains { $0.hasPrefix("remove:") })
            XCTAssertTrue(defaults.bool(forKey: "autoSignEnabled"))
            XCTAssertTrue(defaults.bool(forKey: "remindersEnabled"))

            storage.failWrites = false
            XCTAssertEqual(try store.load().activeAccountID, "1001")
        }
    }

    func testCleanupFailureNeverResurrectsRemovedLegacyAccount() async throws {
        try withStore { storage, _, store in
            try storage.seed(session("1001"), key: "session")
            try storage.seed(StoredCredentials(username: "1001", password: "secret"), key: "credentials")
            storage.failRemovals = true
            let migrated = try store.load()
            XCTAssertNotNil(storage.items["session"])
            XCTAssertNotNil(storage.items["credentials"])
            XCTAssertEqual(try store.load(), migrated)
            XCTAssertNil(try store.legacyCredentials())

            try store.save(AccountVault())
            XCTAssertEqual(try store.load(), AccountVault())
            XCTAssertNil(try store.legacyCredentials())

            storage.failRemovals = false
            XCTAssertEqual(try store.load(), AccountVault())
            XCTAssertNil(storage.items["session"])
            XCTAssertNil(storage.items["credentials"])
        }
    }

    func testCorruptNewStoreCannotFallBackToOrOverwriteLegacyData() async throws {
        try withStore { storage, defaults, store in
            try storage.seed(session("1001"), key: "session")
            storage.items["accounts.v1"] = Data("broken".utf8)
            defaults.set(true, forKey: "autoSignEnabled")
            let before = storage.items

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual((error as? APIError)?.code, "KEYCHAIN_INVALID_DATA")
            }
            XCTAssertThrowsError(try store.save(AccountVault()))
            XCTAssertEqual(storage.items, before)
            XCTAssertTrue(defaults.bool(forKey: "autoSignEnabled"))
            XCTAssertFalse(storage.events.contains { $0.hasPrefix("write:") || $0.hasPrefix("remove:") })
        }
    }

    func testFutureVersionCannotBeOverwritten() async throws {
        try withStore { storage, _, store in
            try storage.seed(AccountVault(version: 2), key: "accounts.v1")
            let before = storage.items
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual((error as? APIError)?.code, "ACCOUNT_STORE_VERSION")
            }
            XCTAssertThrowsError(try store.save(AccountVault()))
            XCTAssertEqual(storage.items, before)
        }
    }

    func testUnavailableNewStoreCannotBeMistakenForMissingData() async throws {
        try withStore { storage, _, store in
            try storage.seed(session("1001"), key: "session")
            storage.failReads = true
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(storage.events, ["read:accounts.v1"])
            XCTAssertNotNil(storage.items["session"])
        }
    }

    func testFailedUpdateLeavesPreviouslySavedAccountsIntact() async throws {
        try withStore { storage, _, store in
            let first = account("1001")
            let original = AccountVault(accounts: [first], activeAccountID: first.id)
            try store.save(original)
            storage.failWrites = true
            var updated = original
            updated.upsert(account("1002"))
            XCTAssertThrowsError(try store.save(updated))
            XCTAssertEqual(try store.load(), original)
        }
    }

    func testInvalidAccountIdentityAndActiveSelectionAreRejected() async throws {
        try withStore { storage, _, store in
            let first = account("1001")
            XCTAssertThrowsError(try store.save(AccountVault(accounts: [first, first])))
            XCTAssertThrowsError(try store.save(AccountVault(accounts: [first], activeAccountID: "1002")))
            XCTAssertThrowsError(try store.save(AccountVault(accounts: [account("")])))
            XCTAssertNil(storage.items["accounts.v1"])
        }
    }

    private func session(_ studentNo: String, token: String = "token") -> SchoolSession {
        SchoolSession(userId: "user-\(studentNo)", sessionId: "\(studentNo)-\(token)", studentNo: studentNo,
                      name: "同学 \(studentNo)")
    }

    private func account(_ studentNo: String, token: String = "token", username: String = "", password: String? = nil) -> StoredAccount {
        StoredAccount(session: session(studentNo, token: token),
                      credentials: password.map { StoredCredentials(username: username.isEmpty ? studentNo : username, password: $0) },
                      loginUsername: username, lastUsedAt: Date(timeIntervalSince1970: 100))
    }

    private func withStore(_ body: (MemoryKeychainStorage, UserDefaults, KeychainAccountStore) throws -> Void) rethrows {
        let suite = "UCASCoreTests.AccountStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryKeychainStorage()
        try body(storage, defaults, KeychainAccountStore(storage: storage, defaults: defaults))
    }
}

private final class MemoryKeychainStorage: KeychainDataStorage {
    enum Failure: Error { case denied }
    var items: [String: Data] = [:]
    var events: [String] = []
    var failReads = false
    var failWrites = false
    var failRemovals = false

    func seed<Value: Encodable>(_ value: Value, key: String) throws {
        items[key] = try JSONEncoder().encode(value)
    }

    func data(for account: String) throws -> Data? {
        events.append("read:\(account)")
        if failReads { throw Failure.denied }
        return items[account]
    }

    func setData(_ data: Data, for account: String) throws {
        events.append("write:\(account)")
        if failWrites { throw Failure.denied }
        items[account] = data
    }

    func removeData(for account: String) throws {
        events.append("remove:\(account)")
        if failRemovals { throw Failure.denied }
        items.removeValue(forKey: account)
    }
}
