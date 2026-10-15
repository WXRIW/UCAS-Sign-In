import WidgetKit

enum CourseWidgetFamilies {
    static var supported: [WidgetFamily] {
        let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        // Xcode 27 (Swift 6.4) adds this symbol to the iOS and macOS SDKs.
        // Older Xcode builds continue to offer the original four families.
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) {
            return families + [.systemExtraLargePortrait]
        }
        #endif
        return families
    }

    static func layoutSize(for family: WidgetFamily) -> WidgetCourseLayout.Size {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait {
            return .extraLargePortrait
        }
        #endif
        switch family {
        case .systemSmall: return .small
        case .systemLarge: return .large
        case .systemExtraLarge: return .extraLarge
        default: return .medium
        }
    }
}
