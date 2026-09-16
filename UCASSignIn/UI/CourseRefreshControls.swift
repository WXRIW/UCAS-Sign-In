import SwiftUI

#if os(macOS)
struct CourseRefreshButton: View {
    let title: String
    let isRefreshing: Bool
    let isConnected: Bool
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
            ZStack {
                Label(title, systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .opacity(isRefreshing || isRequested ? 0 : 1)
                if isRefreshing || isRequested { ProgressView().controlSize(.small) }
            }
        }
        .disabled(!isConnected || isRefreshing || isRequested)
        .accessibilityLabel(title)
        .accessibilityValue(isRefreshing || isRequested ? "正在刷新" : "")
        .help("\(title)（⌘R）")
    }
}

#endif

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
                await performVisibleRefresh(action)
            }
            .courseScrollBounce()
        } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder
    private func courseScrollBounce() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            self.scrollBounceBehavior(.always, axes: .vertical)
        } else { self }
        #else
        self
        #endif
    }
}
