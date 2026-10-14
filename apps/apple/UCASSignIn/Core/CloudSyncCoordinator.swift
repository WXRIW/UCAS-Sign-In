import Foundation

public enum CloudSyncRemoteRefreshResult: Equatable, Sendable {
    case newData, noData, failed
}

/// Owns the local replica. Applying a remote value never creates a new user edit.
@MainActor
public final class CloudSyncCoordinator {
    public var snapshot: (() throws -> CloudSyncLocalSnapshot)?
    public var apply: ((CloudSyncIncoming) async throws -> Void)?
    public var onChange: (() -> Void)?
    public var requiresBootstrapRetry = false
    public private(set) var status: CloudSyncStatus
    public private(set) var enabled: Bool
    public private(set) var state: CloudSyncState
    public let deviceName: String
    private let client: any CloudSyncClient
    private let credentials: any CredentialSyncStore
    private let store: any CloudSyncStateStore
    private var loadFailure: Error?
    private var scheduled: Task<Void, Never>?
    private var run: Task<Void, Never>?
    private var generation = UUID()
    private var retryCount = 0
    private var nextAttempt: Date = .distantPast
    private var requiresExplicitRetry = false
    private var lastAttempt: Date = .distantPast
    private var needsAnotherPass = false
    private var remoteChangesPending = false
    private var failedZone: (namespace: String, error: CloudSyncError)?
    private var requestedZoneRecovery: (namespace: String, generation: UUID)?
    public var now: () -> Date = Date.init

    deinit { scheduled?.cancel(); run?.cancel() }

    public init(client: any CloudSyncClient, credentials: any CredentialSyncStore,
                store: any CloudSyncStateStore, deviceID: String, deviceName: String, enabled: Bool = true) {
        self.client = client; self.credentials = credentials; self.store = store
        self.deviceName = deviceName; self.enabled = enabled
        status = enabled ? .syncing : .disabled
        state = CloudSyncState(deviceID: deviceID)
        do {
            if let saved = try store.load() {
                guard saved.formatVersion == 1 else { throw CloudSyncStateError.unsupportedVersion }
                // A restored backup is a new participant, never a duplicate writer identity.
                if saved.deviceID == deviceID { state = saved }
            }
        } catch { loadFailure = error; status = .failed(error.localizedDescription) }
    }

    private var namespace: String { state.identity ?? "unbound" }
    private var replica: CloudSyncReplica {
        get { state.replicas[namespace] ?? CloudSyncReplica() }
        set { state.replicas[namespace] = newValue }
    }
    public var lastSuccessfulSync: Date? { replica.lastSuccessfulSync }
    public var deviceID: String { state.deviceID }
    public var isSyncing: Bool { status == .syncing && run != nil }

    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        generation = UUID()
        remoteChangesPending = false
        requestedZoneRecovery = nil
        scheduled?.cancel(); scheduled = nil
        run?.cancel(); run = nil
        if value {
            if let failedZone {
                requestedZoneRecovery = (failedZone.namespace, generation)
            }
            status = .syncing; nextAttempt = .distantPast
            retryCount = 0; requiresExplicitRetry = false
            schedule(after: 0)
        }
        else { status = .disabled }
        onChange?()
    }

    /// Called only after the application's own local transaction has committed.
    public func recordLocalChanges(_ value: CloudSyncLocalSnapshot, explicitLogin: String? = nil) throws {
        guard loadFailure == nil else { throw loadFailure! }
        let before = state
        do {
            try capture(value, explicitLogin: explicitLogin, acknowledgeOnly: false)
            try persist()
        } catch {
            state = before; status = .failed(error.localizedDescription); onChange?(); throw error
        }
        if state != before { needsAnotherPass = true; schedule(after: 2) }
    }

    public func removeLocally(accountID: String) throws {
        let before = state
        var value = replica
        value.suppressedAccounts[accountID] = profile(accountID)?.incarnation
            ?? value.localIncarnations[accountID] ?? initialIncarnation(accountID)
        for id in value.pending where value.records[id]?.accountID == accountID { value.pending.remove(id) }
        replica = value
        do { try persist() } catch { state = before; throw error }
    }

    /// Persist an explicit retention cleanup before the host discards its display data.
    /// Call recordLocalChanges first so local-only rows have known immutable identities.
    public func recordHistoryCleanup(accountID: String, attendanceIDs: Set<UUID> = [],
                                     historyIDs: Set<String> = []) throws {
        guard loadFailure == nil else { throw loadFailure! }
        guard !replica.quarantinedAccounts.contains(accountID), let owner = profile(accountID) else { return }
        let before = state
        do {
            let candidates = replica.records.values.filter { record in
                guard record.accountID == accountID, record.incarnation == owner.incarnation,
                      record.resolvedCandidate?.value != nil else { return false }
                if record.kind == .attendance { return UUID(uuidString: record.key).map(attendanceIDs.contains) ?? false }
                return record.kind == .autoHistory && historyIDs.contains(record.key)
            }
            for record in candidates {
                if record.kind == .autoHistory {
                    let history = try SyncCodec.decode(SyncAutoSignHistory.self, from: record.resolvedCandidate!.value!)
                    guard [.signed, .missed, .skipped].contains(history.stage) else { continue }
                }
                try write(kind: record.kind, account: accountID, incarnation: owner.incarnation,
                          key: record.key, value: nil, force: true)
            }
            try persist()
        } catch { state = before; throw error }
        if state != before { needsAnotherPass = true; schedule(after: 2) }
    }

    /// The durable tombstone precedes local account removal and cloud cleanup.
    public func removeEverywhere(accountID: String) throws {
        guard loadFailure == nil else { throw loadFailure! }
        let before = state
        do {
            try write(kind: .account, account: accountID, value: nil, force: true)
            try stripDeletedAccountData()
            try persist()
        } catch { state = before; throw error }
        schedule(after: 0)
    }

    public func invalidateSession(accountID: String, reference: SyncCredentialReference) throws {
        guard let owner = profile(accountID) else { return }
        try write(kind: .invalidSession, account: accountID, incarnation: owner.incarnation,
                  key: reference.id, value: try SyncCodec.encode(reference))
        try persist()
        needsAnotherPass = true
    }

    /// Revocation is bound to an immutable secret version, never to the account's latest token.
    public func invalidateLocalSession(_ session: SchoolSession) throws {
        guard let owner = profile(session.studentNo) else { return }
        let data = try SyncCodec.encode(SyncedSessionSecret(accountID: session.studentNo,
            incarnation: owner.incarnation, session: session))
        let fingerprint = SyncIdentity.hash(data)
        for record in Array(replica.records.values) where record.kind == .session
            && record.accountID == session.studentNo && record.incarnation == owner.incarnation {
            guard let value = record.resolvedCandidate?.value else { continue }
            let reference = try SyncCodec.decode(SyncCredentialReference.self, from: value)
            if reference.fingerprint == fingerprint { try invalidateSession(accountID: session.studentNo, reference: reference) }
        }
        schedule(after: 2)
    }

    public func sessionFingerprint(_ session: SchoolSession, incarnation: String) throws -> String {
        SyncIdentity.hash(try SyncCodec.encode(SyncedSessionSecret(accountID: session.studentNo,
            incarnation: incarnation, session: session)))
    }

    public func incarnation(for accountID: String) -> String {
        profile(accountID)?.incarnation ?? initialIncarnation(accountID)
    }

    public func accountDidChange() {
        generation = UUID()
        remoteChangesPending = false
        failedZone = nil
        requestedZoneRecovery = nil
        run?.cancel(); run = nil
        scheduled?.cancel(); scheduled = nil
        nextAttempt = .distantPast
        retryCount = 0; requiresExplicitRetry = false
        if enabled { schedule(after: 0) }
    }

    public func tick() async {
        guard enabled, now().timeIntervalSince(lastAttempt) >= 60 else { return }
        await synchronize()
    }

    /// Pushes are hints to fetch with the existing cursor, never authoritative data.
    /// Bypass the polling interval while retaining server backoff and permanent-error gates.
    public func remoteChangesAvailable() async -> CloudSyncRemoteRefreshResult {
        guard enabled, loadFailure == nil else { return .noData }
        guard run != nil || !requiresExplicitRetry && now() >= nextAttempt else { return .noData }
        let token = generation
        let records = replica.records
        remoteChangesPending = true
        await synchronize()
        guard enabled, generation == token else { return .noData }
        switch status {
        case .failed, .waitingForAccount, .unconfigured: return .failed
        default: break
        }
        return replica.records != records ? .newData : .noData
    }

    public func synchronize(force: Bool = false) async {
        guard enabled, loadFailure == nil else {
            if let loadFailure { status = .failed(loadFailure.localizedDescription) }
            else { status = .disabled }
            onChange?(); return
        }
        if let run { await run.value; return }
        guard force || !requiresExplicitRetry && now() >= nextAttempt else { return }
        scheduled?.cancel(); scheduled = nil
        let token = generation
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            // A push arriving after fetch has started may describe a change that this
            // pass cannot see. Coalesce those hints into one immediate follow-up.
            for _ in 0..<2 {
                self.remoteChangesPending = false
                await self.performSync(token: token)
                guard self.enabled, self.generation == token, self.remoteChangesPending,
                      !self.requiresExplicitRetry, self.now() >= self.nextAttempt else { break }
            }
        }
        run = task
        await task.value
        if generation == token {
            run = nil
            if needsAnotherPass || remoteChangesPending {
                needsAnotherPass = false
                schedule(after: max(2, nextAttempt.timeIntervalSince(now())))
            }
        }
    }

    private func schedule(after seconds: TimeInterval) {
        guard enabled, loadFailure == nil, !requiresExplicitRetry else { return }
        scheduled?.cancel()
        // A new local edit must not replace a server-requested delay with an early wakeup.
        let delay = max(0, seconds, nextAttempt.timeIntervalSince(now()))
        let nanoseconds = UInt64(min(delay, Double(UInt64.max / 1_000_000_000)) * 1_000_000_000)
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.synchronize()
        }
    }

    private func check(_ token: UUID) throws {
        guard enabled, generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func performSync(token: UUID) async {
        lastAttempt = now(); status = .syncing; onChange?()
        needsAnotherPass = false
        do {
            let identity = try await client.accountIdentifier()
            try check(token)
            let initialLocal = try snapshot?() ?? CloudSyncLocalSnapshot()
            try selectIdentity(identity, local: initialLocal)
            try await recoverZoneIfRequested(token: token)
            let local = try snapshot?() ?? initialLocal
            try capture(local, explicitLogin: nil, acknowledgeOnly: false)
            try persist()
            let changes: CloudSyncChanges
            do { changes = try await client.fetchChanges(cursor: replica.cursor) }
            catch CloudSyncError.tokenExpired {
                var value = replica; value.cursor = nil; replica = value
                changes = try await client.fetchChanges(cursor: nil)
            }
            try check(token)
            try ingest(changes.records)
            var value = replica
            value.cursor = changes.cursor
            // Explicit application deletes always use tombstones. A physically removed record is
            // forgotten locally without inventing an empty account deletion or credential revocation.
            for id in changes.deletedRecordIDs {
                value.systemFields.removeValue(forKey: id)
                if !value.pending.contains(id) { value.records.removeValue(forKey: id) }
            }
            replica = value
            try await settleRetentionPreferences(token: token)
            try stripDeletedAccountData()
            try pruneHistory()
            try persist()
            var waiting = try publishCredentials(from: try snapshot?() ?? local)
            var incoming = try incomingChanges()
            waiting = waiting || incoming.waitingForCredentials
            incoming.waitingForCredentials = waiting
            try check(token)
            try await apply?(incoming)
            try check(token)
            // Refresh baselines from the values actually applied, not from an old pre-await snapshot.
            if let current = try snapshot?() { try capture(current, explicitLogin: nil, acknowledgeOnly: true) }
            try persist()
            // CAS conflicts are rebased through the same deterministic join. Never force overwrite.
            for _ in 0..<4 {
                try check(token)
                let ids = replica.pending.sorted()
                guard !ids.isEmpty else { break }
                let batch = try ids.prefix(150).compactMap { id -> CloudSyncRecord? in
                    guard let record = replica.records[id] else { return nil }
                    return CloudSyncRecord(id: id, data: try SyncCodec.encode(record), systemFields: replica.systemFields[id])
                }
                let result = try await client.save(batch)
                try check(token)
                for saved in result.saved {
                    var current = replica
                    current.systemFields[saved.id] = saved.systemFields
                    if let record = current.records[saved.id], try SyncCodec.encode(record) == saved.data {
                        current.pending.remove(saved.id)
                    }
                    replica = current
                }
                try ingest(result.conflicts)
                try persist()
                if let failure = CloudSyncError.preferredFailure(in: result.failures.map(\.error)) { throw failure }
                if !result.conflicts.isEmpty {
                    try stripDeletedAccountData()
                    try pruneHistory()
                    try persist()
                    waiting = try publishCredentials(from: try snapshot?() ?? local) || waiting
                    let merged = try incomingChanges()
                    try await apply?(merged)
                    try check(token)
                    if let current = try snapshot?() { try capture(current, explicitLogin: nil, acknowledgeOnly: true) }
                    try persist()
                }
            }
            try check(token)
            waiting = try cleanCredentials() || waiting
            var complete = replica
            if complete.pending.isEmpty { complete.lastSuccessfulSync = now() }
            else { needsAnotherPass = true }
            replica = complete
            try persist()
            retryCount = 0; nextAttempt = .distantPast; requiresExplicitRetry = false
            status = waiting ? .waitingForCredentials : complete.pending.isEmpty ? .ready : .syncing
        } catch is CancellationError {
            return
        } catch {
            guard generation == token else { return }
            retryCount = min(retryCount + 1, 8)
            if let cloudError = error as? CloudSyncError {
                if state.identity != nil, cloudError == .zoneMissing || cloudError == .zoneDeletedByUser {
                    failedZone = (namespace, cloudError)
                }
                requiresExplicitRetry = !cloudError.shouldRetryAutomatically || failedZone?.namespace == namespace
            } else {
                // Preserve recovery for transient local storage/apply failures.
                switch error {
                case CloudSyncStateError.invalidData, CloudSyncStateError.unsupportedVersion:
                    requiresExplicitRetry = true
                default: requiresExplicitRetry = false
                }
                requiresExplicitRetry = requiresExplicitRetry || failedZone?.namespace == namespace
            }
            let delay: TimeInterval
            if case CloudSyncError.service(let retryAfter) = error,
               let retryAfter, retryAfter.isFinite, retryAfter >= 0 { delay = retryAfter }
            else { delay = min(300, pow(2, Double(retryCount)) * 5) }
            nextAttempt = now().addingTimeInterval(max(2, delay))
            switch error {
            case CloudSyncError.noAccount: status = .waitingForAccount
            case CloudSyncError.unconfigured, CloudSyncError.unavailable: status = .unconfigured
            case CloudSyncError.keychainLocked: status = .waitingForCredentials
            default: status = .failed(error.localizedDescription)
            }
            // Permanent requests stay pending locally until an explicit retry, account change,
            // or re-enabling sync. Foreground ticks must not turn them into an endless loop.
            needsAnotherPass = !requiresExplicitRetry
        }
        onChange?()
    }

    private func persist() throws { try store.save(state) }

    private func recoverZoneIfRequested(token: UUID) async throws {
        guard let failure = failedZone else { return }
        guard failure.namespace == namespace else {
            failedZone = nil
            requestedZoneRecovery = nil
            return
        }
        guard requestedZoneRecovery?.namespace == namespace,
              requestedZoneRecovery?.generation == token,
              let recovery = client as? any CloudSyncZoneRecoveryClient else { throw failure.error }
        // Consume the authorization before awaiting. A cancellation or failed attempt
        // cannot let an ordinary background fetch recreate a user-deleted zone.
        requestedZoneRecovery = nil
        try await recovery.recoverDeletedZone()
        try check(token)
        let before = state
        do {
            try stripDeletedAccountData()
            var restored = replica
            restored.cursor = nil
            restored.systemFields.removeAll()
            restored.lastSuccessfulSync = nil
            restored.pending = Set(restored.records.values.filter { record in
                guard let account = record.accountID else { return true }
                return !restored.quarantinedAccounts.contains(account)
                    && restored.suppressedAccounts[account] == nil
            }.map(\.id))
            replica = restored
            try persist()
        } catch { state = before; throw error }
        failedZone = nil
    }

    /// Settle policy conflicts before issuing irreversible retention tombstones. Saving
    /// history together with a stale policy could delete rows before a relaxation wins CAS.
    private func settleRetentionPreferences(token: UUID) async throws {
        for _ in 0..<4 {
            try check(token)
            let ids = replica.pending.filter { id in
                guard let record = replica.records[id] else { return false }
                return record.kind == .appPreference && HistoryRetentionSettings.applicationKeys.contains(record.key)
            }.sorted()
            guard !ids.isEmpty else { return }
            let records = try ids.map { id in
                CloudSyncRecord(id: id, data: try SyncCodec.encode(replica.records[id]!), systemFields: replica.systemFields[id])
            }
            let result = try await client.save(records)
            try check(token)
            var updated = replica
            for saved in result.saved {
                updated.systemFields[saved.id] = saved.systemFields
                if let record = updated.records[saved.id], try SyncCodec.encode(record) == saved.data {
                    updated.pending.remove(saved.id)
                }
            }
            replica = updated
            try ingest(result.conflicts)
            try persist()
            if let failure = CloudSyncError.preferredFailure(in: result.failures.map(\.error)) { throw failure }
        }
        let unresolved = replica.pending.contains { id in
            guard let record = replica.records[id] else { return false }
            return record.kind == .appPreference && HistoryRetentionSettings.applicationKeys.contains(record.key)
        }
        if unresolved { throw CloudSyncStateError.deferred }
    }

    private func selectIdentity(_ identity: String, local: CloudSyncLocalSnapshot) throws {
        let key = SyncIdentity.hash(identity)
        guard state.identity != key else { return }
        if state.identity == nil {
            state.replicas[key] = state.replicas.removeValue(forKey: "unbound") ?? CloudSyncReplica()
        } else {
            var next = state.replicas[key] ?? CloudSyncReplica()
            next.initialized = true
            next.quarantinedAccounts.formUnion(local.accounts.map(\.id))
            for (name, data) in local.applicationPreferences {
                next.observations[SyncIdentity.record(.appPreference, key: name)] = SyncIdentity.hash(data)
            }
            state.replicas[key] = next
        }
        state.identity = key
        // Keep the writer counter monotonic, but do not carry another Apple account's
        // device identifiers or causal history into this private database.
        state.context = [state.deviceID: state.counter]
        for record in replica.records.values { observe(record.register) }
        try persist()
    }

    private func initialIncarnation(_ account: String) -> String { "initial-" + SyncIdentity.hash(account) }

    private func profile(_ account: String) -> SyncAccountProfile? {
        let id = SyncIdentity.record(.account, account: account)
        guard let data = replica.records[id]?.resolvedCandidate?.value else { return nil }
        return try? SyncCodec.decode(SyncAccountProfile.self, from: data)
    }

    private func nextVersion(baseline: Bool = false) throws -> SyncVersion {
        let highest = max(state.counter, state.context.values.max() ?? 0)
        guard highest < UInt64.max - 1 else { throw CloudSyncStateError.invalidData }
        state.counter = highest + 1
        let value = SyncVersion(deviceID: state.deviceID, counter: state.counter, mutationID: UUID().uuidString,
                                context: state.context, isBaseline: baseline)
        state.context[state.deviceID] = state.counter
        return value
    }

    private func observe(_ register: SyncRegister) {
        for (device, counter) in register.context { state.context[device] = max(state.context[device] ?? 0, counter) }
        for candidate in register.candidates {
            state.context[candidate.version.deviceID] = max(state.context[candidate.version.deviceID] ?? 0, candidate.version.counter)
            for (device, counter) in candidate.version.context { state.context[device] = max(state.context[device] ?? 0, counter) }
        }
        state.counter = max(state.counter, state.context.values.max() ?? 0)
    }

    private func write(kind: SyncRecordKind, account: String? = nil, incarnation: String? = nil,
                       key: String = "", value: Data?, baseline: Bool = false, force: Bool = false,
                       acknowledgeOnly: Bool = false, version suppliedVersion: SyncVersion? = nil) throws {
        let id = SyncIdentity.record(kind, account: account, incarnation: incarnation, key: key)
        let fingerprint = value.map(SyncIdentity.hash) ?? "deleted"
        var current = replica
        if acknowledgeOnly { current.observations[id] = fingerprint; replica = current; return }
        guard force || current.observations[id] != fingerprint else { return }
        current.observations[id] = fingerprint
        replica = current
        let version = try suppliedVersion ?? nextVersion(baseline: baseline)
        let candidate = SyncCandidate(version: version, value: value)
        let update = SyncRecord(id: id, kind: kind, accountID: account, incarnation: incarnation, key: key,
                                register: SyncRegister(candidates: [candidate]))
        var saved = replica
        saved.records[id] = try saved.records[id].map { try $0.merged(with: update) } ?? update
        saved.pending.insert(id)
        replica = saved
    }

    private func ingest(_ values: [CloudSyncRecord]) throws {
        // Validate the whole batch before advancing its cursor or applying any data.
        let decoded = try values.map { value -> (CloudSyncRecord, SyncRecord) in
            let record = try SyncCodec.decode(SyncRecord.self, from: value.data)
            guard record.id == value.id,
                  !record.register.candidates.isEmpty,
                  record.id == SyncIdentity.record(record.kind, account: record.accountID,
                    incarnation: record.incarnation, key: record.key) else { throw CloudSyncStateError.invalidData }
            switch record.kind {
            case .appPreference:
                guard record.accountID == nil, record.incarnation == nil,
                      SyncPreferenceProjection.applicationKeys.contains(record.key) else { throw CloudSyncStateError.invalidData }
                if HistoryRetentionSettings.applicationKeys.contains(record.key) {
                    for candidate in record.register.candidates {
                        guard let value = candidate.value else { continue }
                        do { _ = try HistoryRetentionSettings.from(applicationPreferences: [record.key: value]) }
                        catch { throw CloudSyncStateError.invalidData }
                    }
                }
            case .account:
                guard let account = record.accountID, record.incarnation == nil, record.key.isEmpty else { throw CloudSyncStateError.invalidData }
                for candidate in record.register.candidates {
                    guard let data = candidate.value else { continue }
                    let profile = try SyncCodec.decode(SyncAccountProfile.self, from: data)
                    guard profile.studentNo == account, !profile.userID.isEmpty, !profile.incarnation.isEmpty else { throw CloudSyncStateError.invalidData }
                }
            default:
                guard let account = record.accountID, let incarnation = record.incarnation else { throw CloudSyncStateError.invalidData }
                switch record.kind {
                case .accountPreference:
                    guard SyncPreferenceProjection.accountKeys.contains(record.key) else { throw CloudSyncStateError.invalidData }
                case .coursePreference:
                    let pair = try SyncCodec.decode([String].self, from: Data(record.key.utf8))
                    guard pair.count == 2, !pair[0].isEmpty, SyncPreferenceProjection.courseKeys.contains(pair[1]) else { throw CloudSyncStateError.invalidData }
                case .password:
                    guard record.key.isEmpty else { throw CloudSyncStateError.invalidData }
                default:
                    guard !record.key.isEmpty else { throw CloudSyncStateError.invalidData }
                }
                if record.kind == .session || record.kind == .password || record.kind == .invalidSession {
                    for candidate in record.register.candidates {
                        guard let data = candidate.value else { continue }
                        let ref = try SyncCodec.decode(SyncCredentialReference.self, from: data)
                        try ref.version.validate()
                        let kind = record.kind == .password ? "password" : "session"
                        guard ref.id == secretPrefix(account: account, incarnation: incarnation, kind: kind) + ref.version.mutationID,
                              !ref.fingerprint.isEmpty else { throw CloudSyncStateError.invalidData }
                        if record.kind == .invalidSession {
                            guard record.key == ref.id else { throw CloudSyncStateError.invalidData }
                        } else {
                            guard ref.version == candidate.version,
                                  record.key == (record.kind == .password ? "" : ref.version.mutationID) else { throw CloudSyncStateError.invalidData }
                        }
                    }
                }
            }
            return (value, record)
        }
        var current = replica
        for (wire, record) in decoded {
            let merged = try current.records[record.id].map { try $0.merged(with: record) } ?? record
            current.records[record.id] = merged
            current.systemFields[record.id] = wire.systemFields
            if merged == record { current.pending.remove(record.id) }
            else { current.pending.insert(record.id) }
        }
        replica = current
        for (_, record) in decoded { observe(current.records[record.id]!.register) }
    }
}

private extension CloudSyncCoordinator {
    func capture(_ snapshot: CloudSyncLocalSnapshot, explicitLogin: String?, acknowledgeOnly: Bool) throws {
        do { _ = try HistoryRetentionSettings.from(applicationPreferences: snapshot.applicationPreferences) }
        catch { throw CloudSyncStateError.invalidData }
        let baseline = !replica.initialized
        for (key, data) in snapshot.applicationPreferences where SyncPreferenceProjection.applicationKeys.contains(key) {
            try write(kind: .appPreference, key: key, value: data, baseline: baseline, acknowledgeOnly: acknowledgeOnly)
        }
        for account in snapshot.accounts {
            let explicit = explicitLogin == account.id
            var current = replica
            if explicit {
                current.suppressedAccounts.removeValue(forKey: account.id)
                current.quarantinedAccounts.remove(account.id)
                current.observations["credential-baseline:" + account.id] = nil
                current.observations["credential-explicit:" + account.id] = "true"
                replica = current
            }
            if current.quarantinedAccounts.contains(account.id) && !explicit { continue }
            let accountRecord = current.records[SyncIdentity.record(.account, account: account.id)]
            let previousProfile = profile(account.id)
            let deleted = accountRecord?.resolvedCandidate?.value == nil && accountRecord != nil
            if deleted && !explicit { continue }
            let incarnation = previousProfile?.incarnation
                ?? (deleted ? UUID().uuidString : current.localIncarnations[account.id] ?? initialIncarnation(account.id))
            if current.suppressedAccounts[account.id] == incarnation && !explicit { continue }
            if let previous = current.localIncarnations[account.id], previous != incarnation, !explicit, !acknowledgeOnly {
                // Data left over from a deleted generation cannot enter a newly added account.
                continue
            }
            if baseline { current.observations["credential-baseline:" + account.id] = "true" }
            current.localIncarnations[account.id] = incarnation
            replica = current
            let profile = SyncAccountProfile(studentNo: account.id, userID: account.session.userId,
                                             name: account.session.name, loginUsername: account.loginUsername,
                                             incarnation: incarnation)
            try write(kind: .account, account: account.id, value: try SyncCodec.encode(profile),
                      baseline: baseline, force: explicit && deleted, acknowledgeOnly: acknowledgeOnly)
            for (key, data) in try SyncPreferenceProjection.account(account.preferences) {
                try write(kind: .accountPreference, account: account.id, incarnation: incarnation, key: key,
                          value: data, baseline: baseline, acknowledgeOnly: acknowledgeOnly)
            }
            let knownCourseIDs = try replica.records.values.filter {
                $0.kind == .coursePreference && $0.accountID == account.id && $0.incarnation == incarnation
            }.map { record -> String in
                let pair = try SyncCodec.decode([String].self, from: Data(record.key.utf8))
                guard pair.count == 2 else { throw CloudSyncStateError.invalidData }
                return pair[0]
            }
            for courseID in Set(knownCourseIDs).union(account.preferences.courses.keys) {
                let preferences = account.preferences.courses[courseID] ?? CoursePreferences()
                for (field, data) in try SyncPreferenceProjection.course(preferences) {
                    let key = String(decoding: try SyncCodec.encode([courseID, field]), as: UTF8.self)
                    try write(kind: .coursePreference, account: account.id, incarnation: incarnation, key: key,
                              value: data, baseline: baseline, acknowledgeOnly: acknowledgeOnly)
                }
            }
            let records = (snapshot.attendance[account.id] ?? []).sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
            }
            for record in records {
                try write(kind: .attendance, account: account.id, incarnation: incarnation, key: record.id.uuidString,
                          value: try SyncCodec.encode(record), baseline: baseline, acknowledgeOnly: acknowledgeOnly)
            }
            for execution in snapshot.executions[account.id] ?? [] {
                guard let projection = SyncAutoSignHistory(execution: execution, accountID: account.id, incarnation: incarnation,
                    sourceDeviceID: deviceID, sourceDeviceName: deviceName, revision: 0) else { continue }
                let fingerprint = SyncIdentity.hash(try SyncCodec.encode(projection))
                let observation = "history:" + projection.id
                var local = replica
                if acknowledgeOnly { local.observations[observation] = fingerprint; replica = local; continue }
                guard local.observations[observation] != fingerprint else { continue }
                local.observations[observation] = fingerprint; replica = local
                let version = try nextVersion(baseline: baseline)
                let history = SyncAutoSignHistory(execution: execution, accountID: account.id, incarnation: incarnation,
                    sourceDeviceID: deviceID, sourceDeviceName: deviceName, revision: version.counter)!
                try write(kind: .autoHistory, account: account.id, incarnation: incarnation, key: history.id,
                          value: try SyncCodec.encode(history), baseline: baseline, force: true, version: version)
            }
            // An unbound journal cannot create secrets with the wrong Apple-account namespace.
            if state.identity != nil {
                try captureCredentials(account, incarnation: incarnation, explicit: explicit,
                                       baseline: replica.observations["credential-baseline:" + account.id] == "true",
                                       acknowledgeOnly: acknowledgeOnly)
            }
        }
        var complete = replica; complete.initialized = true; replica = complete
    }

    func secretPrefix(account: String, incarnation: String? = nil, kind: String? = nil) -> String {
        var value = "v1/\(namespace)/\(SyncIdentity.hash(account))/"
        if let incarnation { value += SyncIdentity.hash(incarnation) + "/" }
        if let kind { value += kind + "/" }
        return value
    }

    func captureCredentials(_ account: StoredAccount, incarnation: String, explicit: Bool,
                            baseline: Bool, acknowledgeOnly: Bool) throws {
        let sessionData = try SyncCodec.encode(SyncedSessionSecret(accountID: account.id, incarnation: incarnation, session: account.session))
        let sessionFingerprint = SyncIdentity.hash(sessionData)
        let sessionKey = "session:\(account.id):\(incarnation)"
        var local = replica
        if !acknowledgeOnly, local.observations[sessionKey] != sessionFingerprint || explicit {
            let version = try nextVersion(baseline: baseline)
            let ref = SyncCredentialReference(id: secretPrefix(account: account.id, incarnation: incarnation, kind: "session") + version.mutationID,
                                              version: version, fingerprint: sessionFingerprint)
            try write(kind: .session, account: account.id, incarnation: incarnation, key: version.mutationID,
                      value: try SyncCodec.encode(ref), baseline: baseline, version: version)
        }
        local = replica; local.observations[sessionKey] = sessionFingerprint; replica = local
        let passwordData = try account.credentials.map {
            try SyncCodec.encode(SyncedPasswordSecret(accountID: account.id, incarnation: incarnation, credentials: $0))
        }
        let passwordFingerprint = passwordData.map(SyncIdentity.hash) ?? "forgotten"
        let passwordKey = "password:\(account.id):\(incarnation)"
        let wasExplicit = explicit || replica.observations["credential-explicit:" + account.id] == "true"
        if !acknowledgeOnly,
           replica.observations[passwordKey] != passwordFingerprint || explicit || wasExplicit {
            // Missing legacy passwords are not a user's instruction to erase a cloud password.
            if passwordData != nil || wasExplicit || replica.observations[passwordKey] != nil {
                let version = try nextVersion(baseline: baseline && !wasExplicit)
                let ref = passwordData.map { _ in
                    SyncCredentialReference(id: secretPrefix(account: account.id, incarnation: incarnation, kind: "password") + version.mutationID,
                                            version: version, fingerprint: passwordFingerprint)
                }
                try write(kind: .password, account: account.id, incarnation: incarnation,
                          value: try ref.map(SyncCodec.encode), baseline: baseline && !wasExplicit,
                          force: true, version: version)
            }
        }
        local = replica
        local.observations[passwordKey] = passwordFingerprint
        local.observations["credential-baseline:" + account.id] = nil
        local.observations["credential-explicit:" + account.id] = nil
        replica = local
    }

    func publishCredentials(from snapshot: CloudSyncLocalSnapshot) throws -> Bool {
        var waiting = false
        for account in snapshot.accounts {
            guard let owner = profile(account.id), replica.suppressedAccounts[account.id] != owner.incarnation,
                  !replica.quarantinedAccounts.contains(account.id) else { continue }
            let sessionData = try SyncCodec.encode(SyncedSessionSecret(accountID: account.id, incarnation: owner.incarnation, session: account.session))
            let sessionFingerprint = SyncIdentity.hash(sessionData)
            let passwordData = try account.credentials.map {
                try SyncCodec.encode(SyncedPasswordSecret(accountID: account.id, incarnation: owner.incarnation, credentials: $0))
            }
            for record in replica.records.values where record.accountID == account.id && record.incarnation == owner.incarnation
                && (record.kind == .session || record.kind == .password) {
                guard let value = record.resolvedCandidate?.value else { continue }
                let reference = try SyncCodec.decode(SyncCredentialReference.self, from: value)
                guard reference.id == secretPrefix(account: account.id, incarnation: owner.incarnation,
                    kind: record.kind.rawValue) + reference.version.mutationID,
                    reference.version == record.resolvedCandidate?.version else { throw CloudSyncStateError.invalidData }
                if record.kind == .session {
                    let invalidID = SyncIdentity.record(.invalidSession, account: account.id,
                        incarnation: owner.incarnation, key: reference.id)
                    if let invalid = replica.records[invalidID]?.resolvedCandidate?.value,
                       try SyncCodec.decode(SyncCredentialReference.self, from: invalid) == reference { continue }
                }
                let data: Data?
                if record.kind == .session { data = reference.fingerprint == sessionFingerprint ? sessionData : nil }
                else { data = passwordData.flatMap { SyncIdentity.hash($0) == reference.fingerprint ? $0 : nil } }
                guard let data else { continue }
                var indexed = replica
                indexed.knownCredentials[reference.id] = CloudSyncKnownCredential(recordID: record.id,
                    accountID: account.id, incarnation: owner.incarnation, kind: record.kind, reference: reference)
                if indexed != replica { replica = indexed; try persist() }
                do { try credentials.setData(data, for: reference.id) }
                catch CloudSyncError.keychainLocked { waiting = true }
                catch CloudSyncError.unconfigured { waiting = true }
            }
        }
        return waiting
    }

    func incomingChanges() throws -> CloudSyncIncoming {
        var incoming = CloudSyncIncoming()
        for record in replica.records.values where record.kind == .appPreference {
            guard SyncPreferenceProjection.applicationKeys.contains(record.key), let data = record.resolvedCandidate?.value else { continue }
            incoming.applicationPreferences[record.key] = data
        }
        let retention = try mergedRetentionSettings()
        for record in replica.records.values.filter({ $0.kind == .account }).sorted(by: { $0.id < $1.id }) {
            guard let accountID = record.accountID else { throw CloudSyncStateError.invalidData }
            // A tombstone from another Apple account must not remove a quarantined local login.
            if replica.quarantinedAccounts.contains(accountID) { continue }
            guard let data = record.resolvedCandidate?.value else {
                incoming.deletedAccountIDs.insert(accountID); continue
            }
            let owner = try SyncCodec.decode(SyncAccountProfile.self, from: data)
            guard owner.studentNo == accountID, !owner.userID.isEmpty, !owner.incarnation.isEmpty else { throw CloudSyncStateError.invalidData }
            if replica.suppressedAccounts[accountID] == owner.incarnation || replica.quarantinedAccounts.contains(accountID) { continue }
            if let localGeneration = replica.localIncarnations[accountID], localGeneration != owner.incarnation {
                incoming.deletedAccountIDs.insert(accountID)
            }
            let records = replica.records.values.filter { $0.accountID == accountID && $0.incarnation == owner.incarnation }
            var preferences: [String: Data] = [:]
            var courses: [String: [String: Data]] = [:]
            var attendance: [SyncAttendanceRecord] = []
            var history: [SyncAutoSignHistory] = []
            var deletedAttendanceIDs: Set<UUID> = []
            var deletedHistoryIDs: Set<String> = []
            var sessions: [SyncedSessionCandidate] = []
            var password = SyncedPassword.unchanged
            let invalid = Set(records.filter { $0.kind == .invalidSession && $0.resolvedCandidate?.value != nil }.map(\.key))
            for entry in records {
                if let candidate = entry.resolvedCandidate, candidate.value == nil {
                    if entry.kind == .attendance {
                        guard let id = UUID(uuidString: entry.key) else { throw CloudSyncStateError.invalidData }
                        deletedAttendanceIDs.insert(id)
                    } else if entry.kind == .autoHistory { deletedHistoryIDs.insert(entry.key) }
                }
                if entry.kind == .password, entry.resolvedCandidate?.value == nil {
                    password = .clear; continue
                }
                guard let data = entry.resolvedCandidate?.value else { continue }
                switch entry.kind {
                case .accountPreference: preferences[entry.key] = data
                case .coursePreference:
                    let pair = try SyncCodec.decode([String].self, from: Data(entry.key.utf8))
                    guard pair.count == 2, !pair[0].isEmpty else { throw CloudSyncStateError.invalidData }
                    courses[pair[0], default: [:]][pair[1]] = data
                case .attendance:
                    let row = try SyncCodec.decode(SyncAttendanceRecord.self, from: data)
                    guard entry.key == row.id.uuidString else { throw CloudSyncStateError.invalidData }
                    attendance.append(row)
                case .autoHistory:
                    let row = try SyncCodec.decode(SyncAutoSignHistory.self, from: data)
                    guard row.id == entry.key, row.accountID == accountID, row.incarnation == owner.incarnation else { throw CloudSyncStateError.invalidData }
                    history.append(row)
                case .session, .password:
                    let reference = try SyncCodec.decode(SyncCredentialReference.self, from: data)
                    let kind = entry.kind == .session ? "session" : "password"
                    guard reference.id.hasPrefix(secretPrefix(account: accountID, incarnation: owner.incarnation, kind: kind)) else {
                        throw CloudSyncStateError.invalidData
                    }
                    if invalid.contains(reference.id) { continue }
                    do {
                        guard let secret = try credentials.data(for: reference.id) else {
                            incoming.waitingForCredentials = true; continue
                        }
                        guard SyncIdentity.hash(secret) == reference.fingerprint else { throw CloudSyncStateError.invalidData }
                        if entry.kind == .session {
                            let value = try SyncCodec.decode(SyncedSessionSecret.self, from: secret)
                            guard value.accountID == accountID, value.incarnation == owner.incarnation,
                                  value.session.studentNo == accountID, value.session.userId == owner.userID,
                                  !value.session.sessionId.isEmpty else { throw CloudSyncStateError.invalidData }
                            sessions.append(SyncedSessionCandidate(reference: reference, session: value.session))
                        } else {
                            let value = try SyncCodec.decode(SyncedPasswordSecret.self, from: secret)
                            guard value.accountID == accountID, value.incarnation == owner.incarnation else { throw CloudSyncStateError.invalidData }
                            password = .value(value.credentials)
                        }
                    } catch CloudSyncError.keychainLocked { incoming.waitingForCredentials = true }
                    catch CloudSyncError.unconfigured { incoming.waitingForCredentials = true }
                default: break
                }
            }
            sessions.sort { $0.reference.version > $1.reference.version }
            attendance = try retention.operations.retained(attendance, now: now(), date: { $0.date }, id: { $0.id.uuidString })
            history = try retention.automatic.retained(history, now: now(), date: { $0.updatedAt }, id: { $0.id },
                protected: { ![.signed, .missed, .skipped].contains($0.stage) })
            let invalidFingerprints = try Set(records.filter { $0.kind == .invalidSession }
                .compactMap { $0.resolvedCandidate?.value }
                .map { try SyncCodec.decode(SyncCredentialReference.self, from: $0).fingerprint })
            incoming.accounts.append(SyncedAccountChanges(profile: owner, preferences: preferences, courses: courses,
                attendance: attendance, history: history, deletedAttendanceIDs: deletedAttendanceIDs,
                deletedHistoryIDs: deletedHistoryIDs, sessions: sessions,
                invalidSessionFingerprints: invalidFingerprints, password: password))
        }
        incoming.accounts.sort {
            guard let left = $0.sessions.first?.reference.version else { return false }
            guard let right = $1.sessions.first?.reference.version else { return true }
            return left > right
        }
        return incoming
    }

    func stripDeletedAccountData() throws {
        let deleted = Set(replica.records.values.filter { $0.kind == .account && $0.resolvedCandidate?.value == nil }.compactMap(\.accountID))
        for record in Array(replica.records.values) where record.kind != .account && record.accountID.map(deleted.contains) == true {
            if record.register.candidates.contains(where: { $0.value != nil }) {
                try write(kind: record.kind, account: record.accountID, incarnation: record.incarnation, key: record.key, value: nil, force: true)
            }
        }
    }

    func mergedRetentionSettings() throws -> HistoryRetentionSettings {
        let fields = Dictionary(replica.records.values.compactMap { record -> (String, Data)? in
            guard record.kind == .appPreference, HistoryRetentionSettings.applicationKeys.contains(record.key),
                  let data = record.resolvedCandidate?.value else { return nil }
            return (record.key, data)
        }, uniquingKeysWith: { _, value in value })
        do { return try HistoryRetentionSettings.from(applicationPreferences: fields) }
        catch { throw CloudSyncStateError.invalidData }
    }

    func pruneHistory() throws {
        // Capture never applies a local policy: a remote relaxation must be merged first.
        let retention = try mergedRetentionSettings()
        if retention == HistoryRetentionSettings() { return }
        var discarded: [SyncRecord] = []
        let accounts = Set(replica.records.values.compactMap(\.accountID))
        for account in accounts {
            guard let owner = profile(account) else { continue }
            let operations = try replica.records.values.filter {
                $0.kind == .attendance && $0.accountID == account && $0.incarnation == owner.incarnation && $0.resolvedCandidate?.value != nil
            }.map { record -> (SyncRecord, SyncAttendanceRecord) in
                let row = try SyncCodec.decode(SyncAttendanceRecord.self, from: record.resolvedCandidate!.value!)
                guard record.key == row.id.uuidString else { throw CloudSyncStateError.invalidData }
                return (record, row)
            }
            let keptOperations = Set(try retention.operations.retained(operations, now: now(), date: { $0.1.date }, id: { $0.1.id.uuidString }).map { $0.0.id })
            discarded += operations.filter { !keptOperations.contains($0.0.id) }.map { $0.0 }
            let automatic = try replica.records.values.filter {
                $0.kind == .autoHistory && $0.accountID == account && $0.incarnation == owner.incarnation && $0.resolvedCandidate?.value != nil
            }.map { record -> (SyncRecord, SyncAutoSignHistory) in
                let row = try SyncCodec.decode(SyncAutoSignHistory.self, from: record.resolvedCandidate!.value!)
                guard row.id == record.key, row.accountID == account, row.incarnation == owner.incarnation else {
                    throw CloudSyncStateError.invalidData
                }
                return (record, row)
            }
            let keptAutomatic = Set(try retention.automatic.retained(automatic, now: now(), date: { $0.1.updatedAt }, id: { $0.1.id },
                protected: { ![.signed, .missed, .skipped].contains($0.1.stage) }).map { $0.0.id })
            discarded += automatic.filter { !keptAutomatic.contains($0.0.id) }.map { $0.0 }
        }
        let before = state
        do {
            for record in discarded {
                try write(kind: record.kind, account: record.accountID, incarnation: record.incarnation, key: record.key, value: nil, force: true)
            }
        } catch { state = before; throw error }
    }

    func cleanCredentials() throws -> Bool {
        var current = replica
        for record in current.records.values where record.kind == .session || record.kind == .password {
            guard let account = record.accountID, let incarnation = record.incarnation else { throw CloudSyncStateError.invalidData }
            let prefix = secretPrefix(account: account, incarnation: incarnation, kind: record.kind.rawValue)
            for candidate in record.register.candidates {
                guard let data = candidate.value else { continue }
                let reference = try SyncCodec.decode(SyncCredentialReference.self, from: data)
                guard reference.id.hasPrefix(prefix), reference.version == candidate.version else {
                    throw CloudSyncStateError.invalidData
                }
                let known = CloudSyncKnownCredential(recordID: record.id, accountID: account,
                    incarnation: incarnation, kind: record.kind, reference: reference)
                if let previous = current.knownCredentials[reference.id], previous != known {
                    throw CloudSyncStateError.invalidData
                }
                current.knownCredentials[reference.id] = known
            }
        }
        if current != replica { replica = current; try persist() }

        // Keychain and CloudKit arrive independently. Never infer obsolescence by enumerating
        // a prefix: an unknown item may be a new login whose metadata has not arrived yet.
        for (id, known) in current.knownCredentials.sorted(by: { $0.key < $1.key }) {
            guard id == known.reference.id, known.kind == .session || known.kind == .password,
                  id.hasPrefix(secretPrefix(account: known.accountID, incarnation: known.incarnation,
                                             kind: known.kind.rawValue)) else { throw CloudSyncStateError.invalidData }
            var obsolete = false
            if let record = current.records[known.recordID], let selected = record.resolvedCandidate {
                let selectedID = try selected.value.map { try SyncCodec.decode(SyncCredentialReference.self, from: $0).id }
                // The joined register must include this exact writer dot before retiring its key.
                obsolete = selectedID != id &&
                    (record.register.context[known.reference.version.deviceID] ?? 0) >= known.reference.version.counter
            }
            if known.kind == .session {
                let revocationID = SyncIdentity.record(.invalidSession, account: known.accountID,
                    incarnation: known.incarnation, key: id)
                if let value = current.records[revocationID]?.resolvedCandidate?.value,
                   try SyncCodec.decode(SyncCredentialReference.self, from: value) == known.reference {
                    obsolete = true
                }
            }
            let accountID = SyncIdentity.record(.account, account: known.accountID)
            if let account = current.records[accountID]?.resolvedCandidate,
               account.version.causallyAfter(known.reference.version) {
                if let data = account.value {
                    let owner = try SyncCodec.decode(SyncAccountProfile.self, from: data)
                    obsolete = obsolete || owner.incarnation != known.incarnation
                } else { obsolete = true }
            }
            guard obsolete else { continue }
            do { try credentials.removeData(for: id) }
            catch CloudSyncError.keychainLocked { return true }
            catch CloudSyncError.unconfigured { return true }
        }
        return false
    }
}
