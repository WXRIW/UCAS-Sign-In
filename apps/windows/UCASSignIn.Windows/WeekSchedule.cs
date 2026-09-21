using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    void ScheduleTextScaleChanged(global::Windows.UI.ViewManagement.UISettings sender, object args)
        => DispatcherQueue.TryEnqueue(() => { if (!closed && section == "schedule" && route is null) { weekPage = null; Render(); } });
    StackPanel? weekPage;
    WeekSchedule? displayedWeek;
    DateOnly weekSelected;
    bool weekDark, weekInitial;
    TextBlock? weekProgressText, weekError, weekUpdated;
    TextBlock? weekMonth;
    ProgressRing? weekProgressRing;
    StackPanel? weekProgressRow;
    Button? weekRetry;
    readonly Dictionary<DateOnly, double> weekScroll = [];
    readonly Dictionary<DateOnly, Button> weekDateButtons = [];
    void UpdateWeekProgress()
    {
        if (section != "schedule" || route is not null || Model.ScheduleMode != ScheduleMode.Week || weekPage != Page) return;
        if (weekProgressText is not null) weekProgressText.Text = Model.ScheduleProgress?.ToString() ?? "";
        if (weekProgressRow is not null) weekProgressRow.Visibility = Model.ScheduleProgress is null ? Visibility.Collapsed : Visibility.Visible;
        if (weekProgressRing is not null) weekProgressRing.IsActive = Model.IsScheduleRefreshing;
        if (weekError is not null) { weekError.Text = Model.ScheduleError ?? ""; weekError.Visibility = Model.ScheduleError is null ? Visibility.Collapsed : Visibility.Visible; }
        if (weekRetry is not null) weekRetry.Visibility = Model.ScheduleError is null ? Visibility.Collapsed : Visibility.Visible;
        if (weekUpdated is not null) weekUpdated.Text = Model.ScheduleUpdatedAt is { } time ? $"刷新于 {time.ToOffset(CourseTime.ShanghaiOffset):yyyy年M月d日 HH:mm}" : "尚未完成完整同步";
        UpdateRefreshButton();
    }
    bool UpdateExistingWeek()
    {
        if (Model.ScheduleMode != ScheduleMode.Week || weekPage != Page || weekDark != dark
            || weekInitial != Model.IsInitialScheduleLoading || !ReferenceEquals(displayedWeek, Model.WeekSchedule())) return false;
        if (weekSelected != Model.SelectedDate)
        {
            weekSelected = Model.SelectedDate;
            if (weekMonth is not null) weekMonth.Text = weekSelected.ToString("yyyy 年 M 月");
            if (weekNumberText is not null) weekNumberText.Text = Model.ScheduleWeekNumber is { } n ? $"第 {n} 周" : "";
            if (previousScheduleButton is not null) previousScheduleButton.IsEnabled = Model.PreviousScheduleWeek is not null;
            if (nextScheduleButton is not null) nextScheduleButton.IsEnabled = Model.NextScheduleWeek is not null;
            foreach (var (date, button) in weekDateButtons)
            {
                button.Background = date == weekSelected ? Pale : null;
                AutomationProperties.SetItemStatus(button, date == weekSelected ? "已选中" : "");
            }
        }
        UpdateWeekProgress(); return true;
    }
    UIElement ScheduleModePicker()
    {
        var day = new ToggleButton { Content = "日", IsChecked = Model.ScheduleMode == ScheduleMode.Day, MinWidth = 36 };
        var week = new ToggleButton { Content = "周", IsChecked = Model.ScheduleMode == ScheduleMode.Week, MinWidth = 36 };
        AutomationProperties.SetName(day, "日课表"); AutomationProperties.SetName(week, "周课表");
        async Task Change(ScheduleMode mode) { Model.ScheduleMode = mode; vm.SaveAppearance(); Render(); await Model.EnterScheduleAsync(); }
        day.Click += async (_, _) => await Run(() => Change(ScheduleMode.Day));
        week.Click += async (_, _) => await Run(() => Change(ScheduleMode.Week));
        return Row(day, week);
    }
    void RenderSchedule()
    {
        Page.MaxWidth = double.PositiveInfinity;
        ScheduleHeader.Margin = new(Page.Padding.Left, 0, Page.Padding.Right, 8);
        if (Model.ScheduleMode == ScheduleMode.Day)
        {
            weekPage = null; RenderDailySchedule();
            var nav = Page.Children[0]; Page.Children.RemoveAt(0);
            var dates = Page.Children[0]; Page.Children.RemoveAt(0);
            ScheduleHeader.Children.Add(Across(nav, ScheduleModePicker())); ScheduleHeader.Children.Add(dates);
            return;
        }
        var date = Model.SelectedDate; var data = Model.WeekSchedule();
        weekPage = Page; displayedWeek = data; weekSelected = date; weekDark = dark; weekInitial = Model.IsInitialScheduleLoading;
        var previous = previousScheduleButton = Plain(new FontIcon { Glyph = "\uE76B", FontSize = 12 }, () => Model.MoveScheduleWeekAsync(false));
        var next = nextScheduleButton = Plain(new FontIcon { Glyph = "\uE76C", FontSize = 12 }, () => Model.MoveScheduleWeekAsync(true));
        AutomationProperties.SetName(previous, "上一周"); AutomationProperties.SetName(next, "下一周");
        previous.IsEnabled = Model.PreviousScheduleWeek is not null; next.IsEnabled = Model.NextScheduleWeek is not null;
        var month = ScheduleMonthTitle(true);
        var dateNavigation = new Grid();
        dateNavigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        dateNavigation.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        dateNavigation.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        dateNavigation.Children.Add(previous);
        Grid.SetColumn(month, 1); dateNavigation.Children.Add(month);
        Grid.SetColumn(next, 2); dateNavigation.Children.Add(next);
        var navigation = Across(dateNavigation, ScheduleModePicker());
        ScheduleHeader.Children.Add(navigation);
        weekProgressText = Text("", 12, color: Secondary); weekProgressRing = new ProgressRing { Width = 16, Height = 16, IsActive = true };
        weekProgressRow = Row(weekProgressRing, weekProgressText); weekProgressRow.HorizontalAlignment = HorizontalAlignment.Center;
        ScheduleHeader.Children.Add(weekProgressRow);
        weekError = Text("", 12, color: Secondary); ScheduleHeader.Children.Add(weekError);
        weekRetry = Button(Model.ViewedSemester is null ? "重试本周" : "重试完整同步", () => Model.RefreshScheduleAsync()); ScheduleHeader.Children.Add(weekRetry);
        void AddReturnToWeek()
        {
            if (Model.CanReturnToToday && ScheduleLayout.Monday(date) != ScheduleLayout.Monday(CourseTime.Today()))
                Page.Children.Add(Button("回到本周", Model.ReturnToScheduleTodayAsync));
        }
        if (weekInitial)
        { Page.Children.Add(Text("正在加载…", 14, color: Secondary)); AddReturnToWeek(); weekUpdated = null; UpdateWeekProgress(); return; }
        var headings = new Canvas { Height = 52 };
        var headingScroll = new ScrollViewer { Content = headings, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        ScheduleHeader.Children.Add(headingScroll);
        var timeline = new Canvas();
        var horizontal = new ScrollViewer { Content = timeline, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        horizontal.ViewChanged += (_, _) => headingScroll.ChangeView(horizontal.HorizontalOffset, null, null, true);
        headingScroll.ViewChanged += (_, _) => horizontal.ChangeView(headingScroll.HorizontalOffset, null, null, true);
        Page.Children.Add(horizontal);
        void Geometry(double available)
        {
            var scale = new global::Windows.UI.ViewManagement.UISettings().TextScaleFactor;
            var width = Math.Max(7 * 36 * scale + 42, available); var col = (width - 42) / 7;
            var hour = ScheduleLayout.HourHeight(col, scale); var top = 12 * scale;
            headings.Width = timeline.Width = width; headings.Height = 52 * scale; timeline.Height = (data.EndHour - data.StartHour) * hour + top + 12;
            headings.Children.Clear(); timeline.Children.Clear();
            weekDateButtons.Clear();
            for (var i = 0; i < 7; i++)
            {
                var d = data.Monday.AddDays(i);
                var labels = Column(Text(new[] { "一", "二", "三", "四", "五", "六", "日" }[i], 12), Text(d.Day.ToString(), 16, d == date));
                labels.Spacing = 4;
                foreach (TextBlock label in labels.Children) { label.TextAlignment = TextAlignment.Center; label.HorizontalAlignment = HorizontalAlignment.Stretch; }
                var b = Plain(labels, ScheduleDayAction(d));
                b.IsEnabled = Model.CanSelectVisibleDate(d); b.Opacity = b.IsEnabled ? 1 : .35;
                b.Width = col; b.Background = d == date ? Pale : null; AutomationProperties.SetName(b, d.ToString("yyyy年M月d日"));
                weekDateButtons[d] = b;
                Canvas.SetLeft(b, 42 + i * col); headings.Children.Add(b);
            }
            for (var h = data.StartHour; h <= data.EndHour; h++)
            {
                var label = Text($"{h:00}:00", 10, color: Secondary); Canvas.SetTop(label, top + (h - data.StartHour) * hour - 7 * scale); timeline.Children.Add(label);
                var line = new Border { Height = 1, Width = width - 42, Background = Stroke }; Canvas.SetLeft(line, 42); Canvas.SetTop(line, top + (h - data.StartHour) * hour); timeline.Children.Add(line);
            }
            foreach (var block in data.Blocks)
            {
                var entry = block.Entries[0]; var multiple = block.Entries.Count > 1;
                var content = Column(Text(multiple ? $"{block.Entries.Count} 项安排" : entry.Course.Name, 14, true), Text(multiple ? "点击选择课程" : entry.Course.Classroom ?? "", 12)); content.Spacing = 2;
                if (!multiple && entry.Preview) content.Children.Add(Text("非本周", 10, color: Secondary));
                var button = Plain(content, () => OpenScheduleBlock(block));
                var colors = new[] { "4285D4", "9862C4", "259CAA", "6472C6", "D78A35", "CA6394", "46A276" };
                var brush = Brush(entry.Preview ? "888888" : colors[entry.Color]); brush.Opacity = dark ? .35 : .18;
                button.Background = brush; button.CornerRadius = new(6); button.Padding = new(4, 3, 4, 3);
                button.VerticalContentAlignment = VerticalAlignment.Top; button.Width = col - 3;
                button.Height = Math.Max(1, (block.EndMinute - block.StartMinute) / 60d * hour - 2); button.MinHeight = 0;
                AutomationProperties.SetName(button, string.Join("；", block.Entries.Select(e => e.AccessibleName)));
                Canvas.SetLeft(button, 42 + (block.Day.DayNumber - data.Monday.DayNumber) * col); Canvas.SetTop(button, top + (block.StartMinute / 60d - data.StartHour) * hour);
                timeline.Children.Add(button);
            }
        }
        Geometry(Math.Max(280, ContentSurface.ActualWidth - 64));
        horizontal.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) Geometry(e.NewSize.Width); };
        if (data.Unplaced.Count > 0)
        {
            Page.Children.Add(Text("时间待确认", 16, true));
            foreach (var entry in data.Unplaced) Page.Children.Add(Button(entry.Course.Name + " · " + entry.Course.Day, () => OpenScheduleEntry(entry)));
        }
        weekUpdated = Text("", 12, color: Secondary); weekUpdated.Margin = new(0, 8, 0, 0); Page.Spacing = 8; Page.Children.Add(weekUpdated);
        AddReturnToWeek();
        var target = PageScroll; var offset = weekScroll.GetValueOrDefault(data.Monday);
        DispatcherQueue.TryEnqueue(() => { if (PageScroll == target && section == "schedule" && route is null) target.ChangeView(null, offset, null, true); });
        UpdateWeekProgress();
    }
    async Task OpenScheduleBlock(ScheduleBlock block)
    {
        if (block.Entries.Count == 1) { await OpenScheduleEntry(block.Entries[0]); return; }
        var generation = Model.Generation;
        var list = new StackPanel { Spacing = 8 };
        ScheduleEntry? selected = null;
        var dialog = new ContentDialog { Title = $"{block.Entries.Count} 项安排", Content = list, CloseButtonText = "取消", Tag = "schedule" };
        foreach (var entry in block.Entries)
        {
            var button = Button(entry.Course.Name + " · " + entry.Course.TimeRange + " · " + entry.Course.Classroom, () => { selected = entry; dialog.Hide(); return Task.CompletedTask; }); list.Children.Add(button);
        }
        await Show(dialog);
        if (generation == Model.Generation && selected is not null) await OpenScheduleEntry(selected);
    }
    async Task OpenScheduleEntry(ScheduleEntry entry)
    {
        var generation = Model.Generation;
        await Model.EnsureCatalogForDateAsync(CourseTime.Date(entry.Course.Day));
        if (generation != Model.Generation || section != "schedule" || route is not null) return;
        var course = Model.CatalogFor(entry.Course) ?? new CatalogCourse("", entry.Course.CourseNumber ?? "", entry.Course.Name, entry.Course.Teacher,
            entry.Course.Classroom, Model.ViewedSemester?.Id ?? "", entry.Course.Day, entry.Course.Day);
        await CatalogDetail(course);
    }
}
