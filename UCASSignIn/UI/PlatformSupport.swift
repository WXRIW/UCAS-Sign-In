import SwiftUI

extension View {
    /// Keeps the shared navigation content native to each platform.
    @ViewBuilder
    func appNavigationStyle(inline: Bool = false) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(inline ? .inline : .large)
            .toolbarBackground(Palette.background, for: .navigationBar)
        #else
        self
        #endif
    }

    /// macOS sheets need an explicit size because their content often scrolls.
    @ViewBuilder
    func appSheetSize(width: CGFloat = 560, height: CGFloat = 700) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self
        #endif
    }
}
