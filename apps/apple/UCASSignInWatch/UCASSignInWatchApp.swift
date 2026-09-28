import SwiftUI
import WatchConnectivity

@main
struct UCASSignInWatchApp: App {
    @StateObject private var bridge = WatchBridge()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
                .environmentObject(bridge)
                .task { bridge.setForeground(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    bridge.setForeground(phase == .active)
                }
        }
    }
}

@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var signingID: String?
    @Published var resultMessage: String?

    private let cacheKey = "watch.today.snapshot.v1"
    private var isForeground = false
    private var refreshWhenActive = false
    private var pendingRefreshDay: String?
    private var currentRefreshID: UUID?
    private var hasQueuedRefresh = false
    private var queuedRefreshDay: String?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: cacheKey) {
            snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
        } else {
            connectionMessage = "此设备无法连接 iPhone"
        }
    }

    var isTodaySnapshot: Bool {
        snapshot.map { Calendar.current.isDateInToday($0.updatedAt) } ?? false
    }

    func setForeground(_ active: Bool) {
        guard isForeground != active else { return }
        isForeground = active
        if active {
            refresh()
        } else {
            refreshWhenActive = false
            pendingRefreshDay = nil
            currentRefreshID = nil
            hasQueuedRefresh = false
            queuedRefreshDay = nil
            signingID = nil
        }
    }

    func refresh(day: String? = nil) {
        guard isForeground, WCSession.isSupported() else { return }
        guard WCSession.default.activationState == .activated else {
            refreshWhenActive = true
            pendingRefreshDay = day
            if WCSession.default.activationState == .notActivated {
                WCSession.default.activate()
            }
            return
        }
        if currentRefreshID != nil {
            if day != nil {
                hasQueuedRefresh = true
                queuedRefreshDay = day
            }
            return
        }
        let refreshID = UUID()
        currentRefreshID = refreshID
        let request: [String: Any] = day.map { ["kind": "day", "day": $0] } ?? ["kind": "refresh"]
        WCSession.default.sendMessage(request, replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard self?.currentRefreshID == refreshID else { return }
                self?.receive(reply)
                self?.finishRefresh()
            }
        }, errorHandler: { [weak self] error in
            let code = (error as NSError).code
            Task { @MainActor in
                guard self?.currentRefreshID == refreshID else { return }
                self?.connectionMessage = "暂时无法连接 iPhone（错误 \(code)），显示上次同步的课程"
                self?.finishRefresh()
            }
        })
    }

    private func finishRefresh() {
        currentRefreshID = nil
        guard isForeground, hasQueuedRefresh else { return }
        let day = queuedRefreshDay
        hasQueuedRefresh = false
        queuedRefreshDay = nil
        refresh(day: day)
    }

    func sign(_ course: WatchCourse) {
        guard isForeground, let snapshot, isTodaySnapshot, signingID == nil else { return }
        guard WCSession.default.activationState == .activated else {
            resultMessage = "正在连接 iPhone，请稍后重试"
            return
        }
        signingID = course.id
        WCSession.default.sendMessage([
            "kind": "sign", "courseID": course.id, "day": course.day,
            "generation": snapshot.accountGeneration
        ], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.signingID = nil
                self?.receive(reply)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.signingID = nil
                self?.resultMessage = "无法确认签到结果，请先刷新课程状态，不要直接重试"
            }
        })
    }

    private func receive(_ reply: [String: Any]) {
        guard isForeground else { return }
        if let error = reply["error"] as? String {
            connectionMessage = error
            resultMessage = error
            return
        }
        guard let data = reply["response"] as? Data,
              let response = try? JSONDecoder().decode(WatchResponse.self, from: data) else { return }
        save(response.snapshot)
        connectionMessage = nil
        resultMessage = response.message
    }

    private func save(_ value: WatchSnapshot) {
        if let snapshot, snapshot.updatedAt > value.updatedAt { return }
        if snapshot == value { return }
        snapshot = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if isForeground, activationState == .activated, refreshWhenActive {
                refreshWhenActive = false
                let day = pendingRefreshDay
                pendingRefreshDay = nil
                refresh(day: day)
            } else if isForeground, let error {
                connectionMessage = "暂时无法连接 iPhone（\(error.localizedDescription)），显示上次同步的课程"
            }
        }
    }
}

private struct WatchTodayView: View {
    @EnvironmentObject private var bridge: WatchBridge
    @State private var quickSignCourse: WatchCourse?
    @State private var showQuickSignConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = bridge.snapshot {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.accountName).font(.headline)
                            Text("今日 \(snapshot.courses.count) 节 · 已签到 \(snapshot.courses.filter(\.isSigned).count) 节")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let next = snapshot.courses.first(where: { ($0.startAt ?? .distantPast) >= .now }) {
                        Section("下一节") {
                            NavigationLink {
                                WatchCourseView(course: next)
                            } label: {
                                WatchCourseRow(course: next)
                            }
                        }
                    }
                    if let signable = snapshot.courses.first(where: \.canSign), bridge.isTodaySnapshot {
                        Button {
                            quickSignCourse = signable
                            showQuickSignConfirmation = true
                        } label: {
                            Label("签到 · \(signable.name)", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bridge.signingID != nil)
                    }
                    if let message = snapshot.message {
                        Label(message, systemImage: "iphone.gen3")
                            .font(.footnote)
                    }
                    if let message = bridge.connectionMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                    if !bridge.isTodaySnapshot {
                        Text("课程来自较早的同步，请连接 iPhone 刷新")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Section("今日课程") {
                        if snapshot.courses.isEmpty {
                            Text(snapshot.updatedAt == .distantPast ? "等待 iPhone 同步" : "今天没有课程")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.courses) { course in
                                NavigationLink {
                                    WatchCourseView(course: course)
                                } label: {
                                    WatchCourseRow(course: course)
                                }
                            }
                        }
                    }
                    Section("更多") {
                        NavigationLink {
                            WatchWeekView()
                        } label: {
                            Label("本周课表", systemImage: "calendar")
                        }
                        NavigationLink {
                            WatchRecordsView()
                        } label: {
                            Label("签到记录", systemImage: "checkmark.circle")
                        }
                        NavigationLink {
                            WatchAccountView()
                        } label: {
                            Label("账户与同步", systemImage: "person.crop.circle")
                        }
                    }
                } else {
                    ContentUnavailableView("等待 iPhone 同步", systemImage: "iphone.gen3")
                }
                Button("刷新今日课程", systemImage: "arrow.clockwise") { bridge.refresh() }
            }
            .navigationTitle("果壳签到")
            .alert("签到结果", isPresented: Binding(
                get: { bridge.resultMessage != nil },
                set: { if !$0 { bridge.resultMessage = nil } }
            )) {
                Button("好") { bridge.resultMessage = nil }
            } message: {
                Text(bridge.resultMessage ?? "")
            }
            .confirmationDialog("确认在 iPhone 上提交签到？", isPresented: $showQuickSignConfirmation) {
                Button("确认签到") {
                    if let quickSignCourse { bridge.sign(quickSignCourse) }
                    quickSignCourse = nil
                }
            }
        }
    }
}

private struct WatchCourseRow: View {
    let course: WatchCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(course.time).font(.caption).foregroundStyle(.secondary)
            Text(course.name).font(.headline).lineLimit(2)
            Text(course.attendance)
                .font(.caption)
                .foregroundStyle(course.isSigned ? .green : .secondary)
        }
    }
}

private struct WatchWeekView: View {
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        List {
            ForEach(bridge.snapshot?.week ?? []) { day in
                NavigationLink {
                    WatchDayView(dayID: day.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                        Text(day.updatedAt == nil ? "尚未同步" : "\(day.courses.count) 节课")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("本周课表")
    }
}

private struct WatchDayView: View {
    @EnvironmentObject private var bridge: WatchBridge
    let dayID: String

    private var day: WatchDay? { bridge.snapshot?.week?.first { $0.id == dayID } }

    var body: some View {
        List {
            if let day {
                if day.updatedAt == nil {
                    Label("尚未同步，可点下方按钮刷新", systemImage: "iphone.gen3")
                        .font(.footnote)
                } else if day.courses.isEmpty {
                    Text("当天没有课程")
                }
                ForEach(day.courses) { course in
                    NavigationLink {
                        WatchCourseView(course: course)
                    } label: {
                        WatchCourseRow(course: course)
                    }
                }
                if let updatedAt = day.updatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("等待 iPhone 同步课表")
            }
            if let message = bridge.connectionMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            Button("刷新这一天", systemImage: "arrow.clockwise") { bridge.refresh(day: dayID) }
        }
        .navigationTitle(day?.date.formatted(.dateTime.month().day()) ?? "课程")
    }
}

private struct WatchRecordsView: View {
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        List {
            if let records = bridge.snapshot?.recentRecords, !records.isEmpty {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(record.courseName, systemImage: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(record.succeeded ? .green : .orange)
                        Text(record.message).font(.caption)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("暂无签到记录")
            }
        }
        .navigationTitle("签到记录")
    }
}

private struct WatchAccountView: View {
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        List {
            if let snapshot = bridge.snapshot {
                LabeledContent("账户", value: snapshot.accountName)
                if let studentNo = snapshot.studentNo {
                    LabeledContent("学号", value: studentNo)
                }
                if let message = snapshot.message {
                    Text(message).foregroundStyle(.orange)
                }
                if snapshot.updatedAt != .distantPast {
                    LabeledContent("今日更新", value: snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                }
            }
            Text("登录、账户切换和学校请求由配对的 iPhone 完成。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("重新同步", systemImage: "arrow.clockwise") { bridge.refresh() }
        }
        .navigationTitle("账户与同步")
    }
}

private struct WatchCourseView: View {
    @EnvironmentObject private var bridge: WatchBridge
    let course: WatchCourse
    @State private var showConfirmation = false

    private var current: WatchCourse {
        bridge.snapshot?.week?.flatMap(\.courses).first(where: { $0.id == course.id && $0.day == course.day })
            ?? bridge.snapshot?.courses.first(where: { $0.id == course.id && $0.day == course.day })
            ?? course
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.name).font(.headline)
                Label(current.time, systemImage: "clock")
                Label(current.location, systemImage: "mappin")
                if let teacher = current.teacher {
                    Label(teacher, systemImage: "person")
                }
                Label(current.attendance, systemImage: current.isSigned ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(current.isSigned ? .green : .secondary)
                Button {
                    showConfirmation = true
                } label: {
                    if bridge.signingID == current.id { ProgressView() }
                    else { Label("为本节课签到", systemImage: "checkmark.circle") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!current.canSign || !bridge.isTodaySnapshot || bridge.signingID != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("课程详情")
        .confirmationDialog("确认在 iPhone 上提交本节课签到？", isPresented: $showConfirmation) {
            Button("确认签到") { bridge.sign(current) }
        }
    }
}
