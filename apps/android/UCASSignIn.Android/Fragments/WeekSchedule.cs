using Android.Content.Res;
using Android.Graphics;
using Android.Views;
using Android.Widget;
using Google.Android.Material.Button;
using Google.Android.Material.Dialog;
using Google.Android.Material.ProgressIndicator;
using UCASSignIn.Core;
using Orientation = Android.Widget.Orientation;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    LinearLayout? weekBody, weekProgress;
    TextView? progressText, scheduleError, scheduleUpdated;
    TextView? weekMonth;
    MaterialButton? scheduleRetry;
    WeekSchedule? displayedWeek;
    DateOnly weekSelected;
    bool weekDark, weekInitial;
    readonly Dictionary<DateOnly, TextView> weekDateButtons = [];
    public void UpdateScheduleProgress()
    {
        if (Host.Vm.Page == 1 && Route is null && Model.ScheduleMode == ScheduleMode.Week && weekBody == body)
            UpdateWeekProgress();
    }
    bool UpdateExistingWeek()
    {
        if (Model.ScheduleMode != ScheduleMode.Week || weekBody != body || weekDark != Dark
            || weekInitial != Model.IsInitialScheduleLoading || !ReferenceEquals(displayedWeek, Model.WeekSchedule())) return false;
        if (weekSelected != Model.SelectedDate)
        {
            weekSelected = Model.SelectedDate;
            if (weekMonth is not null) weekMonth.Text = weekSelected.ToString("yyyy 年 M 月");
            if (weekNumberText is not null) weekNumberText.Text = Model.ScheduleWeekNumber is { } n ? $"第 {n} 周" : "";
            if (previousScheduleButton is not null) previousScheduleButton.Enabled = Model.PreviousScheduleWeek is not null;
            if (nextScheduleButton is not null) nextScheduleButton.Enabled = Model.NextScheduleWeek is not null;
            foreach (var (date, button) in weekDateButtons) { button.SetBackgroundColor(date == weekSelected ? Pale : Color.Transparent); button.Selected = date == weekSelected; }
        }
        UpdateWeekProgress(); return true;
    }
    void UpdateWeekProgress()
    {
        if (progressText is not null) progressText.Text = Model.ScheduleProgress?.ToString() ?? "";
        if (weekProgress is not null) weekProgress.Visibility = Model.ScheduleProgress is null ? ViewStates.Gone : ViewStates.Visible;
        if (scheduleError is not null) { scheduleError.Text = Model.ScheduleError ?? ""; scheduleError.Visibility = Model.ScheduleError is null ? ViewStates.Gone : ViewStates.Visible; }
        if (scheduleRetry is not null) scheduleRetry.Visibility = Model.ScheduleError is null ? ViewStates.Gone : ViewStates.Visible;
        if (scheduleUpdated is not null) scheduleUpdated.Text = Model.ScheduleUpdatedAt is { } time ? $"刷新于 {time.ToOffset(CourseTime.ShanghaiOffset):yyyy年M月d日 HH:mm}" : "尚未完成完整同步";
    }
    View ScheduleModePicker()
    {
        var group = new MaterialButtonToggleGroup(Ui) { SingleSelection = true, SelectionRequired = true };
        foreach (var mode in new[] { ScheduleMode.Day, ScheduleMode.Week })
        {
            var button = new MaterialButton(Ui, null, Resource.Attribute.materialButtonOutlinedStyle)
                { Id = View.GenerateViewId(), Text = mode == ScheduleMode.Day ? "日" : "周", ContentDescription = mode == ScheduleMode.Day ? "日课表" : "周课表", Checkable = true };
            button.SetMinWidth(0); button.SetMinimumWidth(0); button.SetPadding(D(8), 0, D(8), 0); button.TextSize = 12;
            group.AddView(button, new LinearLayout.LayoutParams(D(40), D(40)));
            if (mode == Model.ScheduleMode) group.Check(button.Id);
            button.Click += async (_, _) =>
            {
                Model.ScheduleMode = mode; Host.Vm.SaveSchedulePreferences(); Render(); await Host.Run(Model.EnterScheduleAsync);
            };
        }
        return group;
    }
    void Schedule()
    {
        if (Model.ScheduleMode == ScheduleMode.Day)
        {
            weekBody = null; DailySchedule();
            for (var i = 0; i < body!.ChildCount; i++)
            {
                if (body.GetChildAt(i) is not LinearLayout controls || controls.ContentDescription != "schedule.dateControls") continue;
                var dailyNav = controls.GetChildAt(0)!; controls.RemoveView(dailyNav); controls.AddView(Across(dailyNav, ScheduleModePicker()), 0);
                ConfigureScheduleHeader(controls); break;
            }
            return;
        }
        var date = Model.SelectedDate; var data = Model.WeekSchedule();
        var header = Column();
        header.SetPadding(0, D(12), 0, D(12));
        ConfigureScheduleHeader(header);
        Add(header, 12);
        weekBody = body; displayedWeek = data; weekSelected = date; weekDark = Dark; weekInitial = Model.IsInitialScheduleLoading;
        var nav = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        MaterialButton Arrow(bool next)
        {
            var b = Button("", () => Model.MoveScheduleWeekAsync(next));
            b.Enabled = (next ? Model.NextScheduleWeek : Model.PreviousScheduleWeek) is not null;
            if (next) nextScheduleButton = b; else previousScheduleButton = b;
            b.ContentDescription = next ? "下一周" : "上一周";
            b.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, next ? Resource.Drawable.ic_chevron_right : Resource.Drawable.ic_chevron_left);
            b.IconSize = D(16); b.IconPadding = 0; b.SetPadding(D(10), 0, D(10), 0); b.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent); return b;
        }
        nav.AddView(Arrow(false), new LinearLayout.LayoutParams(D(40), D(44)));
        var month = ScheduleMonthTitle(true);
        nav.AddView(month, new LinearLayout.LayoutParams(0, -2, 1));
        nav.AddView(Arrow(true), new LinearLayout.LayoutParams(D(40), D(44)));
        if (Resources!.Configuration!.ScreenWidthDp / Math.Max(1, Resources.Configuration.FontScale) < 350)
        { header.AddView(nav); header.AddView(ScheduleModePicker()); }
        else header.AddView(Across(nav, ScheduleModePicker()));
        progressText = Text("", 12, color: Secondary);
        var progress = new CircularProgressIndicator(Ui) { Indeterminate = true, IndicatorSize = D(16), TrackThickness = D(2) };
        weekProgress = Layout(Orientation.Horizontal, GravityFlags.Center);
        weekProgress.AddView(progress, new LinearLayout.LayoutParams(D(24), D(24))); weekProgress.AddView(progressText, new LinearLayout.LayoutParams(-2, -2)); header.AddView(weekProgress);
        scheduleError = Text("", 12, color: Secondary); header.AddView(scheduleError);
        scheduleRetry = Button(Model.ViewedSemester is null ? "重试本周" : "重试完整同步", () => Model.RefreshScheduleAsync()); header.AddView(scheduleRetry);
        void AddReturnToWeek()
        {
            if (Model.CanReturnToToday && ScheduleLayout.Monday(date) != ScheduleLayout.Monday(CourseTime.Today()))
                Add(Button("回到本周", Model.ReturnToScheduleTodayAsync));
        }
        if (weekInitial) { Add(Text("正在加载…", 14, color: Secondary)); AddReturnToWeek(); scheduleUpdated = null; UpdateWeekProgress(); return; }
        var headings = new FrameLayout(Ui); var grid = new FrameLayout(Ui);
        var headScroll = new HorizontalScrollView(Ui) { HorizontalScrollBarEnabled = false, FillViewport = false };
        var gridScroll = new HorizontalScrollView(Ui) { HorizontalScrollBarEnabled = true, FillViewport = false };
        headScroll.AddView(headings); gridScroll.AddView(grid);
        headScroll.ScrollChange += (_, _) => { if (gridScroll.ScrollX != headScroll.ScrollX) gridScroll.ScrollTo(headScroll.ScrollX, 0); };
        gridScroll.ScrollChange += (_, _) => { if (headScroll.ScrollX != gridScroll.ScrollX) headScroll.ScrollTo(gridScroll.ScrollX, 0); };
        header.AddView(headScroll); Add(gridScroll, 12);
        var lastWidth = 0;
        void Geometry(int available)
        {
            if (available <= 0 || lastWidth == available) return; lastWidth = available;
            var scale = Math.Max(1, Resources!.Configuration!.FontScale);
            var width = Math.Max(available, D((int)(7 * 36 * scale + 36))); var gutter = D(36); var col = (width - gutter) / 7d;
            var hour = D((int)ScheduleLayout.HourHeight(col / Resources.DisplayMetrics!.Density, scale)); var top = D((int)(12 * scale));
            var height = (data.EndHour - data.StartHour) * hour + top + D(12);
            headings.LayoutParameters = new FrameLayout.LayoutParams(width, D((int)(52 * scale))); grid.LayoutParameters = new FrameLayout.LayoutParams(width, height);
            headings.RemoveAllViews(); grid.RemoveAllViews();
            weekDateButtons.Clear();
            for (var i = 0; i < 7; i++)
            {
                var day = data.Monday.AddDays(i);
                var label = Text(new[] { "一", "二", "三", "四", "五", "六", "日" }[i] + "\n" + day.Day, 12, day == date);
                label.Gravity = GravityFlags.Center; if (day == date) label.SetBackgroundColor(Pale);
                Tap(label, ScheduleDayAction(day), day.ToString("yyyy年M月d日"));
                label.Enabled = Model.CanSelectVisibleDate(day); label.Alpha = label.Enabled ? 1 : .35f;
                weekDateButtons[day] = label;
                headings.AddView(label, new FrameLayout.LayoutParams((int)col, -1) { LeftMargin = gutter + (int)(i * col) });
            }
            for (var h = data.StartHour; h <= data.EndHour; h++)
            {
                var tick = Text($"{h:00}:00", 9, color: Secondary);
                grid.AddView(tick, new FrameLayout.LayoutParams(gutter, -2) { TopMargin = top + (h - data.StartHour) * hour - (int)(tick.TextSize / 2) });
                var rule = new View(Ui); rule.SetBackgroundColor(C(Dark ? "344039" : "E4E9E0"));
                grid.AddView(rule, new FrameLayout.LayoutParams(width - gutter, D(1)) { LeftMargin = gutter, TopMargin = top + (h - data.StartHour) * hour });
            }
            foreach (var block in data.Blocks)
            {
                var entry = block.Entries[0]; var multiple = block.Entries.Count > 1;
                var text = Column(Text(multiple ? $"{block.Entries.Count} 项安排" : entry.Course.Name, 14, true), Text(multiple ? "点击选择课程" : entry.Course.Classroom ?? "", 12));
                for (var i = 0; i < text.ChildCount; i++) ((LinearLayout.LayoutParams)text.GetChildAt(i)!.LayoutParameters!).BottomMargin = D(2);
                if (!multiple && entry.Preview) text.AddView(Text("非本周", 10, color: Secondary));
                var colors = new[] { "4285D4", "9862C4", "259CAA", "6472C6", "D78A35", "CA6394", "46A276" }; var color = C(entry.Preview ? "888888" : colors[entry.Color]);
                var card = Card(text, 3, Color.Argb(Dark ? 85 : 40, color.R, color.G, color.B)); card.Radius = D(6); card.ClipToOutline = true;
                Tap(card, () => OpenScheduleBlock(block), string.Join("；", block.Entries.Select(e => e.AccessibleName)));
                grid.AddView(card, new FrameLayout.LayoutParams((int)col - D(2), Math.Max(1, (int)((block.EndMinute - block.StartMinute) / 60d * hour) - D(2)))
                    { LeftMargin = gutter + (int)((block.Day.DayNumber - data.Monday.DayNumber) * col), TopMargin = top + (int)((block.StartMinute / 60d - data.StartHour) * hour) });
            }
        }
        Geometry(Math.Max(1, (body!.Width > 0 ? body.Width : D(Resources!.Configuration!.ScreenWidthDp)) - D(32)));
        gridScroll.LayoutChange += (_, e) => Geometry(e.Right - e.Left);
        if (data.Unplaced.Count > 0)
        {
            Add(Text("时间待确认", 16, true), 8);
            foreach (var entry in data.Unplaced) Add(Button(entry.Course.Name + " · " + entry.Course.Day, () => OpenScheduleEntry(entry)), 8);
        }
        scheduleUpdated = Text("", 12, color: Secondary); Add(scheduleUpdated, 8); AddReturnToWeek(); UpdateWeekProgress();
    }
    Task OpenScheduleBlock(ScheduleBlock block)
    {
        if (block.Entries.Count == 1) return OpenScheduleEntry(block.Entries[0]);
        if (Host.DialogOpen) return Task.CompletedTask;
        var generation = Model.Generation;
        var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle($"{block.Entries.Count} 项安排")!
            .SetItems(block.Entries.Select(e => e.Course.Name + " · " + e.Course.TimeRange + " · " + e.Course.Classroom).ToArray(),
                (_, e) => { if (generation == Model.Generation) _ = Host.Run(() => OpenScheduleEntry(block.Entries[e.Which])); })!
            .SetNegativeButton("取消", (_, _) => { })!.Create()!;
        TrackScheduleDialog(dialog);
        return Task.CompletedTask;
    }
    async Task OpenScheduleEntry(ScheduleEntry entry)
    {
        var generation = Model.Generation;
        await Model.EnsureCatalogForDateAsync(CourseTime.Date(entry.Course.Day));
        if (!IsAdded || generation != Model.Generation || Host.Vm.Page != 1 || Route is not null) return;
        CatalogDetail(Model.CatalogFor(entry.Course) ?? new CatalogCourse("", entry.Course.CourseNumber ?? "", entry.Course.Name, entry.Course.Teacher,
            entry.Course.Classroom, Model.ViewedSemester?.Id ?? "", entry.Course.Day, entry.Course.Day));
    }
}
