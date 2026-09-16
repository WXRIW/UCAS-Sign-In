import SwiftUI
import CoreImage.CIFilterBuiltins

struct CourseDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let course: Course
    let isActive: Bool
    @State private var accountGeneration: UUID
    @State private var isVisible = false
    @State private var snapshot: QRSnapshot?
    @State private var qrImage: CGImage?
    @State private var qrError: String?
    @State private var retry = UUID()
    init(course: Course, isActive: Bool, accountGeneration: UUID) {
        self.course = course
        self.isActive = isActive
        _accountGeneration = State(initialValue: accountGeneration)
    }

    private var belongsToCurrentAccount: Bool { accountGeneration == model.accountGeneration }
    private var latestCourse: Course? {
        guard belongsToCurrentAccount else { return nil }
        return model.courses.first { $0.id == course.id && $0.day == course.day }
    }
    private var currentCourse: Course { latestCourse ?? course }
    private var courseWasRemoved: Bool { latestCourse == nil && !model.needsCourseRefresh(course) }

    private var canRefreshQR: Bool {
        belongsToCurrentAccount && isVisible && isActive && scenePhase == .active && !model.showLogin && !model.showAccountManagement
    }
    private struct RefreshID: Equatable {
        let active: Bool
        let retry: UUID
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 23) {
                VStack(spacing: 10) {
                    Text(course.name).font(.system(size: 25, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("\(formattedDay) · \(course.timeRange)").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    CourseMetadataView(course: currentCourse, showsMissingClassroom: true)
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    StatusPill(title: currentCourse.signed ? "已签到" : "未签到", symbol: currentCourse.signed ? "checkmark" : "clock")
                }.padding(.top, 15)
                if model.needsCourseRefresh(currentCourse),
                   let date = CourseTime.parse(day: currentCourse.day, time: "00:00") {
                    CachedCoursesBanner(date: date)
                }
                VStack(spacing: 20) {
                    TimelineView(.animation(minimumInterval: 0.2, paused: !canRefreshQR)) { context in
                        VStack(spacing: 18) {
                            if canRefreshQR, model.isDemo, let qrImage {
                                qrGraphic(qrImage)
                                Label("演示二维码 · 无签到效力", systemImage: "sparkles")
                                    .font(.system(size: 12)).foregroundStyle(Palette.green)
                            } else if let snapshot, snapshot.expiresAt > context.date, canRefreshQR, let qrImage {
                                qrGraphic(qrImage)
                                VStack(spacing: 9) {
                                    let remaining = max(0, snapshot.expiresAt.timeIntervalSince(context.date))
                                    ProgressView(value: min(1, remaining / snapshot.validityDuration)).tint(Palette.green)
                                    Text("学校时间已同步 · \(Int(ceil(remaining))) 秒后刷新")
                                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
                                }.frame(width: 220)
                            } else {
                                VStack(spacing: 15) {
                                    if qrError == nil { ProgressView() }
                                    else { Image(systemName: "wifi.exclamationmark").font(.system(size: 35)).foregroundStyle(Palette.secondary) }
                                    Text(qrError == nil ? "正在同步学校时间…" : "二维码暂不可用")
                                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                                }.frame(width: 230, height: 265)
                            }
                        }
                    }
                    if let qrError {
                        Text(qrError).font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                        Button("重新同步二维码") { retry = UUID() }.font(.system(size: 13, weight: .semibold))
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 26).cardSurface()
                PrimaryButton(title: courseWasRemoved ? "课程已不在最新课表中" : currentCourse.signed ? "已完成签到" : "为本节课程签到", symbol: "checkmark.circle",
                              loading: model.signingID == course.id) {
                    Task { await model.sign(currentCourse, accountGeneration: accountGeneration) }
                }
                    .disabled(!model.canSign(currentCourse, accountGeneration: accountGeneration))
                Text(model.isDemo ? "这里是完整的交互演示，所有操作均不会提交给学校。" : "二维码随学校时间自动刷新。签到是否成功，以学校返回结果为准。")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(5).multilineTextAlignment(.center)
                if let date = CourseTime.parse(day: currentCourse.day, time: "00:00"),
                   let notice = model.notice(on: date), !model.needsCourseRefresh(currentCourse) {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Palette.green)
                }
            }.padding(25)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("courseDetail.scroll")
        .background(Palette.background)
        .navigationTitle("课程签到").appNavigationStyle(inline: true)
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            clearQR()
        }
        .onChange(of: model.accountGeneration) { _ in clearQR() }
        .task(id: RefreshID(active: canRefreshQR, retry: retry)) { await refreshQR() }
    }
    private var formattedDay: String {
        course.startDate.map { SchoolDate.text($0, "M月d日") } ?? course.day
    }
    private func qrGraphic(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
            .frame(width: 224, height: 224).padding(13).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(model.isDemo ? "演示二维码" : "签到二维码")
    }
    private func clearQR() {
        snapshot = nil; qrImage = nil; qrError = nil
    }
    @MainActor
    private func refreshQR() async {
        guard !Task.isCancelled else { return }
        clearQR()
        guard canRefreshQR else { return }
        if model.isDemo {
            qrImage = makeQRCode("ucas-signin://demo?course=\(course.id)")
            return
        }
        while !Task.isCancelled {
            do {
                let value = try await model.service.qr(course: course)
                guard !Task.isCancelled, canRefreshQR else { return }
                snapshot = value
                qrImage = makeQRCode(value.url.absoluteString)
                qrError = nil
                try await Task.sleep(for: .seconds(max(0.1, value.expiresAt.timeIntervalSinceNow)))
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, canRefreshQR else { return }
                snapshot = nil; qrImage = nil; qrError = error.localizedDescription
                return
            }
        }
    }
    private func makeQRCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return cgImage
    }
}
