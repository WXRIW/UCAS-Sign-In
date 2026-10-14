import SwiftUI

struct AutoSignView: View {
    @EnvironmentObject private var model: AppModel

    private var nextPlan: AutoSignPlan? {
        model.autoSignPlans.first {
            $0.isParticipating && [.planned, .checking, .submitting, .verifying, .retryWaiting].contains($0.stage)
        }
    }

    var body: some View {
        AutoSignPage(title: "自动签到", identifier: "autoSign.overview") {
            AutoSignSection("运行") {
                AutoSignToggleRow("自动签到", symbol: "clock.arrow.circlepath",
                                  subtitle: model.autoSignRunning ? "按计划处理当前账户的课次" : "开启后按计划自动签到",
                                  identifier: "autoSign.running",
                                  isOn: Binding(get: { model.autoSignRunning }, set: { model.setAutoSignRunning($0) }))
                .disabled(!model.canChangeAccount)
                if model.autoSignRunning {
                    PreferenceDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.autoSignRuntimeStatus).font(PreferenceTypography.body.weight(.medium))
                            .foregroundStyle(Palette.ink)
                        if let paused = model.autoSignPausedUntil, paused > .now {
                            Text("暂停至 \(SchoolDate.text(paused, "M 月 d 日 HH:mm"))")
                                .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                            Button("立即恢复") { model.resumeAutoSign() }.tint(Palette.green)
                        } else {
                            if let nextPlan {
                                Text("下一项：\(nextPlan.course.name)")
                                    .font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                                Text("\(SchoolDate.text(nextPlan.nextAt, "M 月 d 日 HH:mm")) · \(nextPlan.stageTitle)")
                                    .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                            } else {
                                Text("暂无待执行计划").font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                            }
                            Button("暂停至明天") { model.pauseAutoSignUntilTomorrow() }.tint(Palette.green)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                }
            }
            if !model.autoSignRunning {
                AutoSignFootnote("自动签到已关闭。课程和单次设置会保留；关闭期间不执行，也不新增自动签到记录。")
            }
            if let error = model.autoSignError {
                AutoSignSection("需要处理") {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 18)
                }
            }
            AutoSignSection("设置与记录") {
                VStack(spacing: 0) {
                    NavigationLink { AutoSignDefaultRulesView() } label: {
                        PreferenceNavigationRow(title: "默认规则", symbol: "slider.horizontal.3")
                    }.buttonStyle(.plain).accessibilityIdentifier("autoSign.rules")
                    if model.autoSignRunning {
                        PreferenceDivider()
                        NavigationLink { AutoSignPlansView() } label: {
                            PreferenceNavigationRow(title: "未来七天计划", symbol: "calendar.badge.clock")
                        }.buttonStyle(.plain).accessibilityIdentifier("autoSign.plans")
                    }
                    if !model.displayAutoSignHistory.isEmpty {
                        PreferenceDivider()
                        NavigationLink { AutoSignHistoryView() } label: {
                            PreferenceNavigationRow(title: "执行记录", symbol: "clock", value: "\(model.displayAutoSignHistory.count) 条")
                        }.buttonStyle(.plain).accessibilityIdentifier("autoSign.history")
                    }
                }
            }
            if model.autoSignRunning && model.autoSignMigrationPending {
                AutoSignSection("规则已更新") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("已有课程设置已保留。开启后，未单独设置的课程默认参与。默认在课前 5 分钟执行，错过后手动处理；核实仍未签到才重试，最多提交 3 次，间隔 2 分钟。")
                            .font(PreferenceTypography.detail).lineSpacing(4).foregroundStyle(Palette.secondary)
                        Button("知道了") { model.acknowledgeAutoSignMigration() }.tint(Palette.green)
                    }.padding(.vertical, 18)
                }
            }
            AutoSignFootnote("自动签到开关、规则、暂停和单次设置仅在这台设备生效。")
            if model.autoSignRunning { AutoSignFootnote(AutoSignCopy.runtimeExplanation) }
        }
    }
}

private struct AutoSignDefaultRulesView: View {
    @EnvironmentObject private var model: AppModel
    private var rule: AutoSignPolicy { model.autoSignRule }

    var body: some View {
        AutoSignPage(title: "默认规则", identifier: "autoSign.defaultRules") {
            AutoSignSection("执行与重试", footer: "执行时间必须在课前 25 分钟至下课前。重试前必须向学校重新核实，确认仍未签到。") {
                VStack(spacing: 0) {
                    AutoSignMenuRow("执行时间", symbol: "clock", value: AutoSignCopy.offset(rule.offsetMinutes), selection: Binding(get: { rule.offsetMinutes }, set: { value in
                        update { $0.offsetMinutes = value }
                    })) {
                        ForEach(-25...240, id: \.self) { Text(AutoSignCopy.offset($0)).tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("错过计划时间", symbol: "clock.badge.exclamationmark", value: AutoSignCopy.missed(rule.missedAction), selection: Binding(get: { rule.missedAction }, set: { value in
                        update { $0.missedAction = value }
                    })) {
                        ForEach(AutoSignMissedAction.allCases, id: \.self) { Text(AutoSignCopy.missed($0)).tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("最多自动提交", symbol: "arrow.clockwise", value: "\(rule.maxSubmissions) 次", selection: Binding(get: { rule.maxSubmissions }, set: { value in
                        update { $0.maxSubmissions = value }
                    })) {
                        ForEach(1...3, id: \.self) { Text("\($0) 次").tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("重试间隔", symbol: "timer", value: "\(rule.retryMinutes) 分钟", selection: Binding(get: { rule.retryMinutes }, set: { value in
                        update { $0.retryMinutes = value }
                    })) {
                        ForEach([1, 2, 5], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                }
            }
            AutoSignSection("通知") {
                AutoSignMenuRow("结果通知", symbol: "bell", value: AutoSignCopy.notification(rule.notification), selection: Binding(get: { rule.notification }, set: { value in
                    update { $0.notification = value }
                })) {
                    ForEach(AutoSignNotification.allCases, id: \.self) { Text(AutoSignCopy.notification($0)).tag($0) }
                }
            }
            AutoSignFootnote("开启自动签到后，课程默认参与。可在课程详情中停用个别课程，或在单次计划中跳过课次。")
        }
    }

    private func update(_ change: (inout AutoSignPolicy) -> Void) {
        var next = rule; change(&next); model.setAutoSignRule(next)
    }
}

private struct AutoSignPlansView: View {
    @EnvironmentObject private var model: AppModel
    private var plans: [AutoSignPlan] { model.autoSignPlans.filter(\.isParticipating) }

    var body: some View {
        AutoSignPage(title: "未来七天计划", identifier: "autoSign.planList") {
            AutoSignSection("课次") {
                NavigationLink { AutoSignSelectOccurrenceView() } label: {
                    PreferenceNavigationRow(title: "选择课次", symbol: "plus.circle")
                }.buttonStyle(.plain).accessibilityIdentifier("autoSign.selectOccurrence")
            }
            if plans.isEmpty {
                AutoSignEmptyState("暂无参与自动签到的课次", subtitle: "可在课程详情中调整，或通过“选择课次”单独启用。", symbol: "calendar")
            } else {
                AutoSignSection("已安排") {
                    VStack(spacing: 0) {
                        ForEach(Array(plans.enumerated()), id: \.element.key) { index, plan in
                            if index > 0 { PreferenceDivider() }
                            NavigationLink { AutoSignPlanDetail(key: plan.key) } label: {
                                AutoSignPlanRow(plan: plan)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            AutoSignFootnote("计划来自已同步的课表。执行前会再次向学校核实，最终结果以学校返回状态为准。")
        }
    }
}

private struct AutoSignSelectOccurrenceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AutoSignPage(title: "选择课次", identifier: "autoSign.occurrenceList") {
            if model.autoSignPlans.isEmpty {
                AutoSignEmptyState("暂无可选择的课次", subtitle: "同步课程后，可选择未来七天的课次单独调整。", symbol: "calendar")
            } else {
                AutoSignSection("未来七天") {
                    VStack(spacing: 0) {
                        ForEach(Array(model.autoSignPlans.enumerated()), id: \.element.key) { index, plan in
                            if index > 0 { PreferenceDivider() }
                            NavigationLink { AutoSignPlanDetail(key: plan.key) } label: {
                                AutoSignPlanRow(plan: plan)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct AutoSignPlanRow: View {
    let plan: AutoSignPlan
    var body: some View {
        HStack(alignment: .center, spacing: PreferenceRowLayout.spacing) {
            Image(systemName: "calendar").font(.system(size: 17)).foregroundStyle(Palette.green)
                .frame(width: PreferenceRowLayout.iconWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.course.name).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text("上课 \(SchoolDate.text(plan.course.startDate ?? plan.plannedAt, "M 月 d 日 HH:mm"))")
                    .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                Text("计划 \(SchoolDate.text(plan.plannedAt, "HH:mm")) · \(plan.stageTitle)")
                    .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary).accessibilityHidden(true)
        }.padding(.vertical, 18).contentShape(Rectangle())
    }
}

private struct AutoSignPlanDetail: View {
    @EnvironmentObject private var model: AppModel
    let key: String
    private var plan: AutoSignPlan? { model.autoSignPlans.first { $0.key == key } }
    private var occurrence: AutoSignOccurrenceOverride { model.autoSignOccurrences[key] ?? .init() }

    var body: some View {
        AutoSignPage(title: "单次计划", identifier: "autoSign.planDetail") {
            if let plan {
                AutoSignSection("本次课次") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(plan.course.name).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Text("上课 \(SchoolDate.text(plan.course.startDate ?? plan.plannedAt, "M 月 d 日 HH:mm"))")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                        Text("计划 \(SchoolDate.text(plan.plannedAt, "M 月 d 日 HH:mm")) · \(plan.stageTitle)")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                        Text(plan.reason).font(PreferenceTypography.detail).lineSpacing(3).foregroundStyle(Palette.secondary)
                        Text("下一步：\(plan.nextAction)").font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 18)
                }
                if [.missed, .needsAttention].contains(plan.stage) {
                    AutoSignSection("手动处理") {
                        NavigationLink {
                            CourseDetailView(course: plan.course, isActive: true, accountGeneration: model.accountGeneration)
                        } label: {
                            PreferenceNavigationRow(title: "打开课程签到", symbol: "checkmark.circle")
                        }.buttonStyle(.plain).accessibilityIdentifier("autoSign.manualCourse")
                    }
                }
                AutoSignSection("单次调整", footer: "只影响本次课次。恢复继承后，继续使用课程和账户规则。") {
                    VStack(spacing: 0) {
                        AutoSignMenuRow("本次自动签到", symbol: "checkmark.circle",
                                        value: occurrence.enabled.map { $0 ? "单独启用" : "跳过本次" } ?? "跟随课程", selection: Binding(get: {
                            occurrence.enabled.map { $0 ? "enabled" : "disabled" } ?? "inherit"
                        }, set: { value in
                            update { $0.enabled = value == "inherit" ? nil : value == "enabled" }
                        })) {
                            Text("跟随课程").tag("inherit")
                            Text("单独启用").tag("enabled")
                            Text("跳过本次").tag("disabled")
                        }
                        PreferenceDivider()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: PreferenceRowLayout.spacing) {
                                AutoSignSettingLabel("执行时间", symbol: "clock", subtitle: timeSource)
                                Spacer(minLength: 12)
                                timePicker
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                AutoSignSettingLabel("执行时间", symbol: "clock", subtitle: timeSource)
                                timePicker.padding(.leading, PreferenceRowLayout.textInset)
                            }
                        }.padding(.vertical, 18)
                        PreferenceDivider()
                        AutoSignMenuRow("最多自动提交", symbol: "arrow.clockwise", subtitle: submissionSource,
                                        value: occurrence.policy?.maxSubmissions.map { "\($0) 次" } ?? "跟随课程",
                                        selection: Binding(get: { occurrence.policy?.maxSubmissions ?? 0 }, set: { value in
                            update { var rule = $0.policy ?? .init(); rule.maxSubmissions = value == 0 ? nil : value; $0.policy = rule }
                        })) {
                            Text("跟随课程").tag(0)
                            ForEach(1...3, id: \.self) { Text("\($0) 次").tag($0) }
                        }
                        PreferenceDivider()
                        AutoSignMenuRow("重试间隔", symbol: "timer", subtitle: retrySource,
                                        value: occurrence.policy?.retryMinutes.map { "\($0) 分钟" } ?? "跟随课程",
                                        selection: Binding(get: { occurrence.policy?.retryMinutes ?? 0 }, set: { value in
                            update { var rule = $0.policy ?? .init(); rule.retryMinutes = value == 0 ? nil : value; $0.policy = rule }
                        })) {
                            Text("跟随课程").tag(0)
                            ForEach([1, 2, 5], id: \.self) { Text("\($0) 分钟").tag($0) }
                        }
                        PreferenceDivider()
                        Button { if let course = self.plan?.course { model.setAutoSignOccurrence(nil, for: course) } } label: {
                            AutoSignSettingLabel("恢复继承", symbol: "arrow.uturn.backward", subtitle: "清除本次的所有单独设置")
                                .padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                if let start = plan.course.startDate, let end = plan.course.endDate {
                    AutoSignFootnote("本次可执行时间：\(SchoolDate.text(start.addingTimeInterval(-25 * 60), "M 月 d 日 HH:mm")) 至 \(SchoolDate.text(end, "HH:mm")) 前。")
                }
                AutoSignSection("生效规则") {
                    VStack(alignment: .leading, spacing: 10) {
                        effectiveRule("执行时间", value: occurrence.at.map { SchoolDate.text($0, "M 月 d 日 HH:mm") } ?? AutoSignCopy.offset(plan.policy.offsetMinutes), plan: plan)
                        effectiveRule("错过处理", value: AutoSignCopy.missed(plan.policy.missedAction), plan: plan)
                        effectiveRule("提交次数", value: "最多 \(plan.policy.maxSubmissions) 次", plan: plan)
                        effectiveRule("重试间隔", value: "\(plan.policy.retryMinutes) 分钟", plan: plan)
                        effectiveRule("结果通知", value: AutoSignCopy.notification(plan.policy.notification), plan: plan)
                    }.padding(.vertical, 18)
                }
                if let execution = model.autoSignExecutions[key], execution.hasExecutionActivity {
                    AutoSignSection("执行过程") {
                        NavigationLink { AutoSignExecutionDetail(key: key) } label: {
                            PreferenceNavigationRow(title: "查看执行记录", symbol: "clock")
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                AutoSignEmptyState("课次已更新", subtitle: "这项计划已不在未来七天课表中。请返回计划列表查看最新安排。", symbol: "calendar.badge.exclamationmark")
            }
        }
    }

    private var timeSource: String {
        if let at = occurrence.at, let start = plan?.course.startDate, let end = plan?.course.endDate,
           at < start.addingTimeInterval(-25 * 60) || at >= end {
            return "当前时间超出本次签到窗口，请重新选择"
        }
        return occurrence.at == nil ? "\(plan?.sources["执行时间"] ?? "账户默认")" : "本次指定时间"
    }
    private var submissionSource: String {
        "当前最多 \(plan?.policy.maxSubmissions ?? 3) 次 · \(plan?.sources["提交次数"] ?? "账户默认")"
    }
    private var retrySource: String {
        "当前 \(plan?.policy.retryMinutes ?? 2) 分钟 · \(plan?.sources["重试间隔"] ?? "账户默认")"
    }
    @ViewBuilder private var timePicker: some View {
        if let start = plan?.course.startDate, let end = plan?.course.endDate, end > start {
            let window = start.addingTimeInterval(-25 * 60)...end.addingTimeInterval(-1)
            DatePicker("本次执行时间", selection: Binding(get: {
                let selected = occurrence.at ?? plan?.plannedAt ?? start
                return min(max(selected, window.lowerBound), window.upperBound)
            }, set: { value in
                update { $0.at = value }
            }), in: window, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden().font(PreferenceTypography.body).tint(Palette.green)
            .environment(\.timeZone, SchoolDate.calendar.timeZone)
            .accessibilityIdentifier("autoSign.occurrenceTime")
        }
    }
    private func update(_ change: (inout AutoSignOccurrenceOverride) -> Void) {
        guard let course = plan?.course else { return }
        var next = occurrence; change(&next); model.setAutoSignOccurrence(next, for: course)
    }
    private func effectiveRule(_ name: String, value: String, plan: AutoSignPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(name)：\(value)").font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
            Text(plan.sources[name] ?? "账户默认").font(PreferenceTypography.caption).foregroundStyle(Palette.secondary)
        }
    }
}

private struct AutoSignHistoryView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        AutoSignPage(title: "执行记录", identifier: "autoSign.historyList") {
            if model.displayAutoSignHistory.isEmpty {
                AutoSignEmptyState("暂无执行记录", subtitle: "课次实际开始处理后，才会在这里显示。", symbol: "clock")
            } else {
                AutoSignSection("执行历史") {
                    VStack(spacing: 0) {
                        ForEach(Array(model.displayAutoSignHistory.enumerated()), id: \.element.id) { index, execution in
                            if index > 0 { PreferenceDivider() }
                            NavigationLink { AutoSignExecutionDetail(key: execution.occurrenceKey, historyID: execution.id) } label: {
                                HStack(spacing: PreferenceRowLayout.spacing) {
                                    Image(systemName: "clock").font(.system(size: 17)).foregroundStyle(Palette.green)
                                        .frame(width: PreferenceRowLayout.iconWidth).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(courseName(execution)).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                                        if let date = execution.classStartAt ?? execution.events.first?.at {
                                            Text(SchoolDate.text(date, "M 月 d 日 HH:mm"))
                                                .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                                        }
                                        Text(execution.message).font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                                        Text("来源：\(execution.sourceDeviceName)\(execution.sourceDeviceID == model.cloudDeviceID ? " · 本机" : "")")
                                            .font(PreferenceTypography.caption).foregroundStyle(Palette.secondary)
                                    }.fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.secondary).accessibilityHidden(true)
                                }.padding(.vertical, 18).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            AutoSignFootnote("这些记录包含本机与 iCloud 同步的执行历史，不代表学校最终考勤。其他设备的记录仅供查看，不会触发本机签到或重试；学校考勤可在课程详情中查看。")
        }
    }
    private func courseName(_ value: SyncAutoSignHistory) -> String {
        value.courseName ?? model.autoSignPlans.first { $0.key == value.occurrenceKey }?.course.name ?? "课程签到"
    }
}

private struct AutoSignExecutionDetail: View {
    @EnvironmentObject private var model: AppModel
    let key: String
    var historyID: String? = nil
    private var execution: SyncAutoSignHistory? {
        if let historyID { return model.displayAutoSignHistory.first { $0.id == historyID } }
        return model.displayAutoSignHistory.first { $0.occurrenceKey == key && $0.sourceDeviceID == model.cloudDeviceID }
    }

    var body: some View {
        AutoSignPage(title: "执行详情", identifier: "autoSign.executionDetail") {
            if let execution {
                AutoSignSection("结果") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(execution.courseName ?? model.autoSignPlans.first { $0.key == key }?.course.name ?? "课程签到")
                            .font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                        if let start = execution.classStartAt {
                            Text("上课 \(SchoolDate.text(start, "M 月 d 日 HH:mm"))")
                                .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                        }
                        Text(execution.message).font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                        Text("已自动提交 \(execution.submissions) 次")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                        Text("来源：\(execution.sourceDeviceName)\(execution.sourceDeviceID == model.cloudDeviceID ? " · 本机" : "")")
                            .font(PreferenceTypography.detail).foregroundStyle(Palette.secondary)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 18)
                }
                if !execution.events.isEmpty {
                    AutoSignSection("过程") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(execution.events.enumerated()), id: \.offset) { index, event in
                                if index > 0 { PreferenceDivider() }
                                HStack(alignment: .top, spacing: PreferenceRowLayout.spacing) {
                                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Palette.green)
                                        .frame(width: PreferenceRowLayout.iconWidth).padding(.top, 6).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(SchoolDate.text(event.at, "M 月 d 日 HH:mm:ss"))
                                            .font(PreferenceTypography.caption).foregroundStyle(Palette.secondary)
                                        Text(event.message).font(PreferenceTypography.detail).foregroundStyle(Palette.ink)
                                    }.fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                            }
                        }
                    }
                }
            } else {
                AutoSignEmptyState("记录已不可用", subtitle: "请返回执行记录列表查看。", symbol: "clock")
            }
        }
    }
}

struct AutoSignCourseRulesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var preferences: CoursePreferences
    private var effective: AutoSignPolicy { (preferences.autoSignRule ?? .init()).resolve(model.autoSignRule) }

    var body: some View {
        AutoSignPage(title: "课程自动签到规则", identifier: "autoSign.courseRules") {
            AutoSignSection("课程覆盖", footer: "选择“跟随账户”时采用账户默认值。本课程已禁用签到或总开关关闭时，不会自动执行。") {
                VStack(spacing: 0) {
                    AutoSignMenuRow("执行时间", symbol: "clock", subtitle: source(preferences.autoSignRule?.offsetMinutes != nil, value: AutoSignCopy.offset(effective.offsetMinutes)),
                                    value: preferences.autoSignRule?.offsetMinutes.map(AutoSignCopy.offset) ?? "跟随账户",
                                    selection: Binding(get: { preferences.autoSignRule?.offsetMinutes ?? 1000 }, set: { value in
                        update { $0.offsetMinutes = value == 1000 ? nil : value }
                    })) {
                        Text("跟随账户").tag(1000)
                        ForEach(-25...240, id: \.self) { Text(AutoSignCopy.offset($0)).tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("错过计划时间", symbol: "clock.badge.exclamationmark", subtitle: source(preferences.autoSignRule?.missedAction != nil, value: AutoSignCopy.missed(effective.missedAction)),
                                    value: preferences.autoSignRule?.missedAction.map(AutoSignCopy.missed) ?? "跟随账户",
                                    selection: Binding(get: { preferences.autoSignRule?.missedAction?.rawValue ?? "inherit" }, set: { value in
                        update { $0.missedAction = AutoSignMissedAction(rawValue: value) }
                    })) {
                        Text("跟随账户").tag("inherit")
                        ForEach(AutoSignMissedAction.allCases, id: \.self) { Text(AutoSignCopy.missed($0)).tag($0.rawValue) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("最多自动提交", symbol: "arrow.clockwise", subtitle: source(preferences.autoSignRule?.maxSubmissions != nil, value: "\(effective.maxSubmissions) 次"),
                                    value: preferences.autoSignRule?.maxSubmissions.map { "\($0) 次" } ?? "跟随账户",
                                    selection: Binding(get: { preferences.autoSignRule?.maxSubmissions ?? 0 }, set: { value in
                        update { $0.maxSubmissions = value == 0 ? nil : value }
                    })) {
                        Text("跟随账户").tag(0)
                        ForEach(1...3, id: \.self) { Text("\($0) 次").tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("重试间隔", symbol: "timer", subtitle: source(preferences.autoSignRule?.retryMinutes != nil, value: "\(effective.retryMinutes) 分钟"),
                                    value: preferences.autoSignRule?.retryMinutes.map { "\($0) 分钟" } ?? "跟随账户",
                                    selection: Binding(get: { preferences.autoSignRule?.retryMinutes ?? 0 }, set: { value in
                        update { $0.retryMinutes = value == 0 ? nil : value }
                    })) {
                        Text("跟随账户").tag(0)
                        ForEach([1, 2, 5], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                    PreferenceDivider()
                    AutoSignMenuRow("结果通知", symbol: "bell", subtitle: source(preferences.autoSignRule?.notification != nil, value: AutoSignCopy.notification(effective.notification)),
                                    value: preferences.autoSignRule?.notification.map(AutoSignCopy.notification) ?? "跟随账户",
                                    selection: Binding(get: { preferences.autoSignRule?.notification?.rawValue ?? "inherit" }, set: { value in
                        update { $0.notification = AutoSignNotification(rawValue: value) }
                    })) {
                        Text("跟随账户").tag("inherit")
                        ForEach(AutoSignNotification.allCases, id: \.self) { Text(AutoSignCopy.notification($0)).tag($0.rawValue) }
                    }
                    PreferenceDivider()
                    Button { preferences.autoSignRule = nil } label: {
                        AutoSignSettingLabel("恢复继承", symbol: "arrow.uturn.backward", subtitle: "所有规则重新跟随账户默认值")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func source(_ overridden: Bool, value: String) -> String {
        "当前为\(value) · \(overridden ? "课程设置" : "账户默认")"
    }
    private func update(_ change: (inout AutoSignPolicyOverride) -> Void) {
        var next = preferences.autoSignRule ?? .init(); change(&next)
        preferences.autoSignRule = next == AutoSignPolicyOverride() ? nil : next
    }
}

private enum AutoSignCopy {
    static func offset(_ value: Int) -> String {
        value == 0 ? "上课时" : value < 0 ? "课前 \(-value) 分钟" : "开课后 \(value) 分钟"
    }
    static func missed(_ value: AutoSignMissedAction) -> String {
        switch value {
        case .manual: "提示手动处理"
        case .tenMinuteGrace: "宽限 10 分钟"
        case .untilClassEnds: "下课前补执行"
        }
    }
    static func notification(_ value: AutoSignNotification) -> String {
        switch value {
        case .problems: "仅异常"
        case .all: "成功与异常"
        case .none: "关闭"
        }
    }
    static var runtimeExplanation: String {
        #if os(macOS)
        "果壳签到运行时按计划执行。退出应用或 Mac 睡眠时暂停；错过的计划按设置处理。"
        #else
        "请保持 App 在前台。iOS / iPadOS 不保证后台定时运行；错过的计划按设置处理。"
        #endif
    }
}

private struct AutoSignPage<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24, content: content)
                    .appPagePadding()
                    .frame(width: min(680, geometry.size.width), alignment: .leading)
                    .frame(maxWidth: .infinity)
            }.accessibilityIdentifier(identifier)
        }.background(Palette.background)
            .navigationTitle(title).appNavigationStyle(inline: true)
    }
}

private struct AutoSignSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: () -> Content
    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.footer = footer; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(PreferenceTypography.section).foregroundStyle(Palette.secondary)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding).accessibilityAddTraits(.isHeader)
            content().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PreferenceRowLayout.horizontalPadding).cardSurface()
            if let footer { AutoSignFootnote(footer) }
        }
    }
}

private struct AutoSignFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(PreferenceTypography.detail).lineSpacing(4).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, PreferenceRowLayout.horizontalPadding)
    }
}

private struct AutoSignEmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String
    init(_ title: String, subtitle: String, symbol: String) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
    }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(Palette.green).accessibilityHidden(true)
            Text(title).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
            Text(subtitle).font(PreferenceTypography.detail).lineSpacing(4).foregroundStyle(Palette.secondary)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 36).cardSurface()
    }
}

private struct AutoSignSettingLabel: View {
    let title: String
    let symbol: String
    let subtitle: String?
    init(_ title: String, symbol: String, subtitle: String? = nil) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle
    }
    var body: some View {
        HStack(alignment: .center, spacing: PreferenceRowLayout.spacing) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Palette.green)
                .frame(width: PreferenceRowLayout.iconWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PreferenceTypography.body.weight(.medium)).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).font(PreferenceTypography.detail).foregroundStyle(Palette.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AutoSignToggleRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let symbol: String
    let subtitle: String
    let identifier: String
    @Binding var isOn: Bool

    init(_ title: String, symbol: String, subtitle: String, identifier: String, isOn: Binding<Bool>) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle
        self.identifier = identifier; _isOn = isOn
    }
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    AutoSignSettingLabel(title, symbol: symbol, subtitle: subtitle)
                    Toggle(title, isOn: $isOn)
                        .labelsHidden().accessibilityLabel(title).accessibilityIdentifier(identifier)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                Toggle(isOn: $isOn) {
                    AutoSignSettingLabel(title, symbol: symbol, subtitle: subtitle)
                }.accessibilityIdentifier(identifier)
            }
        }.toggleStyle(.switch).tint(Palette.green).padding(.vertical, 18)
    }
}

private struct AutoSignMenuRow<Selection: Hashable, Options: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let symbol: String
    let subtitle: String?
    let value: String
    @Binding var selection: Selection
    let options: () -> Options
    init(_ title: String, symbol: String, subtitle: String? = nil, value: String, selection: Binding<Selection>, @ViewBuilder options: @escaping () -> Options) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle; self.value = value
        _selection = selection; self.options = options
    }
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                verticalContent
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PreferenceRowLayout.spacing) {
                        AutoSignSettingLabel(title, symbol: symbol, subtitle: subtitle)
                        Spacer(minLength: 12)
                        picker
                    }
                    verticalContent
                }
            }
        }.padding(.vertical, 18)
    }
    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AutoSignSettingLabel(title, symbol: symbol, subtitle: subtitle)
            picker.padding(.leading, PreferenceRowLayout.textInset)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var picker: some View {
        Menu {
            Picker(title, selection: $selection, content: options)
        } label: {
            HStack(spacing: 8) {
                Text(value).font(PreferenceTypography.body)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
            }.foregroundStyle(Palette.green).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).tint(Palette.green)
            .accessibilityLabel(title).accessibilityValue(value)
            .accessibilityIdentifier("autoSign.menu.\(title)")
    }
}
