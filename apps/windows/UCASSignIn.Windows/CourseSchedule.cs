using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Markup;
using UCASSignIn.Core;
using Windows.Foundation;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    readonly Dictionary<(Guid, string, string), (string Row, double Offset)> courseSchedulePositions = [];
    Action? saveCourseSchedulePosition;
    static string ScheduleRowKey(object row) => row is CourseScheduleMeeting meeting ? meeting.Id : "week:" + row;
    void RenderCourseScheduleSummary(CatalogCourse course)
    {
        var data = Model.CourseScheduleFor(course);
        var content = new StackPanel();
        var progress = CourseScheduleProgressView(course, data);
        if (progress is not null)
            content.Children.Add(new Border { Child = progress, Padding = new(16) });
        var overview = new StackPanel { Spacing = 16 };
        foreach (var summary in data.Summaries)
            overview.Children.Add(Column(Text(summary.Weeks + " · " + summary.Weekday, 14), Text(summary.Time + " · " + summary.Classroom, 13, color: Secondary)));
        AddCourseScheduleStatus(overview, course, data);
        if (overview.Children.Count > 0)
        {
            if (progress is not null) content.Children.Add(Rule());
            content.Children.Add(new Border { Child = overview, Padding = new(16) });
        }
        var generation = Model.Generation;
        var open = Plain(Across(Text("查看完整排课信息", 13, color: Green), new FontIcon { Glyph = "\uE76C", FontSize = 12, Foreground = Secondary }),
            () => generation == Model.Generation ? Navigate("course-schedule") : Task.CompletedTask);
        open.Padding = new(16);
        open.MinHeight = 52;
        open.CornerRadius = new(0, 0, 7, 7);
        ButtonColors(open, new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), Green, Hover, Pressed);
        AutomationProperties.SetName(open, "查看完整排课信息");
        AutomationProperties.SetHelpText(open, "查看按周排列的完整排课信息");
        content.Children.Add(Rule());
        content.Children.Add(open);
        Page.Children.Add(SettingsGroup("排课信息", Card(content, 0)));
    }
    StackPanel? CourseScheduleProgressView(CatalogCourse course, CourseSchedulePresentation data)
    {
        // Missing associations and an empty partial read do not establish a total.
        if (data.UnavailableReason is not null || data.Meetings.Length == 0 && !Model.CourseScheduleIsComplete(course)) return null;

        var totalLabel = Text("总计", 12, color: Secondary);
        var totalNumber = new Run();
        var endedNumber = new Run();
        var percentageNumber = new Run();
        StackPanel Metric(TextBlock label, Run number, string unit, bool accent)
        {
            var value = Text("", 27, true, accent ? Green : Ink);
            value.Language = "zh-CN";
            value.Inlines.Add(number);
            value.Inlines.Add(new Run { Text = unit, FontFamily = new("Microsoft YaHei UI, Microsoft YaHei"), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Normal, Foreground = Secondary });
            var metric = Column(label, value);
            metric.Spacing = 4;
            return metric;
        }
        var metrics = new Grid { ColumnSpacing = 12 };
        for (var column = 0; column < 5; column++)
        {
            metrics.ColumnDefinitions.Add(new() { Width = column % 2 == 0 ? new(1, GridUnitType.Star) : GridLength.Auto });
            if (column % 2 == 0) continue;
            var divider = new Border { Width = 1, Background = Stroke, Margin = new(0, 4, 0, 4) };
            Grid.SetColumn(divider, column); metrics.Children.Add(divider);
        }
        metrics.Children.Add(Metric(totalLabel, totalNumber, " 节", false));
        var ended = Metric(Text("已结束", 12, color: Secondary), endedNumber, " 节", true);
        Grid.SetColumn(ended, 2); metrics.Children.Add(ended);
        var percentage = Metric(Text("进度", 12, color: Secondary), percentageNumber, "%", false);
        Grid.SetColumn(percentage, 4); metrics.Children.Add(percentage);
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 4, MinHeight = 4, Foreground = Green, Background = Pale, IsTabStop = false };
        AutomationProperties.SetName(bar, "已结束课程占比");
        var note = Text("", 12, color: Secondary);
        var content = Column(metrics, bar, note);
        content.Spacing = 12;
        var generation = Model.Generation;
        var previous = (Total: -1, Ended: -1, UnknownTime: -1, Complete: false);
        void Update()
        {
            if (generation != Model.Generation) return;
            var progress = Model.CourseScheduleProgressFor(course);
            var complete = Model.CourseScheduleIsComplete(course);
            var current = (progress.Total, progress.Ended, progress.UnknownTime, complete);
            if (previous == current) return;
            previous = current;
            totalLabel.Text = complete ? "总计" : "已同步";
            totalNumber.Text = progress.Total.ToString();
            endedNumber.Text = progress.Ended.ToString();
            var percent = progress.Total == 0 ? 0 : (int)Math.Round(progress.Fraction * 100, MidpointRounding.AwayFromZero);
            percentageNumber.Text = percent.ToString();
            bar.Value = progress.Fraction;
            var notes = new List<string>();
            if (!complete) notes.Add("仅统计已同步排课");
            if (progress.UnknownTime > 0) notes.Add($"{progress.UnknownTime} 节时间待确认");
            note.Text = string.Join(" · ", notes);
            note.Visibility = notes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            var description = $"课程进度，{totalLabel.Text} {progress.Total} 节，已结束 {progress.Ended} 节，进度 {percent}%";
            if (notes.Count > 0) description += "，" + note.Text;
            AutomationProperties.SetName(content, description);
            AutomationProperties.SetHelpText(bar, description);
        }
        Update();
        // The page can remain retained across clock changes. Only mutate these
        // small controls; the virtualized meeting list and its scroll stay intact.
        var ticker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        ticker.Tick += (_, _) =>
        {
            if (closed || generation != Model.Generation) { ticker.Stop(); return; }
            if (Model.IsForeground) Update();
        };
        content.Loaded += (_, _) => { Update(); ticker.Start(); };
        content.Unloaded += (_, _) => ticker.Stop();
        return content;
    }
    void AddCourseScheduleStatus(StackPanel panel, CatalogCourse course, CourseSchedulePresentation data)
    {
        if (Model.CourseScheduleStatus(course, data) is { } status) panel.Children.Add(Text(status, 13, color: Secondary));
        if (Model.CourseScheduleError(course.SemesterId) is { } error) panel.Children.Add(Text(error, 13, color: Secondary));
    }
    (StackPanel Panel, CourseSchedulePresentation Data, string? Status, string? Error, bool Complete, bool Dark)? renderedCourseSchedule;
    bool RetainCourseSchedule()
    {
        if (route != "course-schedule" || catalogDetail is not { } course || renderedCourseSchedule is not { } prior) return false;
        return prior.Panel == Page && prior.Dark == dark && ReferenceEquals(prior.Data, Model.CourseScheduleFor(course))
            && prior.Status == Model.CourseScheduleStatus(course, prior.Data) && prior.Error == Model.CourseScheduleError(course.SemesterId)
            && prior.Complete == Model.CourseScheduleIsComplete(course);
    }
    void RenderCourseSchedule(CatalogCourse course)
    {
        var data = Model.CourseScheduleFor(course);
        if (CourseScheduleProgressView(course, data) is { } progress)
            Page.Children.Add(SettingsGroup("课程进度", Card(progress, 20)));
        AddCourseScheduleStatus(Page, course, data);
        var rows = data.Meetings.GroupBy(m => m.Week).SelectMany(week => new object[] { week.Key }.Concat(week.Cast<object>())).ToArray();
        var list = new ItemsRepeater
        {
            ItemsSource = rows,
            Layout = new StackLayout { Spacing = 12 },
            ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Border/></DataTemplate>")
        };
        // Only realize the visible rows, including week headings. A full semester can contain hundreds of meetings.
        list.ElementPrepared += (_, args) =>
        {
            var host = (Border)args.Element;
            if (rows[args.Index] is int week)
            {
                var heading = Text($"第 {week} 周", 14, true);
                heading.Margin = new(0, args.Index == 0 ? 0 : 8, 0, 0);
                host.Child = heading;
            }
            else if (rows[args.Index] is CourseScheduleMeeting meeting)
            {
                var header = new ScheduleFlowPanel { RightAlignLast = true };
                header.Children.Add(Text($"第 {meeting.Week} 周 · {meeting.Weekday}", 14, true));
                header.Children.Add(Text(meeting.Date.ToString("yyyy年M月d日"), 13, color: Secondary));
                var fields = new ScheduleFlowPanel();
                fields.Children.Add(ScheduleField("\uE823", meeting.Time));
                fields.Children.Add(ScheduleField("\uE707", meeting.ClassroomText));
                fields.Children.Add(ScheduleField("\uE77B", meeting.TeacherText));
                host.Child = Card(Column(header, fields), 20);
            }
        };
        list.ElementClearing += (_, args) => ((Border)args.Element).Child = null;
        Page.Children.Add(list);
        var scroller = PageScroll;
        var positionKey = (Model.Generation, course.SemesterId, course.Id);
        saveCourseSchedulePosition = () =>
        {
            for (var i = 0; i < rows.Length; i++)
            {
                if (list.TryGetElement(i) is not FrameworkElement element) continue;
                var y = element.TransformToVisual(scroller).TransformPoint(new Point()).Y;
                if (y + element.ActualHeight <= 0 || y >= scroller.ViewportHeight) continue;
                if (courseSchedulePositions.Count >= 32 && !courseSchedulePositions.ContainsKey(positionKey))
                    courseSchedulePositions.Remove(courseSchedulePositions.Keys.First());
                courseSchedulePositions[positionKey] = (ScheduleRowKey(rows[i]), y);
                break;
            }
        };
        list.Loaded += (_, _) =>
        {
            if (!courseSchedulePositions.TryGetValue(positionKey, out var position)) return;
            var index = Array.FindIndex(rows, row => ScheduleRowKey(row) == position.Row);
            if (index < 0) return;
            var element = (FrameworkElement)list.GetOrCreateElement(index);
            element.UpdateLayout();
            element.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0, VerticalOffset = position.Offset });
        };
        renderedCourseSchedule = (Page, data, Model.CourseScheduleStatus(course, data), Model.CourseScheduleError(course.SemesterId), Model.CourseScheduleIsComplete(course), dark);
    }
    UIElement ScheduleField(string glyph, string value)
    {
        var grid = new Grid { ColumnSpacing = 6 };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Secondary });
        var label = Text(value, 13, color: Secondary); Grid.SetColumn(label, 1); grid.Children.Add(label);
        return grid;
    }
    void EnsureCatalogPage()
    {
        if (catalogDetail is not { } course || route is not ("catalog-detail" or "course-schedule")) return;
        _ = Run(() => Model.EnsureCourseScheduleAsync(course));
        if (route == "catalog-detail" && Model.ShouldRefreshAttendance(course.Id)) _ = Run(() => Model.RefreshAttendanceAsync(course.Id));
    }
}

// Fields keep their natural widths, wrap in order, and individually wrap long text at the available width.
sealed class ScheduleFlowPanel : Panel
{
    public bool RightAlignLast { get; init; }
    const double Gap = 16, LineGap = 10;
    protected override Size MeasureOverride(Size availableSize)
    {
        double x = 0, y = 0, height = 0;
        foreach (var child in Children)
        {
            child.Measure(new(availableSize.Width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > availableSize.Width) { y += height + LineGap; x = height = 0; }
            x += size.Width + Gap; height = Math.Max(height, size.Height);
        }
        return new(double.IsInfinity(availableSize.Width) ? Math.Max(0, x - Gap) : availableSize.Width, y + height);
    }
    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, height = 0;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > finalSize.Width) { y += height + LineGap; x = height = 0; }
            var left = RightAlignLast && child == Children.Last() && x > 0 ? Math.Max(x, finalSize.Width - size.Width) : x;
            child.Arrange(new Rect(left, y, Math.Min(size.Width, finalSize.Width), size.Height));
            x += size.Width + Gap; height = Math.Max(height, size.Height);
        }
        return finalSize;
    }
}
