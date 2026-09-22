using Android.Content;
using Android.Views;
using Android.Widget;
using UCASSignIn.Core;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    void RenderCourseScheduleSummary(CatalogCourse course)
    {
        var content = Column(Text("正在整理排课…", 13, color: Secondary));
        var generation = Model.Generation;
        var inside = Across(content, Icon(Resource.Drawable.ic_chevron_right, 18, Secondary));
        var card = Card(inside, 0);
        inside.SetPadding(D(21), D(12), D(21), D(12));
        Tap(card, () => generation == Model.Generation ? Navigate("course-schedule") : Task.CompletedTask,
            "排课信息，" + course.Name + "，查看按周排列的完整排课信息");
        Add(Column(Text("排课信息", 14, true), card));
        var scene = activeScene!;
        object? requested = null;
        scene.UpdateScheduleSummary = () =>
        {
            var state = (Model.ArrangementVersion, Model.IdentityVersion, Model.CourseScheduleLoading(course.SemesterId), Model.CourseScheduleError(course.SemesterId));
            if (Equals(requested, state)) return;
            requested = state;
            void Apply(CourseSchedulePresentation data)
            {
                content.RemoveAllViews();
                foreach (var summary in data.Summaries)
                    content.AddView(Column(Text(summary.Weeks + " · " + summary.Weekday, 14), Text(summary.Time + " · " + summary.Classroom, 13, color: Secondary)),
                        new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(content.ChildCount == 0 ? 0 : 16) });
                AddCourseScheduleStatus(content, course, data);
            }
            // Rebuilding unrelated detail sections must not replace an already loaded summary with a placeholder.
            if (Model.CachedCourseScheduleFor(course) is { } cached) Apply(cached);
            else PrepareScheduleContent(course, scene, Apply);
        };
        scene.UpdateScheduleSummary();
    }
    void AddCourseScheduleStatus(LinearLayout panel, CatalogCourse course, CourseSchedulePresentation data)
    {
        foreach (var message in new[] { Model.CourseScheduleStatus(course, data), Model.CourseScheduleError(course.SemesterId) }.OfType<string>())
            panel.AddView(Text(message, 13, color: Secondary), new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(panel.ChildCount == 0 ? 0 : 8) });
    }
    bool IsCurrentScheduleContent(Scene scene, Guid generation, long version) => IsAdded && sceneHost is not null
        && Model.Generation == generation && scenes.GetValueOrDefault(scene.Key) == scene && scene.ContentVersion == version;
    void PrepareScheduleContent(CatalogCourse course, Scene scene, Action<CourseSchedulePresentation> apply)
    {
        var model = Model; var host = Host; var generation = model.Generation; var version = scene.ContentVersion;
        // Post first so navigation can present its lightweight scene. Only pure projection runs on the worker.
        scene.Root.Post(async () => await host.Run(async () =>
        {
            if (!IsCurrentScheduleContent(scene, generation, version)) return;
            var data = await model.PrepareCourseScheduleAsync(course);
            await (scene.ContentReady?.Task ?? Task.CompletedTask);
            void Apply()
            {
                if (!IsCurrentScheduleContent(scene, generation, version) || !ReferenceEquals(data, model.CachedCourseScheduleFor(course))) return;
                if (backPreview) { scene.Root.PostOnAnimation(new Java.Lang.Runnable(Apply)); return; }
                apply(data);
            }
            Apply();
        }));
    }
    bool RetainCourseSchedule()
    {
        if (Route != "course-schedule" || CurrentCatalogDetail is not { } course || activeScene is not { } scene) return false;
        return Model.CachedCourseScheduleFor(course) is { } data && ReferenceEquals(scene.ScheduleData, data) && scene.ScheduleStatus == Model.CourseScheduleStatus(course, data)
            && scene.ScheduleError == Model.CourseScheduleError(course.SemesterId) && scene.ScheduleDark == Dark;
    }
    void RenderCourseSchedule(CatalogCourse course)
    {
        var offset = scroll!.IsLaidOut ? scroll.ScrollY : Host.Vm.ScrollPositions.GetValueOrDefault(SceneKey(Route));
        var data = Model.CourseScheduleFor(course);
        AddCourseScheduleStatus(body!, course, data);
        foreach (var week in data.Meetings.GroupBy(m => m.Week))
        {
            Add(Text($"第 {week.Key} 周", 14, true), 12);
            foreach (var meeting in week) Add(CourseScheduleCard(meeting), 12);
        }
        var scene = activeScene!;
        scene.ScheduleData = data; scene.ScheduleStatus = Model.CourseScheduleStatus(course, data);
        scene.ScheduleError = Model.CourseScheduleError(course.SemesterId); scene.ScheduleDark = Dark;
        var scroller = scroll;
        scroller.Post(() => scroller.ScrollTo(0, offset));
    }
    View CourseScheduleCard(CourseScheduleMeeting meeting)
    {
        var header = new ScheduleFlowLayout(Ui, D(16), D(5), true);
        header.AddView(Text($"第 {meeting.Week} 周 · {meeting.Weekday}", 14, true));
        header.AddView(Text(meeting.Date.ToString("yyyy年M月d日"), 13, color: Secondary));
        header.LayoutParameters = new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(6) };
        var fields = new ScheduleFlowLayout(Ui, D(16), D(5));
        fields.AddView(ScheduleField(Resource.Drawable.ic_clock, meeting.Time));
        fields.AddView(ScheduleField(Resource.Drawable.ic_location, meeting.ClassroomText));
        fields.AddView(ScheduleField(Resource.Drawable.ic_person, meeting.TeacherText));
        var content = Column(header, fields);
        var card = Card(content, 0);
        var verticalPadding = (int)Math.Round(D(21) / 2d);
        content.SetPadding(D(21), verticalPadding, D(21), verticalPadding);
        return card;
    }
    TextView ScheduleField(int icon, string value)
    {
        var text = Text(value, 13, color: Secondary);
        var drawable = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, icon)!.Mutate();
        drawable.SetTint(Secondary.ToArgb()); drawable.SetBounds(0, 0, D(16), D(16));
        text.SetCompoundDrawablesRelative(drawable, null, null, null); text.CompoundDrawablePadding = D(6);
        return text;
    }
    public void EnsureCatalogPage()
    {
        if (Route is not ("catalog-detail" or "course-schedule") || CurrentCatalogDetail is not { } course || activeScene is not { } scene || scene.EnsuringCatalog) return;
        var host = Host; var model = Model; var generation = model.Generation;
        scene.EnsuringCatalog = true;
        scene.Root.Post(async () => await host.Run(async () =>
        {
            try
            {
                await (scene.ContentReady?.Task ?? Task.CompletedTask);
                if (!IsAdded || model.Generation != generation || activeScene != scene) return;
                var schedule = model.EnsureCourseScheduleAsync(course);
                var attendance = Route == "catalog-detail" && model.ShouldRefreshAttendance(course.Id)
                    ? model.RefreshAttendanceAsync(course.Id) : Task.CompletedTask;
                await Task.WhenAll(schedule, attendance);
            }
            finally { scene.EnsuringCatalog = false; }
        }));
    }
}

sealed class ScheduleFlowLayout(Context context, int gap, int lineGap, bool rightAlignLast = false) : ViewGroup(context)
{
    protected override void OnMeasure(int widthMeasureSpec, int heightMeasureSpec)
    {
        var width = MeasureSpec.GetSize(widthMeasureSpec); var x = 0; var y = 0; var height = 0;
        for (var i = 0; i < ChildCount; i++)
        {
            var child = GetChildAt(i)!;
            child.Measure(MeasureSpec.MakeMeasureSpec(width, MeasureSpecMode.AtMost), MeasureSpec.MakeMeasureSpec(0, MeasureSpecMode.Unspecified));
            if (x > 0 && x + child.MeasuredWidth > width) { y += height + lineGap; x = height = 0; }
            x += child.MeasuredWidth + gap; height = Math.Max(height, child.MeasuredHeight);
        }
        SetMeasuredDimension(width, ResolveSize(y + height, heightMeasureSpec));
    }
    protected override void OnLayout(bool changed, int left, int top, int right, int bottom)
    {
        var width = right - left; var x = 0; var y = 0; var height = 0;
        for (var i = 0; i < ChildCount; i++)
        {
            var child = GetChildAt(i)!;
            if (x > 0 && x + child.MeasuredWidth > width) { y += height + lineGap; x = height = 0; }
            var start = rightAlignLast && i == ChildCount - 1 && x > 0 ? Math.Max(x, width - child.MeasuredWidth) : x;
            child.Layout(start, y, start + child.MeasuredWidth, y + child.MeasuredHeight);
            x += child.MeasuredWidth + gap; height = Math.Max(height, child.MeasuredHeight);
        }
    }
    protected override LayoutParams GenerateDefaultLayoutParams() => new(LayoutParams.WrapContent, LayoutParams.WrapContent);
}
