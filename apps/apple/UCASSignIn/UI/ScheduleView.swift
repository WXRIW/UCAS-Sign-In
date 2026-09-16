import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [Course]
    let isActive: Bool
    @State private var showDatePicker = false
    @State private var datePickerGeneration: UUID?
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        scheduleContent
                    } header: {
                        dateControls
                    }
                }
            }
            .accessibilityIdentifier("schedule.scroll")
            .background(Palette.background)
            .courseRefreshable(enabled: model.isConnected) { await model.refresh() }
            .navigationTitle("课表")
            .appNavigationStyle()
            .navigationDestination(for: Course.self) { course in
                CourseDetailView(course: course, isActive: isActive, accountGeneration: model.accountGeneration)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        datePickerGeneration = model.accountGeneration
                        showDatePicker = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("选择日期")
                    .accessibilityIdentifier("schedule.datePicker")
                }
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    CourseRefreshButton(title: "刷新课表", isRefreshing: model.isRefreshing(on: model.selectedDate),
                                        isConnected: model.isConnected, refresh: { await model.refresh() })
                        .id(SchoolDate.key(model.selectedDate))
                        .accessibilityIdentifier("schedule.refresh")
                }
                #endif
            }
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                DatePicker("查询日期", selection: Binding(get: { model.selectedDate }, set: { date in
                    guard datePickerGeneration == model.accountGeneration else { return }
                    selectDate(date)
                }), displayedComponents: .date)
                .datePickerStyle(.graphical).environment(\.timeZone, SchoolDate.calendar.timeZone).padding()
                .navigationTitle("选择日期").appNavigationStyle(inline: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDatePicker = false } } }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            .appSheetSize(width: 420, height: 390)
        }
        .onChange(of: model.accountGeneration) { _ in
            showDatePicker = false
            datePickerGeneration = nil
        }
    }

    private var dateControls: some View {
        VStack(spacing: 24) {
            HStack {
                Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.accessibilityLabel("上一周")
                Spacer()
                Text(SchoolDate.text(model.selectedDate, "yyyy 年 M 月")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button { shiftWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.accessibilityLabel("下一周")
            }
            WeekStrip(selectedDate: model.selectedDate, select: selectDate)
        }
        .appPageHorizontalPadding()
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .accessibilityIdentifier("schedule.dateControls")
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: SchoolDate.text(model.selectedDate, "M 月 d 日"), subtitle: "\(model.selectedCourses.count) 门课程")
            if model.isDemo {
                Label("演示课表 · 所有日期均为示例数据", systemImage: "sparkles")
                    .font(.system(size: 12)).foregroundStyle(Palette.green)
            }
            if model.isCached { CachedCoursesBanner(date: model.selectedDate) }
            if !model.isConnected {
                CompatibleContentUnavailableView("连接你的课堂", systemImage: "calendar", description: "登录后即可查询学校课表。") {
                    Button("连接学校账号") { model.presentLogin() }.buttonStyle(.borderedProminent).disabled(!model.canChangeAccount)
                }
            } else if model.isRefreshing(on: model.selectedDate) && model.selectedCourses.isEmpty {
                ProgressView("正在同步课程…").frame(maxWidth: .infinity).padding(40)
            } else if model.selectedCourses.isEmpty {
                CompatibleContentUnavailableView("这一天没有课程", systemImage: "cup.and.saucer", description: LocalizedStringKey(emptyScheduleDescription))
            } else {
                ForEach(Array(model.selectedCourses.enumerated()), id: \.element.id) { index, course in
                    CourseRow(course: course, index: index) { path.append(course) }
                }
            }
            if let notice = model.notice(on: model.selectedDate), !model.isCached { Text(notice).font(.caption).foregroundStyle(Palette.secondary) }
            if !SchoolDate.calendar.isDateInToday(model.selectedDate) {
                Button("回到今天") { selectDate(.now) }
                    .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding()
            }
        }
        .appPagePadding()
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    private var emptyScheduleDescription: String {
        #if os(macOS)
        "切换日期，或点击刷新按钮同步学校课表。"
        #else
        "切换日期，或下拉刷新学校课表。"
        #endif
    }

    private func shiftWeek(_ direction: Int) {
        guard let date = SchoolDate.calendar.date(byAdding: .day, value: direction * 7, to: model.selectedDate) else { return }
        selectDate(date)
    }

    private func selectDate(_ date: Date) {
        let generation = model.accountGeneration
        Task {
            guard generation == model.accountGeneration else { return }
            await model.selectDate(date)
        }
    }
}
