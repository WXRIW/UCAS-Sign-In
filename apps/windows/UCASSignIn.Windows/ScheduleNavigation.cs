using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    FlyoutBase? schedulePicker;
    bool updatingScheduleDate;
    Guid datePickerGeneration;
    string? datePickerSemester;
    TextBlock? weekNumberText;
    Button? previousScheduleButton, nextScheduleButton;
    void CloseSchedulePickers()
    {
        schedulePicker?.Hide(); schedulePicker = null;
        if (activeDialog?.Tag is "schedule") activeDialog.Hide();
        SemesterMenu.Flyout?.Hide(); DatePicker.IsCalendarOpen = false;
        datePickerGeneration = Guid.Empty; datePickerSemester = null;
    }
    void UpdateScheduleNavigation()
    {
        var visible = section == "schedule" && route is null;
        SemesterMenu.Visibility = DatePicker.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SemesterMenu.IsEnabled = Model.ScheduleSemesters.Count > 0;
        ToolTipService.SetToolTip(SemesterMenu, Model.ViewedSemester?.Name ?? "选择学期");
        DatePicker.IsEnabled = Model.ViewedDateRange is not null;
        updatingScheduleDate = true;
        try
        {
            if (Model.ViewedDateRange is { } range)
            {
                var begin = new DateTimeOffset(range.Begin.ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset);
                var end = new DateTimeOffset(range.End.ToDateTime(TimeOnly.MaxValue), CourseTime.ShanghaiOffset);
                // Expand before shrinking so a semester switch never temporarily reverses the range.
                if (end > DatePicker.MaxDate) DatePicker.MaxDate = end;
                if (begin < DatePicker.MinDate) DatePicker.MinDate = begin;
                if (DatePicker.MinDate != begin) DatePicker.MinDate = begin;
                if (DatePicker.MaxDate != end) DatePicker.MaxDate = end;
            }
            if (DatePicker.Date?.Date != Model.SelectedDate.ToDateTime(TimeOnly.MinValue))
                DatePicker.Date = new(Model.SelectedDate.ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset);
        }
        finally { updatingScheduleDate = false; }
    }
    void ScheduleDateOpened(object sender, object args)
    { datePickerGeneration = Model.Generation; datePickerSemester = Model.ViewedSemester?.Id; }
    void ScheduleSemestersOpening(object sender, object args)
    {
        if (sender is not MenuFlyout menu) return;
        var generation = Model.Generation;
        menu.Items.Clear();
        foreach (var semester in Model.ScheduleSemesters)
        {
            var item = new ToggleMenuFlyoutItem { Text = semester.Name, IsChecked = Model.ViewedSemester?.Id == semester.Id };
            item.Click += async (_, _) => await Run(() => Model.SelectScheduleSemesterAsync(semester.Id, generation));
            menu.Items.Add(item);
        }
    }
    Func<Task> ScheduleDayAction(DateOnly date)
    {
        var generation = Model.Generation; var semester = Model.ViewedSemester?.Id;
        return () => Model.SelectScheduleDateAsync(date, generation, semester);
    }
    Button ScheduleMonthTitle(bool trackWeek = false)
    {
        var month = Text(Model.SelectedDate.ToString("yyyy 年 M 月"), 16, true);
        var week = Text(Model.ScheduleWeekNumber is { } number ? $"第 {number} 周" : "", 12, color: Secondary);
        month.TextAlignment = week.TextAlignment = TextAlignment.Center;
        var content = Column(month, week); content.Spacing = 2;
        var button = Plain(content, () => { ShowScheduleWeekPicker(buttonAnchor: content); return Task.CompletedTask; });
        button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Center;
        button.MinHeight = 48; button.IsEnabled = Model.ScheduleWeekNumber is not null;
        AutomationProperties.SetName(button, $"{month.Text} {week.Text}，跳转到周");
        if (trackWeek) { weekMonth = month; weekNumberText = week; }
        return button;
    }
    void ShowScheduleWeekPicker(FrameworkElement buttonAnchor)
    {
        if (Model.ViewedSemester is not { } semester || Model.ScheduleWeekNumber is not { } current) return;
        var generation = Model.Generation;
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 280, MinWidth = 220,
            ItemsSource = Enumerable.Range(1, Model.ScheduleWeekCount).Select(n => $"第 {n} 周").ToArray(), SelectedIndex = current - 1 };
        var rangeText = Text(ScheduleCalendar.WeekRange(semester, current)!.Value.ToString(), 14);
        list.SelectionChanged += (_, _) => rangeText.Text = ScheduleCalendar.WeekRange(semester, list.SelectedIndex + 1)?.ToString() ?? "";
        var flyout = new Flyout { Placement = FlyoutPlacementMode.Bottom };
        var cancel = Button("取消", () => { flyout.Hide(); return Task.CompletedTask; });
        var jump = Button("跳转", async () =>
        {
            var selected = list.SelectedIndex + 1; flyout.Hide();
            await Model.SelectScheduleWeekAsync(selected, generation, semester.Id);
        });
        flyout.Content = Column(Text("跳转到周", 18, true), list, rangeText, Row(cancel, jump));
        schedulePicker?.Hide(); schedulePicker = flyout;
        flyout.Closed += (_, _) => { if (schedulePicker == flyout) schedulePicker = null; };
        flyout.Opened += (_, _) => list.ScrollIntoView(list.SelectedItem);
        flyout.ShowAt(buttonAnchor);
    }
}
