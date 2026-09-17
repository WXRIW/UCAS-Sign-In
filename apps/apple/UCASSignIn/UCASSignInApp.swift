import SwiftUI

@main
struct UCASSignInApp: App {
    @StateObject private var model = AppLaunchEnvironment.makeModel()
    @StateObject private var updates = UpdateCoordinator(defaults: AppLaunchEnvironment.defaults)
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
                .task { await model.restore(); await updates.checkAutomatically() }
        }
    }
}
