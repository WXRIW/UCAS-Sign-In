import SwiftUI

enum AccountPrivacy {
    static func name(_ value: String?, hidden: Bool) -> String {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != "同学" else { return "同学" }
        return hidden ? "\(name.prefix(1))同学" : name
    }

    static func studentNo(_ value: String, hidden: Bool) -> String {
        hidden ? "••••••••" : value
    }
}

struct AccountMenu: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("accountDetailsHidden") private var accountDetailsHidden = false

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    if account.id == model.activeAccountID, account.requiresLogin, !model.isDemo {
                        model.presentLogin(accountID: account.id)
                    } else {
                        Task { await model.switchAccount(id: account.id) }
                    }
                } label: {
                    Label(menuTitle(account), systemImage: account.id == model.activeAccountID && !model.isDemo ? "checkmark.circle.fill" : "person.crop.circle")
                }
                .accessibilityIdentifier("accounts.switch.\(account.id)")
            }
            if !model.accounts.isEmpty { Divider() }
            Button { model.presentLogin() } label: {
                Label("添加账户", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("accounts.add")
            Button { model.showAccountManagement = true } label: {
                Label("切换与管理账户", systemImage: "person.2")
            }
            .accessibilityIdentifier("accounts.manage")
        } label: {
            #if os(macOS)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                Text(model.isConnected ? AccountPrivacy.name(model.accountName, hidden: accountDetailsHidden) : "选择账户")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.callout).foregroundStyle(Palette.green)
            .padding(.vertical, 8)
            #else
            Image(systemName: "person.crop.circle")
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .disabled(!model.canChangeAccount)
        .accessibilityLabel("切换账户")
        .accessibilityIdentifier("accounts.quickSwitch")
    }

    private func menuTitle(_ account: StoredAccount) -> String {
        let name = AccountPrivacy.name(account.session.name, hidden: accountDetailsHidden)
        let number = AccountPrivacy.studentNo(account.id, hidden: accountDetailsHidden)
        return "\(name) · \(number)\(account.requiresLogin ? " · 需重新登录" : "")"
    }
}

struct AccountManagementView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accountDetailsHidden") private var accountDetailsHidden = false
    @State private var accountToRemove: String?
    var onLogin: (String?) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("在这台设备保存多个学校账户，点击账户即可切换。仅当前账户同步课程、签到和安排提醒。")
                        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(Palette.secondary)
                    if model.accounts.isEmpty {
                        CompatibleContentUnavailableView("还没有保存账户", systemImage: "person.2", description: "添加学校账户后，可在这里快捷切换。")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.accounts) { account in
                                accountRow(account)
                                if account.id != model.accounts.last?.id { Divider().padding(.leading, 18) }
                            }
                        }.cardSurface()
                    }
                    PrimaryButton(title: "添加账户", symbol: "person.badge.plus") { onLogin(nil) }
                        .disabled(!model.canChangeAccount)
                        .accessibilityIdentifier("accounts.add")
                    Label("会话与可选密码由系统钥匙串保护。移除账户仅清除该账户在本机的凭据、课程缓存、签到记录和课堂偏好。", systemImage: "lock.shield")
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.secondary)
                }.appPagePadding().frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("切换与管理账户")
            .appNavigationStyle(inline: true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("accounts.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { accountDetailsHidden.toggle() } label: {
                        Image(systemName: accountDetailsHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(accountDetailsHidden ? "显示账户信息" : "隐藏账户信息")
                    .accessibilityIdentifier("accounts.privacyToggle")
                }
            }
        }
        .appSheetSize(width: 560, height: 600)
        .confirmationDialog("移除此账户？", isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }), titleVisibility: .visible) {
            Button("移除此账户", role: .destructive) {
                guard let accountID = accountToRemove else { return }
                model.removeAccount(id: accountID)
                accountToRemove = nil
            }
            .disabled(!model.canChangeAccount)
            Button("取消", role: .cancel) { accountToRemove = nil }
        } message: {
            Text("将清除此账户在本机的登录信息、课程缓存、签到记录和课堂偏好，其他账户会保留。")
        }
        .onChange(of: model.accountGeneration) { _ in accountToRemove = nil }
    }

    private func accountRow(_ account: StoredAccount) -> some View {
        HStack(spacing: 12) {
            Button {
                if account.id == model.activeAccountID, !model.isDemo {
                    if account.requiresLogin { onLogin(account.id) }
                    else { dismiss() }
                    return
                }
                Task { await model.switchAccount(id: account.id) }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(Palette.green).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AccountPrivacy.name(account.session.name, hidden: accountDetailsHidden))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("学号 \(AccountPrivacy.studentNo(account.id, hidden: accountDetailsHidden))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                        if account.requiresLogin {
                            Text("需要重新登录").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 2)
                    if account.id == model.activeAccountID && !model.isDemo {
                        Text("当前账户").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.green)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("accounts.row.\(account.id)")
            Button { accountToRemove = account.id } label: {
                Image(systemName: "trash").foregroundStyle(Palette.secondary)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除\(AccountPrivacy.name(account.session.name, hidden: accountDetailsHidden))的账户")
            .accessibilityIdentifier("accounts.remove.\(account.id)")
        }
        .padding(18)
        .disabled(!model.canChangeAccount)
    }
}
