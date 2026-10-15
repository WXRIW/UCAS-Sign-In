import SwiftUI
import WidgetKit

private enum WidgetPalette {
    static let green = Color(red: 0.18, green: 0.37, blue: 0.27)
    static let cream = Color(red: 0.96, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.16, green: 0.22, blue: 0.18)
}

private struct CourseWidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.containerBackground(WidgetPalette.cream, for: .widget)
        } else {
            // iOS 16 has no automatic content margins. Apply the inset exactly once.
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WidgetPalette.cream)
                .ignoresSafeArea()
        }
    }
}

struct CourseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        CourseWidgetContent(schedule: WidgetSchedule(snapshot: snapshot, at: date), family: family)
            .modifier(CourseWidgetBackground())
            .widgetURL(URL(string: "ucas-signin://today"))
    }
}

/// Content dimensions already exclude WidgetKit margins (or the iOS 16 fallback inset).
struct CourseWidgetContent: View {
    let schedule: WidgetSchedule
    let family: WidgetFamily

    private var size: WidgetCourseLayout.Size {
        CourseWidgetFamilies.layoutSize(for: family)
    }

    private var isExpanded: Bool { size != .small && size != .medium }

    var body: some View {
        GeometryReader { geometry in
            let layout = WidgetCourseLayout(size: size, contentHeight: geometry.size.height)
            let courses = schedule.visibleCourses(limit: layout.capacity)

            VStack(alignment: .leading, spacing: WidgetCourseLayout.sectionSpacing) {
                header
                    .frame(height: WidgetCourseLayout.headerHeight)

                Group {
                    if schedule.todayCourses.isEmpty {
                        emptyState
                    } else if family == .systemSmall, let course = courses.first {
                        smallCourse(course)
                    } else {
                        courseList(courses, layout: layout)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: layout.bodyHeight, alignment: .center)

                footer(courses: courses)
                    .frame(height: WidgetCourseLayout.footerHeight)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(WidgetPalette.ink)
        .environment(\.timeZone, WidgetSchedule.calendar.timeZone)
        .environment(\.calendar, WidgetSchedule.calendar)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
            Text("今日课程")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Text(schedule.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(WidgetPalette.green.opacity(0.65))
                .fixedSize()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(WidgetPalette.green)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("留一点时间给自己")
                .font(.system(size: family == .systemSmall ? 17 : 20, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text("暂无课程")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smallCourse(_ course: WidgetCourse) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(course.startTime, style: .time)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.green)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(course.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(location(for: course))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func courseList(_ courses: [WidgetCourse], layout: WidgetCourseLayout) -> some View {
        let columns = layout.columnRanges(for: courses.count)

        return HStack(alignment: .top, spacing: 24) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, range in
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: layout.rowSpacing) {
                    ForEach(Array(courses[range])) { course in
                        GridRow {
                            courseTime(course)
                                .frame(height: layout.rowHeight)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetPalette.green.opacity(course.isCheckedIn ? 0.3 : 0.8))
                                .frame(width: 3, height: isExpanded ? 38 : 32)
                                .frame(height: layout.rowHeight)
                            courseDetails(course)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: layout.rowHeight)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(WidgetPalette.green)
                                .opacity(course.isCheckedIn ? 1 : 0)
                                .accessibilityLabel(course.attendanceLabel ?? "已签到")
                                .accessibilityHidden(!course.isCheckedIn)
                                .frame(width: 16, height: layout.rowHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep every course in its capacity slot; missing rows stay empty below it.
                .frame(height: layout.courseAreaHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func courseTime(_ course: WidgetCourse) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.startTime, style: .time)
                .font(.system(size: isExpanded ? 17 : 15, weight: .semibold, design: .rounded))
            Text(course.endTime, style: .time)
                .font(.system(size: isExpanded ? 11 : 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func courseDetails(_ course: WidgetCourse) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.name)
                .font(.system(size: isExpanded ? 16 : 14, weight: .semibold))
            Text(location(for: course))
                .font(.system(size: isExpanded ? 12 : 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func footer(courses: [WidgetCourse]) -> some View {
        HStack(spacing: 3) {
            if schedule.todayCourses.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("打开 App 同步")
            } else if family == .systemSmall, let course = courses.first {
                Image(systemName: course.isCheckedIn ? "checkmark.circle.fill" : "calendar")
                Text(course.attendanceLabel ?? (course.isCheckedIn ? "已签到" : "今日 \(schedule.todayCourses.count) 门课程"))
            } else {
                Text("今日 \(schedule.todayCourses.count) 门")
                Spacer(minLength: 8)
                if schedule.remainingCourses.isEmpty {
                    Text("今日课程已结束")
                } else if schedule.remainingCourses.count > courses.count {
                    Text("还有 \(schedule.remainingCourses.count - courses.count) 门后续课程")
                } else {
                    Text("待结束 \(schedule.remainingCourses.count) 门")
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(WidgetPalette.green)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func location(for course: WidgetCourse) -> String {
        course.location.isEmpty ? "授课信息待同步" : course.location
    }
}

struct UCASSignInWidget_Previews: PreviewProvider {
    private static var morning: Date {
        WidgetSchedule.calendar.startOfDay(for: .now).addingTimeInterval(7 * 3_600)
    }

    private static var fullDay: WidgetSnapshot {
        let day = WidgetSchedule.calendar.startOfDay(for: morning)
        let names = ["高等数值分析", "高等人工智能", "学术英语", "计算机网络", "机器学习", "自然辩证法", "软件工程", "信息安全"]
        return WidgetSnapshot(courses: names.enumerated().map { index, name in
            let start = day.addingTimeInterval(Double(8 + index * 2) * 3_600)
            return WidgetCourse(id: "preview-\(index)", name: name, location: "教室 · 教学楼 A\(102 + index)",
                                startTime: start, endTime: start.addingTimeInterval(90 * 60), isCheckedIn: index == 0)
        })
    }

    static var previews: some View {
        ForEach(CourseWidgetFamilies.supported, id: \.self) { family in
            CourseWidgetView(snapshot: fullDay, date: morning)
                .previewContext(WidgetPreviewContext(family: family))
                .previewDisplayName("\(family) · 多门课程")
            CourseWidgetView(snapshot: .preview, date: morning)
                .previewContext(WidgetPreviewContext(family: family))
                .previewDisplayName("\(family) · 少量课程")
            CourseWidgetView(snapshot: .empty, date: morning)
                .previewContext(WidgetPreviewContext(family: family))
                .previewDisplayName("\(family) · 暂无课程")
        }
    }
}
