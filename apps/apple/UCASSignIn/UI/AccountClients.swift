import Foundation
import UserNotifications
import WidgetKit

@MainActor
protocol NotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeAll()
    func remove(ids: [String])
}

struct LiveNotificationClient: NotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    func removeAll() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
    func remove(ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
}

@MainActor
protocol WidgetClient {
    func save(_ snapshot: WidgetSnapshot)
    func clear()
}

struct LiveWidgetClient: WidgetClient {
    func save(_ snapshot: WidgetSnapshot) {
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
    func clear() {
        WidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct LoginRequest: Identifiable, Equatable {
    let id = UUID()
    let accountID: String?
}
