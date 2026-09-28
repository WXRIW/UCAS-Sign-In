import SwiftUI

@main
struct UCASSignInApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(WatchConnectivityAppDelegate.self) private var watchDelegate
    @StateObject private var model = AppLaunchEnvironment.sharedModel
    #else
    @StateObject private var model = AppLaunchEnvironment.makeModel()
    #endif
    @StateObject private var updates = UpdateCoordinator(defaults: AppLaunchEnvironment.defaults)
    #if os(macOS)
    @StateObject private var automaticAttendance = MacAutomaticAttendanceRunner()
    #endif
    @State private var selection = 0
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
                    #if os(iOS)
                    await WatchPhoneBridge.shared.prepare(model)
                    #else
                    await model.restore()
                    #endif
                    #if os(macOS)
                    automaticAttendance.start(model)
                    #endif
                    await updates.checkAutomatically()
                }
        }
    }
}
