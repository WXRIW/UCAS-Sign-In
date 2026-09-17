import SwiftUI

enum ProfileDestination: Hashable {
    case settings
    case records
    case openSource
    case disclaimer
}

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [ProfileDestination]
    @AppStorage("accountDetailsHidden") private var accountDetailsHidden = false
    @State private var showLogout = false
    @State private var accountToRemove: String?
    @State private var logoutWasDemo = false
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    accountCard
                    VStack(spacing: 0) {
                        Button { model.showAccountManagement = true } label: {
                            PreferenceNavigationRow(title: "切换与管理账户", symbol: "person.2")
                        }.buttonStyle(.plain)
                            .disabled(!model.canChangeAccount)
                            .accessibilityIdentifier("accounts.manage")
                        PreferenceDivider()
                        Button { path.append(.settings) } label: {
                            PreferenceNavigationRow(title: "设置", symbol: "gearshape")
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.settings")
                        PreferenceDivider()
                        Button { path.append(.records) } label: { PreferenceNavigationRow(title: "本机签到记录", symbol: "clock.arrow.circlepath") }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.records")
                    }.padding(.horizontal, PreferenceRowLayout.horizontalPadding).cardSurface()
                    VStack(spacing: 0) {
                        Button { path.append(.openSource) } label: {
                            PreferenceNavigationRow(title: "项目源码与致谢", symbol: "chevron.left.forwardslash.chevron.right")
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.openSource")
                        PreferenceDivider()
                        Button { path.append(.disclaimer) } label: {
                            PreferenceNavigationRow(title: "免责声明", symbol: "doc.text")
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("profile.disclaimer")
                    }.padding(.horizontal, PreferenceRowLayout.horizontalPadding).cardSurface()
                    VStack(alignment: .leading, spacing: 9) {
                        Label("安心留在本机", systemImage: "lock.shield").font(PreferenceTypography.section).foregroundStyle(Palette.green)
                        Text("各账户的会话和可选密码由系统钥匙串保存；课程缓存、签到记录与课堂偏好分别保留在此设备，移除账户时仅清除该账户的数据。App 不请求定位权限。")
                            .font(PreferenceTypography.detail).lineSpacing(5).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 4)
                    if model.isConnected {
                        Button(role: model.isDemo ? nil : .destructive) {
                            accountToRemove = model.activeAccountID
                            logoutWasDemo = model.isDemo
                            showLogout = true
                        } label: {
                            Text(model.isDemo ? "退出演示模式" : "退出并移除此账户")
                                .font(PreferenceTypography.body.weight(.medium))
                                .foregroundStyle(model.isDemo ? Palette.secondary : .red)
                                .frame(maxWidth: .infinity).padding(18).cardSurface()
                                .contentShape(RoundedRectangle(cornerRadius: 22))
                        }.buttonStyle(.plain).disabled(!model.canChangeAccount)
                            .accessibilityIdentifier("profile.logout")
                    }
                    Text("果壳签到 · 1.0\n开源许可 · AGPL-3.0")
                        .font(PreferenceTypography.footer).lineSpacing(5).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.appPagePadding()
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("profile.scroll")
            .background(Palette.background)
            .navigationTitle("账户")
            .appNavigationStyle()
            .navigationDestination(for: ProfileDestination.self) { destination in
                switch destination {
                case .settings:
                    SettingsView()
                case .records:
                    recordsView
                case .openSource:
                    OpenSourceView()
                case .disclaimer:
                    DisclaimerView()
                }
            }
        }
        .confirmationDialog(logoutWasDemo ? "退出演示模式？" : "退出并移除此账户？", isPresented: $showLogout, titleVisibility: .visible) {
            Button(logoutWasDemo ? "退出" : "退出并移除此账户", role: logoutWasDemo ? nil : .destructive) {
                if logoutWasDemo { model.logout() }
                else if let accountID = accountToRemove { model.removeAccount(id: accountID) }
                accountToRemove = nil
            }
            .disabled(!model.canChangeAccount)
        } message: {
            Text(logoutWasDemo ? "退出后仍可选择本机保存的学校账户。" : "仅清除此账户在本机的登录信息、课程缓存、签到记录和课堂偏好，其他账户会保留。")
        }
        .onChange(of: model.accountGeneration) { _ in
            showLogout = false
            accountToRemove = nil
        }
    }
    private var canConnectAccount: Bool { model.isDemo || !model.isConnected }

    private var accountDisplayName: String {
        guard accountDetailsHidden, model.isConnected else { return model.accountName }
        return AccountPrivacy.name(model.accountName, hidden: accountDetailsHidden)
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
            Button { model.presentLogin() } label: { accountCardContent }
                .buttonStyle(.plain)
                .disabled(!model.canChangeAccount)
                .accessibilityIdentifier("profile.connectAccount")
                .accessibilityHint("打开账户登录")
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
                Text(accountDisplayName).font(PreferenceTypography.accountName).foregroundStyle(Palette.ink)
                if let studentNo = model.accountStudentNo {
                    Text("学号 \(accountDetailsHidden ? "••••••••" : studentNo)")
                        .font(PreferenceTypography.detail).monospacedDigit().foregroundStyle(Palette.secondary)
                        .accessibilityLabel(accountDetailsHidden ? "学号已隐藏" : "学号 \(studentNo)")
                }
                if canConnectAccount {
                    Text(model.isDemo ? "演示模式 · 点击连接账户" : "点击登录，连接账户")
                        .font(PreferenceTypography.caption).foregroundStyle(Palette.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let session = model.session, session.name == nil {
                    Button("重新登录以同步姓名") { model.presentLogin(accountID: model.activeAccountID) }
                        .font(PreferenceTypography.caption).foregroundStyle(Palette.green)
                        .disabled(!model.canChangeAccount)
                } else {
                    Text("中国科学院大学 · 轻新课堂")
                        .font(PreferenceTypography.caption).foregroundStyle(Palette.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
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

    private var recordsView: some View {
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
                        .listRowBackground(Palette.surface)
                }
                .scrollContentBackground(.hidden)
                .appListPageMargins()
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityIdentifier("records.content")
        .navigationTitle(model.isDemo ? "演示签到记录" : "本机签到记录")
        .appNavigationStyle(inline: true)
    }
}
