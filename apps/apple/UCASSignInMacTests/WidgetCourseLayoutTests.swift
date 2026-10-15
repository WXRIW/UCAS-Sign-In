import XCTest
@testable import UCASSignInMac

final class WidgetCourseLayoutTests: XCTestCase {
    func testBodyReservesHeaderFooterAndBothSectionGaps() {
        let layout = WidgetCourseLayout(size: .large, contentHeight: 200)

        XCTAssertEqual(WidgetCourseLayout.headerHeight, 16)
        XCTAssertEqual(WidgetCourseLayout.footerHeight, 14)
        XCTAssertEqual(WidgetCourseLayout.sectionSpacing, 8)
        XCTAssertEqual(layout.bodyHeight, 154)
        XCTAssertEqual(layout.rowHeight, 44)
        XCTAssertEqual(layout.rowSpacing, 10)
    }

    func testEverySizeKeepsOneRowWhenAvailableHeightIsTooSmall() {
        for size: WidgetCourseLayout.Size in [.small, .medium, .large, .extraLarge, .extraLargePortrait] {
            for height in [-100.0, 0, 20, 46] {
                let layout = WidgetCourseLayout(size: size, contentHeight: height)
                XCTAssertEqual(layout.bodyHeight, 0)
                XCTAssertEqual(layout.rowsPerColumn, 1)
                XCTAssertEqual(layout.capacity, size == .extraLarge ? 2 : 1)
            }
        }
    }

    func testSmallIsAlwaysOneCourseAndMediumIsAtMostTwo() {
        for height in [100.0, 500, 1_000] {
            XCTAssertEqual(WidgetCourseLayout(size: .small, contentHeight: height).capacity, 1)
            XCTAssertEqual(WidgetCourseLayout(size: .medium, contentHeight: height).capacity, height == 100 ? 1 : 2)
        }
        XCTAssertEqual(WidgetCourseLayout(size: .medium, contentHeight: 200).rowHeight, 34)
    }

    func testMediumSecondRowAppearsExactlyWhenBothRowsAndTheirGapFit() {
        XCTAssertEqual(WidgetCourseLayout(size: .medium, contentHeight: 121.99).capacity, 1)
        XCTAssertEqual(WidgetCourseLayout(size: .medium, contentHeight: 122).capacity, 2)
    }

    func testCompactMediumFitsTwoCoursesWithItsSmallerRowGap() {
        let layout = WidgetCourseLayout(size: .medium, contentHeight: 123)

        XCTAssertEqual(layout.bodyHeight, 77)
        XCTAssertEqual(layout.rowSpacing, 8)
        XCTAssertEqual(layout.capacity, 2)
        XCTAssertEqual(layout.courseAreaHeight, 76)
        XCTAssertLessThanOrEqual(layout.courseAreaHeight, layout.bodyHeight)
    }

    func testLargeAndExtraLargeCapacityChangesAtExactRowBoundary() {
        // Three 44-point rows and two 10-point gaps require 152 body points.
        let largeBefore = WidgetCourseLayout(size: .large, contentHeight: 197.99)
        let largeAt = WidgetCourseLayout(size: .large, contentHeight: 198)
        let extraLargeBefore = WidgetCourseLayout(size: .extraLarge, contentHeight: 197.99)
        let extraLargeAt = WidgetCourseLayout(size: .extraLarge, contentHeight: 198)

        XCTAssertEqual(largeBefore.capacity, 2)
        XCTAssertEqual(largeAt.capacity, 3)
        XCTAssertEqual(extraLargeBefore.rowsPerColumn, 2)
        XCTAssertEqual(extraLargeBefore.capacity, 4)
        XCTAssertEqual(extraLargeAt.rowsPerColumn, 3)
        XCTAssertEqual(extraLargeAt.capacity, 6)
    }

    func testExtraLargeUsesOneFullWidthColumnForSparseCourses() {
        let layout = WidgetCourseLayout(size: .extraLarge, contentHeight: 198)

        XCTAssertEqual(layout.columnRanges(for: 1), [0..<1])
        XCTAssertEqual(layout.columnRanges(for: 3), [0..<3])
    }

    func testPortraitUsesTallSingleColumnWithHeightBasedCapacity() {
        let layout = WidgetCourseLayout(size: .extraLargePortrait, contentHeight: 650)

        XCTAssertEqual(layout.bodyHeight, 604)
        XCTAssertEqual(layout.rowHeight, 44)
        XCTAssertEqual(layout.rowSpacing, 10)
        XCTAssertEqual(layout.rowsPerColumn, 11)
        XCTAssertEqual(layout.capacity, 11)
        XCTAssertEqual(layout.courseAreaHeight, 584)
        XCTAssertEqual(layout.columnRanges(for: 11), [0..<11])
        XCTAssertEqual(WidgetCourseLayout(size: .extraLargePortrait, contentHeight: 683.99).capacity, 11)
        XCTAssertEqual(WidgetCourseLayout(size: .extraLargePortrait, contentHeight: 684).capacity, 12)
    }

    func testPortraitKeepsFixedSlotsForSparseListsAndCapsOverflow() {
        let layout = WidgetCourseLayout(size: .extraLargePortrait, contentHeight: 650)

        for count in [1, 5, 11, Int.max] {
            let columns = layout.columnRanges(for: count)
            XCTAssertEqual(columns, [0..<min(count, 11)])
            XCTAssertEqual(layout.courseAreaHeight, 584)
            XCTAssertEqual((layout.bodyHeight - layout.courseAreaHeight) / 2, 10)
        }
        for count in [Int.min, -1, 0] {
            XCTAssertEqual(layout.columnRanges(for: count), [])
        }
    }

    func testCourseAreaReservesAllRowSlotsForSparseAndFullColumns() {
        let medium = WidgetCourseLayout(size: .medium, contentHeight: 122)
        XCTAssertEqual(medium.columnRanges(for: 1), [0..<1])
        XCTAssertEqual(medium.columnRanges(for: 2), [0..<2])
        XCTAssertEqual(medium.courseAreaHeight, 76)

        let large = WidgetCourseLayout(size: .large, contentHeight: 198)
        let extraLarge = WidgetCourseLayout(size: .extraLarge, contentHeight: 198)
        for layout in [large, extraLarge] {
            // Even a one-course column reserves three rows. A top-aligned
            // renderer therefore starts at the same slot as a full column.
            XCTAssertEqual(layout.columnRanges(for: 1), [0..<1])
            XCTAssertEqual(layout.rowsPerColumn, 3)
            XCTAssertEqual(layout.courseAreaHeight, 152)
            XCTAssertEqual(layout.courseAreaHeight, layout.bodyHeight)
            XCTAssertTrue(layout.columnRanges(for: layout.capacity).allSatisfy { $0.count == 3 })
        }
    }

    func testExtraLargeBalancesColumnsAndKeepsChronologicalOrder() {
        let layout = WidgetCourseLayout(size: .extraLarge, contentHeight: 198)

        XCTAssertEqual(layout.columnRanges(for: 4), [0..<2, 2..<4])
        XCTAssertEqual(layout.columnRanges(for: 5), [0..<3, 3..<5])
        XCTAssertEqual(layout.columnRanges(for: 6), [0..<3, 3..<6])
        for courseCount in 1...10 {
            let columns = layout.columnRanges(for: courseCount)
            XCTAssertEqual(columns.flatMap { Array($0) }, Array(0..<min(courseCount, layout.capacity)))
            if columns.count == 2 {
                XCTAssertLessThanOrEqual(abs(columns[0].count - columns[1].count), 1)
            }
            XCTAssertTrue(columns.allSatisfy { $0.count <= layout.rowsPerColumn })
        }
    }

    func testColumnRangesCapOverflowAndIgnoreNonpositiveCounts() {
        let medium = WidgetCourseLayout(size: .medium, contentHeight: 200)
        let extraLarge = WidgetCourseLayout(size: .extraLarge, contentHeight: 198)

        XCTAssertEqual(medium.columnRanges(for: 5), [0..<2])
        XCTAssertEqual(extraLarge.columnRanges(for: Int.max), [0..<3, 3..<6])
        for count in [Int.min, -1, 0] {
            XCTAssertEqual(extraLarge.columnRanges(for: count), [])
        }
    }

    func testInvalidAndExtremeGeometryCannotOverflowCapacity() {
        for size: WidgetCourseLayout.Size in [.small, .medium, .large, .extraLarge, .extraLargePortrait] {
            for height in [Double.nan, .infinity, -.infinity] {
                let layout = WidgetCourseLayout(size: size, contentHeight: height)
                XCTAssertEqual(layout.bodyHeight, 0)
                XCTAssertEqual(layout.rowsPerColumn, 1)
                XCTAssertEqual(layout.capacity, size == .extraLarge ? 2 : 1)
            }
        }

        let huge = WidgetCourseLayout(size: .extraLarge, contentHeight: .greatestFiniteMagnitude)
        XCTAssertEqual(huge.rowsPerColumn, Int.max / 2)
        XCTAssertEqual(huge.capacity, (Int.max / 2) * 2)
        let ranges = huge.columnRanges(for: Int.max)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges[0].upperBound, ranges[1].lowerBound)
        XCTAssertEqual(ranges[1].upperBound, huge.capacity)

        let hugePortrait = WidgetCourseLayout(size: .extraLargePortrait, contentHeight: .greatestFiniteMagnitude)
        XCTAssertEqual(hugePortrait.capacity, Int.max / 2)
        XCTAssertEqual(hugePortrait.columnRanges(for: Int.max), [0..<(Int.max / 2)])
        XCTAssertTrue(hugePortrait.courseAreaHeight.isFinite)
    }
}
