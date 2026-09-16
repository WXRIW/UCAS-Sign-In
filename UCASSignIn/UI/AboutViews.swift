import SwiftUI

struct OpenSourceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("项目源码")
                    .font(.system(size: 25, weight: .bold, design: .serif)).foregroundStyle(Palette.ink)
                sourceRepositoryCard
                Text("致谢")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("轻新课堂接口实现参考了以下项目，感谢原作者及贡献者的开源分享。")
                    .font(.system(size: 14)).lineSpacing(5).foregroundStyle(Palette.secondary)
                projectCard(name: "UCAS-Course-Sign-in", author: "lccipher",
                            description: "课程查询、签到与二维码生成的接口实现。")
                projectCard(name: "UCAS-Sign-in", author: "zhan-nine",
                            description: "Android 客户端、签到流程与课程小组件的实现参考。")
                Text("两个参考项目均采用 GNU Affero General Public License v3.0（AGPL-3.0）。原作者及贡献者保留其相应版权。果壳签到沿用 AGPL-3.0 开源许可。")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.secondary)
            }.padding(24)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("openSource.scroll")
        .background(Palette.background)
        .navigationTitle("项目源码与致谢").appNavigationStyle(inline: true)
    }

    private var sourceRepositoryCard: some View {
        Link(destination: URL(string: "https://github.com/WXRIW/UCAS-Sign-In")!) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UCAS-Sign-In")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("WXRIW")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(Palette.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                Text("查看源码与使用说明")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.secondary)
            }
            .padding(20).cardSurface()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("opensource.repository")
        .accessibilityHint("在浏览器中打开 GitHub 源码仓库")
    }

    private func projectCard(name: String, author: String, description: String) -> some View {
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
            Text(description).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.secondary)
            Divider().overlay(Palette.line)
            HStack {
                Text("AGPL-3.0").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.pale, in: Capsule())
                Spacer()
                Link("查看协议 ↗", destination: URL(string: repository + "/blob/main/LICENSE")!)
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
            }.padding(24)
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
