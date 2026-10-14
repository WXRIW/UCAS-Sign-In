import XCTest
import Foundation
@testable import UCASCore
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(Security)
import Security
#endif

@MainActor
final class CloudSyncTransportTests: XCTestCase {
    func testMemoryStoreRejectsStaleWritesAndReturnsCurrentRecord() async throws {
        let client = MemoryCloudSyncClient()
        let original = CloudSyncRecord(id: "account", data: Data("first".utf8))
        let first = try await client.save([original])
        let saved = try XCTUnwrap(first.saved.first)
        let changed = CloudSyncRecord(id: original.id, data: Data("newer".utf8), systemFields: saved.systemFields)
        let second = try await client.save([changed])
        let stale = try await client.save([saved])
        XCTAssertEqual(stale.conflicts, second.saved)
        XCTAssertTrue(stale.saved.isEmpty)
        XCTAssertEqual(client.records[original.id], second.saved.first)
    }

    func testIncrementalChangesIncludeDeletionAndDoNotResurrectStaleRecord() async throws {
        let client = MemoryCloudSyncClient()
        let saved = try await client.save([.init(id: "one", data: Data([1]))]).saved
        let initial = try await client.fetchChanges(cursor: nil)
        _ = try await client.save([.init(id: "two", data: Data([2]))])
        client.deleteRecord(id: "one")
        let changes = try await client.fetchChanges(cursor: initial.cursor)
        XCTAssertEqual(changes.records.map(\.id), ["two"])
        XCTAssertEqual(changes.deletedRecordIDs, ["one"])
        let stale = try await client.save(saved)
        XCTAssertEqual(stale.failures, [.init(id: "one", error: .recordMissing)])
        let unchanged = try await client.fetchChanges(cursor: changes.cursor)
        XCTAssertTrue(unchanged.records.isEmpty)
        XCTAssertTrue(unchanged.deletedRecordIDs.isEmpty)
    }

    func testInvalidCursorRequiresFullRescan() async throws {
        let client = MemoryCloudSyncClient()
        do {
            _ = try await client.fetchChanges(cursor: Data("invalid".utf8))
            XCTFail("A corrupt cursor must not skip pending changes")
        } catch { XCTAssertEqual(error as? CloudSyncError, .tokenExpired) }
    }

    func testMemoryCredentialsAreImmutableAndDeletionIsScoped() throws {
        let store = MemorySyncCredentialStore()
        try store.setData(Data([1]), for: "version-a")
        try store.setData(Data([1]), for: "version-a")
        try store.setData(Data([2]), for: "version-b")
        XCTAssertThrowsError(try store.setData(Data([3]), for: "version-a")) {
            XCTAssertEqual($0 as? CloudSyncError, .immutableCredential)
        }
        try store.removeData(for: "version-a")
        XCTAssertEqual(try store.allIDs(), ["version-b"])
        XCTAssertEqual(try store.data(for: "version-b"), Data([2]))
    }

    func testExecutableEntitlementReaderUsesSignedXMLAndDER() throws {
        let key = "com.apple.developer.icloud-services"
        let xml = try PropertyListSerialization.data(fromPropertyList: [key: ["CloudKit"]], format: .xml, options: 0)
        XCTAssertEqual(SignedEntitlementReader.stringArrays(from: executableSignature(xml: xml)), [key: ["CloudKit"]])
        let entry = der(0x30, der(0x0c, Data(key.utf8)) + der(0x30, der(0x0c, Data("CloudKit".utf8))))
        let encoded = der(0x70, der(0x02, Data([1])) + der(0xb0, entry))
        XCTAssertEqual(SignedEntitlementReader.stringArrays(from: executableSignature(der: encoded)), [key: ["CloudKit"]])
        // DER is authoritative, even if an XML representation claims a broader capability.
        let emptyDER = der(0x70, der(0x02, Data([1])) + der(0xb0, Data()))
        XCTAssertTrue(SignedEntitlementReader.stringArrays(from: executableSignature(xml: xml, der: emptyDER)).isEmpty)
    }

    func testMalformedSignaturesAndDERFailClosed() {
        XCTAssertTrue(SignedEntitlementReader.stringArrays(from: Data()).isEmpty)
        XCTAssertTrue(SignedEntitlementReader.stringArrays(from: Data(repeating: 255, count: 80)).isEmpty)
        XCTAssertTrue(SignedEntitlementReader.stringArrays(from: executableSignature(der: Data([0x70, 0xff]))).isEmpty)
        XCTAssertNil(SignedEntitlementReader.derStringArrays(Data([0x70, 0x80])))
        var corrupt = executableSignature(der: der(0x70, der(2, Data([1])) + der(0xb0, Data())))
        corrupt.replaceSubrange(64..<68, with: Data(repeating: 255, count: 4))
        XCTAssertTrue(SignedEntitlementReader.stringArrays(from: corrupt).isEmpty)
    }

    #if canImport(CloudKit)
    func testZoneSubscriptionUsesStableIdentityAndOnlySilentContentAvailable() throws {
        let subscription = CloudKitSyncSubscription.makeSubscription()
        XCTAssertEqual(subscription.subscriptionID, CloudKitSyncSubscription.subscriptionID)
        XCTAssertEqual(subscription.zoneID.zoneName, CloudKitSyncSubscription.zoneName)
        XCTAssertEqual(subscription.zoneID.ownerName, CKCurrentUserDefaultName)
        let info = try XCTUnwrap(subscription.notificationInfo)
        XCTAssertTrue(info.shouldSendContentAvailable)
        XCTAssertFalse(info.shouldBadge)
        XCTAssertNil(info.alertBody)
        XCTAssertNil(info.alertLocalizationKey)
        XCTAssertNil(info.title)
        XCTAssertNil(info.subtitle)
        XCTAssertNil(info.soundName)
    }

    func testRemoteChangeNotificationsAreScopedToThisPrivateSubscription() {
        let container = "iCloud.cn.ucas.signin.tests"
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncSubscription.zoneName, ownerName: CKCurrentUserDefaultName)
        func matches(_ actualContainer: String? = container,
                     _ subscription: String? = CloudKitSyncSubscription.subscriptionID,
                     _ database: CKDatabase.Scope = .private,
                     _ actualZone: CKRecordZone.ID? = zone) -> Bool {
            CloudKitSyncSubscription.matches(containerIdentifier: actualContainer, subscriptionID: subscription,
                                             databaseScope: database, recordZoneID: actualZone,
                                             expectedContainerIdentifier: container)
        }
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(container, CloudKitSyncSubscription.subscriptionID, .private, nil))
        XCTAssertFalse(matches(nil))
        XCTAssertFalse(matches("iCloud.another.container"))
        XCTAssertFalse(matches(container, nil))
        XCTAssertFalse(matches(container, "another-subscription"))
        XCTAssertFalse(matches(container, CloudKitSyncSubscription.subscriptionID, .public))
        XCTAssertFalse(matches(container, CloudKitSyncSubscription.subscriptionID, .shared))
        XCTAssertFalse(matches(container, CloudKitSyncSubscription.subscriptionID, .private,
                               .init(zoneName: "another-zone", ownerName: CKCurrentUserDefaultName)))
        XCTAssertFalse(CloudKitSyncSubscription.matches(userInfo: [:], containerIdentifier: container))
        XCTAssertFalse(CloudKitSyncSubscription.matches(userInfo: ["aps": ["alert": "other notification"]],
                                                        containerIdentifier: container))
        XCTAssertFalse(CloudKitSyncSubscription.matches(containerIdentifier: "", subscriptionID: CloudKitSyncSubscription.subscriptionID,
                                                        databaseScope: .private, recordZoneID: zone, expectedContainerIdentifier: ""))
    }

    func testCloudKitRemotePayloadParserAcceptsOwnZoneAndRejectsUnrelatedNotifications() throws {
        let expectedContainer = "iCloud.cn.ucas.signin.tests"
        func payload(container: String = expectedContainer,
                     subscription: String = CloudKitSyncSubscription.subscriptionID,
                     zone: String? = CloudKitSyncSubscription.zoneName,
                     database: Int = 1, kind: String = "fet") -> [AnyHashable: Any] {
            // CloudKit's wire value 1 denotes the private database (not CKDatabase.Scope.rawValue).
            var changes: [String: Any] = ["dbs": database, "sid": subscription]
            if let zone {
                changes["zid"] = zone
                changes["zoid"] = CKCurrentUserDefaultName
            }
            return ["aps": ["content-available": 1],
                    "ck": ["ce": 2, "cid": container, "nid": "notification-id", kind: changes]]
        }
        let incoming = payload()
        let notification = try XCTUnwrap(CKNotification(fromRemoteNotificationDictionary: incoming) as? CKRecordZoneNotification)
        XCTAssertEqual(notification.containerIdentifier, expectedContainer)
        XCTAssertEqual(notification.subscriptionID, CloudKitSyncSubscription.subscriptionID)
        XCTAssertEqual(notification.databaseScope, .private)
        XCTAssertEqual(notification.recordZoneID?.zoneName, CloudKitSyncSubscription.zoneName)
        XCTAssertTrue(CloudKitSyncSubscription.matches(userInfo: incoming, containerIdentifier: expectedContainer))
        XCTAssertTrue(CloudKitSyncSubscription.matches(userInfo: payload(zone: nil), containerIdentifier: expectedContainer))
        for unrelated in [payload(container: "iCloud.another.container"), payload(subscription: "another-subscription"),
                          payload(zone: "another-zone"), payload(database: 2), payload(database: 3), payload(kind: "qry")] {
            XCTAssertFalse(CloudKitSyncSubscription.matches(userInfo: unrelated, containerIdentifier: expectedContainer))
        }
    }

    func testSubscriptionRegistrationCachesSuccessOnlyWithinCurrentAccountAndZone() {
        var state = CloudKitSubscriptionRegistration()
        let firstAccount = UUID(), secondAccount = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(state.beginAttempt(epoch: firstAccount, now: now))
        XCTAssertFalse(state.beginAttempt(epoch: firstAccount, now: now))
        state.finishAttempt(epoch: firstAccount, error: nil, now: now)
        XCTAssertFalse(state.beginAttempt(epoch: firstAccount, now: now.addingTimeInterval(10_000)))
        XCTAssertTrue(state.beginAttempt(epoch: secondAccount, now: now))
        // A result from the former account cannot mark the new account's subscription installed.
        state.finishAttempt(epoch: firstAccount, error: nil, now: now)
        state.finishAttempt(epoch: secondAccount, error: .cancelled, now: now)
        XCTAssertTrue(state.beginAttempt(epoch: secondAccount, now: now))
        state.finishAttempt(epoch: secondAccount, error: nil, now: now)
        state.reset(epoch: secondAccount) // A recreated zone loses its prior subscription.
        XCTAssertTrue(state.beginAttempt(epoch: secondAccount, now: now))
    }

    func testFailedSubscriptionSetupRetriesWithoutHammeringCloudKitAndHonorsRetryAfter() {
        var state = CloudKitSubscriptionRegistration()
        let epoch = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(state.beginAttempt(epoch: epoch, now: now))
        state.finishAttempt(epoch: epoch, error: .network, now: now)
        XCTAssertFalse(state.beginAttempt(epoch: epoch, now: now.addingTimeInterval(59)))
        XCTAssertTrue(state.beginAttempt(epoch: epoch, now: now.addingTimeInterval(60)))
        state.finishAttempt(epoch: epoch, error: .service(retryAfter: 3_600), now: now.addingTimeInterval(60))
        XCTAssertFalse(state.beginAttempt(epoch: epoch, now: now.addingTimeInterval(3_659)))
        XCTAssertTrue(state.beginAttempt(epoch: epoch, now: now.addingTimeInterval(3_660)))
        state.finishAttempt(epoch: epoch, error: .cancelled, now: now.addingTimeInterval(3_660))
        XCTAssertTrue(state.beginAttempt(epoch: epoch, now: now.addingTimeInterval(3_660)))
    }

    func testAppleAccountChangeCancelsPendingOperationsAndRejectsStaleEpoch() throws {
        let guardState = CloudKitAccountEpoch(observeNotifications: false)
        let epoch = guardState.current
        let pending = CKModifyRecordsOperation(recordsToSave: [], recordIDsToDelete: nil)
        let finished = CKFetchRecordZonesOperation(recordZoneIDs: [])
        try guardState.register(pending, epoch: epoch)
        try guardState.register(finished, epoch: epoch)
        guardState.unregister(finished)
        guardState.invalidate()
        XCTAssertTrue(pending.isCancelled)
        XCTAssertFalse(finished.isCancelled)
        XCTAssertThrowsError(try guardState.check(epoch)) {
            XCTAssertEqual($0 as? CloudSyncError, .temporarilyUnavailable)
        }
        XCTAssertThrowsError(try guardState.register(finished, epoch: epoch))
        XCTAssertNoThrow(try guardState.check(guardState.current))
        XCTAssertNoThrow(try guardState.register(finished, epoch: guardState.current))
        guardState.unregister(finished)
    }

    func testCloudKitCodecKeepsPayloadOutOfSystemFieldsAndRejectsAnotherRecordID() throws {
        let zone = CKRecordZone.ID(zoneName: "UCASSync", ownerName: CKCurrentUserDefaultName)
        let payload = Data("private-account-payload-never-in-system-fields".utf8)
        let record = try CloudKitRecordCodec.encode(.init(id: "opaque-id", data: payload), zoneID: zone)
        XCTAssertNil(record["payload"])
        XCTAssertEqual(record.encryptedValues["payload"] as? Data, payload)
        let decoded = try CloudKitRecordCodec.decode(record)
        XCTAssertEqual(decoded.data, payload)
        XCTAssertNil(try XCTUnwrap(decoded.systemFields).range(of: payload))
        let restored = try CloudKitRecordCodec.encode(decoded, zoneID: zone)
        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored.encryptedValues["payload"] as? Data, payload)
        XCTAssertThrowsError(try CloudKitRecordCodec.encode(
            .init(id: "another-id", data: payload, systemFields: decoded.systemFields), zoneID: zone)) {
                XCTAssertEqual($0 as? CloudSyncError, .invalidData)
            }
    }

    func testPartialSavePreservesSuccessesAndConflictsWhenRequestFails() throws {
        let zone = CKRecordZone.ID(zoneName: "UCASSync", ownerName: CKCurrentUserDefaultName)
        let success = try CloudKitRecordCodec.encode(.init(id: "saved", data: Data([1])), zoneID: zone)
        let server = try CloudKitRecordCodec.encode(.init(id: "conflict", data: Data([2])), zoneID: zone)
        let state = CloudKitSaveAccumulator(ids: ["saved", "conflict", "network"])
        state.accept(id: "saved", result: .success(success))
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        state.accept(id: "conflict", result: .failure(conflict))
        state.finish(error: CKError(.networkUnavailable))
        let result = state.result()
        XCTAssertEqual(result.saved.map(\.id), ["saved"])
        XCTAssertEqual(result.conflicts.map(\.id), ["conflict"])
        XCTAssertEqual(result.failures, [.init(id: "network", error: .network)])
    }

    func testPartialErrorDictionaryStillRecoversConflictWithoutPerRecordCallback() throws {
        let zone = CKRecordZone.ID(zoneName: "UCASSync", ownerName: CKCurrentUserDefaultName)
        let server = try CloudKitRecordCodec.encode(.init(id: "conflict", data: Data([2])), zoneID: zone)
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [server.recordID: conflict]])
        let state = CloudKitSaveAccumulator(ids: ["conflict"])
        state.finish(error: error)
        XCTAssertEqual(state.result().conflicts.map(\.id), ["conflict"])
        XCTAssertTrue(state.result().failures.isEmpty)
    }

    func testEncryptedResetIsDifferentFromMissingZoneAndTokenExpiry() {
        XCTAssertEqual(CloudKitFailure.map(CKError(.zoneNotFound)), .zoneMissing)
        XCTAssertEqual(CloudKitFailure.map(CKError(.changeTokenExpired)), .tokenExpired)
        XCTAssertEqual(CloudKitFailure.map(CKError(.userDeletedZone)), .zoneDeletedByUser)
        let reset = CKError(.zoneNotFound, userInfo: [CKErrorUserDidResetEncryptedDataKey: true])
        XCTAssertEqual(CloudKitFailure.map(reset), .encryptedDataReset)
        XCTAssertEqual(CloudKitFailure.map(CKError(.partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: ["zone": reset]])), .encryptedDataReset)
    }

    func testPermanentCloudKitRequestErrorsRemainDiagnosableWithoutAutomaticRetry() {
        let cases: [(CKError.Code, String)] = [
            (.serverRejectedRequest, "serverRejectedRequest"), (.constraintViolation, "constraintViolation"),
            (.limitExceeded, "limitExceeded"), (.batchRequestFailed, "batchRequestFailed"),
            (.internalError, "internalError"), (.invalidArguments, "invalidArguments"),
            (.incompatibleVersion, "incompatibleVersion")
        ]
        for (code, symbol) in cases {
            let failure = CloudKitFailure.map(CKError(code, userInfo: [CKErrorRetryAfterKey: 10]))
            XCTAssertEqual(failure, .cloudKitRequest(code: code.rawValue))
            XCTAssertFalse(failure.shouldRetryAutomatically)
            XCTAssertTrue(failure.localizedDescription.contains("CKError.\(symbol) (\(code.rawValue))"))
            XCTAssertFalse(failure.localizedDescription.contains("服务暂时繁忙"))
        }
        XCTAssertTrue(CloudKitFailure.map(CKError(.serverRejectedRequest)).localizedDescription.contains("请检查容器与字段配置"))
        XCTAssertTrue(CloudKitFailure.map(CKError(.limitExceeded)).localizedDescription.contains("调整请求大小"))
    }

    func testOnlyTransientCloudKitServiceFailuresUseRetryAfter() {
        for code in [CKError.Code.serviceUnavailable, .requestRateLimited, .zoneBusy] {
            let failure = CloudKitFailure.map(CKError(code, userInfo: [CKErrorRetryAfterKey: 120]))
            XCTAssertEqual(failure, .service(retryAfter: 120))
            XCTAssertTrue(failure.shouldRetryAutomatically)
        }
        for invalid in [-1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(CloudKitFailure.map(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: invalid])),
                           .service(retryAfter: nil))
        }
    }

    func testNestedPartialFailuresPreferActualRequestCauseRegardlessOfRecordOrder() {
        let cause = CKError(.constraintViolation)
        let collateral = CKError(.batchRequestFailed)
        let busy = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 120])
        let nested = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["constraint": cause, "batch": collateral]])
        for errors in [["first": nested, "last": busy], ["first": busy, "last": nested]] {
            let failure = CloudKitFailure.map(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]))
            XCTAssertEqual(failure, .cloudKitRequest(code: CKError.Code.constraintViolation.rawValue))
            XCTAssertFalse(failure.shouldRetryAutomatically)
        }
        let reset = CKError(.zoneNotFound, userInfo: [CKErrorUserDidResetEncryptedDataKey: true])
        XCTAssertEqual(CloudKitFailure.map(CKError(.partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: ["request": nested, "reset": reset]])), .encryptedDataReset)
    }

    func testPartialFailureUsesRealTransientCauseInsteadOfCollateralBatchFailure() {
        let busy = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 120])
        let rateLimit = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 240])
        let collateral = CKError(.batchRequestFailed)
        for errors in [["first": busy, "second": rateLimit, "third": collateral],
                       ["first": collateral, "second": rateLimit, "third": busy]] {
            let failure = CloudKitFailure.map(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]))
            XCTAssertEqual(failure, .service(retryAfter: 240))
            XCTAssertTrue(failure.shouldRetryAutomatically)
        }
        XCTAssertEqual(CloudSyncError.preferredFailure(in: [.cloudKitRequest(code: 22), .network]), .network)
    }

    func testEmptyAndDeepPartialFailuresDoNotMasqueradeAsServiceBusy() {
        let empty = CloudKitFailure.map(CKError(.partialFailure))
        XCTAssertEqual(empty, .cloudKitRequest(code: CKError.Code.partialFailure.rawValue))
        XCTAssertFalse(empty.shouldRetryAutomatically)
        var nested = CKError(.constraintViolation)
        for _ in 0..<12 {
            nested = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["nested": nested]])
        }
        XCTAssertEqual(CloudKitFailure.map(nested), .cloudKitRequest(code: CKError.Code.partialFailure.rawValue))
    }

    func testUnknownCloudKitCodePreservesOnlyItsNumberAndDoesNotAutomaticallyRetry() {
        let error = NSError(domain: CKErrorDomain, code: 9_999,
                            userInfo: [NSLocalizedDescriptionKey: "private-account-detail"])
        let failure = CloudKitFailure.map(error)
        XCTAssertEqual(failure, .cloudKitRequest(code: 9_999))
        XCTAssertFalse(failure.shouldRetryAutomatically)
        XCTAssertTrue(failure.localizedDescription.contains("CKError (9999)"))
        XCTAssertFalse(failure.localizedDescription.contains("private-account-detail"))
    }

    func testCloudKitFailureDiagnosticsNeverExposeDescriptionsRecordsOrCredentials() {
        let privateValues = ["private-student-account", "private-session-secret", "private-password-secret",
                             "private-record-payload", "private-record-identifier", "private-zone-owner"]
        let zone = CKRecordZone.ID(zoneName: "private-zone", ownerName: privateValues[5])
        let record = CKRecord(recordType: "SyncEntry", recordID: .init(recordName: privateValues[4], zoneID: zone))
        record.encryptedValues["payload"] = Data(privateValues[3].utf8) as NSData
        let root = CKError(.serverRejectedRequest, userInfo: [
            NSLocalizedDescriptionKey: privateValues[0], NSLocalizedFailureReasonErrorKey: privateValues[1],
            NSDebugDescriptionErrorKey: privateValues[2],
            NSUnderlyingErrorKey: NSError(domain: privateValues[0], code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: privateValues[3]]),
            CKRecordChangedErrorServerRecordKey: record,
            CKRecordChangedErrorClientRecordKey: record
        ])
        let partial = CKError(.partialFailure, userInfo: [
            NSLocalizedDescriptionKey: privateValues.joined(separator: " "),
            CKPartialErrorsByItemIDKey: [record.recordID: root]
        ])
        for error in [root, partial] {
            let failure = CloudKitFailure.map(error)
            XCTAssertEqual(failure, .cloudKitRequest(code: CKError.Code.serverRejectedRequest.rawValue))
            let visible = CloudSyncStatus.failed(failure.localizedDescription).message + String(describing: failure)
            XCTAssertTrue(visible.contains("serverRejectedRequest"))
            XCTAssertTrue(visible.contains("15"))
            for value in privateValues { XCTAssertFalse(visible.contains(value), "A private sentinel escaped the diagnostic") }
        }
    }

    func testPartialSaveKeepsSuccessAndSelectsConstraintOverCollateralBatchError() throws {
        let zone = CKRecordZone.ID(zoneName: "UCASSync", ownerName: CKCurrentUserDefaultName)
        let success = try CloudKitRecordCodec.encode(.init(id: "saved", data: Data([1])), zoneID: zone)
        let state = CloudKitSaveAccumulator(ids: ["saved", "collateral", "request"])
        state.accept(id: "saved", result: .success(success))
        let errors: [CKRecord.ID: Error] = [
            .init(recordName: "collateral", zoneID: zone): CKError(.batchRequestFailed),
            .init(recordName: "request", zoneID: zone): CKError(.constraintViolation)
        ]
        state.finish(error: CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]))
        let result = state.result()
        XCTAssertEqual(result.saved.map(\.id), ["saved"])
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(CloudSyncError.preferredFailure(in: result.failures.map(\.error)),
                       .cloudKitRequest(code: CKError.Code.constraintViolation.rawValue))
    }
    #endif

    #if canImport(Security)
    func testLiveCredentialQueriesUseDedicatedSynchronizableAccessGroup() throws {
        let backend = FakeSyncCredentialBackend()
        let store = LiveSyncCredentialStore(accessGroup: "TEAM.shared.credentials", backend: backend)
        try store.setData(Data([1]), for: "immutable-version")
        let item = try XCTUnwrap(backend.added.first)
        XCTAssertEqual(item[kSecAttrService as String] as? String, "cn.ucas.signin.icloud.v1")
        XCTAssertEqual(item[kSecAttrAccessGroup as String] as? String, "TEAM.shared.credentials")
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        #if os(macOS)
        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
        XCTAssertEqual(try store.data(for: "immutable-version"), Data([1]))
        XCTAssertEqual(try store.allIDs(), ["immutable-version"])
        try store.removeData(for: "immutable-version")
        XCTAssertEqual(backend.deleted.first?[kSecAttrAccount as String] as? String, "immutable-version")
        XCTAssertEqual(backend.deleted.first?[kSecAttrAccessGroup as String] as? String, "TEAM.shared.credentials")
    }

    func testLockedKeychainNeverFallsBackToOverwriteOrDelete() throws {
        let backend = FakeSyncCredentialBackend()
        backend.copyStatus = errSecInteractionNotAllowed
        let store = LiveSyncCredentialStore(accessGroup: "TEAM.shared", backend: backend)
        XCTAssertThrowsError(try store.setData(Data([1]), for: "id")) {
            XCTAssertEqual($0 as? CloudSyncError, .keychainLocked)
        }
        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testMissingEntitlementDoesNotTouchKeychain() throws {
        let backend = FakeSyncCredentialBackend()
        backend.allowed = false
        let store = LiveSyncCredentialStore(accessGroup: "TEAM.shared", backend: backend)
        XCTAssertThrowsError(try store.allIDs()) {
            XCTAssertEqual($0 as? CloudSyncError, .unconfigured)
        }
        XCTAssertEqual(backend.copyCount, 0)
    }

    func testConflictingImmutableKeychainItemIsPreserved() throws {
        let backend = FakeSyncCredentialBackend()
        backend.items["version"] = Data([1])
        let store = LiveSyncCredentialStore(accessGroup: "TEAM.shared", backend: backend)
        XCTAssertThrowsError(try store.setData(Data([2]), for: "version")) {
            XCTAssertEqual($0 as? CloudSyncError, .immutableCredential)
        }
        XCTAssertEqual(backend.items["version"], Data([1]))
        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testDeviceIdentityIsStableAndNeverSynchronizableOrRestorable() throws {
        let backend = FakeSyncCredentialBackend()
        let first = try SyncDeviceIdentity.loadOrCreate(backend: backend)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(try SyncDeviceIdentity.loadOrCreate(backend: backend), first)
        XCTAssertEqual(backend.added.count, 1)
        let item = try XCTUnwrap(backend.added.first)
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #if os(macOS)
        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
    }

    func testUnavailableIdentityDoesNotCreateNewWriter() throws {
        let backend = FakeSyncCredentialBackend()
        backend.copyStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try SyncDeviceIdentity.loadOrCreate(backend: backend)) {
            XCTAssertEqual($0 as? CloudSyncError, .keychainLocked)
        }
        XCTAssertTrue(backend.added.isEmpty)
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testMissingJournalRotatesWriterIdentityWithoutDeletingKeychainItem() throws {
        let backend = FakeSyncCredentialBackend()
        let first = try SyncDeviceIdentity.loadOrCreate(backend: backend)
        let fresh = try SyncDeviceIdentity.loadOrCreate(renew: true, backend: backend)
        XCTAssertNotEqual(first, fresh)
        XCTAssertEqual(try SyncDeviceIdentity.loadOrCreate(backend: backend), fresh)
        XCTAssertEqual(backend.updateCount, 1)
        XCTAssertEqual(backend.added.count, 1)
        XCTAssertTrue(backend.deleted.isEmpty)
    }
    #endif

    private func der(_ tag: UInt8, _ body: Data) -> Data {
        precondition(body.count < 256)
        let size = body.count < 128 ? Data([UInt8(body.count)]) : Data([0x81, UInt8(body.count)])
        return Data([tag]) + size + body
    }

    private func executableSignature(xml: Data? = nil, der: Data? = nil) -> Data {
        func words(_ values: [UInt32], bigEndian: Bool) -> Data {
            Data(values.flatMap { value in
                let shifts = bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]
                return shifts.map { UInt8(truncatingIfNeeded: value >> $0) }
            })
        }
        var entries: [(UInt32, UInt32, Data)] = []
        if let xml { entries.append((5, 0xfade7171, xml)) }
        if let der { entries.append((7, 0xfade7172, der)) }
        var offset = 12 + entries.count * 8
        var indexes = Data()
        var blobs = Data()
        for (slot, magic, payload) in entries {
            indexes += words([slot, UInt32(offset)], bigEndian: true)
            blobs += words([magic, UInt32(payload.count + 8)], bigEndian: true) + payload
            offset += payload.count + 8
        }
        let signature = words([0xfade0cc0, UInt32(offset), UInt32(entries.count)], bigEndian: true) + indexes + blobs
        return words([0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0,
                      0x1d, 16, 48, UInt32(signature.count)], bigEndian: false) + signature
    }
}

#if canImport(Security)
@MainActor
private final class FakeSyncCredentialBackend: SyncCredentialStorageBackend {
    var allowed = true
    var copyStatus: OSStatus?
    var copyCount = 0
    var updateCount = 0
    var items: [String: Data] = [:]
    var added: [[String: Any]] = []
    var deleted: [[String: Any]] = []
    func permitsAccessGroup(_ group: String) -> Bool { allowed }
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        copyCount += 1
        if let copyStatus { return (copyStatus, nil) }
        if let id = query[kSecAttrAccount as String] as? String {
            guard let data = items[id] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
        return (errSecSuccess, items.keys.map { [kSecAttrAccount as String: $0] })
    }
    func add(_ item: [String: Any]) -> OSStatus {
        added.append(item)
        guard let id = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data else { return errSecParam }
        guard items[id] == nil else { return errSecDuplicateItem }
        items[id] = data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deleted.append(query)
        guard let id = query[kSecAttrAccount as String] as? String else { return errSecParam }
        items.removeValue(forKey: id)
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateCount += 1
        guard let id = query[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[id] != nil else { return errSecItemNotFound }
        items[id] = data
        return errSecSuccess
    }
}
#endif
