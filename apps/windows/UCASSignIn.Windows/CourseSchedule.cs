using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
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
        var content = new StackPanel { Spacing = 16 };
        foreach (var summary in data.Summaries)
            content.Children.Add(Column(Text(summary.Weeks + " · " + summary.Weekday, 14), Text(summary.Time + " · " + summary.Classroom, 13, color: Secondary)));
        AddCourseScheduleStatus(content, course, data);
        var generation = Model.Generation;
        var card = ActionCard(Across(content, new FontIcon { Glyph = "\uE76C", FontSize = 14, Foreground = Secondary }),
            () => generation == Model.Generation ? Navigate("course-schedule") : Task.CompletedTask);
        AutomationProperties.SetName(card, "排课信息，" + course.Name);
        AutomationProperties.SetHelpText(card, "查看按周排列的完整排课信息");
        Page.Children.Add(SettingsGroup("排课信息", card));
    }
    void AddCourseScheduleStatus(StackPanel panel, CatalogCourse course, CourseSchedulePresentation data)
    {
        if (Model.CourseScheduleStatus(course, data) is { } status) panel.Children.Add(Text(status, 13, color: Secondary));
        if (Model.CourseScheduleError(course.SemesterId) is { } error) panel.Children.Add(Text(error, 13, color: Secondary));
    }
    (StackPanel Panel, CourseSchedulePresentation Data, string? Status, string? Error, bool Dark)? renderedCourseSchedule;
    bool RetainCourseSchedule()
    {
        if (route != "course-schedule" || catalogDetail is not { } course || renderedCourseSchedule is not { } prior) return false;
        return prior.Panel == Page && prior.Dark == dark && ReferenceEquals(prior.Data, Model.CourseScheduleFor(course))
            && prior.Status == Model.CourseScheduleStatus(course, prior.Data) && prior.Error == Model.CourseScheduleError(course.SemesterId);
    }
    void RenderCourseSchedule(CatalogCourse course)
    {
        var data = Model.CourseScheduleFor(course);
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
        renderedCourseSchedule = (Page, data, Model.CourseScheduleStatus(course, data), Model.CourseScheduleError(course.SemesterId), dark);
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
