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
            ForEach(model.iCloudPendingAccounts, id: \.studentNo) { profile in
                Button { model.presentLogin(accountID: profile.studentNo) } label: {
                    Label("\(AccountPrivacy.name(profile.name, hidden: accountDetailsHidden)) · 等待登录信息", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("accounts.pending.\(profile.studentNo)")
            }
            if !model.accounts.isEmpty || !model.iCloudPendingAccounts.isEmpty { Divider() }
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
        return "\(name) · \(number)\(account.requiresLogin ? " · 需要重新登录" : "")"
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
                    Text("点击账户即可切换。iCloud 可在 Apple 设备间同步账户；仅当前账户从学校获取课程、提交签到和安排提醒。")
                        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(Palette.secondary)
                    if model.accounts.isEmpty && model.iCloudPendingAccounts.isEmpty {
                        CompatibleContentUnavailableView("还没有保存账户", systemImage: "person.2", description: "添加学校账户后，可在这里快捷切换。")
                    } else if !model.accounts.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(model.accounts) { account in
                                accountRow(account)
                                if account.id != model.accounts.last?.id { Divider().padding(.leading, 18) }
                            }
                        }.cardSurface()
                    }
                    if !model.iCloudPendingAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("等待登录信息").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                            VStack(spacing: 0) {
                                ForEach(model.iCloudPendingAccounts, id: \.studentNo) { profile in
                                    pendingAccountRow(profile)
                                    if profile.studentNo != model.iCloudPendingAccounts.last?.studentNo { Divider().padding(.leading, 18) }
                                }
                            }.cardSurface()
                        }
                    }
                    PrimaryButton(title: "添加账户", symbol: "person.badge.plus") { onLogin(nil) }
                        .disabled(!model.canChangeAccount)
                        .accessibilityIdentifier("accounts.add")
                    Label("会话与已记住的密码由 Apple Keychain 保护。仅从本机移除会保留云端副本；从所有设备移除会同步删除账户。自动签到设置始终保留在各设备本机。", systemImage: "lock.shield")
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
            Button("仅从本机移除", role: .destructive) {
                guard let accountID = accountToRemove else { return }
                model.removeAccount(id: accountID)
                accountToRemove = nil
            }
            .disabled(!model.canChangeAccount)
            .accessibilityIdentifier("accounts.remove.local")
            Button("从 iCloud 与所有设备移除", role: .destructive) {
                guard let accountID = accountToRemove else { return }
                model.removeAccount(id: accountID, everywhere: true)
                accountToRemove = nil
            }
            .disabled(!model.canChangeAccount || model.isDemo)
            .accessibilityIdentifier("accounts.remove.everywhere")
            Button("取消", role: .cancel) { accountToRemove = nil }
        } message: {
            Text("本机移除会清理登录信息、缓存、记录和偏好，并阻止自动恢复。选择所有设备还会删除此账户的云端资料和同步凭据；同步开启且联网后传播删除，其他账户会保留。")
        }
        .onChange(of: model.accountGeneration) { _ in accountToRemove = nil }
    }

    private func pendingAccountRow(_ profile: SyncAccountProfile) -> some View {
        HStack(spacing: 12) {
            Button { onLogin(profile.studentNo) } label: {
                HStack(spacing: 13) {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 28)).foregroundStyle(Palette.green)
                        .frame(width: 34).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AccountPrivacy.name(profile.name, hidden: accountDetailsHidden))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("学号 \(AccountPrivacy.studentNo(profile.studentNo, hidden: accountDetailsHidden))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                        Text("正在等待 iCloud 钥匙串，也可点击重新登录")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("accounts.pending.\(profile.studentNo)")
            Button { accountToRemove = profile.studentNo } label: {
                Image(systemName: "trash").foregroundStyle(Palette.secondary)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除等待同步的账户")
            .accessibilityIdentifier("accounts.remove.\(profile.studentNo)")
        }.padding(18).disabled(!model.canChangeAccount)
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
