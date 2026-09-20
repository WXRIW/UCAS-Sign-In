import SwiftUI

struct CourseRefreshButton: View {
    let title: String
    let isRefreshing: Bool
    let isConnected: Bool
    var showsTitle = false
    let refresh: @MainActor () async -> Void
    @State private var isRequested = false

    var body: some View {
        Button {
            guard !isRequested else { return }
            isRequested = true
            Task { @MainActor in
                defer { isRequested = false }
                await performVisibleRefresh(refresh)
            }
        } label: {
            HStack(spacing: 6) {
                if isRefreshing || isRequested {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                if showsTitle {
                    Text(title).font(PreferenceTypography.detail.weight(.medium))
                }
            }
            .foregroundStyle(Palette.green)
            .frame(minWidth: showsTitle ? 52 : nil)
        }
        .disabled(!isConnected || isRefreshing || isRequested)
        .accessibilityLabel(title)
        .accessibilityValue(isRefreshing || isRequested ? "正在刷新" : "")
        .help("\(title)（⌘R）")
    }
}

@MainActor
private func performVisibleRefresh(_ action: @MainActor () async -> Void) async {
    // Give even a fast response a readable indicator without delaying the data update.
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
    await action()
    try? await Task.sleep(until: deadline, clock: .continuous)
}

extension View {
    @ViewBuilder
    func courseRefreshable(enabled: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        #if os(iOS)
        if enabled {
            self.refreshable {
                UISelectionFeedbackGenerator().selectionChanged()
                await action()
            }
        } else { self }
        #else
        self
        #endif
    }

}
