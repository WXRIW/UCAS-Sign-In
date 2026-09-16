import SwiftUI

struct CachedCoursesBanner: View {
    @EnvironmentObject private var model: AppModel
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("正在显示缓存课表", systemImage: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("同步最新课程状态后即可签到。软件在前台时会自动重试，也可以立即重新同步。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.refresh(on: date) }
            } label: {
                HStack(spacing: 7) {
                    if model.isRefreshing(on: date) { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(model.isRefreshing(on: date) ? "正在同步…" : "重新同步")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing(on: date) || model.signingID != nil)
            .accessibilityIdentifier("courses.refreshCache")
        }
        .foregroundStyle(Palette.green)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.pale, in: RoundedRectangle(cornerRadius: 14))
    }
}
