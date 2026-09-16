import SwiftUI

@main
struct UCASSignInApp: App {
    @StateObject private var model = AppModel()
    @State private var selection = 0
    var body: some Scene {
        #if os(macOS)
        Window("果壳签到", id: "main") {
            RootView(selection: $selection).environmentObject(model).tint(Palette.green)
                .task { await model.restore() }
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            MacAppCommands(model: model, selection: $selection)
        }
        #else
        WindowGroup {
            RootView(selection: $selection).environmentObject(model).tint(Palette.green)
                .task { await model.restore() }
        }
        #endif
    }
}
