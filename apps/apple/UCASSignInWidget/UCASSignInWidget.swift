import SwiftUI
import WidgetKit

struct CourseEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CourseProvider: TimelineProvider {
    func placeholder(in context: Context) -> CourseEntry {
        CourseEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(CourseEntry(date: .now, snapshot: context.isPreview ? .preview : WidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        // Schedule known transitions locally, even while the app is closed.
        // Saving a new snapshot in the app also requests a new timeline.
        let snapshot = WidgetSnapshotStore.load()
        let schedule = WidgetSchedule(snapshot: snapshot, at: .now)
        let entries = schedule.timelineDates.map { CourseEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(schedule.nextMidnight)))
    }
}

@main
struct UCASSignInWidget: Widget {
    let kind = "UCASSignInTodayCourses"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CourseProvider()) { entry in
            CourseWidgetView(snapshot: entry.snapshot, date: entry.date)
        }
        .configurationDisplayName("果壳签到 · 今日课程")
        .description("一眼查看今日课程与签到状态。数据由 App 同步。")
        .supportedFamilies(CourseWidgetFamilies.supported)
    }
}
