import SwiftUI
#if os(iOS)
import UIKit
#endif

enum PageLayout {
    static let phoneMargin: CGFloat = 16

    static func horizontalMargin(default value: CGFloat = 24) -> CGFloat {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return phoneMargin }
        #endif
        return value
    }
}

extension View {
    /// Keeps the shared navigation content native to each platform.
    @ViewBuilder
    func appNavigationStyle(inline: Bool = false) -> some View {
        #if os(iOS)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Let the system's scroll-edge treatment see the scrolling content.
            // An opaque toolbar background replaces its soft blur with a hard edge.
            self.navigationBarTitleDisplayMode(inline ? .inline : .large)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .background(PhoneNavigationMargins())
        } else {
            self.navigationBarTitleDisplayMode(inline ? .inline : .large)
                .toolbarBackground(Palette.background, for: .navigationBar)
                .background(PhoneNavigationMargins())
        }
        #else
        self.navigationBarTitleDisplayMode(inline ? .inline : .large)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .background(PhoneNavigationMargins())
        #endif
        #else
        self
        #endif
    }

    func appPageHorizontalPadding(default value: CGFloat = 24) -> some View {
        padding(.horizontal, PageLayout.horizontalMargin(default: value))
    }

    func appPagePadding(_ vertical: CGFloat = 24) -> some View {
        appPageHorizontalPadding(default: vertical).padding(.vertical, vertical)
    }

    @ViewBuilder
    func appListPageMargins() -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 17.0, *) {
                self.contentMargins(.horizontal, PageLayout.phoneMargin, for: .scrollContent)
            } else {
                // Inset-grouped lists already provide a 20-point content margin.
                self.listStyle(.insetGrouped).padding(.horizontal, PageLayout.phoneMargin - 20)
            }
        } else { self }
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

#if os(iOS)
/// Use the same public UIKit margins for native titles and SwiftUI page content.
private struct PhoneNavigationMargins: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.alignMargins() }

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            alignMargins()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            alignMargins()
        }

        func alignMargins() {
            guard traitCollection.userInterfaceIdiom == .phone,
                  let bar = navigationController?.navigationBar else { return }
            var margins = bar.directionalLayoutMargins
            guard margins.leading != PageLayout.phoneMargin || margins.trailing != PageLayout.phoneMargin else { return }
            margins.leading = PageLayout.phoneMargin
            margins.trailing = PageLayout.phoneMargin
            bar.directionalLayoutMargins = margins
        }
    }
}
#endif
