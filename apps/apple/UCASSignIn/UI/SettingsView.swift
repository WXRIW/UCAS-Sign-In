import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appearanceMode") private var appearance = AppAppearance.system
    @State private var showNotificationSettingsHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "外观")
                    Picker("主题", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                }.padding(21).cardSurface()
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "课堂偏好")
                    Toggle(isOn: Binding(get: { model.remindersEnabled }, set: { enabled in Task { await model.setReminders(enabled) } })) {
                        settingsLabel("课程提醒", subtitle: "已同步课程将在开课前 10 分钟提醒", symbol: "bell")
                    }.toggleStyle(.switch).accessibilityIdentifier("settings.reminders")
                    Divider().overlay(Palette.line)
                    Toggle(isOn: Binding(get: { model.autoSignEnabled }, set: { model.setAutoSign($0) })) {
                        settingsLabel("前台自动签到", subtitle: autoSignSubtitle, symbol: "checkmark.circle")
                    }.toggleStyle(.switch).accessibilityIdentifier("settings.autoSign")
                    Text(autoSignExplanation)
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.secondary)
                }.padding(21).cardSurface().disabled(!model.isConnected || !model.canChangeAccount)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(title: "通知")
                    notificationSettingsButton
                }.padding(21).cardSurface()
            }.appPagePadding()
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("settings.scroll")
        .background(Palette.background)
        .navigationTitle("设置")
        .appNavigationStyle(inline: true)
        #if os(macOS)
        .alert("系统通知设置", isPresented: $showNotificationSettingsHelp) {
            Button("打开系统设置") { openSystemSettings() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("在“系统设置 → 通知”中找到“果壳签到”，即可调整通知、声音与横幅。若列表中尚未出现，请先开启本页的“课程提醒”。")
        }
        #endif
    }
    private var autoSignSubtitle: String {
        #if os(macOS)
        "窗口活跃时，进入签到时段后尝试一次"
        #else
        "App 打开时，进入签到时段后尝试一次"
        #endif
    }

    private var autoSignExplanation: String {
        #if os(macOS)
        "请保持果壳签到窗口处于活跃状态。切换到其他 App、关闭窗口或 Mac 睡眠时不会定时签到，签到结果以学校返回状态为准。"
        #else
        "iOS 不保证后台定时运行。请保持 App 在前台，并以学校返回的签到状态为准。"
        #endif
    }

    @ViewBuilder
    private var notificationSettingsButton: some View {
        #if os(macOS)
        Button { showNotificationSettingsHelp = true } label: {
            menuRow("系统通知设置", symbol: "gearshape")
        }.buttonStyle(.plain)
        #else
        Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
            menuRow("系统通知设置", symbol: "gearshape")
        }
        #endif
    }

    #if os(macOS)
    private func openSystemSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
    private func settingsLabel(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.green).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Palette.green)
            Text(title).font(.system(size: 14)).foregroundStyle(Palette.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(.vertical, 20).contentShape(Rectangle())
    }
}
