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
    @EnvironmentObject private var updates: UpdateCoordinator
    @AppStorage("appearanceMode") private var appearance = AppAppearance.system
    @AppStorage(UpdateCoordinator.automaticChecksKey) private var automaticUpdateChecks = true
    @State private var showNotificationSettingsHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("外观") {
                    HStack(spacing: PreferenceRowLayout.spacing) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 17)).foregroundStyle(Palette.green)
                            .frame(width: PreferenceRowLayout.iconWidth)
                            .accessibilityHidden(true)
                        Text("主题").font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                        Spacer(minLength: 12)
                        Picker("主题", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(PreferenceTypography.body)
                        .labelsHidden()
                        .fixedSize()
                        .tint(Palette.green)
                        .accessibilityIdentifier("settings.appearance")
                        .accessibilityValue(appearance.title)
                    }.padding(.vertical, 18)
                }
                settingsSection("课表") {
                    Toggle(isOn: $model.showOutsideWeekCourses) {
                        settingsLabel("显示非本周课程", subtitle: "在周课表中显示非本周课程。", symbol: "calendar")
                    }
                    .toggleStyle(.switch)
                    .tint(Palette.green)
                    .accessibilityIdentifier("settings.showOutsideWeekCourses")
                    .accessibilityLabel("显示非本周课程")
                    .accessibilityHint("在周课表中显示非本周课程。")
                    .padding(.vertical, 18)
                }
                settingsSection("课堂偏好", footer: model.isConnected ? autoSignExplanation : disconnectedClassroomPreferences) {
                    VStack(spacing: 0) {
                        Toggle(isOn: Binding(get: { model.remindersEnabled }, set: { enabled in Task { await model.setReminders(enabled) } })) {
                            settingsLabel("课程提醒", subtitle: "已同步课程将在设定时间提醒", symbol: "bell")
                        }.toggleStyle(.switch).accessibilityIdentifier("settings.reminders")
                            .accessibilityLabel("课程提醒")
                            .accessibilityHint("已同步课程将在设定时间提醒")
                            .padding(.vertical, 18)
                        if model.remindersEnabled {
                            PreferenceDivider()
                            HStack(spacing: PreferenceRowLayout.spacing) {
                                Image(systemName: "clock").font(.system(size: 17)).foregroundStyle(Palette.green)
                                    .frame(width: PreferenceRowLayout.iconWidth)
                                Text("默认提醒时间").font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                                Spacer(minLength: 12)
                                Picker("默认提醒时间", selection: Binding(get: { model.reminderLeadMinutes }, set: { value in
                                    Task { await model.setReminderLead(value) }
                                })) {
                                    ForEach(AccountPreferences.validLeadTimes, id: \.self) { Text("课前 \($0) 分钟").tag($0) }
                                }.labelsHidden().pickerStyle(.menu).fixedSize()
                            }.padding(.vertical, 18)
                        }
                        PreferenceDivider()
                        Toggle(isOn: Binding(get: { model.confirmationEnabled }, set: { model.setConfirmation($0) })) {
                            settingsLabel("签到前二次确认", subtitle: "提交前弹窗确认，避免误触签到", symbol: "questionmark.circle")
                        }.toggleStyle(.switch).accessibilityIdentifier("settings.confirmation")
                            .padding(.vertical, 18)
                        PreferenceDivider()
                        Toggle(isOn: Binding(get: { model.autoSignEnabled }, set: { model.setAutoSign($0) })) {
                            settingsLabel(autoSignTitle, subtitle: autoSignSubtitle, symbol: "checkmark.circle")
                        }.toggleStyle(.switch).accessibilityIdentifier("settings.autoSign")
                            .accessibilityLabel(autoSignTitle)
                            .accessibilityHint(autoSignSubtitle)
                            .padding(.vertical, 18)
                    }.tint(Palette.green)
                        .disabled(!model.isConnected || !model.canChangeAccount)
                }
                settingsSection("通知", footer: "通知权限、声音与横幅可在系统设置中调整。") {
                    notificationSettingsButton
                }
                settingsSection("更新", footer: "从 GitHub 检查最新的正式版本。") {
                    VStack(spacing: 0) {
                        Toggle(isOn: $automaticUpdateChecks) {
                            settingsLabel("自动检查更新", subtitle: "每天最多检查一次，有新版本时提醒", symbol: "arrow.triangle.2.circlepath")
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.automaticUpdateChecks")
                        .padding(.vertical, 18)
                        PreferenceDivider()
                        updateSettingsButton
                    }
                    .tint(Palette.green)
                }
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

    private func settingsSection<Content: View>(_ title: String, footer: String? = nil,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(PreferenceTypography.section).foregroundStyle(Palette.secondary)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .cardSurface()
            if let footer {
                Text(footer)
                    .font(PreferenceTypography.detail).lineSpacing(4).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
            }
        }
    }
    private var autoSignTitle: String {
        #if os(macOS)
        "自动签到"
        #else
        "前台自动签到"
        #endif
    }

    private var disconnectedClassroomPreferences: String {
        #if os(macOS)
        "连接学校账户后，可设置签到确认、课程提醒与自动签到。"
        #else
        "连接学校账户后，可设置签到确认、课程提醒与前台自动签到。"
        #endif
    }

    private var autoSignSubtitle: String {
        #if os(macOS)
        "果壳签到运行时，进入签到时段后尝试一次"
        #else
        "App 处于前台时，进入签到时段后尝试一次"
        #endif
    }

    private var autoSignExplanation: String {
        #if os(macOS)
        "窗口可关闭、最小化，也可切换到其他 App；退出果壳签到或 Mac 睡眠时会暂停。签到结果以学校返回状态为准。"
        #else
        "iOS / iPadOS 不保证后台定时运行。请保持 App 在前台，并以学校返回的签到状态为准。"
        #endif
    }

    @ViewBuilder
    private var notificationSettingsButton: some View {
        #if os(macOS)
        Button { showNotificationSettingsHelp = true } label: {
            PreferenceNavigationRow(title: "系统通知设置", symbol: "gearshape")
        }.buttonStyle(.plain)
        #else
        Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
            PreferenceNavigationRow(title: "系统通知设置", symbol: "gearshape")
        }.buttonStyle(.plain)
        #endif
    }

    private var updateSettingsButton: some View {
        Button { Task { await updates.checkManually() } } label: {
            HStack(spacing: PreferenceRowLayout.spacing) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17)).foregroundStyle(Palette.green)
                    .frame(width: PreferenceRowLayout.iconWidth)
                    .accessibilityHidden(true)
                Text("检查更新").font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("当前 \(UpdateCoordinator.currentVersion)")
                        .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                }
            }.padding(.vertical, 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updates.isChecking)
        .accessibilityIdentifier("settings.checkUpdates")
    }

    #if os(macOS)
    private func openSystemSettings() {
        if let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(notifications) {
            return
        }
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        NSWorkspace.shared.openApplication(at: settings, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
    private func settingsLabel(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: PreferenceRowLayout.spacing) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Palette.green)
                .frame(width: PreferenceRowLayout.iconWidth, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(PreferenceTypography.detail).lineSpacing(3)
                    .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
