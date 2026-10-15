import Foundation

/// Sizing shared by the widget views and their capacity checks.
struct WidgetCourseLayout {
    enum Size {
        case small
        case medium
        case large
        case extraLarge
        case extraLargePortrait
    }

    static let headerHeight = 16.0
    static let footerHeight = 14.0
    static let sectionSpacing = 8.0

    let size: Size
    let contentHeight: Double

    var bodyHeight: Double {
        guard contentHeight.isFinite else { return 0 }
        return max(0, contentHeight - Self.headerHeight - Self.footerHeight - 2 * Self.sectionSpacing)
    }

    var rowSpacing: Double {
        if case .medium = size { return 8 }
        return 10
    }

    var rowHeight: Double {
        switch size {
        case .medium: return 34
        case .small, .large, .extraLarge, .extraLargePortrait: return 44
        }
    }

    var rowsPerColumn: Int {
        if case .small = size { return 1 }

        let fittingRows = floor((bodyHeight + rowSpacing) / (rowHeight + rowSpacing))
        // Keep conversion and a possible two-column capacity safe even for
        // malformed geometry. Real widget dimensions are far below this limit.
        let maximumRows = Int.max / 2
        let rows = fittingRows >= Double(maximumRows) ? maximumRows : max(1, Int(fittingRows))
        if case .medium = size { return min(2, rows) }
        return rows
    }

    var capacity: Int {
        if case .extraLarge = size { return rowsPerColumn * 2 }
        return rowsPerColumn
    }

    /// Reserve every row slot so sparse lists keep the same first-row position.
    var courseAreaHeight: Double {
        Double(rowsPerColumn) * rowHeight + Double(rowsPerColumn - 1) * rowSpacing
    }

    /// Ranges preserve chronological order when read down the left column first.
    func columnRanges(for courseCount: Int) -> [Range<Int>] {
        let visibleCount = min(max(0, courseCount), capacity)
        guard visibleCount > 0 else { return [] }
        guard case .extraLarge = size, visibleCount > rowsPerColumn else {
            return [0..<visibleCount]
        }

        let leftCount = visibleCount / 2 + visibleCount % 2
        return [0..<leftCount, leftCount..<visibleCount]
    }
}
