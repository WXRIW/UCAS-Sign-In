import SwiftUI
import WidgetKit

private enum WidgetPalette {
    static let green = Color(red: 0.18, green: 0.37, blue: 0.27)
    static let cream = Color(red: 0.96, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.16, green: 0.22, blue: 0.18)
}

private enum WidgetDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}

private struct CourseWidgetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.containerBackground(WidgetPalette.cream, for: .widget)
        } else {
            // iOS 16 uses safe areas instead of automatic widget content margins.
            // Own the inset here so it is applied exactly once.
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WidgetPalette.cream)
                .ignoresSafeArea()
        }
    }
}

struct CourseEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    var courses: [WidgetCourse] {
        snapshot.courses.filter { WidgetDate.calendar.isDate($0.startTime, inSameDayAs: date) }
            .sorted { $0.startTime < $1.startTime }
    }

    var nextCourse: WidgetCourse? {
        courses.first { $0.endTime > date } ?? courses.last
    }
}

struct CourseProvider: TimelineProvider {
    func placeholder(in context: Context) -> CourseEntry {
        CourseEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(CourseEntry(date: .now, snapshot: context.isPreview ? .preview : WidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        // The widget only reads a local snapshot. Opening the app refreshes the course data.
        let now = Date()
        let snapshot = WidgetSnapshotStore.load()
        let midnight = WidgetDate.calendar.date(byAdding: .day, value: 1, to: WidgetDate.calendar.startOfDay(for: now))!
        let refresh = min(now.addingTimeInterval(15 * 60), midnight)
        completion(Timeline(entries: [CourseEntry(date: now, snapshot: snapshot)], policy: .after(refresh)))
    }
}

struct CourseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CourseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("今日课程")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(entry.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(WidgetPalette.green)

            if entry.courses.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallCourse
            } else {
                mediumCourses
            }
        }
        .foregroundStyle(WidgetPalette.ink)
        .environment(\.timeZone, WidgetDate.calendar.timeZone)
        .environment(\.calendar, WidgetDate.calendar)
        .modifier(CourseWidgetBackground())
        .widgetURL(URL(string: "ucas-signin://today"))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text("留一点时间给自己")
                .font(.system(size: family == .systemSmall ? 17 : 20, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text("暂无课程 · 打开 App 同步")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var smallCourse: some View {
        if let course = entry.nextCourse {
            VStack(alignment: .leading, spacing: 5) {
                Text(course.startTime, style: .time)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.green)
                Text(course.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(course.location.isEmpty ? "授课信息待同步" : course.location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: course.isCheckedIn ? "checkmark.circle.fill" : "calendar")
                    Text(course.isCheckedIn ? "已签到" : "今日 \(entry.courses.count) 节课")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WidgetPalette.green)
            }
        }
    }

    private var mediumCourses: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(entry.courses.prefix(2))) { course in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(course.startTime, style: .time)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(course.endTime, style: .time)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 51, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(WidgetPalette.green.opacity(course.isCheckedIn ? 0.3 : 0.8))
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(course.location.isEmpty ? "授课信息待同步" : course.location)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if course.isCheckedIn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(WidgetPalette.green)
                            .accessibilityLabel("已签到")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

@main
struct UCASSignInWidget: Widget {
    let kind = "UCASSignInTodayCourses"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CourseProvider()) { entry in
            CourseWidgetView(entry: entry)
        }
        .configurationDisplayName("果壳签到 · 今日课程")
        .description("一眼查看今日课程与签到状态。数据由 App 同步。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UCASSignInWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CourseWidgetView(entry: CourseEntry(date: .now, snapshot: .preview))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("小号 · 今日课程")
            CourseWidgetView(entry: CourseEntry(date: .now, snapshot: .preview))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("中号 · 今日课程")
            CourseWidgetView(entry: CourseEntry(date: .now, snapshot: .empty))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("小号 · 暂无课程")
            CourseWidgetView(entry: CourseEntry(date: .now, snapshot: .empty))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("中号 · 暂无课程")
        }
    }
}
