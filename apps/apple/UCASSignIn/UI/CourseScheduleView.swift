import SwiftUI

struct CourseScheduleSection: View {
    @EnvironmentObject private var model: AppModel
    let course: CatalogCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("排课信息")
                .font(PreferenceTypography.section)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                let presentation = model.courseSchedulePresentation(for: course)
                if let presentation, CourseScheduleProgressView.isVisible(presentation, complete: model.courseScheduleIsComplete(for: course)) {
                    CourseScheduleProgressView(presentation: presentation, complete: model.courseScheduleIsComplete(for: course))
                        .padding(PreferenceRowLayout.horizontalPadding)
                    sectionDivider
                }
                summaryContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PreferenceRowLayout.horizontalPadding)
                sectionDivider
                NavigationLink { CourseScheduleView(course: course) } label: {
                    HStack(spacing: 16) {
                        Text("查看完整排课信息")
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(PreferenceRowLayout.horizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看这门课的完整学期排课")
                .accessibilityIdentifier("courseSchedule.showAll")
            }
            .cardSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadCourseSchedule(for: course) }
    }

    private var sectionDivider: some View {
        Divider().overlay(Palette.line)
            .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let presentation = model.courseSchedulePresentation(for: course)
            if CourseScheduleStatus.isVisible(for: course, model: model) { CourseScheduleStatus(course: course) }
            if let presentation, presentation.associationIssue == nil {
                ForEach(presentation.summaries) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(summary.weekText) · \(weekdayName(summary.weekday))")
                            .font(.subheadline.weight(.medium))
                        Text("\(summary.time) · \(summary.classroom ?? "教室暂未提供")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct CourseScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let course: CatalogCourse

    var body: some View {
        let presentation = model.courseSchedulePresentation(for: course)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let presentation, CourseScheduleProgressView.isVisible(presentation, complete: model.courseScheduleIsComplete(for: course)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("课程进度")
                            .font(PreferenceTypography.section)
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                            .accessibilityAddTraits(.isHeader)
                        CourseScheduleProgressView(presentation: presentation, complete: model.courseScheduleIsComplete(for: course))
                            .padding(PreferenceRowLayout.horizontalPadding)
                            .cardSurface()
                    }
                }
                if CourseScheduleStatus.isVisible(for: course, model: model) {
                    CourseScheduleStatus(course: course)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(PreferenceRowLayout.horizontalPadding)
                        .cardSurface()
                }
                if let presentation {
                    let weeks = Dictionary(grouping: presentation.meetings, by: \.week)
                    let weekNumbers = weeks.keys.sorted()
                    ForEach(weekNumbers, id: \.self) { week in
                        Section {
                            ForEach(weeks[week] ?? []) { meeting in
                                CourseScheduleMeetingCard(meeting: meeting)
                            }
                        } header: {
                            Text("第 \(week) 周")
                                .font(PreferenceTypography.section)
                                .foregroundStyle(Palette.secondary)
                                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                                .padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
            .appPagePadding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .accessibilityIdentifier("courseSchedule.list")
        .navigationTitle("排课信息")
        .appNavigationStyle(inline: true)
        .task(id: scenePhase) {
            if scenePhase == .active { await model.loadCourseSchedule(for: course) }
        }
        #if os(macOS)
        .onAppear { model.visibleCourseSchedule = course }
        .onDisappear {
            if model.visibleCourseSchedule == course { model.visibleCourseSchedule = nil }
        }
        #endif
    }
}

private struct CourseScheduleProgressView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: CourseSchedulePresentation
    let complete: Bool

    static func isVisible(_ presentation: CourseSchedulePresentation, complete: Bool) -> Bool {
        presentation.associationIssue == nil && (complete || !presentation.meetings.isEmpty)
    }

    var body: some View {
        // Only this small summary ticks; the full semester list retains its scroll position.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let progress = presentation.progress(at: context.date)
            let percent = Int((progress.fraction * 100).rounded())
            VStack(alignment: .leading, spacing: 12) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        statistic(complete ? "总计" : "已同步", count: progress.total, tint: Palette.ink)
                        statistic("已结束", count: progress.ended, tint: Palette.green)
                        statistic("进度", count: percent, unit: "%", tint: Palette.green)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        statistic(complete ? "总计" : "已同步", count: progress.total, tint: Palette.ink)
                        statistic("已结束", count: progress.ended, tint: Palette.green)
                        statistic("进度", count: percent, unit: "%", tint: Palette.green)
                    }
                }
                ProgressView(value: progress.fraction)
                    .tint(Palette.green)
                    .accessibilityLabel("课程进度")
                    .accessibilityValue("\(progress.total) 节中已结束 \(progress.ended) 节")
                if !complete || progress.unknownTime > 0 {
                    Text([complete ? nil : "仅统计已同步排课",
                          progress.unknownTime > 0 ? "\(progress.unknownTime) 节时间待确认" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("courseSchedule.progress")
        }
    }

    private func statistic(_ title: String, count: Int, unit: String = " 节", tint: Color) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
        return layout {
            Text(title).font(.subheadline).foregroundStyle(Palette.secondary)
            if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            (Text(count.formatted()).font(.title2.weight(.semibold)) + Text(unit).font(.subheadline))
                .monospacedDigit()
                .foregroundStyle(tint)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(count)\(unit)")
    }
}

private struct CourseScheduleMeetingCard: View {
    let meeting: CourseScheduleMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heading.fixedSize()
                    Spacer(minLength: 0)
                    date.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    date.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            meetingDetails
            if !meeting.hasValidTime {
                Text("时间待确认")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
        .padding(PreferenceRowLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("courseSchedule.meeting.\(meeting.id)")
    }

    private var heading: some View {
        Text("第 \(meeting.week) 周 · \(weekdayName(meeting.weekday))")
            .font(.headline).foregroundStyle(Palette.ink)
    }

    private var date: some View {
        Text(SchoolDate.text(meeting.day, "yyyy年M月d日"))
            .font(.subheadline).foregroundStyle(Palette.secondary)
    }

    private var meetingDetails: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                time.fixedSize()
                classroom.fixedSize()
                teachers.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        time.fixedSize()
                        classroom.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        time
                        classroom
                    }
                }
                teachers
            }
        }
        .font(.subheadline).foregroundStyle(Palette.secondary)
    }

    private var time: some View {
        Label(meeting.timeText, systemImage: "clock")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var classroom: some View {
        Label(meeting.classroom ?? "教室暂未提供", systemImage: "location")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var teachers: some View {
        Label(meeting.teachers.isEmpty ? "教师暂未提供" : meeting.teachers.joined(separator: "、"), systemImage: "person")
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CourseScheduleStatus: View {
    @EnvironmentObject private var model: AppModel
    let course: CatalogCourse

    @MainActor static func isVisible(for course: CatalogCourse, model: AppModel) -> Bool {
        let presentation = model.courseSchedulePresentation(for: course)
        return model.courseScheduleLoading.contains(course.semesterId) || model.courseScheduleErrors[course.semesterId] != nil ||
            !model.courseScheduleIsComplete(for: course) ||
            presentation == nil || presentation?.associationIssue != nil || presentation?.meetings.isEmpty == true
    }

    var body: some View {
        let loading = model.courseScheduleLoading.contains(course.semesterId)
        let presentation = model.courseSchedulePresentation(for: course)
        let complete = model.courseScheduleIsComplete(for: course)
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView("正在加载排课…") }
            if let error = model.courseScheduleErrors[course.semesterId] {
                Text(error).foregroundStyle(.secondary)
                    .accessibilityIdentifier("courseSchedule.error")
            }
            if !loading {
                if model.courseScheduleSemester(for: course) == nil {
                    if model.courseScheduleErrors[course.semesterId] == nil {
                        Text("无法确定这门课所属学期的有效范围。")
                    }
                } else if let issue = presentation?.associationIssue {
                    Text(issue)
                } else if !complete {
                    Text("排课尚未完整同步")
                } else if presentation?.meetings.isEmpty == true {
                    Text("本学期暂无排课")
                }
            } else if !complete, presentation?.meetings.isEmpty == false {
                Text("排课尚未完整同步")
            }
        }
        .font(.subheadline)
    }
}

private func weekdayName(_ value: Int) -> String {
    ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][value - 1]
}
