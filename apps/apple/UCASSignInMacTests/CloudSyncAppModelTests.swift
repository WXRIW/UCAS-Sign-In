import XCTest
import UserNotifications
@testable import UCASSignInMac

/// Exercises the real AppModel/coordinator boundary with memory cloud, credential,
/// account, notification and widget stores. No Apple or school account is accessed.
@MainActor
final class CloudSyncAppModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var coordinators: [CloudSyncCoordinator] = []

    override func setUp() async throws {
        suiteName = "CloudSyncAppModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "iCloudSyncEnabled")
    }

    override func tearDown() async throws {
        coordinators.forEach { $0.setEnabled(false) }
        coordinators.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testRemoteOrdinaryPreferencesPreserveEveryLocalAutomaticSetting() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        var local = cloudAccount()
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        local.preferences = AccountPreferences(autoSignEnabled: false, courses: ["stable-course":
            CoursePreferences(autoSign: .enabled, autoSignRule: .init(offsetMinutes: -12, retryMinutes: 5),
                              autoSignEnabledSince: boundary)], autoSignRunning: false,
            autoSignRule: .init(offsetMinutes: -10, missedAction: .untilClassEnds, maxSubmissions: 2,
                                retryMinutes: 5, notification: .none),
            autoSignOccurrences: ["occurrence": .init(enabled: true, at: boundary,
                policy: .init(maxSubmissions: 1), enabledSince: boundary)],
            autoSignPausedUntil: boundary.addingTimeInterval(100), autoSignV2Acknowledged: true,
            autoSignRunningSince: boundary, autoSignDefaultSince: boundary.addingTimeInterval(1),
            autoSignSinceUsesSchoolTime: false, autoSignPendingClockBoundaries: [boundary])
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [local], active: local.id)
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await source.sync()
        await enable(model)
        let preserved = try XCTUnwrap(store.vault.accounts.first).preferences

        source.local.accounts[0].preferences.confirmationEnabled = true
        source.local.accounts[0].preferences.remindersEnabled = true
        source.local.accounts[0].preferences.reminderLeadMinutes = 30
        source.local.accounts[0].preferences.autoSignEnabled = true
        source.local.accounts[0].preferences.autoSignRunning = true
        source.local.accounts[0].preferences.courses["stable-course"] = .init(
            confirmation: .enabled, autoSign: .disabled, reminders: .disabled,
            reminderLeadMinutes: 15, signInDisabled: true,
            autoSignRule: .init(offsetMinutes: 200), autoSignEnabledSince: .distantFuture)
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()

        var expected = preserved
        expected.confirmationEnabled = true
        expected.remindersEnabled = true
        expected.reminderLeadMinutes = 30
        expected.courses["stable-course"]?.confirmation = .enabled
        expected.courses["stable-course"]?.reminders = .disabled
        expected.courses["stable-course"]?.reminderLeadMinutes = 15
        expected.courses["stable-course"]?.signInDisabled = true
        XCTAssertEqual(store.vault.accounts.first?.preferences, expected)
        XCTAssertFalse(model.autoSignRunning)
        XCTAssertEqual(model.autoSignRule, preserved.autoSignRule)
        XCTAssertEqual(model.autoSignOccurrences, preserved.autoSignOccurrences)
        XCTAssertEqual(model.coursePreferences["stable-course"], expected.courses["stable-course"])
        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertTrue(model.remindersEnabled)
        XCTAssertEqual(model.reminderLeadMinutes, 30)
    }

    func testMissingKeychainSecretKeepsPendingProfileUntilValidatedSessionArrives() async throws {
        let cloud = MemoryCloudSyncClient(), sourceSecrets = MemorySyncCredentialStore()
        let receiverSecrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, sourceSecrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [], active: nil)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, receiverSecrets, transport: transport)
        await model.restore()
        await source.sync()
        await enable(model)

        XCTAssertEqual(model.iCloudPendingAccounts.map(\.studentNo), [cloudAccount().id])
        XCTAssertEqual(model.iCloudSyncStatus, .waitingForCredentials)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(model.session)
        XCTAssertNil(model.activeAccountID)
        let before = await transport.courseRequests
        XCTAssertEqual(before, 0)

        for (key, value) in sourceSecrets.items { try receiverSecrets.setData(value, for: key) }
        await model.synchronizeICloud()
        XCTAssertTrue(model.iCloudPendingAccounts.isEmpty)
        XCTAssertEqual(model.accounts.first?.session, cloudAccount().session)
        XCTAssertEqual(model.accounts.first?.credentials, cloudAccount().credentials)
        XCTAssertFalse(try XCTUnwrap(model.accounts.first).preferences.autoSignIsRunning)
        XCTAssertEqual(model.activeAccountID, cloudAccount().id, "The first validated account becomes the initial selection")
        XCTAssertEqual(model.session, cloudAccount().session)
        let after = await transport.courseRequests
        XCTAssertEqual(after, 1, "A shared session must pass a read-only school request before being stored")
    }

    func testFirstRestoreSelectsAccountWithNewestValidatedSession() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let older = cloudAccount(token: "session-second-account", studentNo: "2026000101")
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount(), older])
        await source.sync()
        let newest = cloudAccount(token: "session-newest")
        source.local.accounts[0].session = newest.session
        try source.capture(explicitLogin: newest.id)
        await source.sync()
        let store = CloudAccountStore(accounts: [], active: nil)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, secrets, transport: transport)
        await model.restore()
        await enable(model)

        XCTAssertEqual(Set(model.accounts.map(\.id)), Set([newest.id, older.id]))
        XCTAssertEqual(model.activeAccountID, newest.id)
        XCTAssertEqual(model.session, newest.session)
        XCTAssertEqual(store.vault.activeAccountID, newest.id)
        XCTAssertTrue(model.iCloudPendingAccounts.isEmpty)
        XCTAssertTrue(model.accounts.allSatisfy { !$0.preferences.autoSignIsRunning })
        let newestValidations = await transport.count(session: newest.session.sessionId)
        let olderValidations = await transport.count(session: older.session.sessionId)
        XCTAssertEqual(newestValidations, 1)
        XCTAssertEqual(olderValidations, 1)
    }

    func testRemoteReenableCreatesLocalParticipationBoundaryWithoutBackfillingGraceWindow() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let schoolNow = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let priorBoundary = schoolNow.addingTimeInterval(-3_600)
        var sourceAccount = cloudAccount()
        sourceAccount.preferences.courses["stable-course"] = .init(signInDisabled: true)
        let source = sourceDevice(cloud, secrets, accounts: [sourceAccount])
        var local = cloudAccount()
        local.preferences = .init(autoSignEnabled: true, courses: ["stable-course":
            .init(autoSign: .enabled, signInDisabled: true, autoSignEnabledSince: priorBoundary)],
            autoSignRunning: true,
            autoSignRule: .init(offsetMinutes: 25, missedAction: .tenMinuteGrace, notification: .none),
            autoSignV2Acknowledged: true, autoSignRunningSince: priorBoundary,
            autoSignDefaultSince: priorBoundary, autoSignSinceUsesSchoolTime: true)
        let store = CloudAccountStore(accounts: [local], active: local.id)
        let transport = CloudTransport(clockDate: schoolNow)
        let model = makeModel(store, cloud, secrets, transport: transport, now: schoolNow)
        await model.restore()
        await source.sync()
        await enable(model)
        XCTAssertTrue(model.coursePreferences(for: "stable-course").signInDisabled)
        source.local.accounts[0].preferences.courses["stable-course"]?.signInDisabled = false
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()
        await model.foregroundTick()

        let preference = model.coursePreferences(for: "stable-course")
        XCTAssertFalse(preference.signInDisabled)
        XCTAssertEqual(preference.autoSignEnabledSince, schoolNow)
        XCTAssertEqual(preference.autoSign, .enabled)
        XCTAssertTrue(model.autoSignRunning)
        XCTAssertEqual(model.autoSignRule, local.preferences.autoSignRule)
        let plan = try XCTUnwrap(model.autoSignPlans.first)
        XCTAssertEqual(plan.plannedAt, schoolNow.addingTimeInterval(-300))
        XCTAssertGreaterThanOrEqual(plan.deadline, schoolNow, "The missed plan is still in its ordinary grace window")
        XCTAssertFalse(plan.isParticipating, "A remote re-enable must exclude plans that predate this device's participation boundary")
        XCTAssertTrue(model.autoSignHistory.isEmpty)
        let submissions = await transport.signRequests
        XCTAssertEqual(submissions, 0)
    }

    func testRemoteHistoryIsDisplayOnlyAndNeverEntersExecutionLedger() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, secrets, transport: transport)
        await model.restore()
        await source.sync()
        await enable(model)
        var execution = AutoSignExecution(key: "remote-pending-occurrence", now: .now)
        execution.courseName = "另一台设备的课程"
        execution.startedAt = .now
        execution.submissions = 1
        execution.lastSchoolSubmissionAt = .now
        execution.nextSchoolVerificationAt = .now
        execution.transition(.retryWaiting, now: .now, message: "远端等待验证", nextAt: .now)
        source.local.executions[cloudAccount().id] = [execution]
        let attendance = SyncAttendanceRecord(courseName: "历史课程", date: .now,
                                              message: "远端签到记录", succeeded: true)
        source.local.attendance[cloudAccount().id] = [attendance]
        try source.capture()
        await source.sync()
        let ledgerBefore = defaults.data(forKey: "auto-sign-\(cloudAccount().id)")
        await model.synchronizeICloud()

        XCTAssertEqual(model.displayAutoSignHistory.count, 1)
        XCTAssertEqual(model.displayAutoSignHistory.first?.sourceDeviceID, "remote-device")
        XCTAssertEqual(model.displayAutoSignHistory.first?.stage, .retryWaiting)
        XCTAssertEqual(model.records, [attendance])
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "auto-sign-\(cloudAccount().id)"), ledgerBefore)
        XCTAssertFalse(model.autoSignRunning)
        let submissions = await transport.signRequests
        XCTAssertEqual(submissions, 0)
    }

    func testRemoteDisableCancelsExistingConfirmation() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, secrets, transport: transport)
        await model.restore()
        await source.sync()
        await enable(model)
        let course = try XCTUnwrap(model.todayCourses.first)
        let confirmation = PendingSignConfirmation(course: course, accountGeneration: model.accountGeneration)
        model.pendingSignConfirmation = confirmation
        source.local.accounts[0].preferences.courses["stable-course"] = .init(signInDisabled: true)
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()

        XCTAssertNil(model.pendingSignConfirmation)
        XCTAssertTrue(model.isSignInDisabled(for: course))
        await model.confirmPendingSign(confirmation)
        let submissions = await transport.signRequests
        XCTAssertEqual(submissions, 0)
    }

    func testStaleCourseFormChangesOnlyEditedFieldAfterRemotePreferenceArrives() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await source.sync()
        await enable(model)
        let previous = model.coursePreferences(for: "stable-course")
        var proposed = previous
        proposed.autoSignRule = .init(retryMinutes: 5)
        source.local.accounts[0].preferences.courses["stable-course"] = .init(
            confirmation: .enabled, reminders: .disabled, reminderLeadMinutes: 30)
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()
        let saved = await model.setCoursePreferences(proposed, for: "stable-course", relativeTo: previous)

        XCTAssertTrue(saved)
        let result = model.coursePreferences(for: "stable-course")
        XCTAssertEqual(result.confirmation, .enabled)
        XCTAssertEqual(result.reminders, .disabled)
        XCTAssertEqual(result.reminderLeadMinutes, 30)
        XCTAssertEqual(result.autoSignRule?.retryMinutes, 5)
        XCTAssertFalse(model.autoSignRunning)
    }

    func testCoursePatchRebasesAfterNotificationPermissionAwait() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let notifications = CloudNotifications()
        notifications.status = .notDetermined
        let gate = CloudResponseGate()
        notifications.authorizationGate = gate
        let model = makeModel(store, cloud, secrets, notifications: notifications)
        await model.restore()
        await source.sync()
        await enable(model)
        let previous = model.coursePreferences(for: "stable-course")
        var proposed = previous
        proposed.reminders = .enabled
        let edit = Task { await model.setCoursePreferences(proposed, for: "stable-course", relativeTo: previous) }
        await eventually { notifications.authorizationCalls == 1 }

        source.local.accounts[0].preferences.courses["stable-course"] = .init(
            confirmation: .enabled, reminderLeadMinutes: 15)
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()
        await gate.open()
        let saved = await edit.value

        XCTAssertTrue(saved)
        let result = model.coursePreferences(for: "stable-course")
        XCTAssertEqual(result.confirmation, .enabled)
        XCTAssertEqual(result.reminderLeadMinutes, 15)
        XCTAssertEqual(result.reminders, .enabled)
        XCTAssertEqual(result.autoSign, previous.autoSign)
        XCTAssertEqual(result.autoSignRule, previous.autoSignRule)
        XCTAssertFalse(model.autoSignRunning)
    }

    func testRemoteSessionRotationRejectsLateOldSessionRefresh() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let transport = CloudTransport()
        let widgets = CloudWidgets()
        let model = makeModel(store, cloud, secrets, transport: transport, widgets: widgets)
        await model.restore()
        await source.sync()
        await enable(model)
        let oldGeneration = model.accountGeneration
        let gate = CloudResponseGate()
        await transport.enqueue(session: "session-original", name: "迟到的旧会话课程", gate: gate)
        let refresh = Task { await model.refresh() }
        await eventually { await transport.count(session: "session-original") == 2 }

        source.local.accounts[0].session = cloudAccount(token: "session-rotated").session
        try source.capture(explicitLogin: cloudAccount().id)
        await source.sync()
        await model.synchronizeICloud()
        XCTAssertEqual(model.session?.sessionId, "session-rotated")
        XCTAssertNotEqual(model.accountGeneration, oldGeneration)
        await gate.open()
        await refresh.value
        XCTAssertFalse(model.todayCourses.contains { $0.name == "迟到的旧会话课程" })
        await transport.enqueue(session: "session-rotated", name: "新会话课程")
        await model.refresh()
        XCTAssertEqual(model.todayCourses.map(\.name), ["新会话课程"])
        XCTAssertEqual(widgets.snapshot?.courses.map(\.name), ["新会话课程"])
    }

    func testNewAccountGenerationClearsOldLocalAutomaticStateAndHistory() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        var local = cloudAccount()
        local.preferences.autoSignRunning = false
        local.preferences.autoSignRule.retryMinutes = 5
        local.preferences.courses["stable-course"] = .init(autoSign: .enabled,
            autoSignRule: .init(offsetMinutes: -20), autoSignEnabledSince: .now)
        let store = CloudAccountStore(accounts: [local], active: local.id)
        var execution = AutoSignExecution(key: "old-generation", now: .now)
        execution.transition(.signed, now: .now, message: "旧代次记录")
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: local.id, executions: [execution.key: execution])
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await source.sync()
        await enable(model)
        let oldGeneration = model.accountGeneration
        model.records = [SyncAttendanceRecord(courseName: "旧代次课程", date: .now, message: "已签到", succeeded: true)]
        try source.coordinator.removeEverywhere(accountID: local.id)
        source.local.accounts = []
        await source.sync()
        source.local.accounts = [cloudAccount(token: "session-recreated")]
        try source.capture(explicitLogin: local.id)
        await source.sync()
        await model.synchronizeICloud()

        let recreated = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(recreated.session.sessionId, "session-recreated")
        XCTAssertFalse(recreated.preferences.autoSignIsRunning)
        XCTAssertEqual(recreated.preferences.autoSignRule, AutoSignPolicy())
        XCTAssertNotEqual(recreated.preferences.courses["stable-course"]?.autoSign, .enabled)
        XCTAssertNil(recreated.preferences.courses["stable-course"]?.autoSignEnabledSince)
        XCTAssertTrue(model.autoSignExecutions.isEmpty)
        XCTAssertTrue(try UserDefaultsAutoSignStore(defaults: defaults).load(accountID: local.id).isEmpty)
        XCTAssertTrue(model.records.isEmpty)
        let persistedRecords = try defaults.data(forKey: "records-\(local.id)")
            .map { try JSONDecoder().decode([SyncAttendanceRecord].self, from: $0) } ?? []
        XCTAssertTrue(persistedRecords.isEmpty)
        XCTAssertNil(model.activeAccountID)
        XCTAssertNotEqual(model.accountGeneration, oldGeneration)
    }

    func testLocalPreferenceEditDuringRemoteSessionValidationIsRetainedOnRetry() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, secrets, transport: transport)
        await model.restore()
        await source.sync()
        await enable(model)
        source.local.accounts[0].session = cloudAccount(token: "session-validating").session
        source.local.accounts[0].preferences.reminderLeadMinutes = 30
        try source.capture(explicitLogin: cloudAccount().id)
        await source.sync()
        let gate = CloudResponseGate()
        await transport.enqueue(session: "session-validating", name: "验证课程", gate: gate)
        let sync = Task { await model.synchronizeICloud() }
        await eventually { await transport.count(session: "session-validating") == 1 }
        model.setConfirmation(true)
        await gate.open()
        await sync.value

        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertTrue(try XCTUnwrap(store.vault.accounts.first).preferences.confirmationEnabled)
        await model.synchronizeICloud()
        XCTAssertEqual(model.session?.sessionId, "session-validating")
        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertEqual(model.reminderLeadMinutes, 30)
        XCTAssertFalse(model.autoSignRunning)
    }

    func testSessionValidationNetworkFailurePreservesCredentialsAndAppliesOrdinaryPreferences() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let transport = CloudTransport()
        let model = makeModel(store, cloud, secrets, transport: transport)
        await model.restore()
        await source.sync()
        await enable(model)
        let oldGeneration = model.accountGeneration
        source.local.accounts[0].session = cloudAccount(token: "session-network-retry").session
        source.local.accounts[0].preferences.confirmationEnabled = true
        source.local.accounts[0].preferences.reminderLeadMinutes = 30
        try source.capture(explicitLogin: cloudAccount().id)
        await source.sync()
        await transport.setUnavailable(session: "session-network-retry", true)
        await model.synchronizeICloud()

        XCTAssertEqual(model.session, cloudAccount().session)
        XCTAssertEqual(model.accountGeneration, oldGeneration)
        XCTAssertEqual(model.accounts.first?.credentials, cloudAccount().credentials)
        XCTAssertFalse(try XCTUnwrap(model.accounts.first).requiresLogin)
        XCTAssertFalse(model.showLogin)
        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertEqual(model.reminderLeadMinutes, 30)
        XCTAssertEqual(store.vault.accounts.first?.preferences.reminderLeadMinutes, 30)
        XCTAssertTrue(model.iCloudPendingAccounts.isEmpty)
        guard case .failed(let message) = model.iCloudSyncStatus else {
            return XCTFail("A failed school validation must remain visible in the sync status")
        }
        XCTAssertTrue(message.hasPrefix("登录信息验证暂不可用，将自动重试："))
        let records = try cloud.records.values.map { try SyncCodec.decode(SyncRecord.self, from: $0.data) }
        XCTAssertFalse(records.contains { $0.kind == .invalidSession }, "A transport failure does not revoke a credential")

        await transport.setUnavailable(session: "session-network-retry", false)
        await model.synchronizeICloud()
        XCTAssertEqual(model.session?.sessionId, "session-network-retry")
        XCTAssertEqual(model.iCloudSyncStatus, .ready)
        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertEqual(model.reminderLeadMinutes, 30)
    }

    func testSilentPushColdLaunchLoadsAccountsAndMergesWithoutNotificationPermission() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        var remote = cloudAccount()
        remote.preferences.confirmationEnabled = true
        remote.preferences.autoSignEnabled = true
        let source = sourceDevice(cloud, secrets, accounts: [remote])
        await source.sync()
        defaults.set(true, forKey: "iCloudSyncEnabled")
        let local = cloudAccount()
        let store = CloudAccountStore(accounts: [local], active: local.id)
        let notifications = CloudNotifications()
        let model = makeModel(store, cloud, secrets, notifications: notifications)

        let result = await model.handleICloudRemoteNotification(syncNotification())
        XCTAssertEqual(result, .newData)
        XCTAssertGreaterThan(store.loadCalls, 0)
        XCTAssertEqual(model.activeAccountID, local.id)
        XCTAssertTrue(model.confirmationEnabled)
        XCTAssertFalse(model.autoSignEnabled)
        XCTAssertEqual(notifications.authorizationCalls, 0)
        XCTAssertEqual(model.iCloudSyncStatus, .ready)
    }

    func testSilentPushUpdatesRecordsBeforeNextForegroundPoll() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let source = sourceDevice(cloud, secrets, accounts: [cloudAccount()])
        await source.sync()
        let local = cloudAccount()
        let store = CloudAccountStore(accounts: [local], active: local.id)
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await enable(model)
        let record = SyncAttendanceRecord(courseName: "Remote Course", date: .now,
                                          message: "Done on another device", succeeded: true)
        source.local.attendance[local.id] = [record]
        try source.capture(); await source.sync()
        let result = await model.handleICloudRemoteNotification(syncNotification())
        XCTAssertEqual(result, .newData)
        XCTAssertTrue(model.records.contains { $0.id == record.id })
        let unchanged = await model.handleICloudRemoteNotification(syncNotification())
        XCTAssertEqual(unchanged, .noData)
    }

    func testDisabledAndUnrelatedSilentPushDoNotLoadLocalAccounts() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let store = CloudAccountStore(accounts: [cloudAccount()], active: cloudAccount().id)
        let model = makeModel(store, cloud, secrets)
        let disabled = await model.handleICloudRemoteNotification(syncNotification())
        XCTAssertEqual(disabled, .noData)
        XCTAssertEqual(store.loadCalls, 0)
        XCTAssertTrue(cloud.records.isEmpty)
        // Change only the setting used at model construction to avoid an independently scheduled sync.
        defaults.set(true, forKey: "iCloudSyncEnabled")
        let enabled = makeModel(store, cloud, secrets)
        let unrelated = await enabled.handleICloudRemoteNotification(syncNotification(container: "iCloud.unrelated"))
        XCTAssertEqual(unrelated, .noData)
        XCTAssertEqual(store.loadCalls, 0)
        coordinators.last?.setEnabled(false)
    }

    private func syncNotification(container: String? = nil) -> [AnyHashable: Any] {
        let identifier = container ?? (Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? "")
        return ["aps": ["content-available": 1], "ck": ["ce": 2, "cid": identifier, "nid": "test-push",
            "fet": ["dbs": 1, "sid": CloudKitSyncSubscription.subscriptionID,
                    "zid": CloudKitSyncSubscription.zoneName, "zoid": "__defaultOwner__"]]]
    }

    private func sourceDevice(_ cloud: MemoryCloudSyncClient, _ secrets: MemorySyncCredentialStore,
                              accounts: [StoredAccount]) -> CloudSourceDevice {
        let source = CloudSourceDevice(cloud: cloud, secrets: secrets, accounts: accounts)
        coordinators.append(source.coordinator)
        return source
    }

    private func makeModel(_ store: CloudAccountStore, _ cloud: MemoryCloudSyncClient,
                           _ secrets: MemorySyncCredentialStore, transport: CloudTransport? = nil,
                           notifications: CloudNotifications? = nil, widgets: CloudWidgets? = nil,
                           now: Date? = nil, syncState: MemoryCloudSyncStateStore? = nil) -> AppModel {
        let coordinator = CloudSyncCoordinator(client: cloud, credentials: secrets,
            store: syncState ?? MemoryCloudSyncStateStore(), deviceID: "host-device", deviceName: "This Mac", enabled: false)
        coordinators.append(coordinator)
        let service = QingxinService(transport: transport ?? CloudTransport(), now: { now ?? .now },
                                     monotonicNow: { now == nil ? ProcessInfo.processInfo.systemUptime : 0 })
        let model = AppModel(service: service, accountStore: store,
            defaults: defaults, notifications: notifications ?? CloudNotifications(),
            widgets: widgets ?? CloudWidgets(), cloudSync: coordinator)
        if let now {
            model.attendanceNow = { now }
            model.autoSignMonotonicNow = { 0 }
        }
        return model
    }

    private func enable(_ model: AppModel) async {
        model.setICloudSyncEnabled(true)
        await model.synchronizeICloud()
    }

    private func eventually(_ predicate: @escaping @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected asynchronous operation did not start", file: file, line: line)
    }
}

extension CloudSyncAppModelTests {
    func testStartupMergesRemoteUnlimitedChoiceBeforeApplyingAnExpiredLocalAgeLimit() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let start = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        let execution = historyExecution("near-age-boundary", at: start.addingTimeInterval(-86_400 + 60))
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [execution.key: execution])
        let source = sourceDevice(cloud, secrets, accounts: [account])
        await source.sync()
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let syncState = MemoryCloudSyncStateStore()
        let model = makeModel(store, cloud, secrets, now: start, syncState: syncState)
        await model.restore()
        await enable(model)
        XCTAssertTrue(model.setHistoryRetention(.init(automatic: .init(maxAgeDays: 1))))
        await model.synchronizeICloud()
        XCTAssertEqual(model.autoSignHistory, [execution], "The execution has not yet reached the selected age limit")
        model.setICloudSyncEnabled(false)

        await source.sync()
        source.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        try source.capture()
        await source.sync()
        defaults.set(true, forKey: "iCloudSyncEnabled")
        let restarted = makeModel(store, cloud, secrets, now: start.addingTimeInterval(120), syncState: syncState)
        XCTAssertTrue(restarted.iCloudSyncEnabled)
        XCTAssertEqual(restarted.historyRetention.automatic.maxAgeDays, 1,
                       "The persisted local choice is still old until the first cloud exchange")
        await restarted.restore()
        await restarted.synchronizeICloud()

        XCTAssertEqual(restarted.historyRetention, HistoryRetentionSettings())
        XCTAssertEqual(restarted.autoSignExecutions[execution.key], execution,
                       "Startup must not discard history under an old policy before merging the newer remote choice")
        XCTAssertEqual(restarted.autoSignHistory, [execution])
        XCTAssertEqual(restarted.displayAutoSignHistory.map(\.occurrenceKey), [execution.key])
        XCTAssertEqual(try UserDefaultsAutoSignStore(defaults: defaults).load(accountID: account.id), [execution.key: execution])
    }

    func testRelaxingUnsyncedRetentionDoesNotRestoreDiscardedLocalOrRemoteHistoryCopies() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let schoolNow = try XCTUnwrap(CourseTime.parse(day: SchoolDate.key(.now), time: "08:30"))
        let oldDate = schoolNow.addingTimeInterval(-100 * 86_400)
        var account = cloudAccount()
        account.preferences = .init(autoSignEnabled: true, autoSignRunning: true,
            autoSignRule: .init(offsetMinutes: 30, notification: .none), autoSignV2Acknowledged: true,
            autoSignRunningSince: oldDate, autoSignDefaultSince: oldDate, autoSignSinceUsesSchoolTime: true)
        let source = sourceDevice(cloud, secrets, accounts: [account])
        source.local.executions[account.id] = [historyExecution("remote-old-copy", at: oldDate)]
        await source.sync()
        let localOld = historyExecution("local-old-copy", at: oldDate.addingTimeInterval(1))
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [localOld.key: localOld])
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let syncState = MemoryCloudSyncStateStore()
        let transport = CloudTransport(clockDate: schoolNow, includeSecondCourse: true)
        let model = makeModel(store, cloud, secrets, transport: transport, now: schoolNow, syncState: syncState)
        await model.restore()
        await enable(model)
        let shared = try XCTUnwrap(model.syncedAutoSignHistory[account.id])
        XCTAssertTrue(shared.contains { $0.sourceDeviceID == model.cloudDeviceID && $0.occurrenceKey == localOld.key })
        XCTAssertTrue(shared.contains { $0.sourceDeviceID == "remote-device" && $0.occurrenceKey == "remote-old-copy" })
        model.setICloudSyncEnabled(false)
        await model.foregroundTick()
        let newKeys = Set(model.autoSignHistory.filter { $0.key != localOld.key }.map(\.key))
        XCTAssertEqual(newKeys.count, 2, "Both new local executions must exist before the retention change")

        XCTAssertTrue(model.setHistoryRetention(.init(automatic: .init(maxCount: 2))))
        XCTAssertEqual(model.autoSignExecutions[localOld.key]?.historyDiscarded, true)
        XCTAssertEqual(Set(model.displayAutoSignHistory.map(\.occurrenceKey)), newKeys)
        XCTAssertTrue(model.setHistoryRetention(.init()))
        XCTAssertEqual(Set(model.displayAutoSignHistory.map(\.occurrenceKey)), newKeys,
                       "Relaxing an unflushed limit must not expose stale local-device or remote-device DTOs")

        let restarted = makeModel(store, cloud, secrets, now: schoolNow, syncState: syncState)
        await restarted.restore()
        XCTAssertEqual(restarted.historyRetention, HistoryRetentionSettings())
        XCTAssertEqual(Set(restarted.displayAutoSignHistory.map(\.occurrenceKey)), newKeys)
        await enable(restarted)
        XCTAssertEqual(Set(restarted.displayAutoSignHistory.map(\.occurrenceKey)), newKeys,
                       "Discarded history must stay removed when an old cloud copy is read after restart")
        XCTAssertEqual(restarted.autoSignExecutions[localOld.key]?.historyDiscarded, true)
    }

    func testDefaultRetentionImportsAndRestoresMoreThanOneHundredOldOperationsAndAutomaticHistory() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        let source = sourceDevice(cloud, secrets, accounts: [account])
        let operations = (0..<150).map {
            SyncAttendanceRecord(courseName: "旧操作\($0)", date: oldDate.addingTimeInterval(Double($0)),
                                 message: "已签到", succeeded: true)
        }
        source.local.attendance[account.id] = operations
        source.local.executions[account.id] = [historyExecution("remote-old", at: oldDate)]
        await source.sync()
        let localExecution = historyExecution("local-old", at: oldDate.addingTimeInterval(1))
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id,
                                                             executions: [localExecution.key: localExecution])
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let syncState = MemoryCloudSyncStateStore()
        let model = makeModel(store, cloud, secrets, syncState: syncState)
        await model.restore()
        await enable(model)
        XCTAssertEqual(model.historyRetention, HistoryRetentionSettings())
        XCTAssertEqual(Set(model.records.map(\.id)), Set(operations.map(\.id)))
        XCTAssertEqual(Set(model.displayAutoSignHistory.map(\.occurrenceKey)), ["local-old", "remote-old"])
        XCTAssertEqual(model.autoSignExecutions[localExecution.key], localExecution)

        model.setICloudSyncEnabled(false)
        let restarted = makeModel(store, cloud, secrets, syncState: syncState)
        await restarted.restore()
        XCTAssertEqual(restarted.records.count, 150)
        XCTAssertEqual(restarted.autoSignHistory, [localExecution])
        await enable(restarted)
        XCTAssertEqual(Set(restarted.records.map(\.id)), Set(operations.map(\.id)))
        XCTAssertEqual(Set(restarted.displayAutoSignHistory.map(\.occurrenceKey)), ["local-old", "remote-old"])
    }

    func testUserCountLimitClearsOnlyHistoryContentAndProtectsUnfinishedExecution() async throws {
        try await assertHistoryRetentionEffects(.init(maxCount: 1), retainedCompletedKeys: ["recent"])
    }

    func testUserAgeLimitClearsOnlyExpiredHistoryAndProtectsUnfinishedExecution() async throws {
        try await assertHistoryRetentionEffects(.init(maxAgeDays: 30), retainedCompletedKeys: ["recent", "middle"])
    }

    func testClearingEveryRetentionLimitPersistsUnlimitedBehaviorAfterRestart() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let store = CloudAccountStore(accounts: [account], active: account.id)
        var model: AppModel? = makeModel(store, cloud, secrets)
        await model!.restore()
        XCTAssertTrue(model!.setHistoryRetention(.init(operations: .init(maxCount: 1, maxAgeDays: 1),
                                                      automatic: .init(maxCount: 1, maxAgeDays: 1))))
        XCTAssertTrue(model!.setHistoryRetention(.init()))
        model = nil
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        let operations = (0..<150).map {
            SyncAttendanceRecord(courseName: "后续导入旧操作\($0)", date: oldDate.addingTimeInterval(Double($0)),
                                 message: "保留", succeeded: true)
        }
        defaults.set(try JSONEncoder().encode(operations), forKey: "records-\(account.id)")
        let execution = historyExecution("later-imported-old", at: oldDate)
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: [execution.key: execution])

        let restarted = makeModel(store, cloud, secrets)
        await restarted.restore()
        XCTAssertEqual(restarted.historyRetention, HistoryRetentionSettings())
        XCTAssertEqual(restarted.records.count, 150)
        XCTAssertEqual(restarted.autoSignHistory, [execution])
        for key in HistoryRetentionSettings.applicationKeys {
            let data = try XCTUnwrap(defaults.data(forKey: key))
            XCTAssertNil(try SyncCodec.decode(Int?.self, from: data), "An explicit unlimited choice must survive persistence")
        }
    }

    func testStaleRetentionFormPreservesDifferentFieldsReceivedFromCloud() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let source = sourceDevice(cloud, secrets, accounts: [account])
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await source.sync()
        await enable(model)
        let previous = model.historyRetention
        var proposal = previous
        proposal.operations.maxCount = 17
        let remote = HistoryRetentionSettings(operations: .init(maxAgeDays: 7), automatic: .init(maxAgeDays: 60))
        source.local.applicationPreferences = try remote.applicationPreferences()
        try source.capture()
        await source.sync()
        await model.synchronizeICloud()
        XCTAssertEqual(model.historyRetention, remote)

        XCTAssertTrue(model.setHistoryRetention(proposal, relativeTo: previous))
        XCTAssertEqual(model.historyRetention.operations, .init(maxCount: 17, maxAgeDays: 7))
        XCTAssertEqual(model.historyRetention.automatic, .init(maxAgeDays: 60))
    }

    func testCloudTombstonesClearOldLocalHistoryEvenAfterRemoteLimitsAreRemoved() async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let now = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        let source = sourceDevice(cloud, secrets, accounts: [account])
        let operations = (0..<3).map {
            SyncAttendanceRecord(courseName: "操作\($0)", date: now.addingTimeInterval(Double(-$0 * 86_400)),
                                 message: "已签到", succeeded: true)
        }
        source.local.attendance[account.id] = operations
        await source.sync()
        let older = historyExecution("local-older", at: now.addingTimeInterval(-172_800))
        let newer = historyExecution("local-newer", at: now.addingTimeInterval(-86_400))
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id,
                                                              executions: [older.key: older, newer.key: newer])
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let model = makeModel(store, cloud, secrets)
        await model.restore()
        await enable(model)
        XCTAssertEqual(model.records.count, 3)
        XCTAssertEqual(model.displayAutoSignHistory.count, 2)
        model.setICloudSyncEnabled(false)

        source.local.applicationPreferences = try HistoryRetentionSettings(
            operations: .init(maxCount: 1), automatic: .init(maxCount: 1)).applicationPreferences()
        try source.capture()
        await source.sync()
        source.local.applicationPreferences = try HistoryRetentionSettings().applicationPreferences()
        try source.capture()
        await source.sync()
        XCTAssertEqual(model.records.count, 3, "The offline device still has the earlier rows before it receives tombstones")
        await enable(model)

        XCTAssertEqual(model.historyRetention, HistoryRetentionSettings())
        XCTAssertEqual(model.records, [operations[0]])
        XCTAssertEqual(model.displayAutoSignHistory.map(\.occurrenceKey), [newer.key])
        var expectedOlder = older
        expectedOlder.discardHistory()
        XCTAssertEqual(model.autoSignExecutions[older.key], expectedOlder)
        XCTAssertEqual(model.autoSignExecutions[newer.key], newer)
        XCTAssertEqual(try UserDefaultsAutoSignStore(defaults: defaults).load(accountID: account.id),
                       [older.key: expectedOlder, newer.key: newer])
        await model.synchronizeICloud()
        XCTAssertEqual(model.records, [operations[0]], "Relaxing a limit must not resurrect removed rows on a later pass")
        XCTAssertEqual(model.displayAutoSignHistory.map(\.occurrenceKey), [newer.key])
    }

    private func assertHistoryRetentionEffects(_ policy: HistoryRetentionPolicy, retainedCompletedKeys: Set<String>,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let cloud = MemoryCloudSyncClient(), secrets = MemorySyncCredentialStore()
        let account = cloudAccount()
        let now = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
        let completed = [historyExecution("old", at: now.addingTimeInterval(-400 * 86_400)),
                         historyExecution("middle", at: now.addingTimeInterval(-20 * 86_400)),
                         historyExecution("recent", at: now.addingTimeInterval(-86_400))]
        let running = historyExecution("unfinished", at: now.addingTimeInterval(-500 * 86_400),
                                       stage: .verifying, classEnd: now.addingTimeInterval(3_600))
        let original = Dictionary(uniqueKeysWithValues: (completed + [running]).map { ($0.key, $0) })
        try UserDefaultsAutoSignStore(defaults: defaults).save(accountID: account.id, executions: original)
        let operations = completed.map {
            SyncAttendanceRecord(courseName: $0.key, date: $0.startedAt!, message: "历史详情", succeeded: true)
        }
        defaults.set(try JSONEncoder().encode(operations), forKey: "records-\(account.id)")
        let store = CloudAccountStore(accounts: [account], active: account.id)
        let model = makeModel(store, cloud, secrets, now: now)
        await model.restore()
        XCTAssertTrue(model.setHistoryRetention(.init(operations: policy, automatic: policy)), file: file, line: line)
        XCTAssertEqual(Set(model.records.map(\.courseName)), retainedCompletedKeys, file: file, line: line)
        XCTAssertEqual(Set(model.displayAutoSignHistory.map(\.occurrenceKey)), retainedCompletedKeys.union([running.key]),
                       file: file, line: line)
        var expected = original
        for value in completed where !retainedCompletedKeys.contains(value.key) { expected[value.key]?.discardHistory() }
        XCTAssertEqual(model.autoSignExecutions, expected,
                       "History cleanup must preserve the complete runtime ledger", file: file, line: line)
        XCTAssertEqual(try UserDefaultsAutoSignStore(defaults: defaults).load(accountID: account.id), expected, file: file, line: line)
        XCTAssertEqual(model.autoSignExecutions[running.key], running,
                       "An unfinished operation is protected even when older than the chosen history window", file: file, line: line)
    }
}

private func historyExecution(_ key: String, at date: Date, stage: AutoSignStage = .signed,
                              classEnd: Date? = nil) -> AutoSignExecution {
    var value = AutoSignExecution(key: key, now: date)
    value.startedAt = date
    value.courseName = "历史课程\(key)"
    value.classStartAt = date.addingTimeInterval(-60)
    value.classEndAt = classEnd ?? date.addingTimeInterval(3_600)
    value.submissions = 1
    value.lastSubmissionAt = date
    value.lastSchoolSubmissionAt = date
    value.firstNegativeAt = date.addingTimeInterval(-30)
    value.firstSchoolNegativeAt = date.addingTimeInterval(-30)
    value.negativeReads = 1
    value.nextSchoolVerificationAt = date.addingTimeInterval(120)
    value.transition(stage, now: date, message: "原始历史详情", nextAt: date.addingTimeInterval(120))
    return value
}

private func cloudAccount(token: String = "session-original", studentNo: String = "2026000100") -> StoredAccount {
    StoredAccount(session: SchoolSession(userId: "sync-user", sessionId: token,
        studentNo: studentNo, name: "同步同学"),
        credentials: StoredCredentials(username: "sync@example.edu", password: "test-password"),
        loginUsername: "sync@example.edu")
}

@MainActor
private final class CloudSourceDevice {
    var local: CloudSyncLocalSnapshot
    let coordinator: CloudSyncCoordinator
    init(cloud: MemoryCloudSyncClient, secrets: MemorySyncCredentialStore, accounts: [StoredAccount]) {
        local = CloudSyncLocalSnapshot(accounts: accounts)
        coordinator = CloudSyncCoordinator(client: cloud, credentials: secrets,
            store: MemoryCloudSyncStateStore(), deviceID: "remote-device", deviceName: "Remote iPhone")
        coordinator.snapshot = { [weak self] in self?.local ?? .init() }
    }
    func sync() async { await coordinator.synchronize(force: true) }
    func capture(explicitLogin: String? = nil) throws {
        try coordinator.recordLocalChanges(local, explicitLogin: explicitLogin)
    }
}

@MainActor
private final class CloudAccountStore: AccountStore {
    var vault: AccountVault
    var loadCalls = 0
    init(accounts: [StoredAccount], active: String?) { vault = AccountVault(accounts: accounts, activeAccountID: active) }
    func load() throws -> AccountVault { loadCalls += 1; return vault }
    func save(_ vault: AccountVault) throws { self.vault = vault }
    func legacyCredentials() throws -> StoredCredentials? { nil }
}

@MainActor
private final class CloudWidgets: WidgetClient {
    var snapshot: WidgetSnapshot?
    func save(_ snapshot: WidgetSnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

@MainActor
private final class CloudNotifications: NotificationClient {
    var status: UNAuthorizationStatus = .authorized
    var authorizationGate: CloudResponseGate?
    var authorizationCalls = 0
    var pendingIDs = Set<String>()
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        authorizationCalls += 1
        await authorizationGate?.wait()
        status = .authorized
        return true
    }
    func add(_ request: UNNotificationRequest) async throws { pendingIDs.insert(request.identifier) }
    func removeAll() { pendingIDs.removeAll() }
    func remove(ids: [String]) { pendingIDs.subtract(ids) }
    func pendingRequestIdentifiers() async -> [String] { Array(pendingIDs) }
}

private actor CloudResponseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor CloudTransport: HTTPTransport {
    struct PlannedResponse: Sendable { let name: String; let gate: CloudResponseGate? }
    private var planned: [String: [PlannedResponse]] = [:]
    private var requests: [String] = []
    private var unavailableSessions = Set<String>()
    private let clockDate: Date?
    private let includeSecondCourse: Bool
    private(set) var signRequests = 0
    init(clockDate: Date? = nil, includeSecondCourse: Bool = false) {
        self.clockDate = clockDate
        self.includeSecondCourse = includeSecondCourse
    }
    var courseRequests: Int { requests.count }
    func count(session: String) -> Int { requests.filter { $0 == session }.count }
    func setUnavailable(session: String, _ unavailable: Bool) {
        if unavailable { unavailableSessions.insert(session) }
        else { unavailableSessions.remove(session) }
    }
    func enqueue(session: String, name: String, gate: CloudResponseGate? = nil) {
        planned[session, default: []].append(.init(name: name, gate: gate))
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path.hasSuffix("stu_scan_sign.action") { signRequests += 1; throw URLError(.badServerResponse) }
        if path.hasSuffix("get_timestamp.do"), let clockDate {
            let body = "{\"STATUS\":\"0\",\"timestamp\":\(Int64(clockDate.timeIntervalSince1970 * 1000))}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                  httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        guard path.hasSuffix("get_stu_course_sched.action") else { throw URLError(.badServerResponse) }
        let session = request.value(forHTTPHeaderField: "sessionId") ?? ""
        requests.append(session)
        if unavailableSessions.contains(session) { throw URLError(.notConnectedToInternet) }
        let response: PlannedResponse
        if var queue = planned[session], !queue.isEmpty {
            response = queue.removeFirst()
            planned[session] = queue
        } else { response = .init(name: "课程", gate: nil) }
        await response.gate?.wait()
        let second = includeSecondCourse
            ? #",{"id":"1234568","courseId":"stable-course-second","courseName":"另一课程","teacherName":"教师","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"0"}"# : ""
        let body = #"{"STATUS":"0","result":[{"id":"1234567","courseId":"stable-course","courseName":"\#(response.name)","teacherName":"教师","classBeginTime":"08:00","classEndTime":"09:40","signStatus":"0"}\#(second)]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
