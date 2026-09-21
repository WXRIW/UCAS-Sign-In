using Android.Views;
using Android.Widget;
using Google.Android.Material.Dialog;
using UCASSignIn.Core;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    AndroidX.AppCompat.Widget.PopupMenu? semesterMenu;
    AndroidX.AppCompat.App.AlertDialog? scheduleDialog;
    TextView? weekNumberText;
    View? previousScheduleButton, nextScheduleButton;
    public void CloseSchedulePickers()
    {
        semesterMenu?.Dismiss(); semesterMenu = null;
        scheduleDialog?.Dismiss(); scheduleDialog = null;
        if (Host.SupportFragmentManager.FindFragmentByTag("date") is AndroidX.Fragment.App.DialogFragment picker)
            picker.DismissAllowingStateLoss();
    }
    void UpdateScheduleNavigation()
    {
        if (Host.Vm.Page != 1 || Route is not null) return;
        ActiveToolbar.Menu?.FindItem(11)?.SetEnabled(Model.ViewedDateRange is not null);
        ActiveToolbar.Menu?.FindItem(12)?.SetEnabled(Model.ScheduleSemesters.Count > 0);
    }
    void PickSemester()
    {
        if (Host.DialogOpen) return;
        semesterMenu?.Dismiss();
        var generation = Model.Generation;
        var terms = Model.ScheduleSemesters.ToArray();
        var menu = new AndroidX.AppCompat.Widget.PopupMenu(Ui, ActiveToolbar, (int)GravityFlags.End);
        for (var i = 0; i < terms.Length; i++)
            menu.Menu.Add(0, i + 1, i, terms[i].Name)!.SetCheckable(true)!.SetChecked(terms[i].Id == Model.ViewedSemester?.Id);
        menu.Menu.SetGroupCheckable(0, true, true);
        menu.MenuItemClick += (_, e) =>
        {
            var index = e.Item!.ItemId - 1;
            if (index >= 0 && index < terms.Length) _ = Host.Run(() => Model.SelectScheduleSemesterAsync(terms[index].Id, generation));
        };
        semesterMenu = menu; menu.Show();
    }
    Func<Task> ScheduleDayAction(DateOnly date)
    {
        var generation = Model.Generation; var semester = Model.ViewedSemester?.Id;
        return () => Model.SelectScheduleDateAsync(date, generation, semester);
    }
    View ScheduleMonthTitle(bool trackWeek = false)
    {
        var month = Text(Model.SelectedDate.ToString("yyyy 年 M 月"), 16, true);
        var week = Text(Model.ScheduleWeekNumber is { } number ? $"第 {number} 周" : "", 12, color: Secondary);
        month.Gravity = week.Gravity = GravityFlags.Center;
        var area = Column(month, week); area.SetPadding(D(4), D(4), D(4), D(4)); area.SetMinimumHeight(D(48));
        ((LinearLayout.LayoutParams)month.LayoutParameters!).BottomMargin = D(2);
        Tap(area, PickScheduleWeek, $"{month.Text} {week.Text}，跳转到周");
        area.Enabled = Model.ScheduleWeekNumber is not null;
        if (trackWeek) { weekMonth = month; weekNumberText = week; }
        return area;
    }
    Task PickScheduleWeek()
    {
        if (Host.DialogOpen || Model.ViewedSemester is not { } semester || Model.ScheduleWeekNumber is not { } current) return Task.CompletedTask;
        var generation = Model.Generation;
        var picker = new NumberPicker(Ui) { MinValue = 1, MaxValue = Model.ScheduleWeekCount, Value = current, WrapSelectorWheel = false };
        picker.SetDisplayedValues(Enumerable.Range(1, Model.ScheduleWeekCount).Select(n => $"第 {n} 周").ToArray());
        picker.DescendantFocusability = DescendantFocusability.BlockDescendants;
        picker.ContentDescription = "选择周次";
        var rangeText = Text(ScheduleCalendar.WeekRange(semester, current)!.Value.ToString(), 14);
        rangeText.Gravity = GravityFlags.Center;
        picker.ValueChanged += (_, _) => rangeText.Text = ScheduleCalendar.WeekRange(semester, picker.Value)?.ToString() ?? "";
        var content = Column(picker, rangeText); content.SetPadding(D(20), 0, D(20), D(8));
        var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle("跳转到周")!.SetView(content)!
            .SetNegativeButton("取消", (_, _) => { })!
            .SetPositiveButton("跳转", (_, _) => _ = Host.Run(() => Model.SelectScheduleWeekAsync(picker.Value, generation, semester.Id)))!.Create()!;
        TrackScheduleDialog(dialog);
        return Task.CompletedTask;
    }
    void TrackScheduleDialog(AndroidX.AppCompat.App.AlertDialog dialog)
    {
        scheduleDialog = dialog;
        dialog.DismissEvent += (_, _) => { if (scheduleDialog == dialog) scheduleDialog = null; };
        Track(dialog);
    }
}
