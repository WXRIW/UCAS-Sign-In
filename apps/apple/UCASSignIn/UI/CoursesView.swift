import SwiftUI

struct CoursesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: [CatalogCourse]
    @State private var searchText = ""

    private var filteredCourses: [CatalogCourse] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.catalogCourses }
        return model.catalogCourses.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.number.localizedCaseInsensitiveContains(query) ||
            $0.teacher.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            catalogContent
            .accessibilityIdentifier("courses.scroll")
            .background(Palette.background)
            .navigationTitle("课程")
            .appNavigationStyle()
            .courseCatalogSearch(text: $searchText)
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    CourseRefreshButton(title: "刷新课程目录", isRefreshing: model.isCatalogRefreshing,
                                        isConnected: model.isConnected) {
                        await model.refreshCatalog(force: true)
                    }
                    .accessibilityIdentifier("courses.refresh")
                }
                #endif
            }
            .courseRefreshable(enabled: model.isConnected) { await model.refreshCatalog(force: true) }
            .navigationDestination(for: CatalogCourse.self) {
                CatalogCourseDetailView(course: $0, initialPreferences: model.coursePreferences(for: $0.id))
            }
            .task { await model.refreshCatalog() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.refreshCatalog()
            }
        }
    }

    @ViewBuilder
    private var catalogContent: some View {
        #if os(iOS)
        // Use List's native refresh lifecycle so the refresh inset and scroll position
        // belong to the same container, including while the search drawer changes size.
        List {
            catalogRow(top: 12, bottom: 18) { header }
            if !model.isConnected {
                catalogRow { disconnected }
            } else if model.isCatalogRefreshing && model.catalogCourses.isEmpty {
                catalogRow { loading }
            } else if model.catalogCourses.isEmpty {
                catalogRow { empty }
            } else if filteredCourses.isEmpty {
                catalogRow { noMatches }
            } else {
                ForEach(filteredCourses) { course in
                    catalogRow {
                        // Keep the existing card's chevron and full-width hit area.
                        Button { path.append(course) } label: { CatalogCourseRow(course: course) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.isConnected { disconnected }
                else if model.isCatalogRefreshing && model.catalogCourses.isEmpty { loading }
                else if model.catalogCourses.isEmpty { empty }
                else { courseList }
            }
            .appPageHorizontalPadding()
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        #endif
    }

    #if os(iOS)
    private func catalogRow<Content: View>(top: CGFloat = 0, bottom: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        content()
            .appPageHorizontalPadding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
    #endif

    private var noMatches: some View {
        Text("没有匹配的课程").font(.system(size: 14)).foregroundStyle(Palette.secondary).padding(.vertical, 36)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selectedSemester?.name ?? (model.isConnected ? "正在确定当前学期" : "连接账户后查看完整课程"))
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.ink)
            HStack(spacing: 6) {
                if model.isCatalogRefreshing { ProgressView().controlSize(.small) }
                if let updated = model.catalogUpdatedAt {
                    Text("\(model.catalogIsCached ? "缓存更新于" : "同步于") \(SchoolDate.text(updated, "M月d日 HH:mm"))")
                } else { Text("课程目录与课表分别同步") }
            }
            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("courses.syncStatus")
            .accessibilityValue(model.isCatalogRefreshing ? "正在刷新" :
                model.catalogUpdatedAt.map { SchoolDate.text($0, "M月d日 HH:mm:ss") } ?? "尚未同步")
            if let error = model.catalogError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var courseList: some View {
        LazyVStack(spacing: 12) {
            if filteredCourses.isEmpty {
                noMatches
            }
            ForEach(filteredCourses) { course in
                NavigationLink(value: course) { CatalogCourseRow(course: course) }.buttonStyle(.plain)
            }
        }
    }

    private var disconnected: some View {
        EmptyCoursesCard(symbol: "person.crop.circle.badge.exclamationmark", title: "尚未连接学校账户",
                         message: "连接账户后即可查看当前学期的全部课程。")
    }
    private var loading: some View {
        VStack(spacing: 12) { ProgressView(); Text("正在同步课程目录…") }
            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 50).cardSurface()
    }
    private var empty: some View {
        EmptyCoursesCard(symbol: "books.vertical", title: model.catalogError == nil ? "本学期暂无课程" : "课程目录暂不可用",
                         message: model.catalogError ?? "学校没有返回当前学期的课程。")
    }
}

private extension View {
    @ViewBuilder
    func courseCatalogSearch(text: Binding<String>) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic),
                   prompt: "课程名、课程编号或教师")
        #else
        searchable(text: text, prompt: "课程名、课程编号或教师")
        #endif
    }
}

private struct CatalogCourseRow: View {
    @EnvironmentObject private var model: AppModel
    let course: CatalogCourse
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "book.closed.fill").font(.system(size: 17)).foregroundStyle(Palette.green)
                .frame(width: 42, height: 42).background(Palette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(course.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(course.number.isEmpty ? "课程编号暂未提供" : course.number)
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                HStack(spacing: 14) {
                    status("提醒", enabled: model.effectiveReminders(for: course.id))
                    if model.isSignInDisabled(for: course.id) {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle")
                            Text("已禁用签到")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                    } else {
                        status("二次确认", enabled: model.effectiveConfirmation(for: course.id))
                        status("自动签到", enabled: model.effectiveAutoSign(for: course.id))
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
        }.padding(16).cardSurface()
    }
    private func status(_ title: String, enabled: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(enabled ? Palette.green : Palette.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyCoursesCard: View {
    let symbol: String; let title: String; let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(Palette.green)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(message).font(.system(size: 13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 42).padding(.horizontal, 20).cardSurface()
    }
}

struct CatalogCourseDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let course: CatalogCourse
    @State private var preferences = CoursePreferences()
    @State private var preferencesLoaded = false

    init(course: CatalogCourse, initialPreferences: CoursePreferences) {
        self.course = course
        _preferences = State(initialValue: initialPreferences)
        _preferencesLoaded = State(initialValue: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                courseSection("课程信息") { identityContent }
                courseSection("通知") { notificationSettingsContent }
                courseSection("签到") { signInSettingsContent }
                courseSection("学校考勤", footer: attendanceFooter) { attendanceContent }
                courseSection("本机操作记录", footer: "这些记录来自本机操作，不代表学校最终考勤状态。") {
                    localRecordsContent
                }
            }
            .appPagePadding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("catalogCourseDetail.scroll")
        .background(Palette.background)
        .navigationTitle(course.name).appNavigationStyle(inline: true)
        .onAppear {
            #if os(macOS)
            model.visibleCatalogCourseId = course.id
            #endif
        }
        .onDisappear {
            #if os(macOS)
            if model.visibleCatalogCourseId == course.id { model.visibleCatalogCourseId = nil }
            #endif
        }
        .onChange(of: preferences) { value in
            guard preferencesLoaded else { return }
            Task {
                if !(await model.setCoursePreferences(value, for: course.id)), preferences == value {
                    preferencesLoaded = false
                    preferences = model.coursePreferences(for: course.id)
                    preferencesLoaded = true
                }
            }
        }
        .task { await model.refreshAttendance(for: course.id) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshAttendance(for: course.id)
        }
    }

    private func courseSection<Content: View>(_ title: String, footer: String? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(PreferenceTypography.section)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
                .cardSurface()
            if let footer {
                Text(footer)
                    .font(PreferenceTypography.detail)
                    .lineSpacing(4)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PreferenceRowLayout.horizontalPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            detailRow("课程编号", course.number.isEmpty ? "暂未提供" : course.number, symbol: "number")
            detailRow("教师", course.teacher.isEmpty ? "暂未提供" : course.teacher, symbol: "person")
            detailRow("教室", course.classroom ?? "暂未提供", symbol: "location")
            detailRow("学期", model.selectedSemester?.name ?? "当前学期", symbol: "calendar")
            detailRow("课程日期", dateRange, symbol: "calendar.badge.clock")
        }
        .padding(.vertical, 18)
    }

    private var notificationSettingsContent: some View {
        VStack(spacing: 0) {
            preferencePicker("课前提醒", symbol: "bell", description: "在上课前发送本地通知",
                             selection: $preferences.reminders, inherited: model.remindersEnabled)
            if resolvedReminders {
                PreferenceDivider()
                reminderTimeRow
            }
        }
        .tint(Palette.green)
    }

    private var signInSettingsContent: some View {
        VStack(spacing: 0) {
            if !preferences.signInDisabled {
                preferencePicker("手动签到二次确认", symbol: "questionmark.circle",
                                 description: "手动签到前显示课程与上课时间",
                                 selection: $preferences.confirmation, inherited: model.confirmationEnabled)
                PreferenceDivider()
                preferencePicker("自动签到", symbol: "checkmark.circle", description: automaticSignDescription,
                                 selection: $preferences.autoSign, inherited: model.autoSignEnabled)
                PreferenceDivider()
            }
            Toggle(isOn: $preferences.signInDisabled) {
                HStack(spacing: PreferenceRowLayout.spacing) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 17)).foregroundStyle(Palette.green)
                        .frame(width: PreferenceRowLayout.iconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("禁用本课程签到")
                            .font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Text("暂停本课程的手动签到和自动签到")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .tint(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .accessibilityIdentifier("coursePreference.signInDisabled")
        }
        .tint(Palette.green)
    }

    private var reminderTimeRow: some View {
        HStack(spacing: PreferenceRowLayout.spacing) {
            Image(systemName: "clock")
                .font(.system(size: 17))
                .foregroundStyle(Palette.green)
                .frame(width: PreferenceRowLayout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("提醒时间").font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text("当前为课前 \(resolvedReminderLead) 分钟")
                    .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            Picker("提醒时间", selection: $preferences.reminderLeadMinutes) {
                Text("跟随全局").tag(Int?.none)
                ForEach(AccountPreferences.validLeadTimes, id: \.self) { Text("\($0) 分钟").tag(Int?.some($0)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(PreferenceTypography.body)
            #if os(macOS)
            .frame(width: 160, alignment: .trailing)
            #else
            .fixedSize()
            #endif
        }
        .padding(.vertical, 18)
    }

    private var attendanceContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: PreferenceRowLayout.spacing) {
                Image(systemName: "building.columns")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.green)
                    .frame(width: PreferenceRowLayout.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("考勤统计与明细").font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("学校记录的签到次数及每次上课的签到状态").font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 12)
                CourseRefreshButton(title: "刷新", isRefreshing: model.attendanceRefreshing.contains(course.id),
                                    isConnected: model.isConnected, showsTitle: true) {
                    await model.refreshAttendance(for: course.id, force: true)
                }
                .accessibilityIdentifier("courseDetail.refreshAttendance")
            }
            .padding(.top, 18)
            .padding(.bottom, model.attendanceByCourse[course.id] != nil ? 12 : 18)
            if let summary = model.attendanceByCourse[course.id] {
                HStack(spacing: 10) {
                    metric("已签到", summary.signedCount, Palette.green)
                    metric("未签到", summary.unsignedCount, Palette.secondary)
                }
                .padding(.bottom, 16)
                ForEach(summary.records.sorted { $0.day > $1.day }) { record in
                    attendanceDivider
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(formattedDay(record.day)).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                            Text("\(CourseTime.display(record.beginTime))–\(CourseTime.display(record.endTime))")
                                .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 12)
                        Label(record.signed ? "已签到" : "未签到", systemImage: record.signed ? "checkmark.circle.fill" : "xmark.circle")
                            .font(PreferenceTypography.detail.weight(.medium))
                            .foregroundStyle(record.signed ? Palette.green : Palette.secondary)
                    }
                    .padding(.vertical, 16)
                }
            } else if let error = model.attendanceErrors[course.id] {
                attendanceDivider
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(PreferenceTypography.detail)
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 18)
            } else {
                attendanceDivider
                Text("暂无学校考勤记录")
                    .font(PreferenceTypography.detail)
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 18)
            }
        }
    }

    private var attendanceDivider: some View {
        Rectangle().fill(Palette.line).frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private var localRecordsContent: some View {
        let records = model.records.filter {
            $0.courseId.map { $0 == course.id } ?? ($0.courseName == course.name)
        }.prefix(20)
        return VStack(spacing: 0) {
            if records.isEmpty {
                Text("本机尚无这门课程的签到操作记录")
                    .font(PreferenceTypography.detail)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(records)) { record in
                    if record.id != records.first?.id { PreferenceDivider() }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.message).font(PreferenceTypography.body).foregroundStyle(Palette.ink)
                            Text(SchoolDate.text(record.date, "M月d日 HH:mm"))
                                .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(record.succeeded ? Palette.green : Palette.secondary)
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private func preferencePicker(_ title: String, symbol: String, description: String,
                                  selection: Binding<PreferenceOverride>, inherited: Bool) -> some View {
        HStack(spacing: PreferenceRowLayout.spacing) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Palette.green)
                .frame(width: PreferenceRowLayout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text(description).font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                preferenceChoice("跟随全局", enabled: inherited).tag(PreferenceOverride.inherit)
                preferenceChoice("启用", enabled: true).tag(PreferenceOverride.enabled)
                preferenceChoice("停用", enabled: false).tag(PreferenceOverride.disabled)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(PreferenceTypography.body)
            #if os(macOS)
            .frame(width: 160, alignment: .trailing)
            #else
            .fixedSize()
            #endif
        }
        .padding(.vertical, 18)
    }

    private func preferenceChoice(_ title: String, enabled: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            // Native picker menus otherwise treat SF Symbols as tinted templates.
            // Original-color assets keep the small status dot green/red in both
            // the selected value and the menu, independently of the app accent.
            Image(enabled ? "PreferenceEnabled" : "PreferenceDisabled")
                .renderingMode(.original)
        }
    }

    private func detailRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(PreferenceTypography.detail)
                .foregroundStyle(Palette.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value).font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resolvedReminders: Bool {
        preferences.reminders.resolve(default: model.remindersEnabled)
    }
    private var resolvedReminderLead: Int {
        guard let lead = preferences.reminderLeadMinutes,
              AccountPreferences.validLeadTimes.contains(lead) else { return model.reminderLeadMinutes }
        return lead
    }
    private var automaticSignDescription: String {
        #if os(macOS)
        "进入签到时段后自动尝试一次"
        #else
        "App 在前台时，进入签到时段后自动尝试一次"
        #endif
    }

    private func metric(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
            Text(title).font(PreferenceTypography.caption).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var attendanceFooter: String {
        if let updated = model.attendanceUpdatedAt[course.id] {
            return "学校数据同步于 \(SchoolDate.text(updated, "M月d日 HH:mm"))。"
        }
        return "考勤数据来自学校接口，进入页面后按缓存有效期自动更新，也可手动刷新。"
    }

    private var dateRange: String {
        let begin = formattedDay(course.beginDate), end = formattedDay(course.endDate)
        return begin == "—" || end == "—" ? "暂未提供" : "\(begin)–\(end)"
    }
    private func formattedDay(_ day: String) -> String {
        CourseTime.parse(day: day, time: "00:00").map { SchoolDate.text($0, "yyyy年M月d日") } ?? "—"
    }
}
