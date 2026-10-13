using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
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
    bool RenderAutoSignPage(string page)
    {
        if (AutoSignPageTitle(page) is null) return false;
        if (page == "autosign") RenderAutoSignOverview();
        else if (page == "autosign-rules") RenderAutoSignRules();
        else if (page == "autosign-plans" || page == "autosign-select") RenderAutoSignPlans(page == "autosign-select");
        else if (page == "autosign-history") RenderAutoSignHistory();
        else if (page.StartsWith(AutoSignEventRoute)) RenderAutoSignEvents(page[AutoSignEventRoute.Length..]);
        else RenderAutoSignDetail(page[(page.StartsWith(AutoSignSelectedRoute) ? AutoSignSelectedRoute.Length : AutoSignPlanRoute.Length)..]);
        return true;
    }
    AutoSignPlan? NextAutoSignPlan() => Model.AutoSignPlans.Where(x => x.IsParticipating
        && x.Stage is AutoSignStage.Planned or AutoSignStage.Checking or AutoSignStage.Submitting or AutoSignStage.RetryWaiting or AutoSignStage.Verifying)
        .OrderBy(x => x.NextAt ?? x.PlannedAt).ThenBy(x => x.Key, StringComparer.Ordinal).FirstOrDefault();
    SettingsCard AutoSignLink(string title, string glyph, string page, string? value = null, string? description = null)
    {
        var card = SettingsLink(title, glyph, () => Navigate(page), description);
        if (!string.IsNullOrWhiteSpace(value)) card.Content = Text(value, 13, color: Secondary);
        return card;
    }
    static string AutoSignTime(DateTimeOffset value) => value.ToOffset(CourseTime.ShanghaiOffset).ToString("M月d日 HH:mm");
    static string AutoSignOffset(int minutes) => minutes == 0 ? "上课时" : minutes < 0 ? $"课前 {-minutes} 分钟" : $"开课后 {minutes} 分钟";
    void RenderAutoSignError()
    {
        if (!string.IsNullOrWhiteSpace(Model.AutoSignError))
            Page.Children.Add(Card(Text(Model.AutoSignError!, 13, color: Secondary)));
    }
    void RenderAutoSignOverview()
    {
        var prefs = Model.Preferences;
        var running = new ToggleSwitch { IsOn = prefs.AutoSignIsRunning, OnContent = "", OffContent = "",
            IsEnabled = Model.IsConnected && !Model.IsDemo && Model.CanChangeAccount };
        running.Toggled += async (_, _) => await Run(() => Model.SetAutoSignSettingsAsync(running: running.IsOn));
        Page.Children.Add(SettingsGroup("自动签到", SettingRow("自动签到运行", "为当前账户按计划执行签到", "\uE73E", running)));
        RenderAutoSignError();
        if (prefs.AutoSignIsRunning)
        {
            var next = NextAutoSignPlan();
            var status = Column(Text(Model.AutoSignRuntimeStatus, 14, true),
                Text(next is null ? "暂无待执行计划" : $"下一项：{next.Course.Name}\n{AutoSignTime(next.NextAt ?? next.PlannedAt)}", 13, color: Secondary));
            if (prefs.AutoSignPausedUntil is { } pause && pause > DateTimeOffset.Now)
                status.Children.Add(Button("立即恢复", () => Model.SetAutoSignSettingsAsync(clearPause: true)));
            else
                status.Children.Add(Button("暂停至明天", () => Model.SetAutoSignSettingsAsync(pauseUntil:
                    new DateTimeOffset(CourseTime.Today().AddDays(1).ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset))));
            Page.Children.Add(Card(status));
            Page.Children.Add(SettingsNote("窗口可最小化，也可切换到其他应用；退出应用或设备睡眠时会暂停。"));
        }
        else Page.Children.Add(SettingsNote("自动签到已关闭。开启后会按规则处理未来课次。"));
        var links = SettingsGroup("管理", AutoSignLink("默认规则", "\uE713", "autosign-rules", AutoSignOffset(prefs.AutoSignRule.OffsetMinutes)));
        var rows = (StackPanel)links.Children[1];
        if (prefs.AutoSignIsRunning) rows.Children.Add(AutoSignLink("未来七天计划", "\uE787", "autosign-plans"));
        if (prefs.AutoSignIsRunning || Model.AutoSignHistory.Count > 0)
            rows.Children.Add(AutoSignLink("执行记录", "\uE81C", "autosign-history", Model.AutoSignHistory.Count > 0 ? $"{Model.AutoSignHistory.Count} 条" : null));
        Page.Children.Add(links);
        if (prefs.AutoSignIsRunning && prefs.NeedsAutoSignMigrationNotice)
            Page.Children.Add(Card(Column(Text("规则已更新", 14, true),
                Text("默认课前 5 分钟执行；错过后需手动处理。确认仍未签到才会重试，最多提交 3 次，间隔 2 分钟。已有课程设置已保留。开启后，未单独设置的课程默认参与。", 13, color: Secondary),
                Button("知道了", () => Model.AcknowledgeAutoSignMigrationAsync()))));
    }
    ComboBox AutoSignPicker(string name, string[] items, int selected, Func<int, Task> save)
    {
        var picker = new ComboBox { ItemsSource = items, SelectedIndex = Math.Clamp(selected, 0, items.Length - 1), MinWidth = 150 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, name);
        picker.SelectionChanged += async (_, _) => { if (picker.SelectedIndex >= 0) await Run(() => save(picker.SelectedIndex)); };
        return picker;
    }
    void RenderAutoSignRules()
    {
        var prefs = Model.Preferences;
        var policy = prefs.AutoSignRule;
        var intervals = new[] { 1, 2, 5 };
        Page.Children.Add(SettingsGroup("账户默认规则",
            SettingRow("执行时间", "须在课前 25 分钟至下课前", "\uE823", AutoSignPicker("执行时间", Enumerable.Range(-25, 266).Select(AutoSignOffset).ToArray(), policy.OffsetMinutes + 25,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { OffsetMinutes = i - 25 }))),
            SettingRow("错过计划时间", "", "\uE823", AutoSignPicker("错过计划时间", ["提示手动处理", "宽限 10 分钟", "下课前补执行"], (int)policy.MissedAction,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { MissedAction = (AutoSignMissedAction)i }))),
            SettingRow("最多自动提交", "包含首次提交", "\uE73E", AutoSignPicker("最多自动提交", ["1 次", "2 次", "3 次"], policy.MaxSubmissions - 1,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { MaxSubmissions = i + 1 }))),
            SettingRow("重试间隔", "重新核实仍未签到后才会提交", "\uE823", AutoSignPicker("重试间隔", ["1 分钟", "2 分钟", "5 分钟"], Array.IndexOf(intervals, policy.RetryMinutes),
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { RetryMinutes = intervals[i] }))),
            SettingRow("结果通知", "", "\uE7F4", AutoSignPicker("结果通知", ["仅异常", "成功与异常", "关闭"], (int)policy.Notification,
                i => Model.SetAutoSignSettingsAsync(rule: Model.Preferences.AutoSignRule with { Notification = (AutoSignNotification)i })))));
        Page.Children.Add(SettingsNote("开启后，未单独设置的课程默认参与。课程可在课程详情中停用，单次课次可在计划详情中跳过。签到结果以学校返回状态为准。"));
    }
    void RenderAutoSignPlans(bool choosing)
    {
        var plans = Model.AutoSignPlans.Where(x => choosing || x.IsParticipating).ToList();
        Page.Children.Add(SettingsNote(choosing ? "选择课次后可单独启用本次自动签到。" : "按当前规则预览，不会因浏览而创建执行记录。"));
        if (!choosing) Page.Children.Add(AutoSignLink("选择课次", "\uE8F4", "autosign-select", description: "查看其他课次并单独启用"));
        foreach (var plan in plans)
            Page.Children.Add(AutoSignLink(plan.Course.Name, "\uE787", (choosing ? AutoSignSelectedRoute : AutoSignPlanRoute) + plan.Key,
                plan.StageTitle, $"上课 {AutoSignTime(plan.Course.Start!.Value)} · 计划 {plan.PlannedAt.ToOffset(CourseTime.ShanghaiOffset):HH:mm}"));
        if (plans.Count == 0) Page.Children.Add(SettingsNote(choosing ? "未来七天暂无可选择课次。" : "未来七天暂无参与自动签到的课次。可在课程详情调整课程设置，或通过“选择课次”单独启用本次。"));
    }
    Task SaveAutoSignOccurrence(string key, Func<AutoSignOccurrenceOverride, AutoSignOccurrenceOverride> update)
    {
        var values = new Dictionary<string, AutoSignOccurrenceOverride>(Model.Preferences.AutoSignOccurrences)
        { [key] = update(Model.Preferences.AutoSignOccurrences.GetValueOrDefault(key) ?? new()) };
        return Model.SetAutoSignSettingsAsync(occurrences: values);
    }
    void RenderAutoSignDetail(string key)
    {
        var plan = Model.AutoSignPlans.FirstOrDefault(x => x.Key == key);
        if (plan is null) { Page.Children.Add(SettingsNote("该课次已不在未来七天计划中，请返回重新选择。")); return; }
        var occurrence = Model.Preferences.AutoSignOccurrences.GetValueOrDefault(key);
        Page.Children.Add(Card(Column(Text(plan.Course.Name, 22, true), Text("上课 " + AutoSignTime(plan.Course.Start!.Value), 13, color: Secondary),
            Text("计划 " + AutoSignTime(plan.PlannedAt) + " · " + plan.StageTitle, 13, color: Green), Text(plan.Reason, 13, color: Secondary),
            Text("下一步：" + plan.NextAction, 13, color: Secondary))));
        if (plan.Stage is AutoSignStage.Missed or AutoSignStage.NeedsAttention)
            Page.Children.Add(Button("打开课程签到", () => Detail(Model.AutoSignPlans.FirstOrDefault(x => x.Key == key)?.Course ?? plan.Course)));
        var enabled = AutoSignPicker("本次参与", ["跟随课程", "启用本次", "跳过本次"], occurrence?.Enabled is null ? 0 : occurrence.Enabled.Value ? 1 : 2,
            i => SaveAutoSignOccurrence(key, x => x with { Enabled = i == 0 ? null : i == 1 }));
        var first = plan.Course.Start!.Value.AddMinutes(-25).ToOffset(CourseTime.ShanghaiOffset);
        var count = Math.Max(1, (int)(plan.Course.End!.Value.AddMinutes(-1) - first).TotalMinutes + 1);
        var labels = new[] { "跟随课程" }.Concat(Enumerable.Range(0, count).Select(i => AutoSignTime(first.AddMinutes(i)))).ToArray();
        var hasOwnTime = occurrence?.At is not null || occurrence?.Policy?.OffsetMinutes is not null;
        var timeIndex = (int)(plan.PlannedAt - first).TotalMinutes;
        var time = new ComboBox { ItemsSource = labels, SelectedIndex = !hasOwnTime ? 0 : timeIndex >= 0 && timeIndex < count ? timeIndex + 1 : -1,
            PlaceholderText = "请选择有效时间", MinWidth = 180 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(time, "本次执行时间");
        time.SelectionChanged += async (_, _) =>
        {
            if (time.SelectedIndex < 0) return;
            if (time.SelectedIndex == 0)
            {
                await Run(() => SaveAutoSignOccurrence(key, x => x with { At = null,
                    Policy = x.Policy is null ? null : x.Policy with { OffsetMinutes = null } }));
                return;
            }
            var latest = Model.AutoSignPlans.FirstOrDefault(x => x.Key == key);
            if (latest is null) return;
            var chosen = first.AddMinutes(time.SelectedIndex - 1);
            if (chosen < latest.Course.Start!.Value.AddMinutes(-25) || chosen >= latest.Course.End)
            { Model.SetMessage("本次时间需在课前 25 分钟至下课前"); return; }
            await Run(() => SaveAutoSignOccurrence(key, x => x with { At = chosen }));
        };
        var intervals = new[] { 1, 2, 5 };
        Page.Children.Add(SettingsGroup("仅调整本次",
            SettingRow("本次参与", "全局关闭和课程禁用仍优先", "\uE73E", enabled),
            SettingRow("执行时间", "当前来源：" + plan.Sources["执行时间"], "\uE823", time),
            SettingRow("最多自动提交", $"当前 {plan.Policy.MaxSubmissions} 次 · {plan.Sources["提交次数"]}", "\uE73E", AutoSignPicker("本次最多提交", ["跟随课程", "1 次", "2 次", "3 次"], occurrence?.Policy?.MaxSubmissions ?? 0,
                i => SaveAutoSignOccurrence(key, x => x with { Policy = (x.Policy ?? new()) with { MaxSubmissions = i == 0 ? null : i } }))),
            SettingRow("重试间隔", $"当前 {plan.Policy.RetryMinutes} 分钟 · {plan.Sources["重试间隔"]}", "\uE823", AutoSignPicker("本次重试间隔", ["跟随课程", "1 分钟", "2 分钟", "5 分钟"], occurrence?.Policy?.RetryMinutes is { } retry ? Array.IndexOf(intervals, retry) + 1 : 0,
                i => SaveAutoSignOccurrence(key, x => x with { Policy = (x.Policy ?? new()) with { RetryMinutes = i == 0 ? null : intervals[i - 1] } })))));
        Page.Children.Add(Button("恢复本次继承", () =>
        {
            var values = new Dictionary<string, AutoSignOccurrenceOverride>(Model.Preferences.AutoSignOccurrences); values.Remove(key);
            return Model.SetAutoSignSettingsAsync(occurrences: values);
        }));
    }
    string AutoSignHistoryName(AutoSignExecution item) => string.IsNullOrWhiteSpace(item.CourseName)
        ? Model.AutoSignPlans.FirstOrDefault(x => x.Key == item.Key)?.Course.Name ?? "课程签到" : item.CourseName;
    static DateTimeOffset? AutoSignHistoryAt(AutoSignExecution item) => item.ClassStartAt ?? item.Events.FirstOrDefault()?.At;
    void RenderAutoSignHistory()
    {
        RenderAutoSignError();
        foreach (var item in Model.AutoSignHistory)
            Page.Children.Add(AutoSignLink(AutoSignHistoryName(item), "\uE81C", AutoSignEventRoute + item.Key,
                description: (AutoSignHistoryAt(item) is { } at ? AutoSignTime(at) + " · " : "") + item.Message));
        if (Model.AutoSignHistory.Count == 0) Page.Children.Add(SettingsNote("尚无实际自动执行记录。"));
    }
    void RenderAutoSignEvents(string key)
    {
        var item = Model.AutoSignHistory.FirstOrDefault(x => x.Key == key);
        if (item is null) { Page.Children.Add(SettingsNote("该记录已不在本机保留范围内。")); return; }
        Page.Children.Add(Card(Column(Text(AutoSignHistoryName(item), 22, true),
            Text(AutoSignHistoryAt(item) is { } at ? "上课 " + AutoSignTime(at) : "本机自动执行记录", 13, color: Secondary),
            Text(item.Message, 14, true), Text($"已自动提交 {item.Submissions} 次", 13, color: Secondary))));
        foreach (var entry in item.Events)
            Page.Children.Add(SettingRow(entry.Message, AutoSignTime(entry.At) + entry.At.ToOffset(CourseTime.ShanghaiOffset).ToString(":ss"), "\uE823", Text("", 12)));
    }
}
