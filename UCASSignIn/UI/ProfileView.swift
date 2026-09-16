import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("accountDetailsHidden") private var accountDetailsHidden = false
    @State private var showRecords = false
    @State private var showLogout = false
    @State private var showOpenSource = false
    @State private var showDisclaimer = false
    @State private var showNotificationSettingsHelp = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    accountCard
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeading(title: "课堂偏好")
                        Toggle(isOn: Binding(get: { model.remindersEnabled }, set: { enabled in Task { await model.setReminders(enabled) } })) {
                            settingsLabel("课程提醒", subtitle: "已同步课程将在开课前 10 分钟提醒", symbol: "bell")
                        }.toggleStyle(.switch)
                        Divider().overlay(Palette.line)
                        Toggle(isOn: Binding(get: { model.autoSignEnabled }, set: { model.setAutoSign($0) })) {
                            settingsLabel("前台自动签到", subtitle: autoSignSubtitle, symbol: "checkmark.circle")
                        }.toggleStyle(.switch)
                        Text(autoSignExplanation)
                            .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.secondary)
                    }.padding(21).cardSurface()
                    VStack(spacing: 0) {
                        Button { showRecords = true } label: { menuRow("本机签到记录", symbol: "clock.arrow.circlepath") }.buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                        Button { showOpenSource = true } label: {
                            menuRow("项目源码与致谢", symbol: "chevron.left.forwardslash.chevron.right")
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.openSource")
                        Divider().padding(.leading, 48)
                        Button { showDisclaimer = true } label: {
                            menuRow("免责声明", symbol: "doc.text")
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                        notificationSettingsButton
                    }.padding(.horizontal, 18).cardSurface()
                    VStack(alignment: .leading, spacing: 9) {
                        Label("安心留在本机", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.green)
                        Text("凭据使用系统钥匙串保存；课程缓存和签到记录保留在此设备，退出时清除。App 不请求定位权限。")
                            .font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.secondary)
                    }.padding(.horizontal, 4)
                    if model.isConnected {
                        Button(role: model.isDemo ? nil : .destructive) { showLogout = true } label: {
                            Text(model.isDemo ? "退出演示模式" : "退出登录")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(model.isDemo ? Palette.secondary : .red)
                                .frame(maxWidth: .infinity).padding(18).cardSurface()
                                .contentShape(RoundedRectangle(cornerRadius: 22))
                        }.buttonStyle(.plain)
                    }
                    Text("果壳签到 · 1.0\n开源许可 · AGPL-3.0")
                        .font(.system(size: 10)).lineSpacing(5).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(24)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("profile.scroll")
            .background(Palette.background)
            .navigationTitle("账户")
            .appNavigationStyle()
        }
        #if os(macOS)
        .alert("系统通知设置", isPresented: $showNotificationSettingsHelp) {
            Button("打开系统设置") { openSystemSettings() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("在“系统设置 → 通知”中找到“果壳签到”，即可调整通知、声音与横幅。若列表中尚未出现，请先开启本页的“课程提醒”。")
        }
        #endif
        .confirmationDialog(model.isDemo ? "退出演示模式？" : "退出并清除本机账号数据？", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出", role: model.isDemo ? nil : .destructive) { model.logout() }
        }.sheet(isPresented: $showRecords) { recordsView }
            .sheet(isPresented: $showOpenSource) { OpenSourceView() }
            .sheet(isPresented: $showDisclaimer) { DisclaimerView() }
    }
    private var canConnectAccount: Bool { model.isDemo || !model.isConnected }

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

    private var accountDisplayName: String {
        guard accountDetailsHidden, model.isConnected else { return model.accountName }
        let name = model.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "同学" else { return "同学" }
        return "\(name.prefix(1))同学"
    }

    private var accountCard: some View {
        accountCardBody
            .overlay(alignment: .trailing) {
                if model.isConnected {
                    Button { accountDetailsHidden.toggle() } label: {
                        Image(systemName: accountDetailsHidden ? "eye.slash" : "eye")
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.privacyToggle")
                    .accessibilityLabel(accountDetailsHidden ? "显示账户信息" : "隐藏账户信息")
                    .accessibilityValue(accountDetailsHidden ? "已隐藏" : "已显示")
                    .padding(.trailing, 12)
                }
            }
    }

    @ViewBuilder
    private var accountCardBody: some View {
        if canConnectAccount {
            Button { model.showLogin = true } label: { accountCardContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.connectAccount")
                .accessibilityHint("打开学校账号登录")
        } else {
            accountCardContent
        }
    }

    private var accountCardContent: some View {
        HStack(spacing: 17) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 53, weight: .light)).foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(accountDisplayName).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.ink)
                if let studentNo = model.accountStudentNo {
                    Text("学号 \(accountDetailsHidden ? "••••••••" : studentNo)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary)
                        .accessibilityLabel(accountDetailsHidden ? "学号已隐藏" : "学号 \(studentNo)")
                }
                if canConnectAccount {
                    Text(model.isDemo ? "演示模式 · 点击连接学校账号" : "点击登录，连接学校账号")
                        .font(.system(size: 11)).foregroundStyle(Palette.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let session = model.session, session.name == nil {
                    Button("重新登录以同步姓名") { model.showLogin = true }
                        .font(.system(size: 11)).foregroundStyle(Palette.green)
                } else {
                    Text("中国科学院大学 · 轻新课堂")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 0)
            if !model.isConnected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, model.isConnected ? 44 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

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
    private var recordsView: some View {
        NavigationStack {
            Group {
                if model.records.isEmpty {
                    CompatibleContentUnavailableView("还没有签到记录", systemImage: "checkmark.seal", description: "在此设备完成签到后，结果会显示在这里。")
                } else {
                    List(model.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(record.courseName).font(.headline)
                                Spacer()
                                Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(record.succeeded ? Palette.green : .orange)
                            }
                            Text(record.message).font(.subheadline).foregroundStyle(.secondary)
                            Text(SchoolDate.text(record.date, "M月d日 HH:mm:ss")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }.navigationTitle(model.isDemo ? "演示签到记录" : "本机签到记录").appNavigationStyle(inline: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showRecords = false } } }
        }.appSheetSize(width: 580, height: 620)
    }
}
