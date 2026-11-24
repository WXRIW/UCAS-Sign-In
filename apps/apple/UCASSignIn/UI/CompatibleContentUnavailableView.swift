import SwiftUI

struct CompatibleContentUnavailableView<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    private let actions: Actions

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 48.0

    init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    @available(iOS 17.0, macOS 14.0, *)
    private var nativeContent: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            actions
        }
    }

    var body: some View {
        #if os(macOS)
        nativeContent
        #else
        if #available(iOS 17.0, *) {
            nativeContent
        } else {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}

extension CompatibleContentUnavailableView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
