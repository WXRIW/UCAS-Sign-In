using Android.Views;
using Android.Widget;
using Google.Android.Material.MaterialSwitch;
using UCASSignIn.Core;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    const string AutoSignPlanRoute = "autosign-plan:";
    const string AutoSignSelectedRoute = "autosign-selected:";
    const string AutoSignEventRoute = "autosign-event:";
    static string? AutoSignPageTitle(string? page) => page switch
    {
        "autosign" => "自动签到",
        "autosign-rules" => "默认规则",
        "autosign-plans" => "未来七天计划",
        "autosign-select" => "选择课次",
        "autosign-history" => "执行记录",
        not null when page.StartsWith(AutoSignPlanRoute) || page.StartsWith(AutoSignSelectedRoute) => "单次自动签到",
        not null when page.StartsWith(AutoSignEventRoute) => "执行过程",
        _ => null
    };
    static string? AutoSignParentRoute(string? page) => page switch
    {
        "autosign" => "settings",
        "autosign-rules" or "autosign-plans" or "autosign-history" => "autosign",
        "autosign-select" => "autosign-plans",
        not null when page.StartsWith(AutoSignPlanRoute) => "autosign-plans",
        not null when page.StartsWith(AutoSignSelectedRoute) => "autosign-select",
        not null when page.StartsWith(AutoSignEventRoute) => "autosign-history",
        _ => null
    };
    static int? AutoSignDepth(string? page) => page switch
    {
        "autosign" => 2,
        "autosign-rules" or "autosign-plans" or "autosign-history" => 3,
        "autosign-select" => 4,
        not null when page.StartsWith(AutoSignPlanRoute) || page.StartsWith(AutoSignEventRoute) => 4,
        not null when page.StartsWith(AutoSignSelectedRoute) => 5,
        _ => null
    };
    bool AutoSignPage(string page)
    {
        if (AutoSignPageTitle(page) is null) return false;
        if (page == "autosign") AutoSignOverview();
        else if (page == "autosign-rules") AutoSignRules();
        else if (page is "autosign-plans" or "autosign-select") AutoSignPlans(page == "autosign-select");
        else if (page == "autosign-history") AutoSignHistory();
        else if (page.StartsWith(AutoSignEventRoute)) AutoSignEvents(page[AutoSignEventRoute.Length..]);
        else AutoSignDetail(page[(page.StartsWith(AutoSignSelectedRoute) ? AutoSignSelectedRoute.Length : AutoSignPlanRoute.Length)..]);
        return true;
    }
    AutoSignPlan? NextAutoSignPlan() => Model.AutoSignPlans.Where(x => x.IsParticipating
        && x.Stage is AutoSignStage.Planned or AutoSignStage.Checking or AutoSignStage.Submitting or AutoSignStage.Verifying or AutoSignStage.RetryWaiting)
        .OrderBy(x => x.NextAt ?? x.PlannedAt).ThenBy(x => x.Key, StringComparer.Ordinal).FirstOrDefault();
    string AutoSignRuntimeStatus => Model.NeedsAutoSignService && !AndroidX.Core.App.NotificationManagerCompat.From(Ui)!.AreNotificationsEnabled()
        ? "当前运行条件不满足 · 请开启通知权限" : Model.AutoSignRuntimeStatus;
    static string AutoSignTime(DateTimeOffset value) => value.ToOffset(CourseTime.ShanghaiOffset).ToString("M月d日 HH:mm");
    static string AutoSignOffset(int minutes) => minutes == 0 ? "上课时" : minutes < 0 ? $"课前 {-minutes} 分钟" : $"开课后 {minutes} 分钟";
    static string AutoSignMissed(AutoSignMissedAction value) => value switch
    { AutoSignMissedAction.TenMinuteGrace => "宽限 10 分钟", AutoSignMissedAction.UntilClassEnds => "下课前补执行", _ => "提示手动处理" };
    static string AutoSignNotify(AutoSignNotification value) => value switch
    { AutoSignNotification.All => "成功与异常", AutoSignNotification.None => "关闭", _ => "仅异常" };
    View AutoSignLink(int icon, string title, string page, string? value = null, string? description = null)
    {
        var row = Tap(Across(SettingLabel(icon, title, description),
            string.IsNullOrWhiteSpace(value) ? Icon(Resource.Drawable.ic_chevron_right, 11, Secondary) : Text(value + "  ›", 13, color: Secondary)),
            () => Navigate(page), title);
        row.SetPadding(0, D(8), 0, D(8));
        row.SetMinimumHeight(D(48));
        return row;
    }
    View AutoSignChoiceRow(int icon, string title, string value, string[] labels, int selected, Func<int, Task> save)
    {
        var row = Tap(Across(SettingLabel(icon, title, value), Icon(Resource.Drawable.ic_chevron_right, 11, Secondary)), () =>
        { AutoSignChoice(title, labels, Math.Clamp(selected, 0, labels.Length - 1), save); return Task.CompletedTask; }, title);
        row.SetPadding(0, D(8), 0, D(8));
        return row;
    }
    void AutoSignError()
    {
        if (!string.IsNullOrWhiteSpace(Model.AutoSignError)) Add(Card(Text(Model.AutoSignError!, 13, color: Secondary)));
    }
    void AutoSignOverview()
    {
        var prefs = Model.Preferences;
        var running = new MaterialSwitch(Ui) { Checked = prefs.AutoSignIsRunning, ContentDescription = "自动签到运行",
            Enabled = Model.IsConnected && !Model.IsDemo && Model.CanChangeAccount };
        running.CheckedChange += async (_, _) => await Host.Run(() => Host.SetAutoSignRunning(running.Checked));
        Add(MaterialSettingsSection("自动签到", Across(SettingLabel(Resource.Drawable.ic_check, "自动签到运行", "为当前账户按计划执行签到"), running)));
        AutoSignError();
        if (prefs.AutoSignIsRunning)
        {
            var next = NextAutoSignPlan();
            var status = Column(Text(AutoSignRuntimeStatus, 14, true),
                Text(next is null ? "暂无待执行计划" : $"下一项：{next.Course.Name}\n{AutoSignTime(next.NextAt ?? next.PlannedAt)}", 13, color: Secondary));
            if (prefs.AutoSignPausedUntil is { } pause && pause > DateTimeOffset.Now)
                status.AddView(Button("立即恢复", () => Model.SetAutoSignSettingsAsync(clearPause: true)));
            else
                status.AddView(Button("暂停至明天", () => Model.SetAutoSignSettingsAsync(pauseUntil:
                    new DateTimeOffset(CourseTime.Today().AddDays(1).ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset))));
            Add(MaterialSettingsSection("运行状态", status,
                "运行时显示常驻通知；系统省电、自启动限制或强行停止应用仍可能使任务延迟或中断。"));
        }
        else Add(Text("自动签到已关闭。开启后会按规则处理未来课次。", 13, color: Secondary));
        var links = Column(AutoSignLink(Resource.Drawable.ic_settings, "默认规则", "autosign-rules", AutoSignOffset(prefs.AutoSignRule.OffsetMinutes)));
        if (prefs.AutoSignIsRunning)
        {
            links.AddView(SettingsRule());
            links.AddView(AutoSignLink(Resource.Drawable.ic_calendar, "未来七天计划", "autosign-plans"));
        }
        if (prefs.AutoSignIsRunning || Model.AutoSignHistory.Count > 0)
        {
            links.AddView(SettingsRule());
            links.AddView(AutoSignLink(Resource.Drawable.ic_history, "执行记录", "autosign-history", Model.AutoSignHistory.Count > 0 ? $"{Model.AutoSignHistory.Count} 条" : null));
        }
        Add(MaterialSettingsSection("管理", links));
        if (prefs.AutoSignIsRunning && prefs.NeedsAutoSignMigrationNotice)
            Add(MaterialSettingsSection("规则已更新", Column(
                Text("默认课前 5 分钟执行；错过后需手动处理。确认仍未签到才会重试，最多提交 3 次，间隔 2 分钟。已有课程设置已保留。开启后，未单独设置的课程默认参与。", 13, color: Secondary),
                Button("知道了", () => Model.AcknowledgeAutoSignMigrationAsync()))));
    }
    void AutoSignRules()
    {
        var prefs = Model.Preferences;
        var policy = prefs.AutoSignRule;
        int[] intervals = [1, 2, 5];
        var rules = Column(
            AutoSignChoiceRow(Resource.Drawable.ic_clock, "执行时间", AutoSignOffset(policy.OffsetMinutes), Enumerable.Range(-25, 266).Select(AutoSignOffset).ToArray(), policy.OffsetMinutes + 25,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { OffsetMinutes = i - 25 })), SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_clock, "错过计划时间", AutoSignMissed(policy.MissedAction), ["提示手动处理", "宽限 10 分钟", "下课前补执行"], (int)policy.MissedAction,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { MissedAction = (AutoSignMissedAction)i })), SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_check_circle, "最多自动提交", $"{policy.MaxSubmissions} 次，包含首次", ["1 次", "2 次", "3 次"], policy.MaxSubmissions - 1,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { MaxSubmissions = i + 1 })), SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_clock, "重试间隔", $"{policy.RetryMinutes} 分钟，重新核实仍未签到后", ["1 分钟", "2 分钟", "5 分钟"], Array.IndexOf(intervals, policy.RetryMinutes),
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { RetryMinutes = intervals[i] })), SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_notification, "结果通知", AutoSignNotify(policy.Notification), ["仅异常", "成功与异常", "关闭"], (int)policy.Notification,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { Notification = (AutoSignNotification)i })));
        Add(MaterialSettingsSection("账户默认规则", rules, "开启后，未单独设置的课程默认参与。课程可在课程详情中停用，单次课次可在计划详情中跳过。执行时间须在课前 25 分钟至下课前，签到结果以学校返回状态为准。"));
    }
    void AutoSignPlans(bool choosing)
    {
        var plans = Model.AutoSignPlans.Where(x => choosing || x.IsParticipating).ToList();
        Add(Text(choosing ? "选择课次后可单独启用本次自动签到。" : "按当前规则预览，不会因浏览而创建执行记录。", 13, color: Secondary));
        if (!choosing) Add(MaterialSettingsSection("单次启用", AutoSignLink(Resource.Drawable.ic_calendar, "选择课次", "autosign-select", description: "查看其他课次并单独启用")));
        foreach (var plan in plans)
            Add(Tap(Card(Column(Text(plan.Course.Name, 15, true),
                Text($"上课 {AutoSignTime(plan.Course.Start!.Value)} · 计划 {plan.PlannedAt.ToOffset(CourseTime.ShanghaiOffset):HH:mm}", 12, color: Secondary),
                Text(plan.StageTitle + "  ›", 12, color: Green))),
                () => Navigate((choosing ? AutoSignSelectedRoute : AutoSignPlanRoute) + plan.Key), plan.Course.Name + "单次自动签到"), 10);
        if (plans.Count == 0) Add(Text(choosing ? "未来七天暂无可选择课次。" : "未来七天暂无参与自动签到的课次。可在课程详情调整课程设置，或通过“选择课次”单独启用本次。", 13, color: Secondary));
    }
    Task SaveAutoSignOccurrence(string key, Func<AutoSignOccurrenceOverride, AutoSignOccurrenceOverride> update)
    {
        var values = new Dictionary<string, AutoSignOccurrenceOverride>(Model.Preferences.AutoSignOccurrences)
        { [key] = update(Model.Preferences.AutoSignOccurrences.GetValueOrDefault(key) ?? new()) };
        return Model.SetAutoSignSettingsAsync(occurrences: values);
    }
    void AutoSignDetail(string key)
    {
        var plan = Model.AutoSignPlans.FirstOrDefault(x => x.Key == key);
        if (plan is null) { Add(Text("该课次已不在未来七天计划中，请返回重新选择。", 13, color: Secondary)); return; }
        var occurrence = Model.Preferences.AutoSignOccurrences.GetValueOrDefault(key);
        Add(Card(Column(Text(plan.Course.Name, 22, true), Text("上课 " + AutoSignTime(plan.Course.Start!.Value), 13, color: Secondary),
            Text("计划 " + AutoSignTime(plan.PlannedAt) + " · " + plan.StageTitle, 13, color: Green), Text(plan.Reason, 13, color: Secondary),
            Text("下一步：" + plan.NextAction, 13, color: Secondary))));
        if (plan.Stage is AutoSignStage.Missed or AutoSignStage.NeedsAttention)
            Add(Button("打开课程签到", () => { Detail(Model.AutoSignPlans.FirstOrDefault(x => x.Key == key)?.Course ?? plan.Course); return Task.CompletedTask; }));
        int[] intervals = [1, 2, 5];
        var timeRow = Tap(Across(SettingLabel(Resource.Drawable.ic_clock, "执行时间", $"{plan.PlannedAt.ToOffset(CourseTime.ShanghaiOffset):HH:mm} · {plan.Sources["执行时间"]}"),
            Icon(Resource.Drawable.ic_chevron_right, 11, Secondary)), () =>
        {
            var latest = Model.AutoSignPlans.FirstOrDefault(x => x.Key == key);
            if (latest is null) return Task.CompletedTask;
            var first = latest.Course.Start!.Value.AddMinutes(-25).ToOffset(CourseTime.ShanghaiOffset);
            var last = latest.Course.End!.Value.AddMinutes(-1).ToOffset(CourseTime.ShanghaiOffset);
            var count = Math.Max(1, (int)(last - first).TotalMinutes + 1);
            var current = Model.Preferences.AutoSignOccurrences.GetValueOrDefault(key);
            var hasOwnTime = current?.At is not null || current?.Policy?.OffsetMinutes is not null;
            var timeIndex = (int)(latest.PlannedAt - first).TotalMinutes;
            AutoSignChoice("本次执行时间", new[] { "跟随课程" }.Concat(Enumerable.Range(0, count).Select(i => AutoSignTime(first.AddMinutes(i)))).ToArray(),
                !hasOwnTime ? 0 : timeIndex >= 0 && timeIndex < count ? timeIndex + 1 : -1,
                i =>
                {
                    if (i == 0) return SaveAutoSignOccurrence(key, x => x with { At = null,
                        Policy = x.Policy is null ? null : x.Policy with { OffsetMinutes = null } });
                    var refreshed = Model.AutoSignPlans.FirstOrDefault(x => x.Key == key);
                    var chosen = first.AddMinutes(i - 1);
                    if (refreshed is null || chosen < refreshed.Course.Start!.Value.AddMinutes(-25) || chosen >= refreshed.Course.End)
                    { Model.SetMessage("本次时间需在课前 25 分钟至下课前"); return Task.CompletedTask; }
                    return SaveAutoSignOccurrence(key, x => x with { At = chosen });
                });
            return Task.CompletedTask;
        }, "本次执行时间");
        timeRow.SetPadding(0, D(8), 0, D(8));
        Add(MaterialSettingsSection("仅调整本次", Column(
            AutoSignChoiceRow(Resource.Drawable.ic_check, "本次参与", (occurrence?.Enabled is null ? "跟随课程" : occurrence.Enabled.Value ? "启用本次" : "跳过本次") + "，全局关闭和课程禁用仍优先",
                ["跟随课程", "启用本次", "跳过本次"], occurrence?.Enabled is null ? 0 : occurrence.Enabled.Value ? 1 : 2,
                i => SaveAutoSignOccurrence(key, x => x with { Enabled = i == 0 ? null : i == 1 })), SettingsRule(), timeRow, SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_check_circle, "最多自动提交", $"当前 {plan.Policy.MaxSubmissions} 次 · {plan.Sources["提交次数"]}", ["跟随课程", "1 次", "2 次", "3 次"], occurrence?.Policy?.MaxSubmissions ?? 0,
                i => SaveAutoSignOccurrence(key, x => x with { Policy = (x.Policy ?? new()) with { MaxSubmissions = i == 0 ? null : i } })), SettingsRule(),
            AutoSignChoiceRow(Resource.Drawable.ic_clock, "重试间隔", $"当前 {plan.Policy.RetryMinutes} 分钟 · {plan.Sources["重试间隔"]}", ["跟随课程", "1 分钟", "2 分钟", "5 分钟"], occurrence?.Policy?.RetryMinutes is { } retry ? Array.IndexOf(intervals, retry) + 1 : 0,
                i => SaveAutoSignOccurrence(key, x => x with { Policy = (x.Policy ?? new()) with { RetryMinutes = i == 0 ? null : intervals[i - 1] } })))));
        Add(Button("恢复本次继承", () =>
        {
            var values = new Dictionary<string, AutoSignOccurrenceOverride>(Model.Preferences.AutoSignOccurrences); values.Remove(key);
            return Model.SetAutoSignSettingsAsync(occurrences: values);
        }));
    }
    string AutoSignHistoryName(AutoSignExecution item) => string.IsNullOrWhiteSpace(item.CourseName)
        ? Model.AutoSignPlans.FirstOrDefault(x => x.Key == item.Key)?.Course.Name ?? "课程签到" : item.CourseName;
    static DateTimeOffset? AutoSignHistoryAt(AutoSignExecution item) => item.ClassStartAt ?? item.Events.FirstOrDefault()?.At;
    void AutoSignHistory()
    {
        AutoSignError();
        foreach (var item in Model.AutoSignHistory)
            Add(Tap(Card(Column(Text(AutoSignHistoryName(item), 15, true),
                Text(AutoSignHistoryAt(item) is { } at ? AutoSignTime(at) : "本机自动执行记录", 12, color: Secondary),
                Text(item.Message + "  ›", 13, color: Secondary))), () => Navigate(AutoSignEventRoute + item.Key), AutoSignHistoryName(item) + "执行过程"), 10);
        if (Model.AutoSignHistory.Count == 0) Add(Text("尚无实际自动执行记录。", 13, color: Secondary));
    }
    void AutoSignEvents(string key)
    {
        var item = Model.AutoSignHistory.FirstOrDefault(x => x.Key == key);
        if (item is null) { Add(Text("该记录已不在本机保留范围内。", 13, color: Secondary)); return; }
        Add(Card(Column(Text(AutoSignHistoryName(item), 22, true),
            Text(AutoSignHistoryAt(item) is { } at ? "上课 " + AutoSignTime(at) : "本机自动执行记录", 13, color: Secondary),
            Text(item.Message, 14, true), Text($"已自动提交 {item.Submissions} 次", 13, color: Secondary))));
        var events = Column();
        foreach (var entry in item.Events)
        {
            if (events.ChildCount > 0) events.AddView(SettingsRule());
            events.AddView(Column(Text(AutoSignTime(entry.At) + entry.At.ToOffset(CourseTime.ShanghaiOffset).ToString(":ss"), 12, color: Secondary), Text(entry.Message, 14)));
        }
        if (events.ChildCount > 0) Add(MaterialSettingsSection("执行过程", events));
    }
}
