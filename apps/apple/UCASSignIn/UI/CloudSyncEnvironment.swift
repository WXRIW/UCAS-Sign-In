import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum CloudSyncEnvironment {
    static func make(defaults: UserDefaults, allowLive: Bool) -> CloudSyncCoordinator {
        let enabled = defaults.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        #if os(macOS)
        let deviceName = Host.current().localizedName ?? "Mac"
        #else
        let deviceName = UIDevice.current.name
        #endif
        guard allowLive else {
            return CloudSyncCoordinator(client: DisabledCloudSyncClient(), credentials: DisabledSyncCredentialStore(),
                store: MemoryCloudSyncStateStore(), deviceID: UUID().uuidString, deviceName: deviceName, enabled: enabled)
        }
        let container = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? ""
        let group = Bundle.main.object(forInfoDictionaryKey: "CloudKeychainAccessGroup") as? String ?? ""
        guard CloudSyncEntitlements.permitsCloudContainer(container), CloudSyncEntitlements.permitsKeychainGroup(group) else {
            return CloudSyncCoordinator(client: FailedCloudSyncClient(error: .unconfigured), credentials: DisabledSyncCredentialStore(),
                store: MemoryCloudSyncStateStore(), deviceID: UUID().uuidString, deviceName: deviceName, enabled: enabled)
        }
        let store = FileCloudSyncStateStore()
        do {
            let saved = try store.load()
            let deviceID = try SyncDeviceIdentity.loadOrCreate(renew: saved == nil)
            return CloudSyncCoordinator(client: LiveCloudSyncClient(containerIdentifier: container),
                credentials: LiveSyncCredentialStore(accessGroup: group), store: store,
                deviceID: deviceID, deviceName: deviceName, enabled: enabled)
        } catch {
            // A locked identity or unreadable journal cannot be replaced with a new writer.
            let coordinator = CloudSyncCoordinator(client: FailedCloudSyncClient(error: error as? CloudSyncError ?? .invalidData),
                credentials: DisabledSyncCredentialStore(), store: MemoryCloudSyncStateStore(),
                deviceID: UUID().uuidString, deviceName: deviceName, enabled: enabled)
            coordinator.requiresBootstrapRetry = (error as? CloudSyncError) == .keychainLocked
            return coordinator
        }
    }
}

@MainActor
private struct FailedCloudSyncClient: CloudSyncClient {
    let error: CloudSyncError
    func accountIdentifier() async throws -> String { throw error }
    func fetchChanges(cursor: Data?) async throws -> CloudSyncChanges { throw error }
    func save(_ records: [CloudSyncRecord]) async throws -> CloudSyncSaveResult { throw error }
}
