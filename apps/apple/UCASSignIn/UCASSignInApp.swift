import SwiftUI

@main
struct UCASSignInApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ICloudNotificationAppDelegate.self) private var notificationDelegate
    #else
    @UIApplicationDelegateAdaptor(ICloudNotificationAppDelegate.self) private var notificationDelegate
    #endif
    @StateObject private var model: AppModel
    @StateObject private var updates = UpdateCoordinator(defaults: AppLaunchEnvironment.defaults)
    #if os(macOS)
    @StateObject private var automaticAttendance = MacAutomaticAttendanceRunner()
    #endif
    @State private var selection = 0

    init() {
        let model = AppLaunchEnvironment.makeModel()
        _model = StateObject(wrappedValue: model)
        // Bind before any scene task runs, including a silent push cold launch.
        ICloudNotificationBridge.shared.configure(model: model)
    }

    var body: some Scene {
        #if os(macOS)
        Window("果壳签到", id: "main") {
            appContent
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            MacAppCommands(model: model, selection: $selection)
        }
        #else
        WindowGroup {
            appContent
        }
        #endif
    }

    @ViewBuilder private var appContent: some View {
        if AppLaunchEnvironment.isUnitTestHost {
            Color.clear
        } else {
            RootView(selection: $selection).environmentObject(model).environmentObject(updates).tint(Palette.green)
                .defaultAppStorage(AppLaunchEnvironment.defaults)
                .task {
                    await model.restore()
                    #if os(macOS)
                    automaticAttendance.start(model)
                    #endif
                    await updates.checkAutomatically()
                }
        }
    }
}
