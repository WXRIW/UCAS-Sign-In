import SwiftUI

struct AboutView: View {
    let openSource: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 15) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 104, height: 104)
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 7)
                        Image("BrandIcon")
                            .renderingMode(.original)
                            .resizable().scaledToFit()
                            .frame(width: 72, height: 72)
                    }
                    VStack(spacing: 7) {
                        Text("果壳签到")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                        Text("为国科大轻新课堂打造的多平台原生客户端")
                            .font(PreferenceTypography.body)
                            .foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text("版本 \(UpdateCoordinator.currentVersion)")
                        .font(PreferenceTypography.caption.weight(.semibold))
                        .foregroundStyle(Palette.green)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Palette.pale, in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                VStack(alignment: .leading, spacing: 16) {
                    Label("功能概览", systemImage: "checklist")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("支持课表查询、课程签到、动态二维码、课程提醒与多账户切换。")
                        .font(PreferenceTypography.body).lineSpacing(5)
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20).cardSurface()

                VStack(alignment: .leading, spacing: 16) {
                    Label("数据与隐私", systemImage: "lock.shield.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 11) {
                        privacyPoint("登录请求直接发送至学校 HTTPS 服务，不经过自建服务器")
                        privacyPoint("各账户的会话和可选密码由 Apple Keychain 保存")
                        privacyPoint("课程缓存、签到记录与课堂偏好按账户保存在本机")
                        privacyPoint("移除账户时仅清除该账户的数据")
                        privacyPoint("App 不申请定位权限")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20).cardSurface()

                Button(action: openSource) {
                    PreferenceNavigationRow(title: "项目源码与致谢", symbol: "chevron.left.forwardslash.chevron.right")
                        .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                        .cardSurface()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about.openSource")

                Text("开源许可 · AGPL-3.0")
                    .font(PreferenceTypography.footer)
                    .foregroundStyle(Palette.secondary)
            }
            .appPagePadding()
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("about.scroll")
        .background(Palette.background)
        .navigationTitle("关于")
        .appNavigationStyle(inline: true)
    }

    private func privacyPoint(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Palette.green)
                .frame(width: 5, height: 5)
            Text(text)
                .font(PreferenceTypography.body).lineSpacing(4)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OpenSourceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionTitle("项目源码")
                sourceRepositoryCard
                sectionTitle("致谢")
                Text("轻新课堂接口实现参考了以下项目，感谢原作者及贡献者的开源分享。")
                    .font(.system(size: 14)).lineSpacing(5).foregroundStyle(Palette.secondary)
                projectCard(name: "UCAS-Course-Sign-in", author: "lccipher")
                projectCard(name: "UCAS-Sign-in", author: "zhan-nine")
                Text("两个参考项目均采用 GNU Affero General Public License v3.0（AGPL-3.0）。原作者及贡献者保留其相应版权。果壳签到沿用 AGPL-3.0 开源许可。")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.secondary)
            }.appPagePadding()
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("openSource.scroll")
        .background(Palette.background)
        .navigationTitle("项目源码与致谢").appNavigationStyle(inline: true)
    }

    private var sourceRepositoryCard: some View {
        projectCard(name: "UCAS-Sign-In", author: "WXRIW",
                    repositoryIdentifier: "opensource.repository")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.ink)
    }

    private func projectCard(name: String, author: String, repositoryIdentifier: String = "") -> some View {
        let repository = "https://github.com/\(author)/\(name)"
        return VStack(alignment: .leading, spacing: 16) {
            Link(destination: URL(string: repository)!) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(author).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(Palette.green)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(repositoryIdentifier)
            .accessibilityHint("在浏览器中打开 GitHub 源码仓库")
            Divider().overlay(Palette.line)
            HStack {
                Text("AGPL-3.0").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.pale, in: Capsule())
                Spacer()
                Link("查看协议", destination: URL(string: repository + "/blob/main/LICENSE")!)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green)
                    .accessibilityLabel("查看 \(name) 的 AGPL-3.0 协议")
            }
        }.padding(20).cardSurface()
    }
}

struct DisclaimerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("使用前请了解", systemImage: "info.circle")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(Palette.green)
                statement("非官方软件", "果壳签到是独立开发的开源客户端，与中国科学院、中国科学院大学及轻新课堂服务运营方不存在隶属、合作或官方授权关系。")
                statement("遵守考勤规定", "本软件用于学习交流和个人课程管理。请遵守学校、课程及服务平台的相关规定，仅在实际到课且满足签到要求时使用。请勿代签、虚假签到、规避考勤或用于其他违法违规活动。")
                statement("以学校系统为准", "课程信息和签到结果以学校系统记录为准。网络状况、接口变化、系统限制等可能导致数据延迟、功能不可用或签到失败；本软件不保证每次请求成功。请及时核对结果，出现异常时使用学校提供的正式渠道处理。")
                statement("保护账号与数据", "请仅使用本人有权使用的账号，并妥善保管设备和登录凭据。登录信息会提交给学校服务进行验证；在他人设备上使用后，请及时退出登录并清除本机账号数据。")
                statement("无担保声明", "在适用法律允许的范围内，本软件按“现状”提供，不作适销性、特定用途适用性或持续可用性的担保。本声明不排除或限制依法不得免除的责任，具体开源许可条款请见“项目源码与致谢”。")
                Text("更新日期：2026 年 9 月 16 日")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.appPagePadding()
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("disclaimer.scroll")
        .background(Palette.background)
        .navigationTitle("免责声明").appNavigationStyle(inline: true)
    }

    private func statement(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(body).font(.system(size: 13)).lineSpacing(6).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
