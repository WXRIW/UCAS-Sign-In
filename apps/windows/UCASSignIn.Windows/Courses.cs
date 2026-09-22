using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    UIElement PreferenceStatus(bool enabled, string label)
    {
        var marker = new Grid { Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Center };
        marker.Children.Add(new Ellipse
        {
            Width = 10,
            Height = 10,
            Fill = enabled ? Green : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Stroke = enabled ? Green : Secondary,
            StrokeThickness = 1.4
        });
        var text = Text(label, 12, color: Secondary);
        var row = Row(marker, text); row.Spacing = 4;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, label + (enabled ? "，启用" : "，停用"));
        return row;
    }

    UIElement DisabledSignInStatus(string label)
    {
        var marker = new Grid { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        marker.Children.Add(new Ellipse { Width = 13, Height = 13, Stroke = Brush("C42B1C"), StrokeThickness = 1.4 });
        marker.Children.Add(new TextBlock
        {
            Text = "×",
            FontSize = 11,
            Foreground = Brush("C42B1C"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        });
        var row = Row(marker, Text(label, 12, color: Secondary));
        row.Spacing = 4;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, label);
        return row;
    }

    void RenderCourses()
    {
        if (!Model.IsConnected)
        {
            Page.Children.Add(Card(Column(Text("连接账户后查看课程", 20, true), Text("课程目录来自学校当前学期，不会由日课表拼接。", 13, color: Secondary), Button("连接账户", () => Login(), true)), 24));
            return;
        }
        if (Model.ShouldRefreshCatalog && !Model.IsCatalogRefreshing)
            _ = Run(() => Model.RefreshCatalogAsync());
        if (Model.SelectedSemester is { } semester)
            Page.Children.Add(Text(semester.Name, 14, true));
        if (Model.CatalogUpdatedAt is { } updated)
            Page.Children.Add(Text($"课程目录 · 最后更新 {updated.ToLocalTime():M-d HH:mm}", 12, color: Secondary));
        if (!string.IsNullOrWhiteSpace(Model.CatalogError))
            Page.Children.Add(Card(Text("刷新失败：" + Model.CatalogError + "\n正在保留已缓存的课程。", 12, color: Secondary)));

        var search = new TextBox { PlaceholderText = "搜索课程名、课程编号或教师", Text = courseSearch, HorizontalAlignment = HorizontalAlignment.Stretch };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(search, "搜索课程");
        Page.Children.Add(search);
        var list = new StackPanel { Spacing = 10 };
        Page.Children.Add(list);
        void UpdateList()
        {
            courseSearch = search.Text.Trim(); list.Children.Clear();
            var query = Model.CatalogCourses.Where(c => courseSearch.Length == 0 || new[] { c.Name, c.Number, c.Teacher }.Any(x => x.Contains(courseSearch, StringComparison.OrdinalIgnoreCase))).ToList();
            if (Model.IsCatalogRefreshing && Model.CatalogCourses.Count == 0)
            {
                list.Children.Add(Card(Row(new ProgressRing { IsActive = true, Width = 18, Height = 18, Foreground = Green }, Text("正在加载课程目录…", 13))));
                return;
            }
            if (query.Count == 0)
            {
                list.Children.Add(Card(Text(courseSearch.Length == 0 ? "当前学期暂无课程" : "没有匹配的课程", 14, color: Secondary), 24));
                return;
            }
            foreach (var course in query)
            {
                var disabled = Model.IsSignInDisabled(course.Id);
                var statuses = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
                statuses.Children.Add(PreferenceStatus(Model.EffectiveReminders(course.Id), "提醒"));
                if (!disabled)
                {
                    statuses.Children.Add(PreferenceStatus(Model.EffectiveConfirmation(course.Id), "二次确认"));
                    statuses.Children.Add(PreferenceStatus(Model.EffectiveAutoSign(course.Id), "自动签到"));
                }
                else statuses.Children.Add(DisabledSignInStatus("已禁用签到"));
                var content = Across(Column(Text(course.Name, 16, true), Text(string.IsNullOrWhiteSpace(course.Number) ? "课程编号暂未提供" : course.Number, 12, color: Secondary), statuses),
                    new FontIcon { Glyph = "\uE76C", FontSize = 14, Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center });
                list.Children.Add(ActionCard(content, () => CatalogDetail(course)));
            }
        }
        search.TextChanged += (_, _) => UpdateList();
        UpdateList();
    }

    ComboBox OverridePicker(string label, PreferenceOverride value, bool inherited, Func<PreferenceOverride, Task> save)
    {
        var picker = new ComboBox { MinWidth = 190, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var item in new[] { PreferenceOverride.Inherit, PreferenceOverride.Enabled, PreferenceOverride.Disabled })
        {
            var enabled = item == PreferenceOverride.Inherit ? inherited : item == PreferenceOverride.Enabled;
            var text = item == PreferenceOverride.Inherit ? "跟随全局" : item == PreferenceOverride.Enabled ? "启用" : "停用";
            picker.Items.Add(new ComboBoxItem { Content = Row(new Ellipse { Width = 8, Height = 8, Fill = Brush(enabled ? "248A3D" : "C42B1C") }, Text(text, 13)), Tag = item });
        }
        picker.SelectedIndex = (int)CoursePreferences.Normalize(value);
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is ComboBoxItem { Tag: PreferenceOverride selected } && selected != value)
                await Run(() => save(selected));
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, label);
        return picker;
    }

    StackPanel CourseInformationSection(UIElement content)
    {
        return SettingsGroup("课程信息", Card(content, 20));
    }

    UIElement CourseInfoRow(string glyph, string label, string value)
    {
        var icon = SettingsIcon(glyph);
        icon.FontSize = 15;
        icon.Foreground = Secondary;
        var caption = Row(icon, Text(label, 12, color: Secondary));
        caption.Spacing = 8;
        var grid = new Grid { ColumnSpacing = 18 };
        grid.ColumnDefinitions.Add(new() { Width = new(118) });
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        grid.Children.Add(caption);
        var valueText = Text(value, 13);
        Grid.SetColumn(valueText, 1);
        grid.Children.Add(valueText);
        return grid;
    }

    Border CourseMetric(string title, int value, Brush color, Brush background)
    {
        var number = Text(value.ToString(), 24, true, color);
        number.TextAlignment = TextAlignment.Center;
        number.HorizontalAlignment = HorizontalAlignment.Stretch;
        var label = Text(title, 12, color: Secondary);
        label.TextAlignment = TextAlignment.Center;
        label.HorizontalAlignment = HorizontalAlignment.Stretch;
        var copy = Column(number, label);
        copy.Spacing = 4;
        copy.HorizontalAlignment = HorizontalAlignment.Stretch;
        return new Border
        {
            Child = copy,
            Padding = new(12),
            Background = background,
            CornerRadius = new(12),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
    }

    UIElement AttendanceStatus(bool signed)
    {
        if (signed)
        {
            var signedMarker = new Grid { Width = 14, Height = 14 };
            signedMarker.Children.Add(new Ellipse { Width = 13, Height = 13, Fill = Green, Stroke = Green, StrokeThickness = 1.4 });
            signedMarker.Children.Add(new TextBlock
            {
                Text = "✓",
                FontSize = 9,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                Foreground = Brush("FFFFFF"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
            var signedRow = Row(signedMarker, Text("已签到", 12, true, Green));
            signedRow.Spacing = 5;
            return signedRow;
        }
        var marker = new Grid { Width = 14, Height = 14 };
        marker.Children.Add(new Ellipse { Width = 13, Height = 13, Stroke = Secondary, StrokeThickness = 1.4 });
        marker.Children.Add(new TextBlock
        {
            Text = "×",
            FontSize = 11,
            Foreground = Secondary,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        });
        var row = Row(marker, Text("未签到", 12, true, Secondary));
        row.Spacing = 5;
        return row;
    }

    UIElement OperationStatus(bool succeeded)
    {
        if (succeeded)
        {
            var marker = new Grid { Width = 14, Height = 14 };
            marker.Children.Add(new Ellipse { Width = 13, Height = 13, Fill = Green, Stroke = Green, StrokeThickness = 1.4 });
            marker.Children.Add(new TextBlock
            {
                Text = "✓",
                FontSize = 9,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                Foreground = Brush("FFFFFF"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
            var success = Row(marker, Text("成功", 12, color: Secondary));
            success.Spacing = 5;
            return success;
        }
        var failed = Row(new FontIcon { Glyph = "\uE783", FontSize = 14, Foreground = Secondary }, Text("失败", 12, color: Secondary));
        failed.Spacing = 5;
        return failed;
    }

    void RenderCatalogDetail(CatalogCourse course)
    {
        var values = Model.CoursePreferencesFor(course.Id);
        string Missing(string? value) => string.IsNullOrWhiteSpace(value) ? "暂未提供" : value;
        var information = new StackPanel { Spacing = 14 };
        information.Children.Add(CourseInfoRow("\uE943", "课程编号", Missing(course.Number)));
        information.Children.Add(CourseInfoRow("\uE77B", "教师", Missing(course.Teacher)));
        information.Children.Add(CourseInfoRow("\uE707", "教室", Missing(course.Classroom)));
        information.Children.Add(CourseInfoRow("\uE787", "学期", Missing(Model.Semesters.FirstOrDefault(s => s.Id == course.SemesterId)?.Name ?? course.SemesterId)));
        information.Children.Add(CourseInfoRow("\uE823", "课程日期", DisplayLongDay(course.BeginDate) + "–" + DisplayLongDay(course.EndDate)));
        Page.Children.Add(CourseInformationSection(information));
        RenderCourseScheduleSummary(course);
        if (string.IsNullOrWhiteSpace(course.Id)) { Page.Children.Add(Text("课程身份尚未唯一关联，设置与学校考勤暂不可用。", 14, color: Secondary)); return; }

        var reminder = OverridePicker("课前提醒", values.Reminders, Model.Preferences.RemindersEnabled,
            selected => Model.SetCoursePreferencesAsync(course.Id, values with { Reminders = selected }));
        var notificationRows = SettingsGroup("通知", SettingRow("课前提醒", "在上课前发送本地通知", "\uE7F4", reminder));
        var notificationCards = (StackPanel)notificationRows.Children[1];
        if (Model.EffectiveReminders(course.Id))
        {
            var lead = new ComboBox { ItemsSource = new[] { "跟随全局", "5 分钟", "10 分钟", "15 分钟", "30 分钟" }, MinWidth = 190,
                SelectedIndex = values.ReminderLeadMinutes switch { 5 => 1, 10 => 2, 15 => 3, 30 => 4, _ => 0 } };
            lead.SelectionChanged += async (_, _) =>
            {
                var selected = lead.SelectedIndex switch { 1 => 5, 2 => 10, 3 => 15, 4 => 30, _ => (int?)null };
                if (selected != values.ReminderLeadMinutes) await Run(() => Model.SetCoursePreferencesAsync(course.Id, values with { ReminderLeadMinutes = selected }));
            };
            notificationCards.Children.Add(SettingRow("提醒时间", $"当前有效值：提前 {Model.EffectiveReminderLeadMinutes(course.Id)} 分钟", "\uE823", lead));
        }
        Page.Children.Add(notificationRows);

        var disabled = new ToggleSwitch { IsOn = values.SignInDisabled, OnContent = "", OffContent = "", Width = 50, MinWidth = 0 };
        disabled.Toggled += async (_, _) => { if (disabled.IsOn != values.SignInDisabled) await Run(() => Model.SetCoursePreferencesAsync(course.Id, values with { SignInDisabled = disabled.IsOn })); };
        var signRows = SettingsGroup("签到");
        var signCards = (StackPanel)signRows.Children[1];
        if (!values.SignInDisabled)
        {
            signCards.Children.Add(SettingRow("手动签到二次确认", "手动签到前显示课程与上课时间", "\uE9D5",
                OverridePicker("手动签到二次确认", values.Confirmation, Model.Preferences.ConfirmBeforeSign,
                    selected => Model.SetCoursePreferencesAsync(course.Id, values with { Confirmation = selected }))));
            signCards.Children.Add(SettingRow("自动签到", "进入签到时段后自动尝试一次", "\uE73E",
                OverridePicker("自动签到", values.AutoSign, Model.Preferences.AutoSignEnabled,
                    selected => Model.SetCoursePreferencesAsync(course.Id, values with { AutoSign = selected }))));
        }
        signCards.Children.Add(SettingRow("禁用本课程签到", "暂停本课程的手动签到和自动签到", "\uEA39", disabled));
        Page.Children.Add(signRows);

        var refresh = Button(Model.IsAttendanceRefreshing(course.Id) ? "正在刷新…" : "刷新", () => Model.RefreshAttendanceAsync(course.Id, true));
        refresh.IsEnabled = !Model.IsAttendanceRefreshing(course.Id);
        var attendanceContent = new StackPanel { Spacing = 0 };
        var attendanceCopy = Column(Text("考勤统计与明细", 14, true), Text("学校记录的签到次数及每次上课的签到状态", 12, color: Secondary));
        attendanceCopy.Spacing = 4;
        var attendanceHeading = Across(
            Leading(SettingsIcon("\uE73E"), attendanceCopy),
            refresh);
        attendanceContent.Children.Add(new Border { Child = attendanceHeading, Padding = new(20, 16, 20, Model.AttendanceFor(course.Id) is not null ? 12 : 16) });
        Border AttendanceRule() => new() { Height = 1, Background = Stroke, Margin = new(20, 0, 20, 0) };
        if (Model.AttendanceFor(course.Id) is { } summary)
        {
            var metrics = new Grid { ColumnSpacing = 12 };
            metrics.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            metrics.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            metrics.Children.Add(CourseMetric("已签到", summary.SignedCount, Green, Pale));
            var unsigned = CourseMetric("未签到", summary.UnsignedCount, Secondary, Hover);
            Grid.SetColumn(unsigned, 1);
            metrics.Children.Add(unsigned);
            attendanceContent.Children.Add(new Border { Child = metrics, Padding = new(20, 0, 20, 16) });
            foreach (var record in summary.Records.OrderByDescending(x => x.Day))
            {
                attendanceContent.Children.Add(AttendanceRule());
                var recordRow = Across(
                    Column(Text(DisplayLongDay(record.Day), 14, true), Text($"{CourseTime.Display(record.BeginTime)}–{CourseTime.Display(record.EndTime)}", 12, color: Secondary)),
                    AttendanceStatus(record.Signed));
                attendanceContent.Children.Add(new Border { Child = recordRow, Padding = new(20, 14, 20, 14) });
            }
        }
        else if (Model.AttendanceError(course.Id) is { } error)
        {
            attendanceContent.Children.Add(AttendanceRule());
            attendanceContent.Children.Add(new Border { Child = Column(Text("刷新失败", 14, true), Text(error, 12, color: Secondary)), Padding = new(54, 16, 20, 16) });
        }
        else
        {
            attendanceContent.Children.Add(AttendanceRule());
            attendanceContent.Children.Add(new Border { Child = Text("暂无学校考勤记录", 12, color: Secondary), Padding = new(54, 16, 20, 16) });
        }
        var attendanceFooter = Model.AttendanceUpdatedAt(course.Id) is { } at
            ? $"学校数据同步于 {at.ToLocalTime():M月d日 HH:mm}。"
            : "考勤数据来自学校接口，进入页面后按缓存有效期自动更新，也可手动刷新。";
        var attendanceGroup = SettingsGroup("学校考勤", Card(attendanceContent, 0));
        attendanceGroup.Children.Add(SettingsNote(attendanceFooter));
        Page.Children.Add(attendanceGroup);

        var local = Model.RecordsForCourse(course.Id).ToList();
        var localGroup = SettingsGroup("本机操作记录");
        var localRows = (StackPanel)localGroup.Children[1];
        if (local.Count == 0)
            localRows.Children.Add(SettingRow("暂无本机记录", "本机尚无这门课程的签到操作记录", "\uE81C", Text("", 12)));
        foreach (var record in local)
        {
            localRows.Children.Add(SettingRow(record.Message, record.Date.ToLocalTime().ToString("M月d日 HH:mm"),
                record.Succeeded ? "\uE73E" : "\uE783", OperationStatus(record.Succeeded)));
        }
        localGroup.Children.Add(SettingsNote("仅保存在本机，与学校返回的考勤状态分开显示。"));
        Page.Children.Add(localGroup);
    }

    static string DisplayDay(string day) => day.Length == 8 ? $"{day[..4]}-{day.Substring(4, 2)}-{day[6..]}" : string.IsNullOrWhiteSpace(day) ? "暂未提供" : day;
    static string DisplayLongDay(string day) => day.Length == 8 && int.TryParse(day[..4], out var year) && int.TryParse(day.Substring(4, 2), out var month) && int.TryParse(day[6..], out var value)
        ? $"{year}年{month}月{value}日"
        : string.IsNullOrWhiteSpace(day) ? "暂未提供" : day;
}
