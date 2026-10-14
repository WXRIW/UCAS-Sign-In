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
    @State private var requestingCloudSync = false

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
                iCloudSettings
                settingsSection("课堂偏好", footer: model.isConnected ? nil : disconnectedClassroomPreferences) {
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
                        NavigationLink {
                            AutoSignView()
                        } label: {
                            PreferenceNavigationRow(title: "自动签到", symbol: "clock.arrow.circlepath", value: model.autoSignSettingsStatus)
                        }.buttonStyle(.plain).accessibilityIdentifier("settings.autoSign")
                    }.tint(Palette.green)
                        .disabled(!model.isConnected || !model.canChangeAccount)
                }
                settingsSection("记录", footer: "默认不限数量和时间，可分别设置操作记录与自动签到历史的保留范围。") {
                    NavigationLink {
                        HistoryRetentionSettingsView()
                    } label: {
                        PreferenceNavigationRow(title: "记录保留", symbol: "clock.arrow.circlepath", value: historyRetentionSummary)
                    }.buttonStyle(.plain).accessibilityIdentifier("settings.historyRetention")
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

    private var historyRetentionSummary: String {
        let settings = model.historyRetention
        return settings.operations.maxCount == nil && settings.operations.maxAgeDays == nil
            && settings.automatic.maxCount == nil && settings.automatic.maxAgeDays == nil ? "不限" : "自定义"
    }

    private var iCloudSettings: some View {
        settingsSection("iCloud 同步", footer: "同步学校账户、登录会话、已记住的密码、普通偏好与签到记录。自动签到设置和执行状态保留在本机；其他设备的历史仅供查看。关闭后保留本地与云端数据，已存入 iCloud 钥匙串的内容仍由系统管理。") {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { model.iCloudSyncEnabled }, set: { model.setICloudSyncEnabled($0) })) {
                    settingsLabel("iCloud 同步", subtitle: "在你的 Apple 设备之间自动同步", symbol: "icloud")
                }
                .toggleStyle(.switch).tint(Palette.green)
                .disabled(model.isDemo)
                .accessibilityIdentifier("settings.iCloudSync")
                .padding(.vertical, 18)
                PreferenceDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.isDemo ? "演示模式不连接 iCloud" : model.iCloudSyncStatus.message)
                        .font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.iCloudStatus")
                    if let date = model.iCloudLastSyncedAt {
                        Text("最近成功同步：\(SchoolDate.text(date, "M 月 d 日 HH:mm:ss"))")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                PreferenceDivider()
                Button {
                    requestingCloudSync = true
                    Task {
                        await model.synchronizeICloud()
                        requestingCloudSync = false
                    }
                } label: {
                    HStack(spacing: PreferenceRowLayout.spacing) {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .font(.system(size: 17)).foregroundStyle(Palette.green)
                            .frame(width: PreferenceRowLayout.iconWidth).accessibilityHidden(true)
                        Text("立即同步").font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                        Spacer(minLength: 12)
                        if requestingCloudSync || model.iCloudSyncStatus == .syncing {
                            ProgressView().controlSize(.small)
                        }
                    }.padding(.vertical, 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.iCloudSyncEnabled || model.isDemo || requestingCloudSync || model.iCloudSyncStatus == .syncing)
                .accessibilityIdentifier("settings.iCloudSyncNow")
            }
        }
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
    private var disconnectedClassroomPreferences: String {
        #if os(macOS)
        "连接学校账户后，可设置签到确认、课程提醒与自动签到。"
        #else
        "连接学校账户后，可设置签到确认、课程提醒与前台自动签到。"
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


private struct HistoryRetentionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseline = HistoryRetentionSettings()
    @State private var operations = HistoryRetentionDraft()
    @State private var automatic = HistoryRetentionDraft()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HistoryRetentionPolicyEditor(title: "签到操作记录", identifier: "operations", draft: $operations)
                HistoryRetentionPolicyEditor(title: "自动签到历史", identifier: "automatic", draft: $automatic)
                Text("默认不限数量和时间，保留限制按账户分别计算。保存限制后会清理超额或过期记录，已清理的记录不会恢复。正在执行的记录会保留至结束，防止重复签到的状态不受影响。开启 iCloud 后，保留设置会在 Apple 设备间同步。")
                    .font(PreferenceTypography.detail).lineSpacing(4).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
            }.appPagePadding().frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle("记录保留")
        .appNavigationStyle(inline: true)
        .accessibilityIdentifier("historyRetention.editor")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(proposedSettings == nil || !hasChanges || model.isDemo)
                    .accessibilityIdentifier("historyRetention.save")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loadCurrent()
            loaded = true
        }
        .onChange(of: model.historyRetention) { _ in
            if !hasChanges { loadCurrent() }
        }
    }

    private var proposedSettings: HistoryRetentionSettings? {
        guard let operations = operations.policy, let automatic = automatic.policy else { return nil }
        return HistoryRetentionSettings(operations: operations, automatic: automatic)
    }

    private var hasChanges: Bool {
        guard let proposedSettings else { return true }
        return proposedSettings != baseline
    }

    private func loadCurrent() {
        baseline = model.historyRetention
        operations = HistoryRetentionDraft(baseline.operations)
        automatic = HistoryRetentionDraft(baseline.automatic)
    }

    private func save() {
        guard let proposed = proposedSettings else { return }
        if model.setHistoryRetention(proposed, relativeTo: baseline) { dismiss() }
    }
}

private struct HistoryRetentionDraft {
    var limitsCount = false
    var count = ""
    var limitsAge = false
    var days = ""

    init() {}
    init(_ policy: HistoryRetentionPolicy) {
        limitsCount = policy.maxCount != nil
        count = policy.maxCount.map(String.init) ?? ""
        limitsAge = policy.maxAgeDays != nil
        days = policy.maxAgeDays.map(String.init) ?? ""
    }

    var policy: HistoryRetentionPolicy? {
        let maxCount = Self.positiveInteger(count)
        let maxAgeDays = Self.positiveInteger(days)
        guard !limitsCount || maxCount != nil, !limitsAge || maxAgeDays != nil else { return nil }
        return HistoryRetentionPolicy(maxCount: limitsCount ? maxCount : nil, maxAgeDays: limitsAge ? maxAgeDays : nil)
    }

    static func positiveInteger(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else { return nil }
        return number
    }
}

private struct HistoryRetentionPolicyEditor: View {
    let title: String
    let identifier: String
    @Binding var draft: HistoryRetentionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(PreferenceTypography.section).foregroundStyle(Palette.secondary)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Toggle(isOn: $draft.limitsCount) {
                    Label("限制数量", systemImage: "number")
                        .font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                }.toggleStyle(.switch).padding(.vertical, 18)
                    .accessibilityIdentifier("historyRetention.\(identifier).limitsCount")
                if draft.limitsCount {
                    PreferenceDivider()
                    numberInput("最多保留", text: $draft.count, unit: "条", placeholder: "例如 1000", field: "count")
                }
                PreferenceDivider()
                Toggle(isOn: $draft.limitsAge) {
                    Label("限制保留时间", systemImage: "calendar")
                        .font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                }.toggleStyle(.switch).padding(.vertical, 18)
                    .accessibilityIdentifier("historyRetention.\(identifier).limitsAge")
                if draft.limitsAge {
                    PreferenceDivider()
                    numberInput("保留最近", text: $draft.days, unit: "天", placeholder: "例如 365", field: "days")
                }
            }.tint(Palette.green)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding).cardSurface()
        }
    }

    private func numberInput(_ title: String, text: Binding<String>, unit: String, placeholder: String, field: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title).font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .frame(maxWidth: 150)
                    .accessibilityLabel("\(self.title)\(title)\(unit)")
                    .accessibilityIdentifier("historyRetention.\(identifier).\(field)")
                Text(unit).font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
            }
            if HistoryRetentionDraft.positiveInteger(text.wrappedValue) == nil {
                Text("请输入大于 0 的整数")
                    .font(PreferenceTypography.detail).foregroundStyle(.red)
                    .accessibilityIdentifier("historyRetention.\(identifier).\(field).error")
            }
        }.padding(.vertical, 18)
    }
}
