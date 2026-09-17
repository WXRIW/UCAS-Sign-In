using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using UCASSignIn.Core;
using Windows.System;
namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    string? route;
    Course? detail;
    readonly Dictionary<string, (string? Route, Course? Detail)> paths = [];
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
        Page.Children.Clear();
        Page.Spacing = section == "account" && route is null ? 16 : 20;
        AccountMenuLabel.Text = AccountName;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(AccountMenu, AccountName);
        AccountMenu.IsEnabled = Model.CanChangeAccount;
        AppTitleBar.IsBackButtonVisible = route is not null;
        AppTitleBar.IsBackButtonEnabled = route is not null;
        UpdateRefreshButton();
        DatePicker.Visibility = section == "schedule" && route is null ? Visibility.Visible : Visibility.Collapsed;
        if (DatePicker.Date?.Date != Model.SelectedDate.ToDateTime(TimeOnly.MinValue))
            DatePicker.Date = new(Model.SelectedDate.ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset);
        PageTitle.Text = route switch
        {
            "detail" => "课程签到",
            "settings" => "设置",
            "records" => Model.IsDemo ? "演示签到记录" : "本机签到记录",
            "about" => "关于",
            "source" => "项目源码与致谢",
            "disclaimer" => "免责声明",
            _ => section == "today" ? "果壳签到" : section == "schedule" ? "课表" : "账户"
        };
        Status.Message = Model.Message ?? "";
        Status.IsOpen = !string.IsNullOrWhiteSpace(Model.Message);
        Status.Severity = InfoBarSeverity.Informational;
        if (route == "detail" && detail is { } c)
        {
            RenderDetail(Model.Courses.FirstOrDefault(x => x.Id == c.Id && x.Day == c.Day) ?? c);
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
        RenderToday();
    }
    void Banner()
    {
        if (Model.IsDemo)
        {
            Page.Children.Add(Card(Across(Leading(new FontIcon { Glyph = "\uE946", FontSize = 16, Foreground = Green },
                Text("演示模式 · 示例课表", 12, color: Secondary)), Button("连接账号", () => Login())), 12));
        }
        else if (Model.Courses.Any(c => !Model.IsFresh(c)))
        {
            var b = Card(Across(Text("正在显示本机缓存\n同步后可继续签到", 12, color: Secondary), Button("重新同步", () => Model.RefreshAsync(section == "today" ? CourseTime.Today() : Model.SelectedDate))), 14);
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
        Banner();
        var (current, next) = CourseTime.CurrentAndNext(courses, now);
        var featured = current is { Signed: false } ? current : next ?? current ?? courses.LastOrDefault();
        if (featured is not null)
        {
            var sign = Button(featured.Signed ? "已完成签到" : "一键签到", () => Model.SignAsync(featured, Model.Generation), true);
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
    void RenderSchedule()
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
        var previousWeek = Button("", () => Model.SelectDateAsync(date.AddDays(-7)));
        previousWeek.Content = new FontIcon { Glyph = "\uE76B", FontSize = 12 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(previousWeek, "上一周");
        weekHeader.Children.Add(previousWeek);
        var month = Text(date.ToString("yyyy 年 M 月"), 16, true);
        month.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetColumn(month, 1);
        weekHeader.Children.Add(month);
        var nextWeek = Button("", () => Model.SelectDateAsync(date.AddDays(7)));
        nextWeek.Content = new FontIcon { Glyph = "\uE76C", FontSize = 12 };
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
            var b = Button("", () => Model.SelectDateAsync(d));
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
        Banner();
        var courses = DayCourses(date);
        Page.Children.Add(Across(Text(date.ToString("M 月 d 日"), 20, true), Text($"{courses.Count} 门课程", 12, color: Secondary)));
        Timeline(courses);
        if (date != CourseTime.Today())
            Page.Children.Add(Button("回到今天", () => Model.SelectDateAsync(CourseTime.Today())));
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
        accountHeader.Margin = new(0, 4, 0, 8);
        Page.Children.Add(accountHeader);
        var menu = new StackPanel { Spacing = 4 };
        Menu("切换与管理账户", "\uE716", ManageAccounts);
        Menu("本机签到记录", "\uE81C", () => Navigate("records"));
        Page.Children.Add(Column(Text("账户与数据", 14, true), menu));
        menu = new StackPanel { Spacing = 4 };
        Menu("设置", "\uE713", () => Navigate("settings"));
        Menu("关于", "\uE946", () => Navigate("about"));
        Menu("免责声明", "\uE8A5", () => Navigate("disclaimer"));
        Page.Children.Add(Column(Text("关于", 14, true), menu));
        if (Model.IsConnected)
        {
            var exitAccount = Button(Model.IsDemo ? "退出演示模式" : "退出并移除此账户", () => Model.IsDemo ? ConfirmExitDemo() : Remove(a!));
            exitAccount.Name = "ExitAccountButton";
            exitAccount.HorizontalAlignment = HorizontalAlignment.Stretch;
            exitAccount.HorizontalContentAlignment = HorizontalAlignment.Center;
            exitAccount.VerticalContentAlignment = VerticalAlignment.Center;
            exitAccount.MinHeight = 40;
            ButtonColors(exitAccount, Surface, Model.IsDemo ? Secondary : Brush(dark ? "FF99A4" : "C42B1C"),
                Model.IsDemo ? Hover : Brush(dark ? "39272B" : "FCEDEC"), Model.IsDemo ? Pressed : Brush(dark ? "492D33" : "F8DDDB"));
            Page.Children.Add(exitAccount);
        }
        var foot = Text($"果壳签到 {Information.DisplayVersion}", 12, color: Secondary);
        foot.TextAlignment = TextAlignment.Center;
        Page.Children.Add(foot);
        void Menu(string title, string glyph, Func<Task> action)
        {
            var icon = new FontIcon { Glyph = glyph, FontSize = 18, Foreground = Secondary };
            var b = ActionCard(Across(Leading(icon, Text(title, 14)), new FontIcon { Glyph = "\uE76C", FontSize = 10, Foreground = Secondary }), action);
            b.Padding = new(16, 12, 16, 12);
            b.MinHeight = 52;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, title);
            menu.Children.Add(b);
        }
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
        Page.Children.Add(Column(Text("外观", 16, true), SettingRow("主题", "选择应用的显示模式", "\uE790", theme)));
        var prefs = Model.Preferences;
        var reminders = new ToggleSwitch { IsOn = prefs.RemindersEnabled, OnContent = "", OffContent = "", Width = 50, MinWidth = 0, IsEnabled = Model.IsConnected && Model.CanChangeAccount };
        var auto = new ToggleSwitch { IsOn = prefs.AutoSignEnabled, OnContent = "", OffContent = "", Width = 50, MinWidth = 0, IsEnabled = Model.IsConnected && Model.CanChangeAccount };
        reminders.Toggled += async (_, _) => await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn));
        auto.Toggled += async (_, _) => await Run(() => Model.SetPreferencesAsync(auto.IsOn, reminders.IsOn));
        var preferences = Column(Text("课堂偏好", 16, true),
            SettingRow("课程提醒", "已同步课程将在开课前 10 分钟提醒", "\uE787", reminders),
            SettingRow("前台自动签到", "窗口活跃时，进入签到时段后尝试一次", "\uE73E", auto),
            Text("切换到其他应用、关闭窗口或设备睡眠时，自动签到会暂停。签到结果以学校返回状态为准。", 12, color: Secondary));
        Page.Children.Add(preferences);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reminders, "课程提醒");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(auto, "前台自动签到");
        var notifications = Button("系统通知设置", async () => { await Launcher.LaunchUriAsync(new("ms-settings:notifications")); });
        notifications.IsEnabled = true;
        Page.Children.Add(Column(Text("通知", 16, true), SettingRow("Windows 通知", "管理通知权限和显示方式", "\uE7F4", notifications)));
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
        Page.Children.Add(Column(Text("更新", 16, true),
            SettingRow("自动检查更新", "每天最多检查一次，有新版本时提醒", "\uE895", automaticUpdates),
            SettingRow("检查更新", "当前版本 " + Information.DisplayVersion, "\uE896", updates)));
    }
    Border SettingRow(string title, string description, string glyph, UIElement control)
    {
        var labels = Column(Text(title, 14), Text(description, 12, color: Secondary));
        labels.Spacing = 4;
        var card = Card(Across(Leading(new FontIcon { Glyph = glyph, FontSize = 20, Foreground = Secondary }, labels), control));
        card.MinHeight = 72;
        return card;
    }
    Task Navigate(string page)
    {
        route = page;
        Render(NavigationMotion.Forward);
        return Task.CompletedTask;
    }
    void GoBack(object sender, RoutedEventArgs e)
    {
        route = route == "source" ? "about" : null;
        detail = null;
        Render(NavigationMotion.Back);
    }
    async void PickDate(CalendarDatePicker sender, CalendarDatePickerDateChangedEventArgs e)
    {
        if (sender.Date is { } d && DateOnly.FromDateTime(d.DateTime) != Model.SelectedDate)
            await Run(() => Model.SelectDateAsync(DateOnly.FromDateTime(d.DateTime)));
    }
    async void RefreshClicked(object sender, RoutedEventArgs e) => await Run(RefreshCurrentCoursesAsync);
    Task Detail(Course course)
    {
        detail = course;
        return Navigate("detail");
    }
    Task Records() => Navigate("records");
    Task About() => Navigate("about");
}
