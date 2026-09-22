using Android.Content;
using Android.Content.Res;
using Android.Graphics;
using Android.Views;
using Android.Widget;
using Google.Android.Material.MaterialSwitch;
using Google.Android.Material.TextField;
using UCASSignIn.Core;
using Orientation = Android.Widget.Orientation;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    View PreferenceStatus(bool enabled, string label)
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        var marker = new View(Ui);
        var shape = new global::Android.Graphics.Drawables.GradientDrawable();
        shape.SetShape(global::Android.Graphics.Drawables.ShapeType.Oval);
        if (enabled) shape.SetColor(Green);
        else
        {
            shape.SetColor(Color.Transparent);
            shape.SetStroke(D(1), Secondary);
        }
        marker.Background = shape;
        row.AddView(marker, new LinearLayout.LayoutParams(D(11), D(11)) { MarginEnd = D(4) });
        row.AddView(Text(label, 11, color: Secondary));
        row.ContentDescription = label + (enabled ? "，启用" : "，停用");
        return row;
    }

    View DisabledSignInStatus(string label)
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        row.AddView(Icon(Resource.Drawable.ic_cancel, 14, C("C42B1C")), new LinearLayout.LayoutParams(D(14), D(14)) { MarginEnd = D(4) });
        row.AddView(Text(label, 11, color: Secondary));
        row.ContentDescription = label;
        return row;
    }

    public void CoursesPage()
    {
        if (!Model.IsConnected)
        {
            Add(Card(Column(Icon(Resource.Drawable.ic_book, 40), Text("连接账户后查看课程", 22, true),
                Text("课程目录来自学校当前学期，不会由日课表拼接。", 13, color: Secondary), Button("连接账户", () => { Login(); return Task.CompletedTask; }, true))));
            return;
        }
        var semesterLabel = Text("", 14, true);
        Add(semesterLabel, 10);
        var updatedLabel = Text("", 11, color: Secondary);
        Add(updatedLabel, 12);
        var errorLabel = Text("", 12, color: Secondary);
        var errorCard = Card(errorLabel);
        Add(errorCard, 12);

        var search = new TextInputEditText(Ui) { Text = courseSearch, Hint = "搜索课程名、课程编号或教师" };
        search.SetSingleLine(true);
        // TextInputLayout already draws the Material filled-field underline.
        // Remove EditText's own underline so the two backgrounds do not stack.
        search.Background = null;
        search.SetTextColor(Ink);
        search.SetHintTextColor(Secondary);
        var searchBox = new TextInputLayout(Ui)
        {
            HintEnabled = false,
            BoxBackgroundMode = TextInputLayout.BoxBackgroundFilled,
            BoxBackgroundColor = Surface,
            BoxStrokeWidth = 0,
            BoxStrokeWidthFocused = 0,
            EndIconMode = TextInputLayout.EndIconClearText
        };
        searchBox.SetBoxCornerRadii(D(28), D(28), D(28), D(28));
        searchBox.StartIconDrawable = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, Resource.Drawable.ic_search);
        searchBox.SetStartIconTintList(ColorStateList.ValueOf(Secondary));
        searchBox.AddView(search, new LinearLayout.LayoutParams(-1, -2));
        Add(searchBox, 16);
        var list = Column(); Add(list, 0);
        object? listVersion = null;
        void UpdateList()
        {
            var version = (Model.CatalogCourses, Model.Preferences, Model.ArrangementVersion, Model.IdentityVersion, courseSearch,
                Loading: Model.IsCatalogRefreshing && Model.CatalogCourses.Count == 0);
            if (Equals(listVersion, version)) return;
            listVersion = version;
            list.RemoveAllViews();
            var values = Model.CatalogCourses.Where(c => courseSearch.Length == 0 || new[] { c.Name, c.Number, c.Teacher }
                .Any(x => x.Contains(courseSearch, StringComparison.OrdinalIgnoreCase))).ToList();
            if (Model.IsCatalogRefreshing && Model.CatalogCourses.Count == 0)
            {
                var progress = new ProgressBar(Ui) { Indeterminate = true };
                list.AddView(Card(Across(Text("正在加载课程目录…", 13), progress)), new LinearLayout.LayoutParams(-1, -2));
                return;
            }
            if (values.Count == 0)
            {
                list.AddView(Card(Text(courseSearch.Length == 0 ? "当前学期暂无课程" : "没有匹配的课程", 14, color: Secondary)), new LinearLayout.LayoutParams(-1, -2));
                return;
            }
            foreach (var course in values)
            {
                var disabled = Model.IsSignInDisabled(course.Id);
                var statuses = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
                statuses.AddView(PreferenceStatus(Model.EffectiveReminders(course.Id), "提醒"), new LinearLayout.LayoutParams(-2, -2) { MarginEnd = D(14) });
                if (!disabled)
                {
                    statuses.AddView(PreferenceStatus(Model.EffectiveConfirmation(course.Id), "二次确认"), new LinearLayout.LayoutParams(-2, -2) { MarginEnd = D(14) });
                    statuses.AddView(PreferenceStatus(Model.EffectiveAutoSign(course.Id), "自动签到"));
                }
                else statuses.AddView(DisabledSignInStatus("已禁用签到"));
                var card = Card(Across(Column(Text(course.Name, 16, true), Text(string.IsNullOrWhiteSpace(course.Number) ? "课程编号暂未提供" : course.Number, 11, color: Secondary), statuses), Icon(Resource.Drawable.ic_chevron_right, 13, Secondary)));
                Tap(card, () => { CatalogDetail(course); return Task.CompletedTask; }, course.Name + "课程详情");
                list.AddView(card, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(10) });
            }
        }
        void UpdatePage()
        {
            semesterLabel.Text = Model.SelectedSemester?.Name ?? "";
            semesterLabel.Visibility = Model.SelectedSemester is null ? ViewStates.Gone : ViewStates.Visible;
            updatedLabel.Text = Model.CatalogUpdatedAt is { } updated ? $"课程目录 · 最后更新 {updated.ToLocalTime():M-d HH:mm}" : "";
            updatedLabel.Visibility = Model.CatalogUpdatedAt is null ? ViewStates.Gone : ViewStates.Visible;
            errorLabel.Text = string.IsNullOrWhiteSpace(Model.CatalogError) ? "" : "刷新失败：" + Model.CatalogError + "\n正在保留已缓存的课程。";
            errorCard.Visibility = string.IsNullOrWhiteSpace(Model.CatalogError) ? ViewStates.Gone : ViewStates.Visible;
            UpdateList();
        }
        search.TextChanged += (_, e) => { courseSearch = (e.Text?.ToString() ?? "").Trim(); UpdateList(); };
        coursePageBody = body;
        updateCoursePage = UpdatePage;
        UpdatePage();
    }

    View OverrideSettingRow(int icon, string title, string description, PreferenceOverride value, bool inherited, Func<PreferenceOverride, Task> save)
    {
        var normalized = CoursePreferences.Normalize(value);
        var selectedLabel = normalized switch
        {
            PreferenceOverride.Enabled => "启用  ›",
            PreferenceOverride.Disabled => "停用  ›",
            _ => "跟随全局  ›"
        };
        return Tap(Across(
            SettingLabel(icon, title, description),
            Text(selectedLabel, 13, color: Secondary)),
            () =>
            {
                PreferenceOverridePicker(title, normalized, inherited, save);
                return Task.CompletedTask;
            }, title);
    }

    View SettingRow(int icon, string title, string description, View control)
    {
        return Across(SettingLabel(icon, title, description), control);
    }

    View MaterialSettingsSection(string title, View content, string? footer = null)
    {
        var section = Column();
        var heading = Text(title, 14, true, Secondary);
        heading.SetPadding(D(16), 0, D(16), 0);
        section.AddView(heading, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(10) });
        var card = Card(content, 0);
        content.SetPadding(D(21), D(12), D(21), D(12));
        section.AddView(card, new LinearLayout.LayoutParams(-1, -2));
        if (!string.IsNullOrWhiteSpace(footer))
        {
            var note = Text(footer, 11, color: Secondary);
            note.SetPadding(D(16), 0, D(16), 0);
            section.AddView(note, new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(8) });
        }
        return section;
    }

    View SettingsRule()
    {
        var rule = Rule();
        var layout = (LinearLayout.LayoutParams)rule.LayoutParameters!;
        layout.MarginStart = D(34);
        rule.LayoutParameters = layout;
        return rule;
    }

    View CourseInfoRow(int icon, string label, string value)
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        var caption = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        caption.AddView(Icon(icon, 16, Secondary), new LinearLayout.LayoutParams(D(18), D(18)) { MarginEnd = D(8) });
        caption.AddView(Text(label, 12, color: Secondary));
        row.AddView(caption, new LinearLayout.LayoutParams(D(112), -2));
        row.AddView(Text(value, 13), new LinearLayout.LayoutParams(0, -2, 1));
        return row;
    }

    View CourseMetric(string label, int value, Color color, Color background)
    {
        var copy = Column(Text(value.ToString(), 24, true, color), Text(label, 11, color: Secondary));
        copy.SetGravity(GravityFlags.Center);
        copy.SetPadding(D(12), D(12), D(12), D(12));
        var shape = new global::Android.Graphics.Drawables.GradientDrawable();
        shape.SetColor(background);
        shape.SetCornerRadius(D(12));
        copy.Background = shape;
        return copy;
    }

    View AttendanceStatus(bool signed)
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        row.AddView(Icon(signed ? Resource.Drawable.ic_check_circle : Resource.Drawable.ic_cancel, 15, signed ? Green : Secondary),
            new LinearLayout.LayoutParams(D(15), D(15)) { MarginEnd = D(5) });
        row.AddView(Text(signed ? "已签到" : "未签到", 12, true, signed ? Green : Secondary));
        return row;
    }

    View OperationStatus(bool succeeded)
    {
        var icon = Icon(succeeded ? Resource.Drawable.ic_check_circle : Resource.Drawable.ic_cancel, 18, succeeded ? Green : Secondary);
        icon.ContentDescription = succeeded ? "成功" : "失败";
        return icon;
    }

    object CatalogContentKey(CatalogCourse course) => (course, Model.CoursePreferencesFor(course.Id), Model.Preferences,
        Model.Records,
        Model.Records.Count > 0 ? (Model.ArrangementVersion, Model.IdentityVersion) : (0L, 0L),
        Model.Semesters.FirstOrDefault(s => s.Id == course.SemesterId)?.Name, Model.CanChangeAccount, Dark);
    bool RetainCatalogDetail()
    {
        if (Route != "catalog-detail" || CurrentCatalogDetail is not { } target || activeScene is not { } scene) return false;
        var course = Model.AllCatalogCourses.FirstOrDefault(c => CourseSchedule.SameCourse(c, target)) ?? target;
        if (!Equals(scene.CatalogContentKey, CatalogContentKey(course))) return false;
        scene.UpdateAttendanceSection?.Invoke();
        scene.UpdateScheduleSummary?.Invoke();
        return true;
    }
    public void RenderCatalogDetail(CatalogCourse course)
    {
        activeScene!.CatalogContentKey = CatalogContentKey(course);
        activeScene.UpdateAttendanceSection = null;
        var values = Model.CoursePreferencesFor(course.Id);
        string Missing(string? value) => string.IsNullOrWhiteSpace(value) ? "暂未提供" : value;
        var information = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
        void AddInformation(int icon, string label, string value)
        {
            var row = CourseInfoRow(icon, label, value);
            information.AddView(row, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(13) });
        }
        AddInformation(Resource.Drawable.ic_code, "课程编号", Missing(course.Number));
        AddInformation(Resource.Drawable.ic_person, "教师", Missing(course.Teacher));
        AddInformation(Resource.Drawable.ic_location, "教室", Missing(course.Classroom));
        AddInformation(Resource.Drawable.ic_calendar, "学期", Missing(Model.Semesters.FirstOrDefault(s => s.Id == course.SemesterId)?.Name ?? course.SemesterId));
        AddInformation(Resource.Drawable.ic_calendar, "课程日期", DisplayLongDay(course.BeginDate) + "–" + DisplayLongDay(course.EndDate));
        if (information.ChildCount > 0)
        {
            var last = information.GetChildAt(information.ChildCount - 1)!;
            var layout = (LinearLayout.LayoutParams)last.LayoutParameters!;
            layout.BottomMargin = 0;
            last.LayoutParameters = layout;
        }
        Add(MaterialSettingsSection("课程信息", information));
        RenderCourseScheduleSummary(course);
        if (string.IsNullOrWhiteSpace(course.Id)) { Add(Text("课程身份尚未唯一关联，设置与学校考勤暂不可用。", 14, color: Secondary)); return; }

        var notification = Column(OverrideSettingRow(Resource.Drawable.ic_bell, "课前提醒", "在上课前发送本地通知",
            values.Reminders, Model.Preferences.RemindersEnabled,
            selected => Model.SetCoursePreferencesAsync(course.Id, values with { Reminders = selected })));
        if (Model.EffectiveReminders(course.Id))
        {
            notification.AddView(SettingsRule());
            var lead = Tap(Across(
                SettingLabel(Resource.Drawable.ic_clock, "提醒时间", $"当前有效值：提前 {Model.EffectiveReminderLeadMinutes(course.Id)} 分钟"),
                Text(values.ReminderLeadMinutes is { } minutes ? $"{minutes} 分钟  ›" : "跟随全局  ›", 13, color: Secondary)),
                () =>
                {
                    ReminderLeadTime(values.ReminderLeadMinutes, true, Model.Preferences.ReminderLeadMinutes,
                        selected => Model.SetCoursePreferencesAsync(course.Id, values with { ReminderLeadMinutes = selected }));
                    return Task.CompletedTask;
                }, "提醒时间");
            notification.AddView(lead);
        }
        Add(MaterialSettingsSection("通知", notification));

        var disabled = new MaterialSwitch(Ui) { Checked = values.SignInDisabled, ContentDescription = "禁用本课程签到" };
        disabled.CheckedChange += async (_, _) => { if (disabled.Checked != values.SignInDisabled) await Host.Run(() => Model.SetCoursePreferencesAsync(course.Id, values with { SignInDisabled = disabled.Checked })); };
        var sign = Column();
        if (!values.SignInDisabled)
        {
            sign.AddView(OverrideSettingRow(Resource.Drawable.ic_check_circle, "手动签到二次确认", "手动签到前显示课程与上课时间",
                values.Confirmation, Model.Preferences.ConfirmBeforeSign,
                selected => Model.SetCoursePreferencesAsync(course.Id, values with { Confirmation = selected })));
            sign.AddView(SettingsRule());
            sign.AddView(OverrideSettingRow(Resource.Drawable.ic_check, "自动签到", "进入签到时段后自动尝试一次",
                values.AutoSign, Model.Preferences.AutoSignEnabled,
                selected => Model.SetCoursePreferencesAsync(course.Id, values with { AutoSign = selected })));
            sign.AddView(SettingsRule());
        }
        sign.AddView(SettingRow(Resource.Drawable.ic_eye_off, "禁用本课程签到", "暂停本课程的手动签到和自动签到", disabled));
        Add(MaterialSettingsSection("签到", sign));

        // Attendance arrives independently of the schedule. Keep the other sections attached.
        var attendanceSection = Column();
        Add(attendanceSection);
        object? attendanceState = null;
        Action? updateAttendanceRefresh = null;
        activeScene.UpdateAttendanceSection = () =>
        {
            var state = (Model.AttendanceFor(course.Id), Model.AttendanceUpdatedAt(course.Id), Model.AttendanceError(course.Id));
            if (!Equals(attendanceState, state))
            {
                attendanceState = state;
                var section = CourseAttendanceSection(course, out var updateRefresh);
                attendanceSection.RemoveAllViews();
                attendanceSection.AddView(section);
                updateAttendanceRefresh = updateRefresh;
            }
            updateAttendanceRefresh?.Invoke();
        };
        activeScene.UpdateAttendanceSection();

        var local = Column();
        var records = Model.RecordsForCourse(course.Id).ToList();
        if (records.Count == 0)
        {
            var empty = Text("本机尚无这门课程的签到操作记录", 12, color: Secondary);
            empty.SetPadding(0, D(12), 0, D(12));
            local.AddView(empty);
        }
        for (var index = 0; index < records.Count; index++)
        {
            if (index > 0) local.AddView(SettingsRule());
            var record = records[index];
            var row = Across(Column(Text(record.Message, 13, true), Text(record.Date.ToLocalTime().ToString("M月d日 HH:mm"), 11, color: Secondary)),
                OperationStatus(record.Succeeded));
            row.SetPadding(0, D(8), 0, D(8));
            local.AddView(row);
        }
        Add(MaterialSettingsSection("本机操作记录", local, "仅保存在本机，与学校返回的考勤状态分开显示。"));
    }

    View CourseAttendanceSection(CatalogCourse course, out Action updateRefresh)
    {
        var attendance = Column();
        var refreshButton = Button(Model.IsAttendanceRefreshing(course.Id) ? "正在刷新…" : "刷新", () => Model.RefreshAttendanceAsync(course.Id, true));
        updateRefresh = () =>
        {
            var refreshing = Model.IsAttendanceRefreshing(course.Id);
            refreshButton.Text = refreshing ? "正在刷新…" : "刷新";
            refreshButton.Enabled = !refreshing && Model.CanChangeAccount;
        };
        refreshButton.SetMinHeight(D(36));
        refreshButton.SetMinimumHeight(D(36));
        attendance.AddView(SettingRow(Resource.Drawable.ic_history, "考勤统计与明细", "学校记录的签到次数及每次上课的签到状态", refreshButton));
        if (Model.AttendanceFor(course.Id) is { } summary)
        {
            var metrics = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
            metrics.SetPadding(0, D(4), 0, D(4));
            metrics.AddView(CourseMetric("已签到", summary.SignedCount, Green, Pale), new LinearLayout.LayoutParams(0, -2, 1) { MarginEnd = D(6) });
            metrics.AddView(CourseMetric("未签到", summary.UnsignedCount, Secondary, C(Dark ? "27302B" : "F4F4F4")), new LinearLayout.LayoutParams(0, -2, 1) { MarginStart = D(6) });
            attendance.AddView(metrics, new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(8), BottomMargin = D(4) });
            foreach (var record in summary.Records.OrderByDescending(x => x.Day))
            {
                var divider = Rule();
                divider.LayoutParameters = new LinearLayout.LayoutParams(-1, D(1)) { TopMargin = D(8), BottomMargin = D(8) };
                attendance.AddView(divider);
                var date = Text(DisplayLongDay(record.Day), 14, true);
                date.LayoutParameters = new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(8) };
                var row = Across(Column(date, Text($"{CourseTime.Display(record.BeginTime)}–{CourseTime.Display(record.EndTime)}", 11, color: Secondary)), AttendanceStatus(record.Signed));
                row.SetPadding(0, D(4), 0, D(4));
                attendance.AddView(row);
            }
        }
        else if (Model.AttendanceError(course.Id) is { } error)
        {
            attendance.AddView(Rule());
            var message = Text("刷新失败：" + error, 12, color: Secondary);
            message.SetPadding(0, D(12), 0, D(12));
            attendance.AddView(message);
        }
        else
        {
            attendance.AddView(Rule());
            var empty = Text("暂无学校考勤记录", 12, color: Secondary);
            empty.SetPadding(0, D(12), 0, D(12));
            attendance.AddView(empty);
        }
        var attendanceFooter = Model.AttendanceUpdatedAt(course.Id) is { } at
            ? $"学校数据同步于 {at.ToLocalTime():M月d日 HH:mm}。"
            : "考勤数据来自学校接口，进入页面后按缓存有效期自动更新，也可手动刷新。";
        return MaterialSettingsSection("学校考勤", attendance, attendanceFooter);
    }

    static string DisplayDay(string day) => day.Length == 8 ? $"{day[..4]}-{day.Substring(4, 2)}-{day[6..]}" : string.IsNullOrWhiteSpace(day) ? "暂未提供" : day;
    static string DisplayLongDay(string day) => day.Length == 8 && int.TryParse(day[..4], out var year) && int.TryParse(day.Substring(4, 2), out var month) && int.TryParse(day[6..], out var value)
        ? $"{year}年{month}月{value}日"
        : string.IsNullOrWhiteSpace(day) ? "暂未提供" : day;
}
