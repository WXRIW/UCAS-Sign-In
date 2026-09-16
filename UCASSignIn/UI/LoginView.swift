import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var remember = false
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
                        Text("连接你的课堂。").font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(Palette.ink)
                        Text("使用 SEP 邮箱或轻新课堂学号登录，\n课程会自动同步到这里。")
                            .font(.system(size: 14)).lineSpacing(6).foregroundStyle(Palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 17) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("学校账号").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
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
                            Text("在此设备记住账号与密码").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }.toggleStyle(.switch).tint(Palette.green)
                    }
                    if let loginError { Text(loginError).font(.system(size: 12)).foregroundStyle(.red).accessibilityLabel("登录失败：\(loginError)") }
                    PrimaryButton(title: "登录并同步课程", loading: submitting, action: submit)
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || model.isLoading)
                        .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)
                    Label("登录信息仅用于学校官方接口；保存的凭据由系统钥匙串保护。", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    Button { model.enterDemo(); dismiss() } label: {
                        Text("先体验演示模式").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                    }.padding(.top, 8)
                }.padding(28).padding(.top, 20)
            }.background(Palette.background)
                .appNavigationStyle(inline: true)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) } }
        }.appSheetSize(width: 520, height: 720)
            .interactiveDismissDisabled(submitting)
            .onAppear {
                guard !attemptedAutofill else { return }
                attemptedAutofill = true
                if let credentials = model.savedCredentials() {
                    username = credentials.username; password = credentials.password; remember = true
                }
            }
    }
    private func submit() {
        guard !submitting, !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        focusedField = nil
        submitting = true
        loginError = nil
        Task {
            let success = await model.login(username: username, password: password, remember: remember)
            submitting = false
            if success { password = ""; dismiss() }
            else { loginError = model.errorMessage; model.errorMessage = nil }
        }
    }
}
