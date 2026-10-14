import Foundation
import XCTest
@testable import UCASCore

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    private func account(password: String? = "private-password", token: String = "private-session") -> StoredAccount {
        StoredAccount(session: SchoolSession(userId: "user-1001", sessionId: token, studentNo: "1001", name: "Test Student"),
                      credentials: password.map { StoredCredentials(username: "1001", password: $0) },
                      lastUsedAt: Date(timeIntervalSince1970: 100))
    }

    func testTwoDevicesConvergeIndependentFieldsAndAttendanceWithoutAutoSignSettings() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let second = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { first.stop(); second.stop() }
        await first.sync(); await second.sync(); await first.sync()
        XCTAssertEqual(second.local.accounts.count, 1)
        first.local.accounts[0].preferences.remindersEnabled = true
        first.local.accounts[0].preferences.autoSignEnabled = true
        second.local.accounts[0].preferences.confirmationEnabled = true
        second.local.accounts[0].preferences.autoSignEnabled = false
        let rowA = SyncAttendanceRecord(courseName: "Course A", date: Date(timeIntervalSince1970: 100), message: "Done A", succeeded: true)
        let rowB = SyncAttendanceRecord(courseName: "Course B", date: Date(timeIntervalSince1970: 101), message: "Done B", succeeded: true)
        first.local.attendance["1001"] = [rowA]
        second.local.attendance["1001"] = [rowB]
        try first.capture(); try second.capture()
        await first.sync(); await second.sync(); await first.sync(); await second.sync()
        for device in [first, second] {
            XCTAssertTrue(device.local.accounts[0].preferences.remindersEnabled)
            XCTAssertTrue(device.local.accounts[0].preferences.confirmationEnabled)
            XCTAssertEqual(Set(device.local.attendance["1001", default: []].map(\.id)), [rowA.id, rowB.id])
            XCTAssertEqual(device.coordinator.status, .ready)
        }
        XCTAssertTrue(first.local.accounts[0].preferences.autoSignEnabled)
        XCTAssertFalse(second.local.accounts[0].preferences.autoSignEnabled)
        let counter = second.coordinator.state.counter
        await second.sync()
        XCTAssertEqual(second.coordinator.state.counter, counter, "Applying unchanged remote values must not create edits")
    }

    func testLegacyNilPasswordDoesNotClearRemoteRememberedPassword() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let legacy = CoordinatorDevice("device-z", cloud: cloud, secrets: secrets, accounts: [account(password: nil)])
        defer { first.stop(); legacy.stop() }
        await first.sync(); await legacy.sync(); await first.sync()
        XCTAssertEqual(legacy.local.accounts.first?.credentials?.password, "private-password")
        XCTAssertEqual(first.local.accounts.first?.credentials?.password, "private-password")
        XCTAssertFalse(try decoded(cloud).contains { $0.kind == .password && $0.resolvedCandidate?.value == nil })
    }

    func testConcurrentForgetWinsAndLaterExplicitRememberCanRestore() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let second = CoordinatorDevice("device-z", cloud: cloud, secrets: secrets)
        defer { first.stop(); second.stop() }
        await first.sync(); await second.sync(); await first.sync()
        first.local.accounts[0].credentials = nil
        try first.capture()
        second.local.accounts[0].credentials = StoredCredentials(username: "1001", password: "concurrent-secret")
        try second.capture(explicitLogin: "1001")
        await second.sync(); await first.sync(); await second.sync()
        XCTAssertNil(first.local.accounts[0].credentials)
        XCTAssertNil(second.local.accounts[0].credentials)
        XCTAssertFalse(secrets.items.keys.contains { $0.contains("/password/") })
        second.local.accounts[0].credentials = StoredCredentials(username: "1001", password: "new-intent-after-clear")
        try second.capture(explicitLogin: "1001")
        await second.sync(); await first.sync()
        XCTAssertEqual(first.local.accounts[0].credentials?.password, "new-intent-after-clear")
    }

    func testLocalRemovalStaysSuppressedAcrossRestartAndKeepsRemoteSecrets() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let savedSecrets = secrets.items
        try device.coordinator.removeLocally(accountID: "1001")
        device.local.accounts = []
        await device.sync()
        XCTAssertTrue(device.local.accounts.isEmpty)
        XCTAssertEqual(secrets.items, savedSecrets)
        device.stop()
        let restarted = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store)
        defer { restarted.stop() }
        await restarted.sync()
        XCTAssertTrue(restarted.local.accounts.isEmpty)
        let other = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { other.stop() }
        await other.sync()
        XCTAssertEqual(other.local.accounts.count, 1)
    }

    func testGlobalDeletionDefeatsOfflineEditsAndExplicitLoginCreatesNewIncarnation() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let offline = CoordinatorDevice("device-z", cloud: cloud, secrets: secrets)
        defer { first.stop(); offline.stop() }
        await first.sync(); await offline.sync()
        let oldIncarnation = try XCTUnwrap(offline.lastIncoming?.accounts.first?.profile.incarnation)
        offline.local.accounts[0].preferences.reminderLeadMinutes = 30
        try offline.capture()
        try first.coordinator.removeEverywhere(accountID: "1001")
        first.local.accounts = []
        await first.sync(); await offline.sync(); await first.sync()
        XCTAssertTrue(offline.local.accounts.isEmpty)
        XCTAssertTrue(first.local.accounts.isEmpty)
        XCTAssertTrue(secrets.items.isEmpty)
        let accountRecord = try XCTUnwrap(try decoded(cloud).first { $0.kind == .account })
        XCTAssertNil(accountRecord.resolvedCandidate?.value)
        offline.local.accounts = [account(token: "new-login-after-delete")]
        try offline.capture(explicitLogin: "1001")
        await offline.sync(); await first.sync()
        XCTAssertEqual(first.local.accounts.first?.session.sessionId, "new-login-after-delete")
        XCTAssertNotEqual(first.lastIncoming?.accounts.first?.profile.incarnation, oldIncarnation)
    }

    func testDisabledCoordinatorPerformsNoTransportReadsOrWrites() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        await device.sync()
        device.stop()
        let calls = cloud.calls, records = cloud.current.records, items = secrets.items
        device.local.accounts[0].preferences.remindersEnabled.toggle()
        try device.capture()
        await device.sync(); await device.coordinator.tick()
        XCTAssertEqual(device.coordinator.status, .disabled)
        XCTAssertEqual(cloud.calls, calls)
        XCTAssertEqual(cloud.current.records, records)
        XCTAssertEqual(secrets.items, items)
        // Persistence of the user's enabled choice belongs to the host preferences, not this journal.
        let disabledRestart = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: device.store, enabled: false)
        await disabledRestart.sync()
        XCTAssertEqual(cloud.calls, calls)
    }

    func testAppleIdentitySwitchDoesNotUploadPreviousAccountsOrPreferences() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        device.local.applicationPreferences["appearanceMode"] = try SyncCodec.encode("dark")
        await device.sync()
        let original = cloud.current.records
        cloud.current = MemoryCloudSyncClient(accountID: "different-apple-account")
        await device.sync()
        XCTAssertTrue(cloud.current.records.isEmpty)
        XCTAssertEqual(device.local.accounts.count, 1)
        XCTAssertEqual(device.coordinator.state.replicas.count, 2)
        XCTAssertFalse(original.isEmpty)
    }

    func testIdentitySwitchWithNoSchoolAccountsDoesNotSeedOldApplicationPreferences() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets)
        defer { device.stop() }
        device.local.applicationPreferences["appearanceMode"] = try SyncCodec.encode("dark")
        await device.sync()
        cloud.current = MemoryCloudSyncClient(accountID: "second-apple-account")
        await device.sync()
        XCTAssertTrue(cloud.current.records.isEmpty, "An empty school-account list must not disable Apple-account data isolation")
    }

    func testCloudPayloadAndDurableJournalContainReferencesButNoRawSecrets() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let journal = String(decoding: try SyncCodec.encode(try XCTUnwrap(device.store.state)), as: UTF8.self)
        for forbidden in ["private-session", "private-password", Data("private-session".utf8).base64EncodedString(), Data("private-password".utf8).base64EncodedString()] {
            XCTAssertFalse(journal.contains(forbidden))
        }
        for record in try decoded(cloud) {
            for candidate in record.register.candidates {
                let text = String(decoding: candidate.value ?? Data(), as: UTF8.self)
                XCTAssertFalse(text.contains("private-session"))
                XCTAssertFalse(text.contains("private-password"))
            }
        }
        XCTAssertFalse(secrets.items.isEmpty, "Secrets must go through the separate credential store")
    }

    func testCloudDataBeforeKeychainWaitsThenRestoresWithoutReuploadingNewSession() async throws {
        let cloud = MemoryCloudSyncClient(), sourceSecrets = MemorySyncCredentialStore(), lateSecrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: sourceSecrets, accounts: [account()])
        let second = CoordinatorDevice("device-b", cloud: cloud, secrets: lateSecrets)
        defer { first.stop(); second.stop() }
        await first.sync(); await second.sync()
        XCTAssertEqual(second.coordinator.status, .waitingForCredentials)
        XCTAssertTrue(second.local.accounts.isEmpty)
        let sessionIDs = Set(try decoded(cloud).filter { $0.kind == .session }.map(\.id))
        for (key, value) in sourceSecrets.items { try lateSecrets.setData(value, for: key) }
        await second.sync()
        XCTAssertEqual(second.local.accounts.first?.session.sessionId, "private-session")
        XCTAssertEqual(second.coordinator.status, .ready)
        await second.sync()
        XCTAssertEqual(Set(try decoded(cloud).filter { $0.kind == .session }.map(\.id)), sessionIDs)
    }

    func testFailedJournalWriteRetainsHostDataAndCanBeRetried() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let before = device.coordinator.state, remoteBefore = cloud.records
        device.local.accounts[0].preferences.confirmationEnabled = true
        store.saveError = CloudSyncStateError.unavailable
        XCTAssertThrowsError(try device.capture())
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertTrue(device.local.accounts[0].preferences.confirmationEnabled)
        XCTAssertEqual(cloud.records, remoteBefore)
        store.saveError = nil
        try device.capture(); await device.sync()
        let other = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { other.stop() }
        await other.sync()
        XCTAssertTrue(other.local.accounts[0].preferences.confirmationEnabled)
    }

    func testPartialRemoteSaveRetainsFailedPendingRecordAndRetries() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        cloud.failOneSave = true
        await device.sync()
        XCTAssertFalse(cloud.current.records.isEmpty)
        let state = try XCTUnwrap(device.store.state)
        let replica = try XCTUnwrap(state.identity.flatMap { state.replicas[$0] })
        XCTAssertEqual(replica.pending.count, 1)
        XCTAssertEqual(device.local.accounts.count, 1)
        if case .failed = device.coordinator.status { } else { XCTFail("Partial failure must not report success") }
        await device.sync()
        XCTAssertEqual(device.coordinator.status, .ready)
        XCTAssertTrue(try XCTUnwrap(device.coordinator.state.identity.flatMap { device.coordinator.state.replicas[$0] }).pending.isEmpty)
    }

    func testInvalidatingAnOldSessionCannotInvalidateNewLogin() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let second = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { first.stop(); second.stop() }
        await first.sync(); await second.sync()
        let old = try XCTUnwrap(second.lastIncoming?.accounts.first?.sessions.first?.reference)
        first.local.accounts[0].session = SchoolSession(userId: "user-1001", sessionId: "fresh-session", studentNo: "1001", name: "Test Student")
        try first.capture(explicitLogin: "1001")
        await first.sync()
        try second.coordinator.invalidateSession(accountID: "1001", reference: old)
        await second.sync(); await first.sync()
        XCTAssertEqual(first.local.accounts.first?.session.sessionId, "fresh-session")
        XCTAssertEqual(second.local.accounts.first?.session.sessionId, "fresh-session")
        XCTAssertFalse(second.lastIncoming?.accounts.first?.sessions.contains { $0.reference.id == old.id } ?? true)
    }

    func testFutureJournalVersionIsPreservedWithoutTransportAccess() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        var future = CloudSyncState(deviceID: "device-a")
        future.formatVersion = 99
        let store = MemoryCloudSyncStateStore(state: future)
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        XCTAssertThrowsError(try device.capture())
        await device.sync()
        XCTAssertEqual(cloud.calls, 0)
        XCTAssertEqual(store.state, future)
        XCTAssertEqual(device.local.accounts.count, 1)
        if case .failed = device.coordinator.status { } else { XCTFail("Newer journal must be reported instead of overwritten") }
    }

    func testLockedKeychainKeepsAccountAndQueuedReferencesUntilUnlocked() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        secrets.error = .keychainLocked
        await device.sync()
        XCTAssertEqual(device.coordinator.status, .waitingForCredentials)
        XCTAssertEqual(device.local.accounts.first?.session.sessionId, "private-session")
        XCTAssertEqual(device.local.accounts.first?.credentials?.password, "private-password")
        XCTAssertFalse(cloud.records.isEmpty)
        XCTAssertTrue(secrets.items.isEmpty)
        secrets.error = nil
        await device.sync()
        XCTAssertEqual(device.coordinator.status, .ready)
        let second = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { second.stop() }
        await second.sync()
        XCTAssertEqual(second.local.accounts.first?.credentials?.password, "private-password")
    }

    func testFailedHostApplyRetriesSavedIncomingDataWithoutDroppingLocalAccount() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let target = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { source.stop(); target.stop() }
        await source.sync(); await target.sync()
        source.local.accounts[0].preferences.confirmationEnabled = true
        try source.capture(); await source.sync()
        target.applyError = CloudSyncStateError.unavailable
        await target.sync()
        XCTAssertEqual(target.local.accounts.count, 1)
        XCTAssertFalse(target.local.accounts[0].preferences.confirmationEnabled)
        if case .failed = target.coordinator.status { } else { XCTFail("Failed host transaction must be reported") }
        target.applyError = nil
        await target.sync()
        XCTAssertTrue(target.local.accounts[0].preferences.confirmationEnabled)
        XCTAssertEqual(target.coordinator.status, .ready)
    }

    func testCASConflictRebasesConcurrentSessionsAndPasswordClear() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let second = CoordinatorDevice("device-z", cloud: cloud.current, secrets: secrets)
        defer { first.stop(); second.stop() }
        await first.sync(); await second.sync(); await first.sync()
        first.local.accounts[0].session = SchoolSession(userId: "user-1001", sessionId: "session-a", studentNo: "1001")
        first.local.accounts[0].credentials = nil
        try first.capture(explicitLogin: "1001")
        second.local.accounts[0].session = SchoolSession(userId: "user-1001", sessionId: "session-b", studentNo: "1001")
        second.local.accounts[0].credentials = StoredCredentials(username: "1001", password: "concurrent-b")
        try second.capture(explicitLogin: "1001")
        // A already fetched the old versions when B wins the first save on the server.
        cloud.beforeSave = { await second.sync() }
        await first.sync(); await second.sync(); await first.sync()
        XCTAssertGreaterThan(cloud.conflictCount, 0, "This test must exercise server CAS, not only client-side fetch merging")
        XCTAssertNil(first.local.accounts[0].credentials)
        XCTAssertNil(second.local.accounts[0].credentials)
        let candidateTokens = Set(first.lastIncoming?.accounts.first?.sessions.map { $0.session.sessionId } ?? [])
        XCTAssertTrue(candidateTokens.contains("session-a"))
        XCTAssertTrue(candidateTokens.contains("session-b"))
        XCTAssertEqual(first.local.accounts[0].session, second.local.accounts[0].session)
        XCTAssertEqual(first.coordinator.status, .ready)
        XCTAssertFalse(secrets.items.keys.contains { $0.contains("/password/") })
    }

    func testPhysicallyRemovedServerRecordIsRebasedInsteadOfRetryingStaleMetadataForever() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let id = try XCTUnwrap(try decoded(cloud.current).first { $0.kind == .accountPreference && $0.key == "confirmationEnabled" }?.id)
        device.local.accounts[0].preferences.confirmationEnabled = true
        try device.capture()
        cloud.beforeSave = { cloud.current.deleteRecord(id: id) }
        await device.sync()
        XCTAssertGreaterThan(cloud.missingRecordCount, 0)
        // The next pull observes deletion, drops only the etag, and recreates the pending edit.
        await device.sync()
        XCTAssertEqual(device.coordinator.status, .ready)
        let restored = try XCTUnwrap(try decoded(cloud.current).first { $0.id == id }?.resolvedCandidate?.value)
        XCTAssertTrue(try SyncCodec.decode(Bool.self, from: restored))
        XCTAssertTrue(device.local.accounts[0].preferences.confirmationEnabled)
    }

    func testFailedRemovalJournalDoesNotPublishTombstoneOrSuppressAccount() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let state = device.coordinator.state, records = cloud.records, items = secrets.items
        store.saveError = CloudSyncStateError.unavailable
        XCTAssertThrowsError(try device.coordinator.removeEverywhere(accountID: "1001"))
        XCTAssertEqual(device.coordinator.state, state)
        XCTAssertThrowsError(try device.coordinator.removeLocally(accountID: "1001"))
        XCTAssertEqual(device.coordinator.state, state)
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(device.local.accounts.count, 1)
        XCTAssertEqual(cloud.records, records)
        XCTAssertEqual(secrets.items, items)
        store.saveError = nil
        await device.sync()
        XCTAssertEqual(device.local.accounts.count, 1)
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testLoginChangedWhileFetchAwaitsCannotBeOverwrittenByStaleSnapshot() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        cloud.beforeFetchReturns = {
            await Task.yield()
            device.local.accounts[0].session = SchoolSession(userId: "user-1001", sessionId: "login-during-fetch", studentNo: "1001")
            device.local.accounts[0].credentials = StoredCredentials(username: "1001", password: "password-during-fetch")
            try device.capture(explicitLogin: "1001")
        }
        await device.sync()
        XCTAssertEqual(device.local.accounts[0].session.sessionId, "login-during-fetch")
        XCTAssertEqual(device.local.accounts[0].credentials?.password, "password-during-fetch")
        await device.sync()
        XCTAssertEqual(device.coordinator.status, .ready)
        let other = CoordinatorDevice("device-b", cloud: cloud.current, secrets: secrets)
        defer { other.stop() }
        await other.sync()
        XCTAssertEqual(other.local.accounts.first?.session.sessionId, "login-during-fetch")
        XCTAssertEqual(other.local.accounts.first?.credentials?.password, "password-during-fetch")
    }

    func testRemoteApplyAndRepeatedSyncDoNotCreateEchoVersions() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let receiver = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { source.stop(); receiver.stop() }
        await source.sync(); await receiver.sync(); await source.sync()
        source.local.accounts[0].preferences.confirmationEnabled = true
        try source.capture(); await source.sync(); await receiver.sync()
        let counter = receiver.coordinator.state.counter
        let records = cloud.records
        try receiver.capture()
        await receiver.sync(); await receiver.sync()
        XCTAssertEqual(receiver.coordinator.state.counter, counter)
        XCTAssertEqual(cloud.records, records)
        XCTAssertTrue(receiver.local.accounts[0].preferences.confirmationEnabled)
    }

    func testReturningToPriorAppleIdentityQuarantinesSameSchoolAccountFromOtherIdentity() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let appleA = cloud.current
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account(token: "session-apple-a")])
        defer { device.stop() }
        await device.sync()
        let originalA = appleA.records
        let appleB = MemoryCloudSyncClient(accountID: "apple-b")
        cloud.current = appleB
        await device.sync()
        device.local.accounts = [account(password: "password-apple-b", token: "session-apple-b")]
        device.local.accounts[0].preferences.reminderLeadMinutes = 30
        try device.capture(explicitLogin: "1001")
        await device.sync()
        XCTAssertFalse(appleB.records.isEmpty)
        cloud.current = appleA
        await device.sync()
        XCTAssertEqual(appleA.records, originalA, "Returning to an existing namespace must not upload the other identity's host data")
        XCTAssertEqual(device.local.accounts.first?.session.sessionId, "session-apple-b", "Quarantined school accounts must not be overwritten by a different Apple identity's inbound record")
        XCTAssertTrue(device.lastIncoming?.accounts.isEmpty ?? false)
        device.local.accounts[0].preferences.confirmationEnabled = true
        try device.capture(); await device.sync()
        XCTAssertEqual(appleA.records, originalA)
    }

    func testOfflineDeviceThatSkippedDeletionResetsGenerationAndRemovesOldCredentials() async throws {
        let cloud = MemoryCloudSyncClient(), sourceSecrets = MemorySyncCredentialStore(), offlineSecrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: sourceSecrets, accounts: [account()])
        let offline = CoordinatorDevice("device-b", cloud: cloud, secrets: offlineSecrets)
        defer { source.stop(); offline.stop() }
        await source.sync()
        for (key, value) in sourceSecrets.items { try offlineSecrets.setData(value, for: key) }
        await offline.sync()
        let oldKeys = Set(offlineSecrets.items.keys)
        offline.local.accounts[0].preferences.autoSignEnabled = true
        offline.local.accounts[0].preferences.reminderLeadMinutes = 30
        let oldRow = SyncAttendanceRecord(courseName: "Old generation", date: Date(timeIntervalSince1970: 100), message: "Old", succeeded: true)
        offline.local.attendance["1001"] = [oldRow]
        try offline.capture()
        try source.coordinator.removeEverywhere(accountID: "1001")
        source.local.accounts = []
        await source.sync()
        source.local.accounts = [account(password: "new-generation-password", token: "new-generation-session")]
        try source.capture(explicitLogin: "1001")
        await source.sync()
        for (key, value) in sourceSecrets.items { try offlineSecrets.setData(value, for: key) }
        await offline.sync()
        XCTAssertTrue(offline.lastIncoming?.deletedAccountIDs.contains("1001") ?? false, "A reset instruction must accompany the new account generation")
        XCTAssertEqual(offline.local.accounts.first?.session.sessionId, "new-generation-session")
        XCTAssertEqual(offline.local.accounts.first?.credentials?.password, "new-generation-password")
        XCTAssertFalse(try XCTUnwrap(offline.local.accounts.first).preferences.autoSignEnabled)
        XCTAssertEqual(offline.local.accounts.first?.preferences.reminderLeadMinutes, AccountPreferences().reminderLeadMinutes)
        XCTAssertTrue(offline.local.attendance["1001", default: []].isEmpty)
        XCTAssertTrue(oldKeys.isDisjoint(with: offlineSecrets.items.keys))
        await offline.sync(); await source.sync()
        XCTAssertEqual(source.local.accounts.first?.session.sessionId, "new-generation-session")
    }

    func testPasswordKeychainItemArrivingBeforeItsMetadataIsNotDeleted() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let observer = CoordinatorDevice("device-b", cloud: cloud.current, secrets: secrets)
        defer { source.stop(); observer.stop() }
        await source.sync(); await observer.sync()
        let oldKeys = Set(secrets.items.keys)
        source.local.accounts[0].credentials = StoredCredentials(username: "1001", password: "new-password-before-metadata")
        try source.capture(explicitLogin: "1001")
        cloud.beforeSave = {
            let earlyKeys = Set(secrets.items.keys).subtracting(oldKeys)
            XCTAssertTrue(earlyKeys.contains { $0.contains("/password/") })
            await observer.sync()
            XCTAssertTrue(earlyKeys.isSubset(of: Set(secrets.items.keys)), "Old metadata must never delete a newer Keychain item")
        }
        await source.sync(); await observer.sync()
        XCTAssertEqual(observer.local.accounts.first?.credentials?.password, "new-password-before-metadata")
        XCTAssertEqual(observer.coordinator.status, .ready)
    }

    func testNewGenerationKeysSurviveBothOldProfileAndDeletionMetadata() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let observer = CoordinatorDevice("device-b", cloud: cloud.current, secrets: secrets)
        defer { source.stop(); observer.stop() }
        await source.sync(); await observer.sync()
        try source.coordinator.removeEverywhere(accountID: "1001")
        source.local.accounts = []
        await source.sync()
        source.local.accounts = [account(password: "new-incarnation-password", token: "new-incarnation-session")]
        try source.capture(explicitLogin: "1001")
        cloud.beforeSave = {
            let earlyKeys = Set(secrets.items.keys)
            XCTAssertFalse(earlyKeys.isEmpty)
            await observer.sync()
            XCTAssertTrue(observer.local.accounts.isEmpty)
            XCTAssertTrue(earlyKeys.isSubset(of: Set(secrets.items.keys)), "A deleted account must not erase an unobserved new incarnation")
        }
        await source.sync(); await observer.sync()
        XCTAssertEqual(observer.local.accounts.first?.session.sessionId, "new-incarnation-session")
        XCTAssertEqual(observer.local.accounts.first?.credentials?.password, "new-incarnation-password")
        XCTAssertEqual(observer.coordinator.status, .ready)
    }

    func testReplicaBeforeKnownCredentialIndexMigratesWithoutInventingKnownKeys() throws {
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncCodec.encode(CloudSyncReplica())) as? [String: Any])
        encoded.removeValue(forKey: "knownCredentials")
        let migrated = try SyncCodec.decode(CloudSyncReplica.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertTrue(migrated.knownCredentials.isEmpty)
        XCTAssertEqual(migrated, CloudSyncReplica())
    }

    func testAppleNamespaceSwitchRebuildsCausalContextWithoutLeakingOtherDeviceIDs() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let appleA = cloud.current
        let appleB = MemoryCloudSyncClient(accountID: "apple-b")
        let writerA = CoordinatorDevice("remote-a", cloud: appleA, secrets: secrets, accounts: [account(token: "session-a")])
        let writerB = CoordinatorDevice("remote-b", cloud: appleB, secrets: secrets, accounts: [account(token: "session-b")])
        let switching = CoordinatorDevice("local-switcher", cloud: cloud, secrets: secrets)
        defer { writerA.stop(); writerB.stop(); switching.stop() }
        await writerA.sync(); await writerB.sync(); await switching.sync()
        XCTAssertNotNil(switching.coordinator.state.context["remote-a"])
        let counterA = switching.coordinator.state.counter

        cloud.current = appleB
        await switching.sync()
        switching.local.accounts = [account(token: "explicit-session-b")]
        try switching.capture(explicitLogin: "1001")
        await switching.sync()
        XCTAssertNil(switching.coordinator.state.context["remote-a"])
        XCTAssertNotNil(switching.coordinator.state.context["remote-b"])
        XCTAssertGreaterThan(switching.coordinator.state.counter, counterA)
        for record in try decoded(appleB) {
            XCTAssertNil(record.register.context["remote-a"])
            for candidate in record.register.candidates { XCTAssertNil(candidate.version.context["remote-a"]) }
        }
        let counterB = switching.coordinator.state.counter

        cloud.current = appleA
        await switching.sync()
        switching.local.accounts = [account(token: "explicit-session-a")]
        try switching.capture(explicitLogin: "1001")
        await switching.sync()
        XCTAssertNil(switching.coordinator.state.context["remote-b"])
        XCTAssertNotNil(switching.coordinator.state.context["remote-a"])
        XCTAssertGreaterThan(switching.coordinator.state.counter, counterB)
        for record in try decoded(appleA) {
            XCTAssertNil(record.register.context["remote-b"])
            for candidate in record.register.candidates { XCTAssertNil(candidate.version.context["remote-b"]) }
        }
    }

    func testReturningToAppleNamespaceWithOldTombstoneKeepsOtherIdentityLocalAccount() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let appleA = cloud.current
        let appleB = MemoryCloudSyncClient(accountID: "apple-b")
        let writerA = CoordinatorDevice("remote-a", cloud: appleA, secrets: secrets, accounts: [account(token: "session-a")])
        let switching = CoordinatorDevice("local-switcher", cloud: cloud, secrets: secrets)
        defer { writerA.stop(); switching.stop() }
        await writerA.sync(); await switching.sync()
        try writerA.coordinator.removeEverywhere(accountID: "1001")
        writerA.local.accounts = []
        await writerA.sync()

        cloud.current = appleB
        await switching.sync()
        switching.local.accounts = [account(password: "apple-b-password", token: "apple-b-session")]
        try switching.capture(explicitLogin: "1001")
        await switching.sync()
        let originalB = appleB.records

        cloud.current = appleA
        await switching.sync(); await switching.sync()
        XCTAssertEqual(switching.local.accounts.first?.session.sessionId, "apple-b-session")
        XCTAssertEqual(switching.local.accounts.first?.credentials?.password, "apple-b-password")
        XCTAssertFalse(switching.lastIncoming?.deletedAccountIDs.contains("1001") ?? true)
        XCTAssertTrue(switching.lastIncoming?.accounts.isEmpty ?? false)
        XCTAssertEqual(appleB.records, originalB)
        XCTAssertNil(try XCTUnwrap(try decoded(appleA).first { $0.kind == .account }).resolvedCandidate?.value)
    }

    func testRejectsNoncanonicalAccountTombstoneWithoutDeletingLocalData() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let before = device.coordinator.state, secretBefore = secrets.items
        let tombstone = SyncRecord(id: "noncanonical-account-id", kind: .account, accountID: "1001",
            register: SyncRegister(candidates: [.init(version: .init(deviceID: "corrupt-writer", counter: 1, mutationID: "bad-delete"), value: nil)]))
        _ = try await cloud.save([.init(id: tombstone.id, data: SyncCodec.encode(tombstone))])
        let remoteBefore = cloud.records
        await device.sync()
        XCTAssertEqual(device.local.accounts.first?.session.sessionId, "private-session")
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertEqual(secrets.items, secretBefore)
        XCTAssertEqual(cloud.records, remoteBefore)
        if case .failed = device.coordinator.status { } else { XCTFail("Invalid tombstone must be rejected") }
    }

    func testRejectsEmptyAccountRegisterWithoutTreatingItAsDeletion() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let before = device.coordinator.state, secretBefore = secrets.items
        let id = SyncIdentity.record(.account, account: "1001")
        let empty = SyncRecord(id: id, kind: .account, accountID: "1001", register: SyncRegister())
        _ = try await cloud.save([.init(id: id, data: SyncCodec.encode(empty), systemFields: cloud.records[id]?.systemFields)])
        let remoteBefore = cloud.records
        await device.sync()
        XCTAssertEqual(device.local.accounts.first?.session.sessionId, "private-session")
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertEqual(secrets.items, secretBefore)
        XCTAssertEqual(cloud.records, remoteBefore)
        if case .failed = device.coordinator.status { } else { XCTFail("An empty register is not a versioned deletion") }
    }

    func testForeignNamespaceReferenceCannotPublishMatchingLocalSecret() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = AuditedSyncCredentials()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let before = device.coordinator.state, secretBefore = secrets.storage.items
        let original = try XCTUnwrap(try decoded(cloud).first { $0.kind == .session })
        let reference = try SyncCodec.decode(SyncCredentialReference.self, from: XCTUnwrap(original.resolvedCandidate?.value))
        let version = SyncVersion(deviceID: "foreign-wire", counter: before.counter + 1, mutationID: "new-foreign-ref")
        var pieces = reference.id.split(separator: "/").map(String.init)
        pieces[1] = "different-apple-namespace"
        pieces[pieces.count - 1] = version.mutationID
        let foreign = SyncCredentialReference(id: pieces.joined(separator: "/"), version: version, fingerprint: reference.fingerprint)
        let id = SyncIdentity.record(.session, account: "1001", incarnation: original.incarnation, key: version.mutationID)
        let record = SyncRecord(id: id, kind: .session, accountID: "1001", incarnation: original.incarnation, key: version.mutationID,
            register: SyncRegister(candidates: [.init(version: version, value: try SyncCodec.encode(foreign))]))
        _ = try await cloud.save([.init(id: id, data: SyncCodec.encode(record))])
        secrets.writes = []
        await device.sync()
        XCTAssertTrue(secrets.writes.isEmpty, "Reject the whole batch before publishing any credential")
        XCTAssertEqual(secrets.storage.items, secretBefore)
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertNil(secrets.storage.items[foreign.id])
        if case .failed = device.coordinator.status { } else { XCTFail("Another Apple namespace must not be accepted") }
    }

    func testRevokedSessionKeyIsNotRepublishedDuringLaterSync() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = AuditedSyncCredentials()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        let record = try XCTUnwrap(try decoded(cloud).first { $0.kind == .session })
        let reference = try SyncCodec.decode(SyncCredentialReference.self, from: XCTUnwrap(record.resolvedCandidate?.value))
        try device.coordinator.invalidateSession(accountID: "1001", reference: reference)
        secrets.writes = []
        await device.sync(); await device.sync()
        XCTAssertFalse(secrets.writes.contains(reference.id))
        XCTAssertNil(secrets.storage.items[reference.id])
        XCTAssertEqual(device.local.accounts.first?.session.sessionId, "private-session", "The host may retain a token while showing its login-required state")
    }

    func testUnlimitedRetentionSyncsMoreThan100RecordsOlderThan90Days() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let receiver = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { source.stop(); receiver.stop() }
        let now = source.coordinator.now()
        source.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        source.local.attendance["1001"] = (0..<125).map {
            SyncAttendanceRecord(courseName: "Operation \($0)", date: now.addingTimeInterval(-Double(120 + $0) * 86_400),
                                 message: "done", succeeded: true)
        }
        source.local.executions["1001"] = (0..<125).map {
            historyExecution("automatic-\($0)", at: now.addingTimeInterval(-Double(120 + $0) * 86_400))
        }
        await source.sync(); await receiver.sync()
        XCTAssertEqual(receiver.local.attendance["1001"]?.count, 125)
        XCTAssertEqual(receiver.lastIncoming?.accounts.first?.history.count, 125)
        let history = try decoded(cloud).filter { $0.kind == .attendance || $0.kind == .autoHistory }
        XCTAssertEqual(history.count, 250)
        XCTAssertTrue(history.allSatisfy { $0.resolvedCandidate?.value != nil })
        XCTAssertEqual(source.coordinator.status, .ready)
    }

    func testSelectedRetentionCreatesTombstonesAndProtectsInProgressAutomaticHistory() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let offline = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { source.stop(); offline.stop() }
        let now = source.coordinator.now()
        source.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        source.local.attendance["1001"] = (0..<5).map {
            SyncAttendanceRecord(courseName: "Operation \($0)", date: now.addingTimeInterval(-Double($0) * 86_400),
                                 message: "done", succeeded: true)
        }
        source.local.executions["1001"] = [historyExecution("new", at: now),
            historyExecution("old-terminal", at: now.addingTimeInterval(-10 * 86_400)),
            historyExecution("old-active", at: now.addingTimeInterval(-10 * 86_400), stage: .needsAttention)]
        await source.sync(); await offline.sync()
        source.local.applicationPreferences = try HistoryRetentionSettings(
            operations: .init(maxCount: 2, maxAgeDays: 3), automatic: .init(maxCount: 1, maxAgeDays: 3)).applicationPreferences()
        try source.capture(); await source.sync(); await offline.sync(); await source.sync()
        XCTAssertEqual(offline.local.attendance["1001"]?.count, 2)
        XCTAssertEqual(Set(offline.lastIncoming?.accounts.first?.history.map(\.occurrenceKey) ?? []), ["new", "old-active"])
        let deleted = try decoded(cloud).filter { $0.resolvedCandidate?.value == nil }
        XCTAssertEqual(deleted.filter { $0.kind == .attendance }.count, 3)
        XCTAssertEqual(deleted.filter { $0.kind == .autoHistory }.count, 1)
        XCTAssertEqual(offline.lastIncoming?.accounts.first?.deletedAttendanceIDs.count, 3)
        XCTAssertEqual(offline.lastIncoming?.accounts.first?.deletedHistoryIDs.count, 1)
        // Relaxation cannot resurrect entries already explicitly deleted by a prior policy.
        source.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        try source.capture(); await source.sync(); await offline.sync()
        XCTAssertEqual(offline.local.attendance["1001"]?.count, 2)
        XCTAssertEqual(try decoded(cloud).filter { $0.kind == .attendance && $0.resolvedCandidate?.value == nil }.count, 3)
    }

    func testOfflineDevicesMergeRetentionFieldsBeforePruning() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let first = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let second = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { first.stop(); second.stop() }
        let now = first.coordinator.now()
        first.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        first.local.attendance["1001"] = (0..<4).map {
            SyncAttendanceRecord(courseName: "Row \($0)", date: now.addingTimeInterval(-Double($0) * 86_400), message: "done", succeeded: true)
        }
        first.local.executions["1001"] = [historyExecution("today", at: now),
            historyExecution("expired", at: now.addingTimeInterval(-10 * 86_400))]
        await first.sync(); await second.sync()
        first.local.applicationPreferences["history.operations.maxCount"] = try SyncCodec.encode(2)
        second.local.applicationPreferences["history.automatic.maxAgeDays"] = try SyncCodec.encode(1)
        try first.capture(); try second.capture()
        await first.sync(); await second.sync(); await first.sync()
        for device in [first, second] {
            let merged = try HistoryRetentionSettings.from(applicationPreferences: device.local.applicationPreferences)
            XCTAssertEqual(merged.operations.maxCount, 2)
            XCTAssertEqual(merged.automatic.maxAgeDays, 1)
            XCTAssertEqual(device.local.attendance["1001"]?.count, 2)
            XCTAssertEqual(device.lastIncoming?.accounts.first?.history.map(\.occurrenceKey), ["today"])
        }
    }

    func testFetchedUnlimitedPolicyPreventsOldLocalLimitFromDeletingNewlyCapturedHistory() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let oldLocal = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let relaxing = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { oldLocal.stop(); relaxing.stop() }
        oldLocal.local.applicationPreferences = try HistoryRetentionSettings(
            operations: .init(maxCount: 1), automatic: .init(maxAgeDays: 1)).applicationPreferences()
        await oldLocal.sync(); await relaxing.sync()
        relaxing.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        try relaxing.capture(); await relaxing.sync()
        let oldDate = oldLocal.coordinator.now().addingTimeInterval(-200 * 86_400)
        oldLocal.local.attendance["1001"] = (0..<120).map {
            SyncAttendanceRecord(courseName: "Offline \($0)", date: oldDate, message: "done", succeeded: true)
        }
        oldLocal.local.executions["1001"] = [historyExecution("old-offline", at: oldDate)]
        try oldLocal.capture()
        await oldLocal.sync(); await relaxing.sync()
        XCTAssertEqual(relaxing.local.attendance["1001"]?.count, 120)
        XCTAssertEqual(relaxing.lastIncoming?.accounts.first?.history.map(\.occurrenceKey), ["old-offline"])
        XCTAssertFalse(try decoded(cloud).contains {
            ($0.kind == .attendance || $0.kind == .autoHistory) && $0.resolvedCandidate?.value == nil
        })
        XCTAssertEqual(try HistoryRetentionSettings.from(applicationPreferences: oldLocal.local.applicationPreferences), HistoryRetentionSettings())
    }

    func testCASPolicyRelaxationIsResolvedBeforeHistoryTombstonesAreWritten() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let narrowing = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        let relaxing = CoordinatorDevice("device-z", cloud: cloud.current, secrets: secrets)
        defer { narrowing.stop(); relaxing.stop() }
        narrowing.local.applicationPreferences = try HistoryRetentionSettings(operations: .init(maxCount: 2)).applicationPreferences()
        await narrowing.sync(); await relaxing.sync()
        narrowing.local.applicationPreferences["history.operations.maxCount"] = try SyncCodec.encode(1)
        relaxing.local.applicationPreferences["history.operations.maxCount"] = try SyncCodec.encode(Int?.none)
        try narrowing.capture(); try relaxing.capture()
        narrowing.local.attendance["1001"] = (0..<6).map {
            SyncAttendanceRecord(courseName: "Concurrent \($0)", date: narrowing.coordinator.now(), message: "done", succeeded: true)
        }
        try narrowing.capture()
        cloud.beforeSave = { await relaxing.sync() }
        await narrowing.sync(); await relaxing.sync()
        XCTAssertGreaterThan(cloud.conflictCount, 0)
        XCTAssertNil(try HistoryRetentionSettings.from(applicationPreferences: narrowing.local.applicationPreferences).operations.maxCount)
        XCTAssertEqual(relaxing.local.attendance["1001"]?.count, 6)
        XCTAssertFalse(try decoded(cloud.current).contains { $0.kind == .attendance && $0.resolvedCandidate?.value == nil })
    }

    func testInvalidRemoteRetentionCannotDeleteHistoryOrAdvanceReplica() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        device.local.attendance["1001"] = [SyncAttendanceRecord(courseName: "Old", date: Date(timeIntervalSince1970: 1), message: "done", succeeded: true)]
        await device.sync()
        let before = device.coordinator.state
        let key = "history.operations.maxCount"
        let id = SyncIdentity.record(.appPreference, key: key)
        let record = SyncRecord(id: id, kind: .appPreference, key: key,
            register: .init(candidates: [.init(version: .init(deviceID: "bad-policy", counter: 1, mutationID: "invalid-limit"), value: Data("0".utf8))]))
        _ = try await cloud.save([.init(id: id, data: SyncCodec.encode(record))])
        await device.sync()
        XCTAssertEqual(device.local.attendance["1001"]?.count, 1)
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertFalse(try decoded(cloud).contains { $0.kind == .attendance && $0.resolvedCandidate?.value == nil })
        if case .failed = device.coordinator.status { } else { XCTFail("Invalid retention must stop the sync before mutation") }
    }

    func testExplicitOfflineCleanupSurvivesUnlimitedPolicyAndRestart() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        let now = device.coordinator.now()
        let row = SyncAttendanceRecord(courseName: "Deleted", date: now, message: "done", succeeded: true)
        device.local.attendance["1001"] = [row]
        device.local.executions["1001"] = [historyExecution("terminal", at: now), historyExecution("active", at: now, stage: .verifying)]
        await device.sync()
        let histories = try XCTUnwrap(device.lastIncoming?.accounts.first?.history)
        let terminalID = try XCTUnwrap(histories.first { $0.occurrenceKey == "terminal" }?.id)
        let activeID = try XCTUnwrap(histories.first { $0.occurrenceKey == "active" }?.id)
        device.stop()
        try device.coordinator.recordHistoryCleanup(accountID: "1001", attendanceIDs: [row.id], historyIDs: [terminalID, activeID])
        device.local.attendance["1001"] = []
        device.local.executions["1001"]?[0].discardHistory()
        device.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        try device.capture()
        let restarted = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store)
        restarted.local = device.local
        defer { restarted.stop() }
        await restarted.sync()
        XCTAssertTrue(restarted.local.attendance["1001", default: []].isEmpty)
        XCTAssertEqual(restarted.lastIncoming?.accounts.first?.deletedAttendanceIDs, [row.id])
        XCTAssertEqual(restarted.lastIncoming?.accounts.first?.deletedHistoryIDs, [terminalID])
        XCTAssertEqual(restarted.lastIncoming?.accounts.first?.history.map(\.id), [activeID])
        let other = CoordinatorDevice("device-b", cloud: cloud, secrets: secrets)
        defer { other.stop() }
        await other.sync()
        XCTAssertTrue(other.local.attendance["1001", default: []].isEmpty)
        XCTAssertEqual(other.lastIncoming?.accounts.first?.history.map(\.id), [activeID])
    }

    func testExplicitHistoryCleanupPersistenceFailureRollsBackWithoutRemoteDeletion() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        let row = SyncAttendanceRecord(courseName: "Retained", date: device.coordinator.now(), message: "done", succeeded: true)
        device.local.attendance["1001"] = [row]
        await device.sync()
        let before = device.coordinator.state, remoteBefore = cloud.records
        store.saveError = CloudSyncStateError.unavailable
        XCTAssertThrowsError(try device.coordinator.recordHistoryCleanup(accountID: "1001", attendanceIDs: [row.id]))
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertEqual(cloud.records, remoteBefore)
        XCTAssertEqual(device.local.attendance["1001"]?.count, 1)
    }

    func testNetworkFailuresRespectExponentialBackoffWithoutForce() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        cloud.current.error = .network
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 1)
        clock.addTimeInterval(9)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 1)
        clock.addTimeInterval(1)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 2)
        clock.addTimeInterval(19)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 2)
        cloud.current.error = nil
        clock.addTimeInterval(1)
        await device.coordinator.synchronize()
        XCTAssertGreaterThan(cloud.calls, 2)
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testServerRetryAfterSurvivesLocalEditsAndForegroundTicks() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        cloud.current.error = .service(retryAfter: 120)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 1)
        device.local.accounts[0].preferences.remindersEnabled = true
        try device.capture()
        clock.addTimeInterval(60)
        await device.coordinator.tick()
        XCTAssertEqual(cloud.calls, 1)
        clock.addTimeInterval(59)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 1)
        cloud.current.error = nil
        clock.addTimeInterval(1)
        await device.coordinator.tick()
        XCTAssertGreaterThan(cloud.calls, 1)
        XCTAssertEqual(device.coordinator.status, .ready)
        XCTAssertTrue(device.local.accounts[0].preferences.remindersEnabled)
    }

    func testRemoteNotificationFetchesBeforeNextForegroundPollingInterval() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("source", cloud: cloud, secrets: secrets, accounts: [account()])
        let receiver = CoordinatorDevice("receiver", cloud: cloud, secrets: secrets)
        defer { source.stop(); receiver.stop() }
        await source.sync(); await receiver.sync()
        source.local.accounts[0].preferences.confirmationEnabled = true
        try source.capture(); await source.sync()

        await receiver.coordinator.tick()
        XCTAssertFalse(receiver.local.accounts[0].preferences.confirmationEnabled)
        let result = await receiver.coordinator.remoteChangesAvailable()
        XCTAssertEqual(result, .newData)
        XCTAssertTrue(receiver.local.accounts[0].preferences.confirmationEnabled)
        let unchanged = await receiver.coordinator.remoteChangesAvailable()
        XCTAssertEqual(unchanged, .noData)
    }

    func testRemoteNotificationsDuringFetchCoalesceAndAwaitASecondFetch() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let source = CoordinatorDevice("source", cloud: cloud, secrets: secrets, accounts: [account()])
        let receiver = CoordinatorDevice("receiver", cloud: cloud, secrets: secrets)
        defer { source.stop(); receiver.stop() }
        await source.sync(); await receiver.sync()
        var resumeFetch: CheckedContinuation<Void, Never>?
        cloud.beforeFetchReturns = {
            await withCheckedContinuation { resumeFetch = $0 }
        }
        let sync = Task { await receiver.coordinator.synchronize() }
        for _ in 0..<1_000 where resumeFetch == nil { await Task.yield() }
        guard let continuation = resumeFetch else {
            XCTFail("The receiver must have fetched before the remote edit")
            sync.cancel()
            return
        }
        source.local.accounts[0].preferences.confirmationEnabled = true
        try source.capture(); await source.sync()
        let calls = cloud.calls
        var started = 0
        let notifications = (0..<8).map { _ in Task {
            started += 1
            return await receiver.coordinator.remoteChangesAvailable()
        } }
        for _ in 0..<1_000 where started < notifications.count { await Task.yield() }
        XCTAssertEqual(started, notifications.count)
        continuation.resume()
        await sync.value
        for notification in notifications {
            let result = await notification.value
            XCTAssertEqual(result, .newData)
        }
        XCTAssertTrue(receiver.local.accounts[0].preferences.confirmationEnabled)
        XCTAssertEqual(cloud.calls - calls, 2, "A burst of pushes needs only one additional account check and fetch")
    }

    func testRemoteNotificationHonorsRetryAfterAndPermanentFailure() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("receiver", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        cloud.current.error = .service(retryAfter: 120)
        await device.coordinator.synchronize()
        let failedCalls = cloud.calls
        cloud.current.error = nil
        clock.addTimeInterval(119)
        let deferred = await device.coordinator.remoteChangesAvailable()
        XCTAssertEqual(deferred, .noData)
        XCTAssertEqual(cloud.calls, failedCalls)
        clock.addTimeInterval(1)
        _ = await device.coordinator.remoteChangesAvailable()
        XCTAssertGreaterThan(cloud.calls, failedCalls)

        cloud.current.error = .cloudKitRequest(code: 15)
        let failed = await device.coordinator.remoteChangesAvailable()
        XCTAssertEqual(failed, .failed)
        let permanentCalls = cloud.calls
        cloud.current.error = nil
        clock.addTimeInterval(86_400)
        let ignored = await device.coordinator.remoteChangesAvailable()
        XCTAssertEqual(ignored, .noData)
        XCTAssertEqual(cloud.calls, permanentCalls)
    }

    func testDisabledCoordinatorIgnoresRemoteNotifications() async {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("receiver", cloud: cloud, secrets: secrets, enabled: false)
        let result = await device.coordinator.remoteChangesAvailable()
        XCTAssertEqual(result, .noData)
        XCTAssertEqual(cloud.calls, 0)
    }

    func testFirstNotificationWithEmptyCloudDoesNotReportDownloadedData() async {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("receiver", cloud: cloud, secrets: secrets)
        defer { device.stop() }
        let result = await device.coordinator.remoteChangesAvailable()
        XCTAssertEqual(result, .noData)
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testPermanentCloudKitRequestDoesNotLoopAndManualRetryPreservesPendingChanges() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        cloud.current.error = .cloudKitRequest(code: 15)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, 1)
        XCTAssertEqual(device.coordinator.status, .failed(CloudSyncError.cloudKitRequest(code: 15).localizedDescription))
        device.local.accounts[0].preferences.remindersEnabled = true
        try device.capture()
        let pending = device.coordinator.state
        cloud.current.error = nil
        clock.addTimeInterval(86_400)
        await device.coordinator.synchronize()
        await device.coordinator.tick()
        XCTAssertEqual(cloud.calls, 1, "Neither a foreground tick nor a local edit retries a permanent request")
        XCTAssertEqual(device.coordinator.state, pending)
        await device.coordinator.synchronize(force: true)
        XCTAssertGreaterThan(cloud.calls, 1)
        XCTAssertEqual(device.coordinator.status, .ready)
        XCTAssertTrue(device.local.accounts[0].preferences.remindersEnabled)
    }

    func testAccountChangeAndReEnablingAllowRetryAfterPermanentFailure() async throws {
        for signalAccountChange in [true, false] {
            let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
            let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
            defer { device.stop() }
            cloud.current.error = .cloudKitRequest(code: 19)
            await device.coordinator.synchronize()
            XCTAssertEqual(cloud.calls, 1)
            cloud.current.error = nil
            if signalAccountChange { device.coordinator.accountDidChange() }
            else { device.coordinator.setEnabled(false); device.coordinator.setEnabled(true) }
            await device.coordinator.synchronize()
            XCTAssertGreaterThan(cloud.calls, 1)
            XCTAssertEqual(device.coordinator.status, .ready)
        }
    }

    func testUnlockedCredentialsRecoverOnForegroundTickWithoutForce() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        secrets.error = .keychainLocked
        await device.coordinator.synchronize()
        XCTAssertEqual(device.coordinator.status, .waitingForCredentials)
        let calls = cloud.calls
        secrets.error = nil
        clock.addTimeInterval(60)
        await device.coordinator.tick()
        XCTAssertGreaterThan(cloud.calls, calls)
        XCTAssertEqual(device.coordinator.status, .ready)
        XCTAssertFalse(secrets.items.isEmpty)
    }

    func testTransientHostApplyFailureStillRetriesWithoutForce() async throws {
        let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
        defer { device.stop() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        device.coordinator.now = { clock }
        device.applyError = NSError(domain: "TestHost", code: 1)
        await device.coordinator.synchronize()
        let calls = cloud.calls
        clock.addTimeInterval(9)
        await device.coordinator.synchronize()
        XCTAssertEqual(cloud.calls, calls)
        device.applyError = nil
        clock.addTimeInterval(1)
        await device.coordinator.synchronize()
        XCTAssertGreaterThan(cloud.calls, calls)
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testMixedSaveFailuresPreferPermanentCauseInBothSavePhases() async throws {
        for policyPhase in [true, false] {
            let cloud = CountingCloud(), secrets = MemorySyncCredentialStore()
            let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
            defer { device.stop() }
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            device.coordinator.now = { clock }
            if policyPhase { device.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences() }
            cloud.nextSaveFailures = [.service(retryAfter: 120), .cloudKitRequest(code: 15)]
            await device.coordinator.synchronize()
            let calls = cloud.calls
            XCTAssertEqual(device.coordinator.status, .failed(CloudSyncError.cloudKitRequest(code: 15).localizedDescription))
            XCTAssertTrue(device.coordinator.state.replicas.values.contains { !$0.pending.isEmpty })
            clock.addTimeInterval(86_400)
            await device.coordinator.tick()
            XCTAssertEqual(cloud.calls, calls)
        }
    }

    func testDeletedZoneRequiresReenableAndReuploadsRecordsWithoutStaleServerMetadata() async throws {
        for failure: CloudSyncError in [.zoneMissing, .zoneDeletedByUser] {
            let cloud = RecoverableZoneCloud(), secrets = MemorySyncCredentialStore()
            let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
            defer { device.stop() }
            let row = SyncAttendanceRecord(courseName: "Keep", date: Date(timeIntervalSince1970: 100), message: "Done", succeeded: true)
            device.local.attendance["1001"] = [row]
            await device.sync()
            let identity = try XCTUnwrap(device.coordinator.state.identity)
            let saved = try XCTUnwrap(device.coordinator.state.replicas[identity])
            XCTAssertNotNil(saved.cursor)
            XCTAssertFalse(saved.systemFields.isEmpty)
            XCTAssertTrue(saved.pending.isEmpty)

            cloud.removeZone(error: failure)
            await device.sync()
            let calls = cloud.fetchCalls
            device.coordinator.now = { Date(timeIntervalSince1970: 1_800_086_400) }
            await device.coordinator.tick()
            await device.sync()
            XCTAssertEqual(cloud.fetchCalls, calls, "A manual fetch alone cannot authorize rebuilding the deleted zone")
            XCTAssertEqual(cloud.recoveryCalls, 0)
            XCTAssertEqual(device.coordinator.state.replicas[identity]?.cursor, saved.cursor)
            XCTAssertEqual(device.coordinator.state.replicas[identity]?.systemFields, saved.systemFields)
            XCTAssertTrue(cloud.current.records.isEmpty)

            device.coordinator.setEnabled(false)
            device.coordinator.setEnabled(true)
            await device.sync()
            XCTAssertEqual(cloud.recoveryCalls, 1)
            XCTAssertEqual(cloud.recreationCount, 1)
            XCTAssertTrue(cloud.uploads.allSatisfy { $0.systemFields == nil })
            XCTAssertEqual(Set(cloud.current.records.keys), Set(saved.records.keys))
            let recovered = try Dictionary(uniqueKeysWithValues: decoded(cloud.current).map { ($0.id, $0) })
            XCTAssertEqual(recovered, saved.records, "Recovery republishes existing mutations, not new credentials or account generations")
            XCTAssertEqual(device.local.attendance["1001"], [row])
            XCTAssertEqual(device.local.accounts.first?.session.sessionId, "private-session")
            XCTAssertEqual(device.coordinator.status, .ready)
        }
    }

    func testZoneRecoveryPreservesDeletionRevocationAndLocalAccountExclusions() async throws {
        let cloud = RecoverableZoneCloud(), secrets = AuditedSyncCredentials(), store = MemoryCloudSyncStateStore()
        func extra(_ id: String) -> StoredAccount {
            StoredAccount(session: SchoolSession(userId: "user-\(id)", sessionId: "session-\(id)", studentNo: id, name: "Test"),
                          credentials: StoredCredentials(username: id, password: "password-\(id)"))
        }
        let source = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store,
                                       accounts: [account(), extra("2002"), extra("3003"), extra("4004")])
        defer { source.stop() }
        await source.sync()
        try source.coordinator.invalidateLocalSession(source.local.accounts[0].session)
        source.local.accounts[0].credentials = nil
        try source.coordinator.removeEverywhere(accountID: "2002")
        try source.coordinator.removeLocally(accountID: "3003")
        source.local.accounts.removeAll { ["2002", "3003"].contains($0.id) }
        try source.capture()
        await source.sync()
        source.stop()

        var savedState = try XCTUnwrap(store.state)
        let identity = try XCTUnwrap(savedState.identity)
        savedState.replicas[identity]?.quarantinedAccounts.insert("4004")
        store.state = savedState
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: source.local.accounts)
        defer { device.stop() }
        let before = try XCTUnwrap(savedState.replicas[identity])
        let revocations = before.records.values.filter { $0.kind == .invalidSession && $0.accountID == "1001" }
        XCTAssertFalse(revocations.isEmpty)
        let expectedSecrets = secrets.storage.items
        secrets.writes.removeAll()
        cloud.removeZone(error: .zoneDeletedByUser)
        await device.sync()
        device.coordinator.setEnabled(false)
        device.coordinator.setEnabled(true)
        await device.sync()

        let recovered = try decoded(cloud.current)
        XCTAssertTrue(recovered.contains { $0.kind == .account && $0.accountID == "2002" && $0.resolvedCandidate?.value == nil })
        XCTAssertTrue(recovered.filter { $0.accountID == "2002" }.allSatisfy { $0.resolvedCandidate?.value == nil })
        XCTAssertFalse(recovered.contains { ["3003", "4004"].contains($0.accountID ?? "") })
        XCTAssertTrue(recovered.contains { $0.kind == .password && $0.accountID == "1001" && $0.resolvedCandidate?.value == nil })
        for revocation in revocations { XCTAssertTrue(recovered.contains(revocation)) }
        XCTAssertEqual(Set(device.local.accounts.map(\.id)), ["1001", "4004"])
        XCTAssertEqual(secrets.storage.items, expectedSecrets)
        XCTAssertTrue(secrets.writes.isEmpty, "Recovery must not republish revoked or removed credentials")
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testZoneRecoveryAuthorizationDoesNotFollowAnotherAppleAccountOrSurviveCancellation() async throws {
        for changeAccount in [true, false] {
            let cloud = RecoverableZoneCloud(), secrets = MemorySyncCredentialStore()
            let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
            defer { device.stop() }
            await device.sync()
            let originalIdentity = try XCTUnwrap(device.coordinator.state.identity)
            let original = try XCTUnwrap(device.coordinator.state.replicas[originalIdentity])
            cloud.removeZone(error: .zoneDeletedByUser)
            await device.sync()
            device.coordinator.setEnabled(false)
            device.coordinator.setEnabled(true)
            if changeAccount {
                cloud.current = MemoryCloudSyncClient(accountID: "another-apple-account")
            } else {
                cloud.beforeRecovery = { device.coordinator.accountDidChange() }
            }
            await device.sync()
            XCTAssertEqual(cloud.recreationCount, 0)
            XCTAssertEqual(cloud.recoveryCalls, changeAccount ? 0 : 1)
            XCTAssertEqual(device.coordinator.state.replicas[originalIdentity]?.cursor, original.cursor)
            XCTAssertEqual(device.coordinator.state.replicas[originalIdentity]?.systemFields, original.systemFields)
            XCTAssertTrue(cloud.current.records.isEmpty)
        }
    }

    func testZoneRecoveryPersistenceFailurePreservesReplicaAndRequiresAnotherExplicitAttempt() async throws {
        let cloud = RecoverableZoneCloud(), secrets = MemorySyncCredentialStore(), store = MemoryCloudSyncStateStore()
        let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, store: store, accounts: [account()])
        defer { device.stop() }
        await device.sync()
        cloud.removeZone(error: .zoneMissing)
        await device.sync()
        let before = device.coordinator.state
        store.saveError = CloudSyncStateError.unavailable
        device.coordinator.setEnabled(false)
        device.coordinator.setEnabled(true)
        await device.sync()
        XCTAssertEqual(device.coordinator.state, before)
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(cloud.recoveryCalls, 1)
        XCTAssertTrue(cloud.current.records.isEmpty)
        device.coordinator.now = { Date(timeIntervalSince1970: 1_800_086_400) }
        let calls = cloud.fetchCalls
        await device.coordinator.tick()
        XCTAssertEqual(cloud.fetchCalls, calls)

        store.saveError = nil
        device.coordinator.setEnabled(false)
        device.coordinator.setEnabled(true)
        await device.sync()
        XCTAssertEqual(cloud.recoveryCalls, 2)
        XCTAssertFalse(cloud.current.records.isEmpty)
        XCTAssertEqual(device.coordinator.status, .ready)
    }

    func testReenablingAfterOtherCloudErrorsDoesNotAuthorizeZoneRecovery() async throws {
        for failure: CloudSyncError in [.encryptedDataReset, .cloudKitRequest(code: 15)] {
            let cloud = RecoverableZoneCloud(), secrets = MemorySyncCredentialStore()
            let device = CoordinatorDevice("device-a", cloud: cloud, secrets: secrets, accounts: [account()])
            defer { device.stop() }
            await device.sync()
            let identity = try XCTUnwrap(device.coordinator.state.identity)
            let before = try XCTUnwrap(device.coordinator.state.replicas[identity])
            cloud.zoneError = failure
            await device.sync()
            device.coordinator.setEnabled(false)
            device.coordinator.setEnabled(true)
            await device.sync()
            XCTAssertEqual(cloud.recoveryCalls, 0)
            XCTAssertEqual(device.coordinator.state.replicas[identity]?.cursor, before.cursor)
            XCTAssertEqual(device.coordinator.state.replicas[identity]?.systemFields, before.systemFields)
        }
    }

    private func historyExecution(_ key: String, at date: Date, stage: AutoSignStage = .signed) -> AutoSignExecution {
        var value = AutoSignExecution(key: key, now: date)
        value.startedAt = date
        value.submissions = 1
        value.transition(stage, now: date, message: "History \(key)")
        return value
    }

    private func decoded(_ cloud: MemoryCloudSyncClient) throws -> [SyncRecord] {
        try cloud.records.values.map { try SyncCodec.decode(SyncRecord.self, from: $0.data) }
    }
}

@MainActor
private final class AuditedSyncCredentials: CredentialSyncStore {
    let storage = MemorySyncCredentialStore()
    var writes: [String] = []
    func data(for id: String) throws -> Data? { try storage.data(for: id) }
    func setData(_ data: Data, for id: String) throws { writes.append(id); try storage.setData(data, for: id) }
    func removeData(for id: String) throws { try storage.removeData(for: id) }
    func allIDs() throws -> [String] { try storage.allIDs() }
}

/// Models a host transaction while keeping sessions/passwords in a distinct transport.
@MainActor
private final class CoordinatorDevice {
    var local: CloudSyncLocalSnapshot
    var lastIncoming: CloudSyncIncoming?
    var applyError: Error?
    let coordinator: CloudSyncCoordinator
    let store: MemoryCloudSyncStateStore

    init(_ id: String, cloud: any CloudSyncClient, secrets: any CredentialSyncStore,
         store: MemoryCloudSyncStateStore? = nil, accounts: [StoredAccount] = [], enabled: Bool = true) {
        local = CloudSyncLocalSnapshot(accounts: accounts)
        self.store = store ?? MemoryCloudSyncStateStore()
        coordinator = CloudSyncCoordinator(client: cloud, credentials: secrets, store: self.store,
                                           deviceID: id, deviceName: "Test \(id)", enabled: enabled)
        coordinator.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        coordinator.snapshot = { [weak self] in self?.local ?? CloudSyncLocalSnapshot() }
        coordinator.apply = { [weak self] incoming in try self?.apply(incoming) }
    }
    func sync() async { await coordinator.synchronize(force: true) }
    func capture(explicitLogin: String? = nil) throws { try coordinator.recordLocalChanges(local, explicitLogin: explicitLogin) }
    func stop() { coordinator.setEnabled(false) }

    private func apply(_ incoming: CloudSyncIncoming) throws {
        if let applyError { throw applyError }
        lastIncoming = incoming
        var updated = local
        updated.applicationPreferences.merge(incoming.applicationPreferences) { _, remote in remote }
        updated.accounts.removeAll { incoming.deletedAccountIDs.contains($0.id) }
        for change in incoming.accounts {
            let id = change.profile.studentNo
            let existing = updated.accounts.first { $0.id == id }
            guard let session = change.sessions.first?.session ?? existing?.session else { continue }
            var account = existing ?? StoredAccount(session: session)
            account.session = session
            try SyncPreferenceProjection.applyAccount(change.preferences, to: &account.preferences)
            for (courseID, fields) in change.courses {
                var course = account.preferences.courses[courseID] ?? CoursePreferences()
                try SyncPreferenceProjection.applyCourse(fields, to: &course)
                account.preferences.courses[courseID] = course
            }
            switch change.password {
            case .unchanged: break
            case .clear: account.credentials = nil
            case .value(let value): account.credentials = value
            }
            if let index = updated.accounts.firstIndex(where: { $0.id == id }) { updated.accounts[index] = account }
            else { updated.accounts.append(account) }
            updated.attendance[id] = change.attendance
        }
        local = updated
    }
}

@MainActor
private final class CountingCloud: CloudSyncClient {
    var current = MemoryCloudSyncClient(accountID: "original-apple-account")
    var calls = 0
    var failOneSave = false
    var nextSaveFailures: [CloudSyncError]?
    var beforeSave: (() async throws -> Void)?
    var beforeFetchReturns: (() async throws -> Void)?
    var conflictCount = 0
    var missingRecordCount = 0
    func accountIdentifier() async throws -> String { calls += 1; return try await current.accountIdentifier() }
    func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges {
        calls += 1
        let result = try await current.fetchChanges(cursor: cursor)
        if let beforeFetchReturns {
            self.beforeFetchReturns = nil
            try await beforeFetchReturns()
        }
        return result
    }
    func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult {
        calls += 1
        if let errors = nextSaveFailures {
            nextSaveFailures = nil
            return .init(failures: zip(records, errors).map { .init(id: $0.0.id, error: $0.1) })
        }
        if let beforeSave {
            self.beforeSave = nil
            try await beforeSave()
        }
        if failOneSave, let failed = records.first {
            failOneSave = false
            let result = try await current.save(Array(records.dropFirst()))
            return CloudSyncSaveResult(saved: result.saved, conflicts: result.conflicts,
                                       failures: [CloudSyncRecordFailure(id: failed.id, error: .quotaExceeded)])
        }
        let result = try await current.save(records)
        conflictCount += result.conflicts.count
        missingRecordCount += result.failures.filter { $0.error == .recordMissing }.count
        return result
    }
}

@MainActor
private final class RecoverableZoneCloud: CloudSyncZoneRecoveryClient {
    var current = MemoryCloudSyncClient(accountID: "original-apple-account")
    var zoneError: CloudSyncError?
    var beforeRecovery: (() async throws -> Void)?
    var fetchCalls = 0
    var recoveryCalls = 0
    var recreationCount = 0
    var uploads: [CloudSyncRecord] = []

    func removeZone(error: CloudSyncError) {
        current = MemoryCloudSyncClient(accountID: current.accountID)
        zoneError = error
        uploads.removeAll()
    }

    func accountIdentifier() async throws -> String { try await current.accountIdentifier() }
    func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges {
        fetchCalls += 1
        if let zoneError { throw zoneError }
        return try await current.fetchChanges(cursor: cursor)
    }
    func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult {
        if let zoneError { throw zoneError }
        uploads += records
        return try await current.save(records)
    }
    func recoverDeletedZone() async throws {
        recoveryCalls += 1
        if let beforeRecovery {
            self.beforeRecovery = nil
            try await beforeRecovery()
        }
        try Task.checkCancellation()
        if let zoneError {
            guard zoneError == .zoneMissing || zoneError == .zoneDeletedByUser else { throw zoneError }
            recreationCount += 1
            self.zoneError = nil
        }
    }
}
