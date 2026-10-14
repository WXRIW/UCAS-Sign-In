import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Recreating a deleted zone requires an explicit user action, separate from fetching.
@MainActor
public protocol CloudSyncZoneRecoveryClient: CloudSyncClient {
    func recoverDeletedZone() async throws
}

/// Shared identity for the private-zone subscription and incoming silent notifications.
public enum CloudKitSyncSubscription {
    public static let zoneName = "UCASSync"
    public static let subscriptionID = "ucas-sync-zone-changes-v1"

    public static func matches(userInfo: [AnyHashable: Any], containerIdentifier: String) -> Bool {
        #if canImport(CloudKit)
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKRecordZoneNotification else {
            return false
        }
        return matches(containerIdentifier: notification.containerIdentifier, subscriptionID: notification.subscriptionID,
                       databaseScope: notification.databaseScope, recordZoneID: notification.recordZoneID,
                       expectedContainerIdentifier: containerIdentifier)
        #else
        return false
        #endif
    }

    #if canImport(CloudKit)
    static func makeSubscription() -> CKRecordZoneSubscription {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    static func matches(containerIdentifier: String?, subscriptionID: String?, databaseScope: CKDatabase.Scope,
                        recordZoneID: CKRecordZone.ID?, expectedContainerIdentifier: String) -> Bool {
        guard !expectedContainerIdentifier.isEmpty, containerIdentifier == expectedContainerIdentifier,
              subscriptionID == Self.subscriptionID, databaseScope == .private else { return false }
        // CloudKit may prune zone metadata. The stable subscription still identifies our private zone.
        return recordZoneID.map { $0.zoneName == zoneName } ?? true
    }
    #endif
}

#if canImport(CloudKit)

/// CloudKit transport. Constructing this value does not contact iCloud.
@MainActor
public final class LiveCloudSyncClient: CloudSyncZoneRecoveryClient {
    private let containerIdentifier: String
    private var container: CKContainer?
    private let accountEpoch = CloudKitAccountEpoch()
    private var boundEpoch: UUID?
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitSyncSubscription.zoneName, ownerName: CKCurrentUserDefaultName)
    private var subscriptionRegistration = CloudKitSubscriptionRegistration()

    public init(containerIdentifier: String) { self.containerIdentifier = containerIdentifier }

    public func accountIdentifier() async throws -> String {
        let container = try configuredContainer()
        let epoch = accountEpoch.current
        do {
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount: throw CloudSyncError.noAccount
            case .restricted: throw CloudSyncError.restricted
            case .temporarilyUnavailable: throw CloudSyncError.temporarilyUnavailable
            case .couldNotDetermine: throw CloudSyncError.temporarilyUnavailable
            @unknown default: throw CloudSyncError.unavailable
            }
            try Task.checkCancellation()
            let identifier = try await container.userRecordID().recordName
            try Task.checkCancellation()
            try accountEpoch.check(epoch)
            boundEpoch = epoch
            return identifier
        } catch { throw CloudKitFailure.map(error) }
    }

    public func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges {
        let epoch = try currentEpoch()
        let database = try configuredContainer().privateCloudDatabase
        var token = try CloudKitRecordCodec.decodeToken(cursor)
        try await ensureZone(in: database, allowCreation: cursor == nil, epoch: epoch)
        var records: [String: CloudSyncRecord] = [:]
        var deletions: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page = try await fetchPage(database: database, token: token, epoch: epoch)
            try accountEpoch.check(epoch)
            for record in page.records {
                records[record.id] = record
                deletions.remove(record.id)
            }
            for id in page.deletions {
                records.removeValue(forKey: id)
                deletions.insert(id)
            }
            token = page.token
            if !page.moreComing { break }
        } while true
        return CloudSyncChanges(records: records.values.sorted { $0.id < $1.id },
                                deletedRecordIDs: deletions.sorted(),
                                cursor: try CloudKitRecordCodec.encodeToken(token))
    }

    public func recoverDeletedZone() async throws {
        try Task.checkCancellation()
        let epoch = try currentEpoch()
        let database = try configuredContainer().privateCloudDatabase
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            try Task.checkCancellation()
            try accountEpoch.check(epoch)
            let failure = CloudKitFailure.map(error)
            guard failure == .zoneMissing || failure == .zoneDeletedByUser else { throw failure }
            do { _ = try await database.save(CKRecordZone(zoneID: zoneID)) }
            catch { throw CloudKitFailure.map(error) }
        }
        try Task.checkCancellation()
        try accountEpoch.check(epoch)
        subscriptionRegistration.reset(epoch: epoch)
    }

    public func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult {
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ !$0.id.isEmpty }) else { throw CloudSyncError.invalidData }
        guard !records.isEmpty else { return .init() }
        let epoch = try currentEpoch()
        let database = try configuredContainer().privateCloudDatabase
        try await ensureZone(in: database, allowCreation: true, epoch: epoch)
        var saved: [CloudSyncRecord] = []
        var conflicts: [CloudSyncRecord] = []
        var failures: [CloudSyncRecordFailure] = []
        // Bound request size without imposing an artificial limit on an individual record.
        var batches: [[CloudSyncRecord]] = []
        var batch: [CloudSyncRecord] = []
        var bytes = 0
        for record in records {
            if !batch.isEmpty && (batch.count >= 100 || bytes + record.data.count > 750_000) {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(record)
            bytes += record.data.count
        }
        if !batch.isEmpty { batches.append(batch) }
        var deferredError: CloudSyncError?
        for batch in batches {
            try accountEpoch.check(epoch)
            if let deferredError {
                failures += batch.map { .init(id: $0.id, error: deferredError) }
                continue
            }
            if Task.isCancelled {
                failures += batch.map { .init(id: $0.id, error: .cancelled) }
                continue
            }
            let result = await saveBatch(batch, database: database, epoch: epoch)
            try accountEpoch.check(epoch)
            saved += result.saved
            conflicts += result.conflicts
            failures += result.failures
            // A throttled/offline request must not immediately issue the remaining batches.
            deferredError = result.failures.first(where: { $0.error.defersRemainingBatches })?.error
        }
        return .init(saved: saved, conflicts: conflicts, failures: failures)
    }

    private func configuredContainer() throws -> CKContainer {
        guard CloudSyncEntitlements.permitsCloudContainer(containerIdentifier) else {
            throw CloudSyncError.unconfigured
        }
        if let container { return container }
        // CKContainer can raise an ObjC exception when its signing entitlement is absent.
        let value = CKContainer(identifier: containerIdentifier)
        container = value
        return value
    }

    private func currentEpoch() throws -> UUID {
        guard let epoch = boundEpoch else { throw CloudSyncError.temporarilyUnavailable }
        try accountEpoch.check(epoch)
        return epoch
    }

    private func ensureZone(in database: CKDatabase, allowCreation: Bool, epoch: UUID) async throws {
        try Task.checkCancellation()
        try accountEpoch.check(epoch)
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            try accountEpoch.check(epoch)
            let mapped = CloudKitFailure.map(error)
            guard mapped == .zoneMissing, allowCreation else { throw mapped }
            // A reset of encrypted data and an explicit user deletion are not an empty new zone.
            try Task.checkCancellation()
            try accountEpoch.check(epoch)
            do { _ = try await database.save(CKRecordZone(zoneID: zoneID)) }
            catch { throw CloudKitFailure.map(error) }
            try accountEpoch.check(epoch)
            subscriptionRegistration.reset(epoch: epoch)
        }
        try Task.checkCancellation()
        try accountEpoch.check(epoch)
        await ensureSubscription(in: database, epoch: epoch)
        // Subscription failure is best effort; cancellation and an account change still stop this sync.
        try Task.checkCancellation()
        try accountEpoch.check(epoch)
    }

    private func ensureSubscription(in database: CKDatabase, epoch: UUID) async {
        guard subscriptionRegistration.beginAttempt(epoch: epoch, now: Date()) else { return }
        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [CloudKitSyncSubscription.makeSubscription()], subscriptionIDsToDelete: nil)
        // Subscription setup must not hold a normal sync indefinitely when the network is unavailable.
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        do {
            try Task.checkCancellation()
            try accountEpoch.register(operation, epoch: epoch)
            defer { accountEpoch.unregister(operation) }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    operation.modifySubscriptionsResultBlock = { result in
                        continuation.resume(with: result)
                    }
                    operation.qualityOfService = .utility
                    database.add(operation)
                }
            } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            try accountEpoch.check(epoch)
            subscriptionRegistration.finishAttempt(epoch: epoch, error: nil, now: Date())
        } catch {
            subscriptionRegistration.finishAttempt(epoch: epoch, error: CloudKitFailure.map(error), now: Date())
        }
    }

    private func fetchPage(database: CKDatabase, token: CKServerChangeToken?, epoch: UUID) async throws -> CloudKitFetchPage {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token
        configuration.resultsLimit = 200
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                           configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = false
        let state = CloudKitFetchAccumulator()
        try accountEpoch.register(operation, epoch: epoch)
        defer { accountEpoch.unregister(operation) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.recordWasChangedBlock = { _, result in
                    do {
                        let record = try result.get()
                        guard record.recordType == CloudKitRecordCodec.recordType else { return }
                        let value = try CloudKitRecordCodec.decode(record)
                        state.records[value.id] = value
                        state.deletions.remove(value.id)
                    } catch { state.error = CloudKitFailure.map(error) }
                }
                operation.recordWithIDWasDeletedBlock = { id, type in
                    guard type == CloudKitRecordCodec.recordType else { return }
                    state.records.removeValue(forKey: id.recordName)
                    state.deletions.insert(id.recordName)
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let value):
                        state.token = value.serverChangeToken
                        state.moreComing = value.moreComing
                    case .failure(let error): state.error = CloudKitFailure.map(error)
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    if case .failure(let error) = result, state.error == nil { state.error = CloudKitFailure.map(error) }
                    if let error = state.error { continuation.resume(throwing: error) }
                    else if let token = state.token {
                        continuation.resume(returning: .init(records: Array(state.records.values),
                                                             deletions: state.deletions, token: token,
                                                             moreComing: state.moreComing))
                    } else { continuation.resume(throwing: CloudSyncError.invalidData) }
                }
                operation.qualityOfService = .utility
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private func saveBatch(_ records: [CloudSyncRecord], database: CKDatabase, epoch: UUID) async -> CloudSyncSaveResult {
        var outgoing: [CKRecord] = []
        let state = CloudKitSaveAccumulator(ids: records.map(\.id))
        for record in records {
            do { outgoing.append(try CloudKitRecordCodec.encode(record, zoneID: zoneID)) }
            catch { state.failures[record.id] = CloudKitFailure.map(error) }
        }
        guard !outgoing.isEmpty else { return state.result() }
        let operation = CKModifyRecordsOperation(recordsToSave: outgoing, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false
        do { try accountEpoch.register(operation, epoch: epoch) }
        catch { state.finish(error: error); return state.result() }
        defer { accountEpoch.unregister(operation) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.perRecordSaveBlock = { id, result in state.accept(id: id.recordName, result: result) }
                operation.modifyRecordsResultBlock = { result in
                    let error: Error?
                    if case .failure(let value) = result { error = value } else { error = nil }
                    // Preserve every per-record success even if the enclosing request failed.
                    state.finish(error: error)
                    continuation.resume(returning: state.result())
                }
                operation.qualityOfService = .utility
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }
}

/// In-memory setup state is scoped to the current account, including retries after a failed save.
struct CloudKitSubscriptionRegistration {
    private var epoch: UUID?
    private var installed = false
    private var inFlight = false
    private var failures = 0
    private var retryNotBefore = Date.distantPast

    mutating func reset(epoch: UUID) {
        self = .init()
        self.epoch = epoch
    }

    mutating func beginAttempt(epoch: UUID, now: Date) -> Bool {
        if self.epoch != epoch { reset(epoch: epoch) }
        guard !installed, !inFlight, now >= retryNotBefore else { return false }
        inFlight = true
        return true
    }

    mutating func finishAttempt(epoch: UUID, error: CloudSyncError?, now: Date) {
        guard self.epoch == epoch else { return }
        inFlight = false
        guard let error else {
            installed = true
            failures = 0
            return
        }
        guard error != .cancelled else { return }
        failures = min(failures + 1, 6)
        let delay = min(60 * pow(2, Double(failures - 1)), 1_800)
        if case .service(let retryAfter) = error, let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            retryNotBefore = now.addingTimeInterval(max(delay, retryAfter))
        } else {
            retryNotBefore = now.addingTimeInterval(delay)
        }
    }
}

/// Invalidate on the notification's own thread, before the UI actor can resume an old sync.
final class CloudKitAccountEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()
    private var operations: [ObjectIdentifier: CKOperation] = [:]
    private var observer: NSObjectProtocol?

    init(observeNotifications: Bool = true) {
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var current: UUID { lock.lock(); defer { lock.unlock() }; return epoch }
    func check(_ expected: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard expected == epoch else { throw CloudSyncError.temporarilyUnavailable }
    }
    func register(_ operation: CKOperation, epoch expected: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard expected == epoch else { throw CloudSyncError.temporarilyUnavailable }
        operations[ObjectIdentifier(operation)] = operation
    }
    func unregister(_ operation: CKOperation) {
        lock.lock(); defer { lock.unlock() }
        operations.removeValue(forKey: ObjectIdentifier(operation))
    }
    func invalidate() {
        lock.lock()
        epoch = UUID()
        let pending = Array(operations.values)
        operations.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}

private extension CloudSyncError {
    var defersRemainingBatches: Bool {
        switch self {
        case .network, .service, .quotaExceeded, .cancelled, .noAccount, .restricted,
             .temporarilyUnavailable, .unconfigured, .zoneMissing, .zoneDeletedByUser, .encryptedDataReset,
             .cloudKitRequest:
            true
        default: false
        }
    }
}

enum CloudKitRecordCodec {
    static let recordType = "SyncEntry"
    static func decode(_ record: CKRecord) throws -> CloudSyncRecord {
        guard record.recordType == recordType,
              let payload = record.encryptedValues["payload"] as? Data else { throw CloudSyncError.invalidData }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return .init(id: record.recordID.recordName, data: payload, systemFields: archiver.encodedData)
    }

    static func encode(_ value: CloudSyncRecord, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let id = CKRecord.ID(recordName: value.id, zoneID: zoneID)
        let record: CKRecord
        if let fields = value.systemFields {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: fields)
                unarchiver.requiresSecureCoding = true
                unarchiver.decodingFailurePolicy = .setErrorAndReturn
                defer { unarchiver.finishDecoding() }
                guard let restored = CKRecord(coder: unarchiver), restored.recordID == id,
                      restored.recordType == recordType else { throw CloudSyncError.invalidData }
                record = restored
            } catch { throw CloudSyncError.invalidData }
        } else { record = CKRecord(recordType: recordType, recordID: id) }
        record.encryptedValues["payload"] = value.data as NSData
        return record
    }

    static func decodeToken(_ data: Data?) throws -> CKServerChangeToken? {
        guard let data else { return nil }
        do {
            guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
                throw CloudSyncError.tokenExpired
            }
            return token
        } catch { throw CloudSyncError.tokenExpired }
    }

    static func encodeToken(_ token: CKServerChangeToken?) throws -> Data? {
        guard let token else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}

enum CloudKitFailure {
    static func map(_ error: Error) -> CloudSyncError {
        map(error, depth: 0)
    }

    private static func map(_ error: Error, depth: Int) -> CloudSyncError {
        if let error = error as? CloudSyncError { return error }
        if error is CancellationError { return .cancelled }
        let value = error as NSError
        if value.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true { return .encryptedDataReset }
        guard let cloudError = error as? CKError else { return .unavailable }
        switch cloudError.code {
        case .badContainer, .missingEntitlement, .badDatabase: return .unconfigured
        case .notAuthenticated: return .noAccount
        case .managedAccountRestricted, .permissionFailure: return .restricted
        case .accountTemporarilyUnavailable: return .temporarilyUnavailable
        case .changeTokenExpired: return .tokenExpired
        case .zoneNotFound: return .zoneMissing
        case .userDeletedZone: return .zoneDeletedByUser
        case .unknownItem: return .recordMissing
        case .networkFailure, .networkUnavailable, .serverResponseLost: return .network
        case .quotaExceeded: return .quotaExceeded
        case .operationCancelled: return .cancelled
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // The documented value is NSNumber; some SDK overlays accept only a
            // floating-point value in retryAfterSeconds and miss integer seconds.
            let seconds = cloudError.retryAfterSeconds
                ?? (cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
            let retryAfter = seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return .service(retryAfter: retryAfter)
        case .partialFailure:
            guard depth < 8 else { return .cloudKitRequest(code: cloudError.code.rawValue) }
            let failures = cloudError.partialErrorsByItemID?.values.map { map($0, depth: depth + 1) } ?? []
            return CloudSyncError.preferredFailure(in: failures) ?? .cloudKitRequest(code: cloudError.code.rawValue)
        default: return .cloudKitRequest(code: cloudError.code.rawValue)
        }
    }
}

private struct CloudKitFetchPage: Sendable {
    let records: [CloudSyncRecord]
    let deletions: Set<String>
    let token: CKServerChangeToken
    let moreComing: Bool
}

// CloudKit documents that callbacks for each operation run on one private serial queue.
private final class CloudKitFetchAccumulator: @unchecked Sendable {
    var records: [String: CloudSyncRecord] = [:]
    var deletions: Set<String> = []
    var token: CKServerChangeToken?
    var moreComing = false
    var error: CloudSyncError?
}

final class CloudKitSaveAccumulator: @unchecked Sendable {
    let ids: [String]
    var saved: [String: CloudSyncRecord] = [:]
    var conflicts: [String: CloudSyncRecord] = [:]
    var failures: [String: CloudSyncError] = [:]

    init(ids: [String]) { self.ids = ids }

    func accept(id: String, result: Result<CKRecord, Error>) {
        switch result {
        case .success(let record):
            do { saved[id] = try CloudKitRecordCodec.decode(record) }
            catch { failures[id] = CloudKitFailure.map(error) }
        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged,
               let record = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                do { conflicts[id] = try CloudKitRecordCodec.decode(record) }
                catch { failures[id] = CloudKitFailure.map(error) }
            } else { failures[id] = CloudKitFailure.map(error) }
        }
    }

    func finish(error: Error?) {
        let partial = (error as? CKError)?.partialErrorsByItemID
        for id in ids where saved[id] == nil && conflicts[id] == nil && failures[id] == nil {
            if let itemError = partial?.first(where: { ($0.key as? CKRecord.ID)?.recordName == id })?.value {
                accept(id: id, result: .failure(itemError))
            } else { failures[id] = error.map(CloudKitFailure.map) ?? .invalidData }
        }
    }

    func result() -> CloudSyncSaveResult {
        .init(saved: ids.compactMap { saved[$0] }, conflicts: ids.compactMap { conflicts[$0] },
              failures: ids.compactMap { id in failures[id].map { .init(id: id, error: $0) } })
    }
}
#else
@MainActor
public struct LiveCloudSyncClient: CloudSyncClient {
    public init(containerIdentifier: String) {}
    public func accountIdentifier() async throws -> String { throw CloudSyncError.unavailable }
    public func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges { throw CloudSyncError.unavailable }
    public func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult { throw CloudSyncError.unavailable }
}
#endif
