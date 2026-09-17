import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    let request: LoginRequest
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var submitting = false
    @State private var loginError: String?
    @State private var attemptedAutofill = false
    @FocusState private var focusedField: Field?
    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    Image(systemName: "leaf.fill").font(.system(size: 34)).foregroundStyle(Palette.green)
                        .frame(width: 74, height: 74).background(Palette.pale, in: RoundedRectangle(cornerRadius: 23))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(request.accountID == nil ? "连接你的课堂。" : "重新连接课堂。")
                            .font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(Palette.ink)
                        Text(request.accountID == nil ? "使用 SEP 邮箱或轻新课堂学号登录，\n添加成功后将切换到这个账户。" : "验证此账户的登录信息，\n继续同步课程与签到状态。")
                            .font(.system(size: 14)).lineSpacing(6).foregroundStyle(Palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("账户").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                            TextField("SEP 邮箱 / 轻新课堂学号", text: $username)
                                .textContentType(.username)
                                .textFieldStyle(.plain)
                                #if os(iOS)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                #endif
                                .focused($focusedField, equals: .username).submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .padding(17).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 9) {
                            Text("密码").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                            SecureField("对应账号的密码", text: $password).textContentType(.password)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .password).submitLabel(.go)
                                .onSubmit { submit() }.padding(17)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Toggle(isOn: $remember) {
                            Text("在此设备记住密码").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }.toggleStyle(.switch).tint(Palette.green)
                    }.disabled(submitting)
                    if let loginError { Text(loginError).font(.system(size: 12)).foregroundStyle(.red).accessibilityLabel("登录失败：\(loginError)") }
                    PrimaryButton(title: "登录并同步课程", loading: submitting, action: submit)
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || submitting || !model.canChangeAccount)
                        .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)
                    Label("此账户的登录会话会保存在系统钥匙串；勾选后也会保存密码，供登录过期时自动恢复。", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    Button { model.enterDemo() } label: {
                        Text("先体验演示模式").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                    }.padding(.top, 8).disabled(submitting || !model.canChangeAccount)
                }.appPagePadding(28).padding(.top, 20)
            }.background(Palette.background)
                .appNavigationStyle(inline: true)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if model.loginRequest?.id == request.id { model.loginRequest = nil }
                    }.disabled(submitting).accessibilityIdentifier("login.cancel")
                } }
        }.appSheetSize(width: 520, height: 720)
            .interactiveDismissDisabled(submitting)
            .onAppear {
                guard !attemptedAutofill else { return }
                attemptedAutofill = true
                if let accountID = request.accountID {
                    username = model.accounts.first(where: { $0.id == accountID })?.loginUsername ?? accountID
                }
                if request.accountID != nil, let credentials = model.savedCredentials(for: request.accountID) {
                    username = credentials.username; password = credentials.password; remember = true
                }
            }
    }
    private func submit() {
        guard !submitting, model.canChangeAccount, !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        focusedField = nil
        submitting = true
        loginError = nil
        Task {
            let success = await model.login(username: username, password: password, remember: remember, requestID: request.id)
            submitting = false
            if success { password = "" }
            else if model.loginRequest?.id == request.id { loginError = model.errorMessage; model.errorMessage = nil }
        }
    }
}
