#if os(macOS)
import SwiftUI

struct MacAppCommands: Commands {
    @ObservedObject var model: AppModel
    @Binding var selection: Int
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { navigate(to: 3); model.showSettings = true }
                .keyboardShortcut(",")
                .disabled(model.showLogin)
        }
        CommandMenu("课堂") {
            Button("今日课程") { navigate(to: 0) }.keyboardShortcut("1")
            Button("课表") { navigate(to: 1) }.keyboardShortcut("2")
            Button("课程") { navigate(to: 2) }.keyboardShortcut("3")
            Button("账户") { navigate(to: 3) }.keyboardShortcut("4")
            Divider()
            Button("刷新课程") {
                Task {
                    if (selection == 1 || selection == 2), let courseId = model.visibleCatalogCourseId {
                        await model.refreshAttendance(for: courseId, force: true)
                    }
                    else if selection == 1 { await model.refreshSchedule() }
                    else if selection == 2 { await model.refreshCatalog(force: true) }
                    else { await model.refresh(on: .now) }
                }
            }
            .keyboardShortcut("r")
            .disabled(!model.isConnected || model.isCatalogRefreshing ||
                      model.visibleCatalogCourseId.map { model.attendanceRefreshing.contains($0) } == true ||
                      (selection == 1 ? model.isScheduleRefreshing : model.isRefreshing(on: .now)) || model.showLogin)
            Divider()
            Button("添加学校账户…") {
                openWindow(id: "main")
                model.presentLogin()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.showLogin || !model.canChangeAccount)
            Button("切换与管理账户…") {
                openWindow(id: "main")
                model.showAccountManagement = true
            }
            .disabled(model.showLogin || !model.canChangeAccount)
        }
    }

    private func navigate(to page: Int) {
        openWindow(id: "main")
        selection = page
    }
}
#endif
