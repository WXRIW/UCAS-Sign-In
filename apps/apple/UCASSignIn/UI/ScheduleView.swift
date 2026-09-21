import SwiftUI

enum ScheduleDestination: Hashable {
    case signIn(Course)
    case course(Course)
}

struct ScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [ScheduleDestination]
    let isActive: Bool
    @State private var showDatePicker = false
    @State private var datePickerGeneration: UUID?
    @State private var dateControlsHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var modePickerWidth: CGFloat = 104

    private var pinsDateHeaders: Bool {
        #if os(iOS) && compiler(>=6.2)
        return false
        #else
        return true
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: pinsDateHeaders ? [.sectionHeaders] : []) {
                    Section {
                        activeContent
                    } header: {
                        dateControls
                    }
                }
            }
            .coordinateSpace(name: "schedule.scroll")
            .onPreferenceChange(ScheduleDateControlsHeight.self) { dateControlsHeight = $0 }
            .accessibilityIdentifier("schedule.scroll")
            .background(Palette.background)
            .courseRefreshable(enabled: model.isConnected) { await model.refreshSchedule() }
            .navigationTitle("课表")
            .appNavigationStyle()
            .navigationDestination(for: ScheduleDestination.self) { destination in
                switch destination {
                case .signIn(let course):
                    CourseDetailView(course: course, isActive: isActive, accountGeneration: model.accountGeneration)
                case .course(let course):
                    ScheduleCatalogCourseView(scheduledCourse: course)
                }
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
                    CourseRefreshButton(title: "刷新课表", isRefreshing: model.isScheduleRefreshing,
                                        isConnected: model.isConnected, refresh: { await model.refreshSchedule() })
                        .id(SchoolDate.key(model.selectedDate))
                        .accessibilityIdentifier("schedule.refresh")
                }
                #endif
            }
        }
        .task(id: "\(isActive)-\(model.accountGeneration)-\(model.scheduleMode.rawValue)") {
            if isActive {
                await model.openScheduleDate(model.selectedDate)
                await model.refreshCatalog()
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
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    monthNavigation
                    modePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    monthNavigation
                    modePicker.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if model.isConnected && hasSynchronizationStatus { synchronizationStatus }
            if model.scheduleMode == .day {
                WeekStrip(selectedDate: model.selectedDate, select: selectDate)
            }
        }
        .appPageHorizontalPadding()
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ScheduleDateControlsHeight.self, value: geometry.size.height)
            }
        }
    }

    private var monthNavigation: some View {
        HStack {
            Button { shiftWeek(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("上一周")
            Spacer(minLength: 0)
            Text(SchoolDate.text(model.selectedDate, "yyyy 年 M 月"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Button { shiftWeek(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("下一周")
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    private var modePicker: some View {
        Picker("课表视图", selection: $model.scheduleMode) {
            Text("日").tag(ScheduleMode.day)
            Text("周").tag(ScheduleMode.week)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: modePickerWidth)
        .accessibilityIdentifier("schedule.mode")
    }

    @ViewBuilder
    private var activeContent: some View {
        if model.scheduleMode == .week && model.isConnected {
            VStack(spacing: 16) {
                if model.isDemo {
                    Label("演示课表 · 所有日期均为示例数据", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(Palette.green)
                }
                VStack(spacing: 8) {
                    WeekScheduleView(pinnedHeaderTop: pinsDateHeaders ? dateControlsHeight : nil,
                                     selectDate: selectDate) { path.append(.course($0)) }
                    if SchoolDate.week(containing: model.selectedDate).first != SchoolDate.week(containing: .now).first {
                        Button("回到本周") { selectDate(.now) }.buttonStyle(.bordered)
                    }
                    synchronizationFooter
                }
            }.padding(.vertical)
        } else {
            scheduleContent
        }
    }

    private var hasSynchronizationStatus: Bool {
        guard model.scheduleMode == .week else { return false }
        if model.isScheduleRefreshing {
            return model.isSemesterSyncing && !model.scheduleSyncProgress.isEmpty
        }
        return model.scheduleSyncError != nil || SchoolDate.week(containing: model.selectedDate).contains {
            model.scheduleDayErrors[SchoolDate.key($0)] != nil
        }
    }

    private var synchronizationStatus: some View {
        Group {
            if model.isScheduleRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.scheduleSyncProgress).font(.caption2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("schedule.syncDetail")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = model.scheduleSyncError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试完整同步") { Task { await model.synchronizeSchedules(force: true) } }
                        .buttonStyle(.bordered)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("本周部分日期未能同步，已保留可用缓存。", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试本周") { Task { await model.refreshSchedule() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var synchronizationFooter: some View {
        Group {
            if let date = model.scheduleUpdatedAt(on: model.selectedDate) {
                Text("刷新于 \(SchoolDate.text(date, "yyyy年M月d日 HH:mm"))")
            } else {
                Text("尚未完成完整同步")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(.horizontal)
        .accessibilityIdentifier("schedule.updatedAt")
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: SchoolDate.text(model.selectedDate, "M 月 d 日"), subtitle: "\(model.selectedCourses.count) 门课程")
            if model.isDemo {
                Label("演示课表 · 所有日期均为示例数据", systemImage: "sparkles")
                    .font(.system(size: 12)).foregroundStyle(Palette.green)
            }
            if model.isCached && model.scheduleDayErrors[SchoolDate.key(model.selectedDate)] != nil {
                CachedCoursesBanner(date: model.selectedDate)
            }
            if !model.isConnected {
                CompatibleContentUnavailableView("连接你的课堂", systemImage: "calendar", description: "登录后即可查询学校课表。") {
                    Button("连接账户") { model.presentLogin() }.buttonStyle(.borderedProminent).disabled(!model.canChangeAccount)
                }
            } else if model.isRefreshing(on: model.selectedDate) && model.selectedCourses.isEmpty {
                ProgressView("正在同步课程…").frame(maxWidth: .infinity).padding(40)
            } else if let error = model.scheduleDayErrors[SchoolDate.key(model.selectedDate)], model.selectedCourses.isEmpty {
                CompatibleContentUnavailableView("课程暂未同步", systemImage: "exclamationmark.icloud", description: LocalizedStringKey(error)) {
                    Button("重试") { Task { await model.refreshSchedule() } }.buttonStyle(.bordered)
                }
            } else if model.selectedCourses.isEmpty && !model.hasSchedule(on: model.selectedDate) {
                ProgressView("正在同步课程…").frame(maxWidth: .infinity).padding(40)
            } else if model.selectedCourses.isEmpty {
                CompatibleContentUnavailableView("这一天没有课程", systemImage: "cup.and.saucer", description: LocalizedStringKey(emptyScheduleDescription))
            } else {
                ForEach(Array(model.selectedCourses.enumerated()), id: \.element.id) { index, course in
                    CourseRow(course: course, index: index) { path.append(.signIn(course)) }
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

private struct ScheduleDateControlsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ScheduleCatalogCourseView: View {
    @EnvironmentObject private var model: AppModel
    let scheduledCourse: Course

    var body: some View {
        let course = model.catalogCourse(for: scheduledCourse)
        CatalogCourseDetailView(course: course, initialPreferences: model.coursePreferences(for: course.id))
            .id(course.id)
            .task { await model.refreshCatalog() }
    }
}
