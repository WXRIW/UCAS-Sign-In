import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app and delegates use one model, including notifications arriving before a scene exists.
@MainActor
final class ICloudNotificationBridge {
    static let shared = ICloudNotificationBridge()
    private weak var model: AppModel?
    private var pending: [(userInfo: [AnyHashable: Any], continuation: CheckedContinuation<CloudSyncRemoteRefreshResult, Never>)] = []

    private var permitsLiveNotifications: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard !AppLaunchEnvironment.isUnitTestHost, !arguments.contains("--demo"),
              !arguments.contains("--account-fixtures"), model?.isDemo != true else { return false }
        let container = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? ""
        return CloudSyncEntitlements.permitsCloudContainer(container) && CloudSyncEntitlements.permitsRemoteNotifications
    }

    var canRegister: Bool { permitsLiveNotifications }

    func configure(model: AppModel) {
        self.model = model
        let queued = pending
        pending.removeAll()
        for notification in queued {
            Task { @MainActor in
                notification.continuation.resume(returning: await receive(notification.userInfo))
            }
        }
    }

    func receive(_ userInfo: [AnyHashable: Any]) async -> CloudSyncRemoteRefreshResult {
        let container = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? ""
        guard permitsLiveNotifications,
              CloudKitSyncSubscription.matches(userInfo: userInfo, containerIdentifier: container) else { return .noData }
        guard let model else {
            return await withCheckedContinuation { continuation in
                pending.append((userInfo, continuation))
            }
        }
        guard !Task.isCancelled else { return .failed }
        return await model.handleICloudRemoteNotification(userInfo)
    }
}

#if os(macOS)
@MainActor
final class ICloudNotificationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ICloudNotificationBridge.shared.canRegister else { return }
        // CloudKit sends silent pushes; user-facing notification authorization is unnecessary.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in
            _ = await ICloudNotificationBridge.shared.receive(userInfo)
        }
    }
}
#else
@MainActor
final class ICloudNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ICloudNotificationBridge.shared.canRegister {
            // Register for silent pushes without prompting for alerts, badges, or sounds.
            application.registerForRemoteNotifications()
        }
        // UIKit delivers a silent cold-launch push through the fetch callback below.
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let completion = ICloudBackgroundFetchCompletion(completionHandler)
        let refresh = Task { @MainActor in
            let result = await ICloudNotificationBridge.shared.receive(userInfo)
            switch result {
            case .newData: completion.finish(.newData)
            case .noData: completion.finish(.noData)
            case .failed: completion.finish(.failed)
            }
        }
        completion.timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(25)) }
            catch { return }
            // UIKit grants at most 30 seconds; complete once even if a cloud request stalls.
            refresh.cancel()
            completion.finish(.failed)
        }
    }
}

@MainActor
private final class ICloudBackgroundFetchCompletion {
    private var handler: ((UIBackgroundFetchResult) -> Void)?
    var timeout: Task<Void, Never>?

    init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { self.handler = handler }

    func finish(_ result: UIBackgroundFetchResult) {
        guard let handler else { return }
        self.handler = nil
        timeout?.cancel()
        timeout = nil
        handler(result)
    }
}
#endif
