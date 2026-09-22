using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using UCASSignIn.Core;
using UCASSignIn.Windows.Services;
using Windows.System;
namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    string? route;
    Course? detail;
    CatalogCourse? catalogDetail;
    string courseSearch = "";
    readonly Dictionary<string, (string? Route, Course? Detail, CatalogCourse? CatalogDetail)> paths = [];
    bool dark => Root.ActualTheme == ElementTheme.Dark;
    SolidColorBrush Brush(string hex) => new(global::Windows.UI.Color.FromArgb(255, Convert.ToByte(hex[..2], 16), Convert.ToByte(hex[2..4], 16), Convert.ToByte(hex[4..6], 16)));
    SolidColorBrush Ink => Brush(dark ? "F3F3F3" : "1A1A1A");
    SolidColorBrush Green => Brush(dark ? "91C6A6" : "285C45");
    SolidColorBrush Secondary => Brush(dark ? "C5C5C5" : "616161");
    SolidColorBrush Surface => Brush(dark ? "2B2B2B" : "FFFFFF");
    SolidColorBrush Stroke => Brush(dark ? "414141" : "E0E0E0");
    SolidColorBrush Hover => Brush(dark ? "323232" : "F5F5F5");
    SolidColorBrush Pressed => Brush(dark ? "383838" : "EEEEEE");
    SolidColorBrush Pale => Brush(dark ? "2C4234" : "E8EFE4");
    TextBlock Text(string value, double size = 14, bool bold = false, Brush? color = null) => new() { Text = value, FontSize = size, FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal, Foreground = color ?? Ink, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    StackPanel Column(params UIElement[] items)
    {
        var p = new StackPanel { Spacing = 10 };
        foreach (var item in items)
            p.Children.Add(item);
        return p;
    }
    StackPanel Row(params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in items)
            p.Children.Add(item);
        return p;
    }
    Grid Across(UIElement left, UIElement right)
    {
        var p = new Grid { ColumnSpacing = 12 };
        p.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        p.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        p.Children.Add(left);
        Grid.SetColumn((FrameworkElement)right, 1);
        p.Children.Add(right);
        return p;
    }
    Grid Leading(UIElement icon, UIElement content)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        grid.Children.Add(icon);
        Grid.SetColumn((FrameworkElement)content, 1);
        grid.Children.Add(content);
        return grid;
    }
    Border Card(UIElement child, int padding = 16) => new() { Child = child, Padding = new(padding), Style = (Style)Application.Current.Resources["SurfaceCardStyle"] };
    // Override the native template's state brushes as well as its resting colors.
    // Otherwise transparent/green buttons flash the default gray fill on hover.
    void ButtonColors(Button button, Brush background, Brush foreground, Brush hover, Brush pressed)
    {
        button.Background = background;
        button.Foreground = foreground;
        button.Resources["ButtonBackgroundPointerOver"] = hover;
        button.Resources["ButtonBackgroundPressed"] = pressed;
        button.Resources["ButtonForegroundPointerOver"] = foreground;
        button.Resources["ButtonForegroundPressed"] = foreground;
    }
    Button Button(string title, Func<Task> action, bool primary = false)
    {
        var b = new Button { Content = title, MinHeight = 32, Padding = new(12, 6, 12, 6), CornerRadius = new(4), IsEnabled = Model.CanChangeAccount, UseSystemFocusVisuals = true,
            Style = (Style)Application.Current.Resources[primary ? "AccentButtonStyle" : "DefaultButtonStyle"] };
        b.Click += async (_, _) => await Run(action);
        return b;
    }
    Button ActionCard(UIElement content, Func<Task> action)
    {
        var b = Button("", action);
        b.Style = (Style)Application.Current.Resources["CardActionButtonStyle"];
        b.Content = content;
        b.Padding = new(16);
        b.CornerRadius = new(8);
        b.MinHeight = 64;
        return b;
    }
    FontIcon SettingsIcon(string glyph)
    {
        return new FontIcon
        {
            Glyph = glyph,
            FontSize = 18,
            Width = 20,
            Height = 20,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
    }
    SettingsCard SettingsLink(string title, string glyph, Func<Task> action, string? description = null)
    {
        var card = new SettingsCard
        {
            Header = title,
            Description = description ?? "",
            HeaderIcon = SettingsIcon(glyph),
            IsClickEnabled = true,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinHeight = description is null ? 56 : 68,
            IsEnabled = Model.CanChangeAccount
        };
        card.Click += async (_, _) => await Run(action);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, title);
        return card;
    }
    StackPanel SettingsGroup(string title, params UIElement[] rows)
    {
        var header = Text(title, 14, true);
        header.Margin = new(2, 0, 0, 0);
        var cards = new StackPanel { Spacing = 2 };
        foreach (var row in rows)
            cards.Children.Add(row);
        var group = new StackPanel { Spacing = 8 };
        group.Children.Add(header);
        group.Children.Add(cards);
        return group;
    }
    TextBlock SettingsNote(string value)
    {
        var note = Text(value, 12, color: Secondary);
        note.Margin = new(2, 0, 2, 0);
        return note;
    }
    Button Plain(UIElement content, Func<Task> action)
    {
        var b = Button("", action);
        b.Content = content;
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ButtonColors(b, transparent, Green, transparent, transparent);
        b.Resources["ButtonBackgroundDisabled"] = transparent;
        b.Padding = new(0);
        b.BorderThickness = new(0);
        // The native ContentPresenter clips children to this radius, even with
        // a transparent background. Edge-aligned text needs a square viewport.
        // Padded menu rows and cards opt back into their own radius below.
        b.CornerRadius = new(0);
        b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        b.HorizontalAlignment = HorizontalAlignment.Stretch;
        return b;
    }
    UIElement Rule() => new Border { Height = 1, Background = Stroke };
    string Name(string? name) => string.IsNullOrWhiteSpace(name) ? "同学" : vm.HideIdentity ? name[..1] + "同学" : name;
    string AccountName => Model.IsDemo ? Name("演示同学") : Model.ActiveAccount is { } a ? Name(a.Session.Name) : "连接账户";
    string Number(string number) => vm.HideIdentity ? "••••••••" : number;
    List<Course> DayCourses(DateOnly date) => Model.Courses.Where(c => c.Day == CourseTime.DayKey(date)).OrderBy(c => c.Start).ToList();
    void ApplyTheme()
    {
        Root.RequestedTheme = vm.Theme == "dark" ? ElementTheme.Dark : vm.Theme == "light" ? ElementTheme.Light : ElementTheme.Default;
        Root.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        // NavigationView supplies its native, theme-aware content layer above Mica.
        ContentSurface.Background = null;
    }
    void RenderCurrentPage()
    {
        if (Page is null)
            return;
        qrCancellation?.Cancel();
        ApplyTheme();
        UpdateScheduleNavigation();
        AccountMenuLabel.Text = AccountName;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(AccountMenu, AccountName);
        AccountMenu.IsEnabled = Model.CanChangeAccount;
        AppTitleBar.IsBackButtonVisible = route is not null;
        AppTitleBar.IsBackButtonEnabled = route is not null;
        UpdateRefreshButton();
        PageTitle.Text = route switch
        {
            "detail" => "课程签到",
            "catalog-detail" => catalogDetail?.Name ?? "课程详情",
            "course-schedule" => "排课信息",
            "settings" => "设置",
            "records" => Model.IsDemo ? "演示签到记录" : "本机签到记录",
            "about" => "关于",
            "source" => "项目源码与致谢",
            "disclaimer" => "免责声明",
            _ => section == "today" ? "果壳签到" : section == "schedule" ? "课表" : section == "courses" ? "课程" : "账户"
        };
        Status.Message = Model.Message ?? "";
        Status.IsOpen = !string.IsNullOrWhiteSpace(Model.Message);
        Status.Severity = InfoBarSeverity.Informational;
        if (section == "schedule" && route is null && UpdateExistingWeek()) return;
        if (RetainCourseSchedule()) return;
        if (route == "course-schedule" && renderedCourseSchedule is { } prior && prior.Panel == Page)
            saveCourseSchedulePosition?.Invoke();
        ScheduleHeader.Children.Clear();
        Page.Children.Clear();
        Page.Spacing = section == "account" || route is "settings" or "catalog-detail" ? 24 : 20;
        if (route == "detail" && detail is { } c)
        {
            RenderDetail(Model.Courses.FirstOrDefault(x => x.Id == c.Id && x.Day == c.Day) ?? c);
            return;
        }
        if (route == "course-schedule" && catalogDetail is { } scheduledCourse)
        { RenderCourseSchedule(scheduledCourse); return; }
        if (route == "catalog-detail" && catalogDetail is { } catalogCourse)
        {
            RenderCatalogDetail(Model.AllCatalogCourses.FirstOrDefault(x => CourseSchedule.SameCourse(x, catalogCourse)) ?? catalogCourse);
            return;
        }
        if (route is not null)
        {
            if (route == "settings") RenderSettings();
            else RenderInformation();
            return;
        }
        if (section == "account")
        {
            RenderAccount();
            return;
        }
        if (section == "schedule")
        {
            RenderSchedule();
            return;
        }
        if (section == "courses")
        {
            RenderCourses();
            return;
        }
        RenderToday();
    }
    void Banner(DateOnly date)
    {
        if (Model.IsDemo)
        {
            Page.Children.Add(Card(Across(Leading(new FontIcon { Glyph = "\uE946", FontSize = 16, Foreground = Green },
                Text("演示模式 · 示例课表", 12, color: Secondary)), Button("连接账号", () => Login())), 12));
        }
        else if (Model.IsCached(date))
        {
            var syncing = Model.IsLoadingCourses(date);
            var retry = Button(syncing ? "正在同步…" : "重新同步", () => Model.RefreshAsync(date));
            retry.IsEnabled = Model.CanChangeAccount && !syncing;
            var b = Card(Across(Text("正在显示本机缓存\n同步后可继续签到", 12, color: Secondary), retry), 14);
            b.Background = Pale;
            Page.Children.Add(b);
        }
    }
    void RenderToday()
    {
        var now = DateTimeOffset.Now.ToOffset(CourseTime.ShanghaiOffset);
        var courses = DayCourses(CourseTime.Today());
        var greeting = Text("", 30, true);
        greeting.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "今天，" });
        greeting.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "从容一点。", Foreground = Green });
        var introduction = Column(
            Text(now.ToString("M 月 d 日 · dddd", System.Globalization.CultureInfo.GetCultureInfo("zh-CN")), 12, color: Secondary),
            greeting,
            Text(Model.IsConnected ? "课表、签到，都在这里。" : "你的国科大课堂，轻松相伴。", 13, color: Secondary));
        introduction.Spacing = 9;
        Page.Children.Add(introduction);
        if (!Model.IsConnected)
        {
            Welcome();
            return;
        }
        Banner(CourseTime.Today());
        var (current, next) = CourseTime.CurrentAndNext(courses, now);
        var featured = current is { Signed: false } ? current : next ?? current ?? courses.LastOrDefault();
        if (featured is not null)
        {
            var sign = Button(featured.Signed ? "已完成签到" : "一键签到", () => RequestManualSignAsync(featured), true);
            sign.IsEnabled = Model.CanSign(featured);
            sign.MinWidth = 132;
            sign.Height = 36;
            var qr = Button("", () => Detail(featured));
            qr.Content = new FontIcon { Glyph = "\uED14", FontSize = 16 };
            qr.Width = 36;
            qr.Height = 36;
            qr.Padding = new(0);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(qr, "课程签到二维码");
            ToolTipService.SetToolTip(qr, "课程签到二维码");
            var caption = Text(featured.Signed ? "已签到" : current?.Id == featured.Id ? "正在进行" : "下一节课", 12, true, Green);
            var actions = Row(sign, qr);
            actions.Margin = new(0, 8, 0, 0);
            Page.Children.Add(Card(Column(caption, Text(featured.Name, 24, true),
                Leading(new FontIcon { Glyph = "\uE917", FontSize = 14, Foreground = Secondary }, Text(featured.TimeRange, 14, color: Secondary)),
                Text(Metadata(featured, true), 12, color: Secondary), actions), 20));
        }
        var ringHost = AttendanceRing(courses.Count(c => c.Signed), courses.Count);
        var metrics = new Grid { ColumnSpacing = 22 };
        metrics.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        metrics.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        metrics.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        metrics.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        metrics.Children.Add(SummaryMetric("今日课程", courses.Count));
        var divider = new Border { Width = 1, Height = 30, Background = Pale };
        Grid.SetColumn(divider, 1);
        metrics.Children.Add(divider);
        var signed = SummaryMetric("已签到", courses.Count(c => c.Signed));
        Grid.SetColumn(signed, 2);
        metrics.Children.Add(signed);
        Grid.SetColumn(ringHost, 3);
        metrics.Children.Add(ringHost);
        Page.Children.Add(Card(metrics));
        Page.Children.Add(Across(Text("今日安排", 20, true), Button("查看课表", () => Select(1))));
        Timeline(courses);
        Page.Children.Add(Text(Model.IsDemo ? "示例数据，仅供体验" : Model.LastSyncAt is { } sync ? $"上次同步 {sync.ToOffset(CourseTime.ShanghaiOffset):HH:mm} · Ctrl+R 刷新" : "使用右上角按钮或 Ctrl+R 同步课程", 12, color: Secondary));
    }
    string Metadata(Course c, bool showMissingClassroom = false) => string.Join("   ·   ", new[] { c.Classroom ?? (showMissingClassroom ? "教室暂未提供" : null), c.Teacher }.Where(s => !string.IsNullOrWhiteSpace(s)));
    void Welcome() => Page.Children.Add(Card(Column(Text("连接学校账户", 20, true), Text("登录后可同步课表、查看签到状态并管理课程提醒。", 14, color: Secondary), Button("连接账户", () => Login(), true), Button("先体验演示模式", Model.EnterDemoAsync)), 20));
    void Timeline(IReadOnlyList<Course> courses)
    {
        if (courses.Count == 0)
        {
            Page.Children.Add(Card(Column(Text("当天暂无课程", 20, true), Text("可在课表中选择其他日期，或刷新课程列表。", 14, color: Secondary))));
            return;
        }
        var list = new StackPanel { Spacing = 12 };
        foreach (var c in courses)
        {
            var line = new Border { Width = 3, Height = 38, CornerRadius = new(2), Background = c.Signed ? Pale : Green };
            var badge = Text(c.Signed ? "已签到" : "未签到", 12, color: c.Signed ? Secondary : Green);
            var content = Across(Leading(line, Column(Text(c.Name, 16, true), Text(Metadata(c), 12, color: Secondary))), Row(badge, new FontIcon { Glyph = "\uE76C", FontSize = 10, Foreground = Secondary }));
            var open = ActionCard(content, () => Detail(c));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, $"{c.Name}，{c.TimeRange}，{(c.Signed ? "已签到" : "未签到")}");
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new()
            {
                Width = new(42)
            });
            grid.ColumnDefinitions.Add(new()
            {
                Width = new(1, GridUnitType.Star)
            });
            grid.Children.Add(Column(Text(CourseTime.Display(c.BeginTime), 12, true), Text(CourseTime.Display(c.EndTime), 10, color: Secondary)));
            Grid.SetColumn(open, 1);
            grid.Children.Add(open);
            list.Children.Add(grid);
        }
        Page.Children.Add(list);
    }
    void RenderDailySchedule()
    {
        var date = Model.SelectedDate;
        var weekHeader = new Grid();
        weekHeader.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        weekHeader.ColumnDefinitions.Add(new()
        {
            Width = new(1, GridUnitType.Star)
        });
        weekHeader.ColumnDefinitions.Add(new()
        {
            Width = GridLength.Auto
        });
        var previousWeek = Plain(new FontIcon { Glyph = "\uE76B", FontSize = 12 }, () => Model.MoveScheduleWeekAsync(false));
        previousWeek.IsEnabled = Model.PreviousScheduleWeek is not null;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(previousWeek, "上一周");
        weekHeader.Children.Add(previousWeek);
        var month = ScheduleMonthTitle();
        month.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetColumn(month, 1);
        weekHeader.Children.Add(month);
        var nextWeek = Plain(new FontIcon { Glyph = "\uE76C", FontSize = 12 }, () => Model.MoveScheduleWeekAsync(true));
        nextWeek.IsEnabled = Model.NextScheduleWeek is not null;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nextWeek, "下一周");
        Grid.SetColumn(nextWeek, 2);
        weekHeader.Children.Add(nextWeek);
        Page.Children.Add(weekHeader);
        var week = new Grid { ColumnSpacing = 4 };
        var monday = date.AddDays(-(((int)date.DayOfWeek + 6) % 7));
        for (int i = 0; i < 7; i++)
        {
            week.ColumnDefinitions.Add(new()
            {
                Width = new(1, GridUnitType.Star)
            });
            var d = monday.AddDays(i);
            var active = d == date;
            var p = Column(Text(new[] { "一", "二", "三", "四", "五", "六", "日" }[i], 12, color: active ? Brush("FFFFFF") : Secondary), Text(d.Day.ToString(), 16, true, active ? Brush("FFFFFF") : Ink));
            p.Spacing = 4;
            foreach (FrameworkElement item in p.Children)
                item.HorizontalAlignment = HorizontalAlignment.Center;
            var b = Button("", ScheduleDayAction(d));
            b.IsEnabled = Model.CanSelectVisibleDate(d); b.Opacity = b.IsEnabled ? 1 : .35;
            b.Content = p;
            b.Padding = new(0, 8, 0, 8);
            b.HorizontalAlignment = HorizontalAlignment.Stretch;
            ButtonColors(b, active ? Brush("285C45") : Surface, active ? Brush("FFFFFF") : Ink,
                active ? Brush("346D53") : Hover, active ? Brush("1F4736") : Pressed);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, d.ToString("M月d日") + (active ? "，已选中" : ""));
            Grid.SetColumn(b, i);
            week.Children.Add(b);
        }
        Page.Children.Add(week);
        if (!Model.IsConnected)
        {
            Welcome();
            return;
        }
        Banner(date);
        var courses = DayCourses(date);
        Page.Children.Add(Across(Text(date.ToString("M 月 d 日"), 20, true), Text($"{courses.Count} 门课程", 12, color: Secondary)));
        Timeline(courses);
        if (date != CourseTime.Today() && Model.CanReturnToToday)
            Page.Children.Add(Button("回到今天", Model.ReturnToScheduleTodayAsync));
    }
    void RenderAccount()
    {
        var a = Model.ActiveAccount;
        var identity = Column(Text(AccountName, 22, true), Text(Model.IsConnected ? "学号 " + Number(Model.IsDemo ? "2026123456" : a!.Id) : "点击登录，连接账户", 14, color: Secondary), Text(Model.IsDemo ? "演示模式 · 点击连接账户" : "中国科学院大学 · 轻新课堂", 12, color: Secondary));
        identity.Spacing = 5;
        var avatar = new PersonPicture { DisplayName = AccountName, Width = 56, Height = 56 };
        UIElement identityContent = Leading(avatar, identity);
        // An already connected account is information, not a no-op button.
        if (Model.IsDemo || a is null || a.RequiresLogin || a.Session.Name is null)
            identityContent = Plain(identityContent, () => Model.IsDemo || a is null ? Login() : Login(a));
        var eye = Button("", () => { vm.HideIdentity = !vm.HideIdentity; vm.SaveAppearance(); Render(); return Task.CompletedTask; });
        eye.Content = new FontIcon { Glyph = vm.HideIdentity ? "\uED1A" : "\uE890", FontSize = 16 };
        eye.Width = 36;
        eye.Height = 36;
        eye.HorizontalContentAlignment = HorizontalAlignment.Center;
        eye.Padding = new(0);
        ToolTipService.SetToolTip(eye, "隐藏或显示姓名与学号");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(eye, vm.HideIdentity ? "显示账户信息" : "隐藏账户信息");
        var accountHeader = Across(identityContent, eye);
        Page.Children.Add(Card(accountHeader, 20));
        Page.Children.Add(SettingsGroup("账户与数据",
            SettingsLink("切换与管理账户", "\uE716", ManageAccounts),
            SettingsLink("本机签到记录", "\uE81C", () => Navigate("records"))));
        Page.Children.Add(SettingsGroup("应用",
            SettingsLink("设置", "\uE713", () => Navigate("settings")),
            SettingsLink("关于", "\uE946", () => Navigate("about")),
            SettingsLink("免责声明", "\uE8A5", () => Navigate("disclaimer"))));
        if (Model.IsConnected)
        {
            var exitAccount = Button(Model.IsDemo ? "退出演示模式" : "退出并移除此账户", () => Model.IsDemo ? ConfirmExitDemo() : Remove(a!));
            exitAccount.Name = "ExitAccountButton";
            exitAccount.HorizontalAlignment = HorizontalAlignment.Stretch;
            exitAccount.HorizontalContentAlignment = HorizontalAlignment.Center;
            exitAccount.VerticalContentAlignment = VerticalAlignment.Center;
            exitAccount.MinHeight = 44;
            ButtonColors(exitAccount, Surface, Model.IsDemo ? Secondary : Brush(dark ? "FF99A4" : "C42B1C"),
                Model.IsDemo ? Hover : Brush(dark ? "39272B" : "FCEDEC"), Model.IsDemo ? Pressed : Brush(dark ? "492D33" : "F8DDDB"));
            Page.Children.Add(exitAccount);
        }
        var foot = Text($"果壳签到 {Information.DisplayVersion}", 12, color: Secondary);
        foot.TextAlignment = TextAlignment.Center;
        foot.Margin = new(0, -4, 0, 0);
        Page.Children.Add(foot);
    }
    void RenderSettings()
    {
        var theme = new ComboBox { ItemsSource = new[] { "跟随系统", "浅色", "深色" }, SelectedIndex = vm.Theme == "light" ? 1 : vm.Theme == "dark" ? 2 : 0, MinWidth = 160 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(theme, "主题");
        theme.SelectionChanged += (_, _) =>
        {
            if (theme.SelectedIndex < 0) return;
            vm.Theme = new[] { "system", "light", "dark" }[theme.SelectedIndex];
            vm.SaveAppearance();
            Render();
        };
        Page.Children.Add(SettingsGroup("外观", SettingRow("主题", "选择应用的显示模式", "\uE790", theme)));
        var otherWeeks = new ToggleSwitch { IsOn = Model.ShowOtherWeeks, OnContent = "", OffContent = "" };
        otherWeeks.Toggled += (_, _) => { Model.ShowOtherWeeks = otherWeeks.IsOn; vm.SaveAppearance(); };
        Page.Children.Add(SettingsGroup("课表", SettingRow("显示非本周课程", "在周课表中显示非本周课程。", "\uE787", otherWeeks)));
        var prefs = Model.Preferences;
        var reminders = new ToggleSwitch { IsOn = prefs.RemindersEnabled, OnContent = "", OffContent = "", Width = 50, MinWidth = 0, IsEnabled = Model.IsConnected && Model.CanChangeAccount };
        var confirmation = new ToggleSwitch { IsOn = prefs.ConfirmBeforeSign, OnContent = "", OffContent = "", Width = 50, MinWidth = 0, IsEnabled = Model.IsConnected && Model.CanChangeAccount };
        var auto = new ToggleSwitch { IsOn = prefs.AutoSignEnabled, OnContent = "", OffContent = "", Width = 50, MinWidth = 0, IsEnabled = Model.IsConnected && Model.CanChangeAccount };
        reminders.Toggled += async (_, _) => await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn, confirmation.IsOn, prefs.ReminderLeadMinutes));
        confirmation.Toggled += async (_, _) => await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn, confirmation.IsOn, prefs.ReminderLeadMinutes));
        auto.Toggled += async (_, _) => await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn, confirmation.IsOn, prefs.ReminderLeadMinutes));
        var preferences = SettingsGroup("课堂偏好",
            SettingRow("课程提醒", "按全局默认值安排本机通知", "\uE787", reminders));
        var preferenceCards = (StackPanel)preferences.Children[1];
        if (prefs.RemindersEnabled)
        {
            var lead = new ComboBox { ItemsSource = new[] { "5 分钟", "10 分钟", "15 分钟", "30 分钟" }, MinWidth = 160,
                SelectedIndex = prefs.ReminderLeadMinutes switch { 5 => 0, 15 => 2, 30 => 3, _ => 1 } };
            lead.SelectionChanged += async (_, _) =>
            {
                var minutes = new[] { 5, 10, 15, 30 }[Math.Max(0, lead.SelectedIndex)];
                if (minutes != prefs.ReminderLeadMinutes) await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn, confirmation.IsOn, minutes));
            };
            preferenceCards.Children.Add(SettingRow("提醒时间", "课程可单独覆盖此默认值", "\uE823", lead));
        }
        preferenceCards.Children.Add(SettingRow("手动签到二次确认", "提交前再次核对课程、日期和时间", "\uE9D5", confirmation));
        preferenceCards.Children.Add(SettingRow("自动签到", "果壳签到运行时，进入签到时段后尝试一次", "\uE73E", auto));
        preferences.Children.Add(SettingsNote("窗口可最小化，也可切换到其他应用；退出果壳签到或设备睡眠时会暂停。签到结果以学校返回状态为准。"));
        Page.Children.Add(preferences);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reminders, "课程提醒");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(confirmation, "手动签到二次确认");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(auto, "自动签到");
        var notifications = Button("系统通知设置", async () => { await Launcher.LaunchUriAsync(new("ms-settings:notifications")); });
        notifications.IsEnabled = true;
        Page.Children.Add(SettingsGroup("通知", SettingRow("Windows 通知", "管理通知权限和显示方式", "\uE7F4", notifications)));
        if (WindowsDistribution.IsStorePackage)
        {
            var storeUpdates = new ComboBox
            {
                ItemsSource = new[] { "通知", "下载并稍后安装", "下载并立即安装" },
                SelectedIndex = (int)vm.StoreUpdates,
                MinWidth = 180
            };
            storeUpdates.SelectionChanged += (_, _) =>
            {
                if (storeUpdates.SelectedIndex < 0) return;
                vm.StoreUpdates = (StoreUpdateOption)storeUpdates.SelectedIndex;
                vm.SaveAppearance();
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(storeUpdates, "Microsoft Store 更新方式");
            var storeUpdateGroup = SettingsGroup("更新",
                SettingRow("Microsoft Store 更新", "启动时检查更新，由 Microsoft Store 管理下载与安装", "\uE895", storeUpdates));
            storeUpdateGroup.Children.Add(SettingsNote("静默更新受 Microsoft Store 的“自动更新应用”和按流量计费网络设置影响。"));
            Page.Children.Add(storeUpdateGroup);
            return;
        }
        var automaticUpdates = new ToggleSwitch
        {
            IsOn = vm.AutoCheckUpdates,
            OnContent = "",
            OffContent = "",
            Width = 50,
            MinWidth = 0
        };
        automaticUpdates.Toggled += (_, _) =>
        {
            vm.AutoCheckUpdates = automaticUpdates.IsOn;
            vm.SaveAppearance();
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(automaticUpdates, "自动检查更新");
        var updates = Button("检查更新", () => CheckForUpdates(true));
        updates.IsEnabled = true;
        Page.Children.Add(SettingsGroup("更新",
            SettingRow("自动检查更新", "每天最多检查一次，有新版本时提醒", "\uE895", automaticUpdates),
            SettingRow("检查更新", "当前版本 " + Information.DisplayVersion, "\uE896", updates)));
    }
    SettingsCard SettingRow(string title, string description, string glyph, UIElement control)
    {
        return new SettingsCard
        {
            Header = title,
            Description = description,
            HeaderIcon = SettingsIcon(glyph),
            Content = control,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinHeight = 68
        };
    }
    Task Navigate(string page)
    {
        route = page;
        Render(NavigationMotion.Forward);
        EnsureCatalogPage();
        return Task.CompletedTask;
    }
    void GoBack(object sender, RoutedEventArgs e)
    {
        route = route == "source" ? "about" : route == "course-schedule" ? "catalog-detail" : null;
        detail = null;
        if (route != "catalog-detail") catalogDetail = null;
        Render(NavigationMotion.Back);
        EnsureCatalogPage();
    }
    async void PickDate(CalendarDatePicker sender, CalendarDatePickerDateChangedEventArgs e)
    {
        if (!updatingScheduleDate && sender.Date is { } d && Model.ViewedDateRange is not null)
            await Run(() => Model.SelectScheduleDateAsync(DateOnly.FromDateTime(d.DateTime), datePickerGeneration, datePickerSemester));
    }
    async void RefreshClicked(object sender, RoutedEventArgs e) => await Run(RefreshCurrentCoursesAsync);
    Task Detail(Course course)
    {
        detail = course;
        return Navigate("detail");
    }
    Task CatalogDetail(CatalogCourse course)
    {
        catalogDetail = course;
        return Navigate("catalog-detail");
    }
    Task Records() => Navigate("records");
    Task About() => Navigate("about");
}
