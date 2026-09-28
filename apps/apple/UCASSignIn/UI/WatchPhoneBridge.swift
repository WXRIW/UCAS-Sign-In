#if os(iOS)
import Foundation
import UIKit
import WatchConnectivity

@MainActor
final class WatchConnectivityAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !AppLaunchEnvironment.isUnitTestHost {
            WatchPhoneBridge.shared.start(AppLaunchEnvironment.sharedModel)
        }
        return true
    }
}

/// Keeps the school session and all sign-in decisions on the paired iPhone.
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneBridge()

    private weak var model: AppModel?
    private var pendingSigns = Set<String>()
    private var restoreTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    @MainActor
    func start(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    @MainActor
    func prepare(_ model: AppModel) async {
        start(model)
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { await model.restore() }
        restoreTask = task
        await task.value
    }

    @MainActor
    private func snapshot(for model: AppModel) -> WatchSnapshot {
        func watchCourse(_ course: Course, on date: Date) -> WatchCourse {
            WatchCourse(
                id: course.id,
                day: course.day,
                name: course.name,
                time: course.timeRange,
                location: course.classroom ?? "教室暂未提供",
                teacher: course.teacher.isEmpty ? nil : course.teacher,
                startAt: course.startDate,
                attendance: model.attendanceLabel(for: course),
                isSigned: model.attendanceStatus(for: course) == .signed,
                canSign: Calendar.current.isDateInToday(date) && model.canSign(course)
            )
        }
        let week = SchoolDate.week(containing: .now).map { date in
            WatchDay(id: SchoolDate.key(date), date: date,
                     courses: model.courses(on: date).map { watchCourse($0, on: date) },
                     updatedAt: model.lastUpdated(on: date))
        }
        let records = model.records.prefix(20).map { record in
            WatchRecord(id: record.id.uuidString, courseName: record.courseName,
                        date: record.date, message: record.message, succeeded: record.succeeded)
        }
        return WatchSnapshot(
            accountGeneration: model.accountGeneration.uuidString,
            accountName: model.accountName,
            message: model.showLogin ? "请在 iPhone 上重新登录" : model.isConnected ? nil : "请先在 iPhone 上登录",
            courses: model.todayCourses.map { watchCourse($0, on: .now) },
            updatedAt: model.lastUpdated(on: .now) ?? .distantPast,
            week: week,
            recentRecords: records,
            studentNo: model.accountStudentNo
        )
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            guard let model = self.model else {
                replyHandler(["error": "请先打开 iPhone 上的果壳签到"])
                return
            }
            await self.prepare(model)
            let result: WatchResponse
            if message["kind"] as? String == "sign" {
                result = await self.sign(message, model: model)
            } else if message["kind"] as? String == "day",
                      let day = message["day"] as? String,
                      let date = CourseTime.parse(day: day, time: "00:00"),
                      SchoolDate.week(containing: .now).contains(where: { SchoolDate.key($0) == SchoolDate.key(date) }) {
                await model.enterDay(date)
                result = WatchResponse(snapshot: self.snapshot(for: model), message: nil)
            } else {
                await model.enterDay(.now)
                result = WatchResponse(snapshot: self.snapshot(for: model), message: nil)
            }
            guard let data = try? JSONEncoder().encode(result) else {
                replyHandler(["error": "无法同步课程"])
                return
            }
            replyHandler(["response": data])
        }
    }

    @MainActor
    private func sign(_ request: [String: Any], model: AppModel) async -> WatchResponse {
        func response(_ message: String) -> WatchResponse {
            WatchResponse(snapshot: snapshot(for: model), message: message)
        }
        guard let id = request["courseID"] as? String,
              let day = request["day"] as? String,
              let generation = request["generation"] as? String,
              generation == model.accountGeneration.uuidString else {
            return response("账户已切换，请刷新课程")
        }
        let key = "\(day)|\(id)"
        guard pendingSigns.insert(key).inserted else { return response("正在处理这节课的签到") }
        defer { pendingSigns.remove(key) }

        await model.enterDay(.now)
        guard generation == model.accountGeneration.uuidString,
              let course = model.todayCourses.first(where: { $0.id == id && $0.day == day }) else {
            return response("课程已变化，请刷新后重试")
        }
        guard model.canSign(course, accountGeneration: model.accountGeneration) else {
            return response(model.attendanceLabel(for: course) == "未签到" ? "当前无法签到，请在 iPhone 查看详情" : model.attendanceLabel(for: course))
        }
        model.errorMessage = nil
        await model.sign(course, accountGeneration: model.accountGeneration)
        guard generation == model.accountGeneration.uuidString else { return response("账户已切换，请刷新课程") }
        let latest = model.todayCourses.first(where: { $0.id == id && $0.day == day }) ?? course
        let signed = model.attendanceStatus(for: latest) == .signed
        return response(signed ? "签到已提交，请以学校状态为准" : model.errorMessage ?? "签到结果未确认，请刷新状态后再决定是否重试")
    }
}
#endif
