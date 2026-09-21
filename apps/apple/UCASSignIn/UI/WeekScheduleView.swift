import SwiftUI

struct WeekScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var baseHourHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var courseTitleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var courseDetailSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var timeLabelSize: CGFloat = 10
    let pinnedHeaderTop: CGFloat?
    let selectDate: (Date) -> Void
    let openCourse: (Course) -> Void
    @State private var overlappingBlock: WeekScheduleBlock?
    @State private var pendingCourse: Course?

    private var days: [Date] { SchoolDate.week(containing: model.selectedDate) }
    private var gutter: CGFloat { dynamicTypeSize.isAccessibilitySize ? 64 : 36 }
    private var headerHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 100 : 64 }
    private var timelineTopInset: CGFloat { max(10, timeLabelSize) }

    var body: some View {
        let days = self.days
        let presentation = model.weekSchedulePresentation
        let hours = presentation.hours
        let gridLayout = WeekScheduleGridLayout(
            gutter: gutter, headerHeight: headerHeight, timelineTopInset: timelineTopInset,
            minimumColumnWidth: dynamicTypeSize.isAccessibilitySize ? 130 : 36,
            baseHourHeight: baseHourHeight, hourCount: hours.upperBound - hours.lowerBound
        )
        VStack(alignment: .leading, spacing: 16) {
            gridLayout {
                GeometryReader { geometry in
                    let metrics = gridLayout.metrics(for: geometry.size.width)
                    let columnWidth = metrics.columnWidth
                    let contentWidth = gutter + columnWidth * 7
                    let overflows = contentWidth > geometry.size.width + 0.5
                    ScrollView(overflows ? .horizontal : [], showsIndicators: overflows) {
                        VStack(spacing: 0) {
                            GeometryReader { headerGeometry in
                                // Keep the header inside the same horizontal scroll content as
                                // the columns, so large-type scrolling always stays aligned.
                                let top = headerGeometry.frame(in: .named("schedule.scroll")).minY
                                let offset = pinnedHeaderTop.map { min(metrics.gridHeight, max(0, $0 - top)) } ?? 0
                                HStack(spacing: 0) {
                                    Text(SchoolDate.text(days[0], "M月"))
                                        .font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
                                    ForEach(days, id: \.self) { date in
                                        dateHeader(date).frame(width: columnWidth, height: headerHeight)
                                    }
                                }
                                .background(Palette.background)
                                .offset(y: offset)
                            }
                            .frame(height: headerHeight)
                            .zIndex(1)
                            HStack(alignment: .top, spacing: 0) {
                                timeLabels(hours: hours, hourHeight: metrics.hourHeight)
                                    .frame(width: gutter, height: metrics.gridHeight)
                                ForEach(days, id: \.self) { date in
                                    dayColumn(date, blocks: presentation.blocksByDay[SchoolDate.key(date)] ?? [], colors: presentation.colors,
                                              width: columnWidth, hours: hours, hourHeight: metrics.hourHeight)
                                        .frame(width: columnWidth, height: metrics.gridHeight)
                                }
                            }
                            // Hour labels straddle their grid lines; leave room above
                            // the first one instead of drawing it under the date header.
                            .padding(.top, timelineTopInset)
                        }
                        .frame(width: contentWidth)
                        .padding(.bottom, 12)
                    }
                }
            }
            .accessibilityIdentifier("schedule.weekGrid")

            ForEach(days, id: \.self) { date in
                let untimed = presentation.untimedByDay[SchoolDate.key(date)] ?? []
                if !untimed.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(SchoolDate.text(date, "M月d日")) · 时间待确认").font(.headline)
                        ForEach(untimed) { entry in
                            Button { openCourse(entry.course) } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.course.name)
                                    if entry.isOutsideWeek { Text("非本周").font(.caption) }
                                    if let classroom = entry.course.classroom { Text(classroom).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.bordered).tint(entry.isOutsideWeek ? .gray : Palette.green)
                        }
                    }.padding(.horizontal)
                }
            }
        }
        .sheet(item: $overlappingBlock, onDismiss: {
            if let course = pendingCourse { pendingCourse = nil; openCourse(course) }
        }) { block in
            NavigationStack {
                List(block.groups) { group in
                    Button {
                        pendingCourse = group.course
                        overlappingBlock = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.course.name).font(.headline)
                            if !group.teachers.isEmpty { Text(group.teachers.joined(separator: "、")).font(.subheadline) }
                            if group.isOutsideWeek {
                                Text("非本周 · \(CourseTime.parse(day: group.course.day, time: "00:00").map { SchoolDate.text($0, "M月d日") } ?? group.course.day)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(group.course.timeRange).font(.subheadline)
                            if let classroom = group.course.classroom { Text(classroom).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                            .foregroundStyle(group.isOutsideWeek ? Color.secondary : Palette.ink)
                    }.buttonStyle(.plain)
                }
                .navigationTitle("重叠安排")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { overlappingBlock = nil } } }
            }
            .appSheetSize(width: 440, height: 420)
        }
        .onChange(of: model.accountGeneration) { _ in pendingCourse = nil; overlappingBlock = nil }
    }

    private func dateHeader(_ date: Date) -> some View {
        let selected = SchoolDate.key(date) == SchoolDate.key(model.selectedDate)
        let today = SchoolDate.key(date) == SchoolDate.key(.now)
        return Button { selectDate(date) } label: {
            VStack(spacing: 5) {
                Text(SchoolDate.text(date, "EEEEE")).font(.caption2)
                Text(SchoolDate.text(date, "d")).font(.body.weight(.semibold))
                    .foregroundStyle(today ? Color.white : (selected ? Palette.green : Palette.ink))
                    .padding(4)
                    .background(today ? Palette.green : .clear, in: Circle())
                Circle().fill(selected ? Palette.green : .clear).frame(width: 4, height: 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SchoolDate.text(date, "M月d日 EEEE"))
        .accessibilityIdentifier("schedule.weekDate.\(SchoolDate.key(date))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func timeLabels(hours: ClosedRange<Int>, hourHeight: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(hours), id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: timeLabelSize).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .offset(y: CGFloat(hour - hours.lowerBound) * hourHeight - 7)
                    .accessibilityIdentifier("schedule.hour.\(hour)")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func dayColumn(_ date: Date, blocks: [WeekScheduleBlock], colors: ScheduleColors, width: CGFloat,
                           hours: ClosedRange<Int>, hourHeight: CGFloat) -> some View {
        let dayStart = SchoolDate.calendar.startOfDay(for: date)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(SchoolDate.key(date) == SchoolDate.key(.now) ? Palette.green.opacity(0.035) : .clear)
            Rectangle().fill(Palette.line).frame(width: 0.5)
            ForEach(Array(hours), id: \.self) { hour in
                Rectangle().fill(Palette.line).frame(height: 0.5)
                    .offset(y: CGFloat(hour - hours.lowerBound) * hourHeight)
            }
            ForEach(blocks) { block in
                let startHours = block.start.timeIntervalSince(dayStart) / 3600 - Double(hours.lowerBound)
                let height = max(18, block.end.timeIntervalSince(block.start) / 3600 * hourHeight - 3)
                courseBlock(block, colors: colors)
                    .frame(width: max(0, width - 4), height: height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(x: 2, y: startHours * hourHeight + 1)
            }
            if blocks.isEmpty {
                if let error = model.scheduleDayErrors[SchoolDate.key(date)] {
                    Image(systemName: "exclamationmark.icloud").font(.caption)
                        .foregroundStyle(.secondary).padding(.top, 16).frame(width: width)
                        .accessibilityLabel("\(SchoolDate.text(date, "M月d日")) 查询失败：\(error)")
                }
            }
        }
    }

    private func courseBlock(_ block: WeekScheduleBlock, colors: ScheduleColors) -> some View {
        let groups = block.groups
        let course = (block.entries.first { !$0.isOutsideWeek } ?? block.entries[0]).course
        let tint = block.isOutsideWeek ? Color.gray : courseColor(course, palette: colors)
        return Button {
            if groups.count > 1 { overlappingBlock = block }
            else { openCourse(course) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if block.isOutsideWeek {
                    Text("非本周").font(.system(size: courseDetailSize))
                }
                if groups.count > 1 {
                    Text("\(groups.count) 项安排").font(.system(size: courseTitleSize, weight: .semibold))
                    Image(systemName: "square.stack").font(.system(size: courseDetailSize))
                    let outsideCount = groups.filter(\.isOutsideWeek).count
                    if outsideCount > 0 && !block.isOutsideWeek {
                        Text("\(outsideCount) 项非本周").font(.system(size: courseDetailSize))
                    }
                } else {
                    Text(course.name)
                        .font(.system(size: courseTitleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let classroom = course.classroom {
                        Text(classroom)
                            .font(.system(size: courseDetailSize))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.entries.map {
            "\($0.isOutsideWeek ? "非本周，" : "")\($0.course.name)，\($0.course.teacher)，\($0.course.day)，\($0.course.timeRange)，\($0.course.classroom ?? "教室未提供")"
        }.joined(separator: "；"))
        .accessibilityHint(groups.count > 1 ? "选择重叠安排" : "查看课程详情")
        .accessibilityIdentifier("schedule.\(block.isOutsideWeek ? "outsideWeekCourse" : "weekCourse").\(SchoolDate.key(block.start)).\(course.id)")
    }

    private func courseColor(_ course: Course, palette: ScheduleColors) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .orange, .pink, .green]
        return colors[palette.index(for: course)]
    }
}

/// Derive both the proposed grid height and its time scale from the same column width.
/// Narrow columns need extra height for wrapping; wide windows retain the compact scale.
private struct WeekScheduleGridLayout: Layout {
    let gutter: CGFloat
    let headerHeight: CGFloat
    let timelineTopInset: CGFloat
    let minimumColumnWidth: CGFloat
    let baseHourHeight: CGFloat
    let hourCount: Int

    func metrics(for width: CGFloat) -> (columnWidth: CGFloat, hourHeight: CGFloat, gridHeight: CGFloat) {
        let columnWidth = max(minimumColumnWidth, (width - gutter) / 7)
        let wrappingScale = min(1.5, max(1, 80 / columnWidth))
        let hourHeight = baseHourHeight * wrappingScale
        return (columnWidth, hourHeight, CGFloat(hourCount) * hourHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 680
        return CGSize(width: width, height: metrics(for: width).gridHeight + headerHeight + timelineTopInset + 12)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
