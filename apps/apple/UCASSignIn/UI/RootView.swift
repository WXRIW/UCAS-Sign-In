import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("appearanceMode") private var appearance = AppAppearance.system
    @Binding var selection: Int
    @State private var refreshTodayOnSelection = false
    @State private var todayPath: [Course] = []
    @State private var schedulePath: [Course] = []
    @State private var profilePath: [ProfileDestination] = []
    @State private var deferLoginPresentation = false
    @State private var pendingLogin: PendingLogin?
    @State private var presentedLogin: LoginRequest?
    @State private var presentedLoginID: UUID?

    private enum PendingLogin { case add, reauthenticate(String) }

    var body: some View {
        navigation
        .onChange(of: selection) { index in
            guard index == 0, refreshTodayOnSelection else { return }
            refreshTodayOnSelection = false
            Task { await model.refresh(on: .now) }
        }
        .onChange(of: model.accountGeneration) { _ in
            resetNavigation()
            model.showAccountManagement = false
        }
        .onChange(of: model.showSettings) { _ in openRequestedSettings() }
        .onChange(of: model.showAccountManagement) { presented in
            if presented { deferLoginPresentation = true }
        }
        .onChange(of: model.loginRequest?.id) { _ in synchronizeLoginPresentation() }
        .onAppear { synchronizeLoginPresentation(); openRequestedSettings() }
        .sheet(item: loginPresentation, onDismiss: finishLoginPresentation) { LoginView(request: $0) }
        .sheet(isPresented: accountManagementPresentation, onDismiss: finishAccountManagement) {
            AccountManagementView { accountID in
                pendingLogin = accountID.map(PendingLogin.reauthenticate) ?? .add
                model.showAccountManagement = false
            }
        }
        .alert("温馨提示", isPresented: Binding(get: { model.errorMessage != nil && model.loginRequest == nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .background { updateAlertHost }
        .preferredColorScheme(appearance.colorScheme)
        .onOpenURL { url in
            guard url.scheme == "ucas-signin" else { return }
            todayPath.removeAll()
            selectTab(0, refreshToday: true)
        }
        .task(id: scenePhase) {
            #if os(iOS)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.foregroundTick()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
            #endif
        }
    }

    private var updateAlertHost: some View {
        Color.clear.frame(width: 0, height: 0)
            .alert(item: $updates.presentation) { presentation in
                switch presentation {
                case .release(let release):
                    Alert(title: Text("检测到新版本"),
                          message: Text("果壳签到 \(release.version) 已发布，当前版本为 \(UpdateCoordinator.currentVersion)。"),
                          primaryButton: .default(Text("前往下载")) { openURL(release.url) },
                          secondaryButton: .cancel(Text("稍后")))
                case .current:
                    Alert(title: Text("已是最新版本"),
                          message: Text("当前版本 \(UpdateCoordinator.currentVersion) 已是最新的正式版本。"),
                          dismissButton: .default(Text("知道了")))
                case .failed:
                    Alert(title: Text("暂时无法检查更新"),
                          message: Text("请检查网络连接后重试，或直接前往 GitHub Releases 查看。"),
                          dismissButton: .default(Text("知道了")))
                }
            }
    }

    @ViewBuilder private var navigation: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: Binding<Int?>(get: { selection }, set: { if let value = $0 { selectTab(value) } })) {
                Label("今日", systemImage: "square.grid.2x2")
                    .tag(0).accessibilityIdentifier("mac.sidebar.today")
                Label("课表", systemImage: "calendar")
                    .tag(1).accessibilityIdentifier("mac.sidebar.schedule")
                Label("账户", systemImage: "person.crop.circle")
                    .tag(2).accessibilityIdentifier("mac.sidebar.profile")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    AccountMenu()
                    Divider()
                    Label("果壳签到", systemImage: "leaf.fill")
                        .font(.headline).foregroundStyle(Palette.green)
                    Text(model.isDemo ? "演示模式 · 示例课表" : "国科大轻新课堂")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            Group {
                switch selection {
                case 1: ScheduleView(path: activePath($schedulePath, for: 1), isActive: selection == 1)
                case 2: ProfileView(path: activePath($profilePath, for: 2))
                default: TodayView(path: activePath($todayPath, for: 0), isActive: selection == 0, openSchedule: { selectTab(1) })
                }
            }
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 620)
        #else
        TabView(selection: $selection) {
            TodayView(path: $todayPath, isActive: selection == 0, openSchedule: { selectTab(1) })
                .tabItem { Label("今日", systemImage: "square.grid.2x2") }
                .tag(0)
            ScheduleView(path: $schedulePath, isActive: selection == 1)
                .tabItem { Label("课表", systemImage: "calendar") }
                .tag(1)
            ProfileView(path: $profilePath)
                .tabItem { Label("账户", systemImage: "person.crop.circle") }
                .tag(2)
        }
        #endif
    }

    #if os(macOS)
    // NavigationSplitView resets its outgoing stack when the sidebar selection changes.
    // Keep that teardown write from erasing the inactive section's saved path.
    private func activePath<Value>(_ path: Binding<[Value]>, for index: Int) -> Binding<[Value]> {
        Binding(get: { path.wrappedValue }, set: { value in
            guard selection == index else { return }
            path.wrappedValue = value
        })
    }
    #endif

    private func resetNavigation() {
        refreshTodayOnSelection = false
        todayPath.removeAll()
        schedulePath.removeAll()
        profilePath.removeAll()
    }

    private func openRequestedSettings() {
        guard model.showSettings else { return }
        selection = 2
        profilePath = [.settings]
        model.showSettings = false
    }

    private var loginPresentation: Binding<LoginRequest?> {
        let presentationID = presentedLoginID
        return Binding(get: { presentedLogin }, set: { value in
            // A dismissed sheet may only clear the request it actually presented.
            guard presentedLoginID == presentationID else { return }
            presentedLogin = value
            if value == nil, model.loginRequest?.id == presentationID {
                model.loginRequest = nil
            }
        })
    }

    private var accountManagementPresentation: Binding<Bool> {
        Binding(get: { model.showAccountManagement && presentedLoginID == nil }, set: { presented in
            guard presentedLoginID == nil else { return }
            model.showAccountManagement = presented
        })
    }

    private func synchronizeLoginPresentation() {
        if let presentationID = presentedLoginID {
            // Keep the old ID through dismissal, and queue any replacement in the model.
            if model.loginRequest?.id != presentationID { presentedLogin = nil }
            return
        }
        guard !model.showAccountManagement, !deferLoginPresentation,
              let request = model.loginRequest else { return }
        presentedLoginID = request.id
        presentedLogin = request
    }

    private func finishLoginPresentation() {
        let dismissedID = presentedLoginID
        presentedLogin = nil
        presentedLoginID = nil
        if model.loginRequest?.id == dismissedID { model.loginRequest = nil }
        synchronizeLoginPresentation()
    }

    private func finishAccountManagement() {
        deferLoginPresentation = false
        guard let request = pendingLogin else {
            synchronizeLoginPresentation()
            return
        }
        pendingLogin = nil
        switch request {
        case .add: model.presentLogin()
        case .reauthenticate(let accountID): model.presentLogin(accountID: accountID)
        }
        synchronizeLoginPresentation()
    }

    private func selectTab(_ index: Int, refreshToday: Bool = false) {
        if index == 0, refreshToday {
            if selection == 0 {
                Task { await model.refresh(on: .now) }
            } else {
                refreshTodayOnSelection = true
            }
        }
        selection = index
    }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [Course]
    let isActive: Bool
    var openSchedule: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    introduction
                    if model.isConnected {
                        if model.isDemo { demoBanner }
                        if model.isCached(on: .now) { CachedCoursesBanner(date: .now) }
                        if let course = model.featuredCourse {
                            FeaturedCourseCard(course: course, accountGeneration: model.accountGeneration, openDetail: { path.append(course) })
                                .id(model.accountGeneration)
                        } else if model.todayCourses.isEmpty {
                            emptyDay
                        }
                        progressCard
                        courseList
                        if let notice = model.notice(on: .now), !model.isCached(on: .now) {
                            Label(notice, systemImage: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else { welcomeCard }
                    HStack(spacing: 6) {
                        Image(systemName: "leaf").font(.system(size: 11))
                        Text("专注课堂，把琐事交给果壳").font(.system(size: 11)).tracking(1)
                    }.foregroundStyle(Palette.secondary.opacity(0.75))
                        .frame(maxWidth: .infinity).padding(.top, 3).padding(.bottom, 16)
                }.appPageHorizontalPadding().padding(.top, 17)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("today.scroll")
            .background(Palette.background)
            .navigationTitle("果壳签到")
            .appNavigationStyle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { brandMark }
                ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
                #endif
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    CourseRefreshButton(title: "刷新课程", isRefreshing: model.isRefreshing(on: .now),
                                        isConnected: model.isConnected,
                                        refresh: { await model.refresh(on: .now) })
                        .id(SchoolDate.key(.now))
                        .accessibilityIdentifier("today.refresh")
                }
                #endif
            }
            .courseRefreshable(enabled: model.isConnected) { await model.refresh(on: .now) }
            .navigationDestination(for: Course.self) { course in
                CourseDetailView(course: course, isActive: isActive, accountGeneration: model.accountGeneration)
            }
        }
    }

    private var brandMark: some View {
        HStack(spacing: 6) {
            Image("BrandIcon").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Palette.green).accessibilityHidden(true)
            Text("UCAS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Palette.secondary)
        }
        // iOS 26 sizes the Liquid Glass toolbar platter from this intrinsic width.
        // Refuse the compact proposal so the wordmark expands the platter instead of wrapping.
        .fixedSize(horizontal: true, vertical: false)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(SchoolDate.text(.now, "M 月 d 日 · EEEE"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("今天，").foregroundStyle(Palette.ink)
                Text("从容一点。").foregroundStyle(Palette.green)
            }.font(.system(size: 30, weight: .bold, design: .serif)).minimumScaleFactor(0.7).lineLimit(1)
            Text(model.isConnected ? "课表、签到，都在这里。" : "你的国科大课堂，轻松相伴。")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
        }
    }
    private var demoBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
            Text("演示模式").fontWeight(.medium)
            Text("· 示例课表").foregroundStyle(Palette.secondary)
            Spacer()
            Button("连接账号") { model.presentLogin() }.fontWeight(.semibold).disabled(!model.canChangeAccount)
        }.font(.system(size: 11)).foregroundStyle(Palette.green)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Palette.pale, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, -10).padding(.bottom, -10)
    }
    private var progressCard: some View {
        HStack(spacing: 0) {
            metric("今日课程", value: "\(model.todayCourses.count)", unit: "门")
            Rectangle().fill(Palette.line).frame(width: 1, height: 30)
            metric("已签到", value: "\(model.todaySignedCount)", unit: "门")
            Spacer(minLength: 12)
            ZStack {
                Circle().stroke(Palette.pale, lineWidth: 5)
                Circle().trim(from: 0, to: model.todayCourses.isEmpty ? 0 : CGFloat(model.todaySignedCount) / CGFloat(model.todayCourses.count))
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.green)
            }.frame(width: 42, height: 42).padding(.trailing, 21).accessibilityLabel("已完成 \(model.todaySignedCount) 门签到")
        }.padding(.vertical, 18).cardSurface()
    }
    private func metric(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                Text(unit).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
    }
    private var courseList: some View {
        VStack(spacing: 16) {
            HStack {
                SectionHeading(title: "今日安排")
                Button(action: openSchedule) {
                    HStack(spacing: 4) { Text("查看课表"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green)
                }.buttonStyle(.plain).fixedSize()
            }
            ForEach(Array(model.todayCourses.enumerated()), id: \.element.id) { index, course in
                CourseRow(course: course, index: index) { path.append(course) }
            }
            if let updated = model.lastUpdated(on: .now) {
                HStack(spacing: 4) {
                    Circle().fill(model.isCached(on: .now) ? Color.orange : Palette.green.opacity(0.6)).frame(width: 4, height: 4)
                    Text(model.isDemo ? "示例数据，仅供体验" : "\(model.isCached(on: .now) ? "缓存更新于" : "同步于") \(SchoolDate.text(updated, "HH:mm")) · \(refreshHint)")
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }
    }
    private var emptyDay: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.horizon").font(.system(size: 35, weight: .light)).foregroundStyle(Palette.green)
            Text(model.isRefreshing(on: .now) ? "正在整理你的课表" : "留一点时间给自己").font(.headline).foregroundStyle(Palette.ink)
            Text(model.isRefreshing(on: .now) ? "正在与学校同步课程…" : "今天暂无课程，\(refreshHint)即可重新同步。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 30).cardSurface()
    }
    private var refreshHint: String {
        #if os(macOS)
        "点击刷新按钮"
        #else
        "下拉刷新"
        #endif
    }
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "book.closed").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.green)
            Text("一堂课，也不匆忙。").font(.system(size: 25, weight: .bold, design: .serif)).foregroundStyle(Palette.ink)
            Text("连接账户，查看当天课程、完成签到，\n让每一次到课都井井有条。")
                .font(.system(size: 14)).lineSpacing(7).foregroundStyle(Palette.secondary)
            PrimaryButton(title: "连接账户") { model.presentLogin() }.disabled(!model.canChangeAccount)
            Button("先体验一下 →") { model.enterDemo() }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.green).frame(maxWidth: .infinity)
                .disabled(!model.canChangeAccount)
        }.padding(24).cardSurface()
    }
}

struct WeekStrip: View {
    let selectedDate: Date
    var select: (Date) -> Void
    var body: some View {
        HStack(spacing: 5) {
            ForEach(SchoolDate.week(containing: selectedDate), id: \.self) { date in
                let selected = SchoolDate.calendar.isDate(date, inSameDayAs: selectedDate)
                Button { select(date) } label: {
                    VStack(spacing: 10) {
                        Text(SchoolDate.text(date, "EEEEE")).font(.system(size: 10, weight: .medium))
                        Text(SchoolDate.text(date, "d")).font(.system(size: 18, weight: .semibold, design: .rounded))
                        Circle().fill(selected ? Palette.accent : .clear).frame(width: 4, height: 4)
                    }.foregroundStyle(selected ? .white : Palette.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 9)
                        .background(selected ? Palette.hero : .clear, in: RoundedRectangle(cornerRadius: 17))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(SchoolDate.text(date, "M月d日 EEEE"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct FeaturedCourseCard: View {
    @EnvironmentObject private var model: AppModel
    let course: Course
    let accountGeneration: UUID
    var openDetail: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                    Text(course.signed ? "到课已记录" : CourseTime.isInProgress(course, now: .now) ? "正在上课，专注当下" : "下一堂，准备就绪").tracking(1)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                Spacer()
            }
            Text(course.name).font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                .padding(.top, 22).padding(.bottom, 12)
            Label(course.timeRange, systemImage: "clock")
                .labelStyle(CourseMetadataLabelStyle())
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.68))
            CourseMetadataView(course: course)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.68))
                .padding(.top, 9)
            HStack(spacing: 10) {
                Button { Task { await model.sign(course, accountGeneration: accountGeneration) } } label: {
                    HStack(spacing: 7) {
                        if model.signingID == course.id { ProgressView().tint(Palette.hero) }
                        else { Image(systemName: course.signed ? "checkmark.circle.fill" : "checkmark.circle").font(.system(size: 17)) }
                        Text(course.signed ? "已完成签到" : "一键签到").font(.system(size: 14, weight: .semibold))
                    }.foregroundStyle(Palette.hero).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).disabled(!model.canSign(course, accountGeneration: accountGeneration))
                Button(action: openDetail) {
                    Image(systemName: "qrcode").font(.system(size: 21)).foregroundStyle(.white)
                        .frame(width: 49, height: 47).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).accessibilityLabel("查看课程和签到二维码")
            }.padding(.top, 24)
        }.padding(23)
            .background(alignment: .trailing) {
                ZStack {
                    Palette.hero
                    Image(systemName: "leaf").font(.system(size: 150, weight: .ultraLight))
                        .rotationEffect(.degrees(-25)).foregroundStyle(.white.opacity(0.04)).offset(x: 115, y: -6)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 25))
    }
}

struct CourseRow: View {
    let course: Course
    let index: Int
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 5) {
                    Text(course.startDate.map { SchoolDate.text($0, "HH:mm") } ?? "待定")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                    Text(course.endDate.map { SchoolDate.text($0, "HH:mm") } ?? "—")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.secondary)
                }.frame(width: 39).padding(.top, 20)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(course.signed ? Palette.line : Palette.green.opacity(0.6)).frame(width: 3, height: 38)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(course.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                        CourseMetadataView(course: course)
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 11) {
                        StatusPill(title: course.signed ? "已签到" : "未签到", symbol: course.signed ? "checkmark" : nil,
                                   tint: course.signed ? Palette.secondary : Palette.green)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary.opacity(0.7))
                    }
                }.padding(.vertical, 17).padding(.horizontal, 13).cardSurface()
            }
        }.buttonStyle(.plain)
    }
}
