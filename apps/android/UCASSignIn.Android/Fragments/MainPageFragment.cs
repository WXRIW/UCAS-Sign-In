using Android.Content;
using Android.Content.Res;
using Orientation = Android.Widget.Orientation;
using Android.OS;
using Android.Views;
using Android.Widget;
using Android.Graphics;
using Google.Android.Material.Button;
using Google.Android.Material.Card;
using Google.Android.Material.MaterialSwitch;
using UCASSignIn.Core;
namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment : AndroidX.Fragment.App.Fragment
{
    new MainActivity Host => (MainActivity)RequireActivity();
    AccountCoordinator Model => Host.Model;
    Context Ui => Host.UiContext;
    LinearLayout? body;
    ScrollView? scroll;
    AndroidX.SwipeRefreshLayout.Widget.SwipeRefreshLayout? refresh;
    CancellationTokenSource? qrCancellation;
    string? Route
    {
        get => Host.Vm.Routes[Host.Vm.Page]; set => Host.Vm.Routes[Host.Vm.Page] = value;
    }
    Course? CurrentDetail
    {
        get => Host.Vm.Details[Host.Vm.Page]; set => Host.Vm.Details[Host.Vm.Page] = value;
    }
    bool Dark => (Resources!.Configuration!.UiMode & UiMode.NightMask) == UiMode.NightYes;
    Color Ink => C(Dark ? "EDF3ED" : "1C342B");
    Color Secondary => C(Dark ? "A0ADA4" : "7B8780");
    Color Green => C(Dark ? "91C6A6" : "285C45");
    Color Pale => C(Dark ? "2C4234" : "E8EFE4");
    Color Surface => C(Dark ? "1D2922" : "FFFFFF");
    bool Landscape => Resources!.Configuration!.ScreenWidthDp > Resources.Configuration.ScreenHeightDp;
    bool TwoColumns => Landscape && Resources!.Configuration!.ScreenWidthDp >= 760 * Math.Max(1, Resources.Configuration.FontScale);
    int ContentWidthLimit => TwoColumns ? 1040 : 680;
    Color C(string hex) => Color.ParseColor("#" + hex);
    int D(int value) => Host.Dp(value);
    LinearLayout Layout(Orientation orientation, GravityFlags gravity)
    {
        var p = new LinearLayout(Ui) { Orientation = orientation };
        p.SetGravity(gravity);
        return p;
    }
    public override View OnCreateView(LayoutInflater inflater, ViewGroup? container, Bundle? state)
    {
        sceneHost = new FrameLayout(Ui);
        sceneHost.LayoutChange += (_, e) =>
        {
            var width = Math.Min(e.Right - e.Left, D(ContentWidthLimit));
            if (width <= 0) return;
            foreach (var scene in scenes.Values)
                if (scene.Body.LayoutParameters is { } layout && layout.Width != width)
                {
                    layout.Width = width;
                    scene.Body.LayoutParameters = layout;
                }
        };
        Render();
        return sceneHost;
    }
    public override void OnDestroyView()
    {
        qrCancellation?.Cancel();
        ClearScenes();
        body = null;
        scroll = null;
        refresh = null;
        sceneHost = null;
        base.OnDestroyView();
    }
    LinearLayout Column(params View[] children)
    {
        var p = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
        for (var i = 0; i < children.Length; i++)
        {
            var size = children[i].LayoutParameters;
            var margins = size as ViewGroup.MarginLayoutParams;
            p.AddView(children[i], new LinearLayout.LayoutParams(size?.Width ?? -1, size?.Height ?? -2) { TopMargin = margins?.TopMargin ?? 0, BottomMargin = margins?.BottomMargin ?? D(i == children.Length - 1 ? 0 : 8), Gravity = children[i] is ImageView ? GravityFlags.CenterHorizontal : GravityFlags.NoGravity });
        }
        return p;
    }
    LinearLayout Across(View left, View right)
    {
        var p = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        p.AddView(left, new LinearLayout.LayoutParams(0, -2, 1) { MarginEnd = D(12) });
        var iconSize = right is ImageView ? right.LayoutParameters : null;
        p.AddView(right, new LinearLayout.LayoutParams(iconSize?.Width ?? -2, iconSize?.Height ?? -2));
        return p;
    }
    TextView Text(string value, float size = 14, bool bold = false, Color? color = null)
    {
        var t = new TextView(Ui) { Text = value, TextSize = size };
        t.SetIncludeFontPadding(false);
        t.SetTextColor(color ?? Ink);
        t.SetLineSpacing(0, 1);
        if (bold)
            t.SetTypeface(null, TypefaceStyle.Bold);
        t.SetPadding(0, 0, 0, 0);
        return t;
    }
    MaterialButton Button(string label, Func<Task> action, bool primary = false)
    {
        var b = new MaterialButton(Ui, null, primary ? Resource.Attribute.materialButtonStyle : Resource.Attribute.materialButtonOutlinedStyle) { Text = label, Enabled = Model.CanChangeAccount, ContentDescription = label, CornerRadius = D(17), InsetTop = 0, InsetBottom = 0, StrokeWidth = 0 };
        b.SetAllCaps(false);
        b.TextSize = 14;
        b.IconGravity = MaterialButton.IconGravityTextStart;
        b.SetTextColor(primary ? Color.White : Green);
        b.BackgroundTintList = ColorStateList.ValueOf(primary ? C("285C45") : Pale);
        b.SetMinHeight(D(48));
        b.SetMinimumHeight(D(48));
        b.SetMinWidth(0);
        b.SetMinimumWidth(0);
        b.SetPadding(D(12), D(8), D(12), D(8));
        b.Click += async (_, _) => await Host.Run(action);
        return b;
    }
    MaterialCardView Card(View content, int padding = 21, Color? color = null)
    {
        var card = new MaterialCardView(Ui) { Radius = D(22), CardElevation = 0, StrokeWidth = 0 };
        card.SetCardBackgroundColor(color ?? Surface);
        content.SetPadding(D(padding), D(padding), D(padding), D(padding));
        card.AddView(content, new ViewGroup.LayoutParams(-1, -2));
        return card;
    }
    View Tap(View view, Func<Task> action, string label)
    {
        view.Clickable = true;
        view.Focusable = true;
        view.ContentDescription = label;
        view.Click += async (_, _) => await Host.Run(action);
        return view;
    }
    void Add(View view, int gap = 24) => body!.AddView(view, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(gap) });
    // Keep whole sections and their actions together when changing reading order.
    void ArrangeColumns(Func<int, bool> inLeft, float leftWeight = .44f)
    {
        if (!TwoColumns) return;
        var items = Enumerable.Range(0, body!.ChildCount).Select(i => body.GetChildAt(i)!).ToArray();
        body.RemoveAllViews();
        var left = Column();
        var right = Column();
        for (var i = 0; i < items.Length; i++)
            (inLeft(i) ? left : right).AddView(items[i]);
        var columns = Layout(Orientation.Horizontal, GravityFlags.Top);
        columns.Tag = new Java.Lang.String("layout.columns");
        columns.AddView(left, new LinearLayout.LayoutParams(0, -2, leftWeight) { MarginEnd = D(24) });
        columns.AddView(right, new LinearLayout.LayoutParams(0, -2, 1 - leftWeight));
        Add(columns, 0);
    }
    View Rule()
    {
        var v = new View(Ui);
        v.SetBackgroundColor(C(Dark ? "344039" : "E4E9E0"));
        v.LayoutParameters = new LinearLayout.LayoutParams(-1, D(1)) { TopMargin = D(12), BottomMargin = D(12) };
        return v;
    }
    string Name(string? value) => string.IsNullOrWhiteSpace(value) ? "同学" : Host.Vm.HideIdentity ? value[..1] + "同学" : value;
    string Number(string value) => Host.Vm.HideIdentity ? "••••••••" : value;
    string AccountName => Model.IsDemo ? Name("演示同学") : Model.ActiveAccount is { } a ? Name(a.Session.Name) : "连接账户";
    List<Course> DayCourses(DateOnly date) => Model.Courses.Where(c => c.Day == CourseTime.DayKey(date)).OrderBy(c => c.Start).ToList();
    string Metadata(Course c, bool showMissingClassroom = false) => string.Join("   ·   ", new[] { c.Classroom ?? (showMissingClassroom ? "教室暂未提供" : null), c.Teacher }.Where(s => !string.IsNullOrWhiteSpace(s)));
    void RenderContent()
    {
        var y = scroll!.ScrollY;
        body!.RemoveAllViews();
        scroll!.SetBackgroundColor(C(Dark ? "111A16" : "F6F7F2"));
        if (refresh is not null)
            refresh.Enabled = Route is null && Host.Vm.Page < 2 && Model.IsConnected;
        if (Route == "detail" && CurrentDetail is { } d)
        {
            RenderDetail(Model.Courses.FirstOrDefault(c => c.Id == d.Id && c.Day == d.Day) ?? d);
            return;
        }
        if (Route is not null)
        {
            if (Route == "settings") SettingsPage();
            else InformationPage();
            return;
        }
        if (!Landscape) Add(Text(new[] { "果壳签到", "课表", "账户" }[Host.Vm.Page], 32, true), 22);
        if (Host.Vm.Page == 2 && !string.IsNullOrWhiteSpace(Model.Message))
            Add(Text(Model.Message!, 12, color: Secondary), 12);
        if (Host.Vm.Page == 2)
            Account();
        else if (Host.Vm.Page == 1)
            Schedule();
        else
            Today();
        var targetScroll = scroll;
        targetScroll.Post(() => targetScroll.ScrollTo(0, y));
    }
    void Banner(DateOnly date)
    {
        if (Model.IsDemo)
        {
            var connect = Button("连接账号", () => { Login(); return Task.CompletedTask; });
            connect.SetMinHeight(D(28));
            connect.SetMinimumHeight(D(28));
            connect.SetPadding(D(4), 0, D(4), 0);
            connect.TextSize = 11;
            var banner = Card(Across(Text("✧  演示模式 · 示例课表", 11, color: Green), connect), 10, Pale);
            banner.Radius = D(12);
            Add(banner, 16);
        }
        else if (Model.IsCached(date))
        {
            var syncing = Model.IsLoadingCourses(date);
            var retry = Button(syncing ? "正在同步…" : "重新同步", () => Model.RefreshAsync(date));
            retry.Enabled = !syncing && !Model.IsBusy;
            Add(Card(Column(Text("正在显示缓存课表", 13, true, Green), Text("同步最新课程状态后即可签到。软件在前台时会自动重试，也可以立即重新同步。", 12, color: Secondary), retry), 16, Pale), 20);
        }
    }
    void Welcome() => Add(Card(Column(Icon(Resource.Drawable.ic_book, 40), Text("一堂课，也不匆忙。", 25, true), Text("连接账户，查看当天课程、完成签到，\n让每一次到课都井井有条。", 14, color: Secondary), Button("连接账户", () => { Login(); return Task.CompletedTask; }, true), Button("先体验一下 →", Model.EnterDemoAsync)), 24));
    View Metric(string label, int value)
    {
        var number = Text(value + " 门", 27, true);
        var content = new global::Android.Text.SpannableString(number.Text);
        var unitStart = value.ToString().Length;
        content.SetSpan(new global::Android.Text.Style.RelativeSizeSpan(11f / 27), unitStart, content.Length(), global::Android.Text.SpanTypes.ExclusiveExclusive);
        content.SetSpan(new global::Android.Text.Style.ForegroundColorSpan(Secondary), unitStart, content.Length(), global::Android.Text.SpanTypes.ExclusiveExclusive);
        content.SetSpan(new global::Android.Text.Style.StyleSpan(TypefaceStyle.Normal), unitStart, content.Length(), global::Android.Text.SpanTypes.ExclusiveExclusive);
        number.TextFormatted = content;
        return Column(Text(label, 11, color: Secondary), number);
    }
    View SettingLabel(int icon, string title, string subtitle)
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        var image = new ImageView(Ui);
        image.SetImageResource(icon);
        image.ImageTintList = ColorStateList.ValueOf(Green);
        row.AddView(image, new LinearLayout.LayoutParams(D(22), D(22)) { MarginEnd = D(12) });
        row.AddView(Column(Text(title, 14, true), Text(subtitle, 10, color: Secondary)), new LinearLayout.LayoutParams(0, -2, 1));
        return row;
    }
    void Today()
    {
        var now = DateTimeOffset.Now.ToOffset(CourseTime.ShanghaiOffset);
        var courses = DayCourses(CourseTime.Today());
        Add(Text(now.ToString("M 月 d 日 · dddd", System.Globalization.CultureInfo.GetCultureInfo("zh-CN")), 12, color: Secondary), TwoColumns ? 6 : 12);
        var introduction = Text("今天，从容一点。", Landscape ? 24 : 30, true);
        introduction.SetSingleLine(true);
        AndroidX.Core.Widget.TextViewCompat.SetAutoSizeTextTypeUniformWithConfiguration(introduction, 21, Landscape ? 24 : 30, 1, (int)global::Android.Util.ComplexUnitType.Sp);
        var styled = new global::Android.Text.SpannableString(introduction.Text);
        styled.SetSpan(new global::Android.Text.Style.ForegroundColorSpan(Green), 3, introduction.Text!.Length, global::Android.Text.SpanTypes.ExclusiveExclusive);
        introduction.TextFormatted = styled;
        if (TwoColumns) Add(introduction, 14);
        else Add(Column(introduction, Text(Model.IsConnected ? "课表、签到，都在这里。" : "你的国科大课堂，轻松相伴。", 13, color: Secondary)), 14);
        if (!Model.IsConnected)
        {
            Welcome();
            return;
        }
        var today = CourseTime.Today();
        if (!TwoColumns || !Model.IsDemo) Banner(today);
        var (current, next) = CourseTime.CurrentAndNext(courses, now);
        var featured = current is { Signed: false } ? current : next ?? current ?? courses.LastOrDefault();
        if (featured is not null)
        {
            var sign = Button(featured.Signed ? "✓  已完成签到" : "✓  一键签到", () => Model.SignAsync(featured, Model.Generation), true);
            sign.Enabled = Model.CanSign(featured);
            sign.BackgroundTintList = ColorStateList.ValueOf(C("C9E69C"));
            sign.SetTextColor(C("1F4736"));
            var qr = Button("", () => { Detail(featured); return Task.CompletedTask; });
            qr.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, Resource.Drawable.ic_qr);
            qr.IconTint = ColorStateList.ValueOf(Color.White);
            qr.IconPadding = 0;
            qr.IconSize = D(21);
            qr.CornerRadius = D(13);
            qr.ContentDescription = "课程签到二维码";
            qr.BackgroundTintList = ColorStateList.ValueOf(C("365D49"));
            qr.SetTextColor(Color.White);
            qr.SetWidth(D(49));
            sign.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, Resource.Drawable.ic_check_circle);
            sign.Text = featured.Signed ? "已完成签到" : "一键签到";
            sign.IconSize = D(17);
            sign.IconTint = ColorStateList.ValueOf(C("1F4736"));
            sign.CornerRadius = D(13);
            var p = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
            p.AddView(Text("●  " + (featured.Signed ? "到课已记录" : current?.Id == featured.Id ? "正在上课，专注当下" : "下一堂，准备就绪"), 11, color: C("C9E69C")));
            p.AddView(Text(featured.Name, Landscape ? 22 : 27, true, Color.White), new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(Landscape ? 12 : 22), BottomMargin = D(12) });
            p.AddView(IconLabel(Resource.Drawable.ic_clock, featured.TimeRange, 11, C("C2D1C9")));
            p.AddView(MetadataView(featured, 11, C("C2D1C9")), new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(9) });
            var actions = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
            actions.AddView(sign, new LinearLayout.LayoutParams(0, D(48), 1) { MarginEnd = D(10) });
            actions.AddView(qr, new LinearLayout.LayoutParams(D(49), D(48)));
            p.AddView(actions, new LinearLayout.LayoutParams(-1, -2) { TopMargin = D(TwoColumns ? 12 : Landscape ? 16 : 24) });
            var backdrop = new FrameLayout(Ui);
            backdrop.SetClipToPadding(false);
            backdrop.SetClipChildren(false);
            var watermark = Icon(Resource.Drawable.ic_leaf, 150, Color.White);
            watermark.Alpha = .04f;
            watermark.Rotation = -25;
            watermark.TranslationX = D(60);
            watermark.TranslationY = D(-6);
            backdrop.AddView(watermark, new FrameLayout.LayoutParams(D(150), D(150), GravityFlags.Right | GravityFlags.CenterVertical));
            backdrop.AddView(p);
            var hero = Card(backdrop, TwoColumns ? 16 : 23, C("1F4736"));
            hero.Radius = D(25);
            hero.ClipToOutline = true;
            Add(hero, 26);
        }
        else
        {
            var syncing = Model.IsLoadingCourses(today);
            var empty = Column(Icon(Resource.Drawable.ic_sun_horizon, 35), Text(syncing ? "正在整理你的课表" : "留一点时间给自己", 20, true), Text(syncing ? "正在与学校同步课程…" : "今天暂无课程，下拉刷新即可重新同步。", 12, color: Secondary));
            empty.SetGravity(GravityFlags.CenterHorizontal);
            foreach (var label in new[] { empty.GetChildAt(1), empty.GetChildAt(2) }.OfType<TextView>()) label.Gravity = GravityFlags.Center;
            Add(Card(empty, 30), 26);
        }
        if (TwoColumns && Model.IsDemo) Banner(today);
        var summaryStart = body!.ChildCount;
        var count = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        count.AddView(Metric("今日课程", courses.Count), new LinearLayout.LayoutParams(0, -2, 1));
        var divider = new View(Ui);
        divider.SetBackgroundColor(Pale);
        count.AddView(divider, new LinearLayout.LayoutParams(D(1), D(30)) { MarginEnd = D(22) });
        count.AddView(Metric("已签到", courses.Count(c => c.Signed)), new LinearLayout.LayoutParams(0, -2, 1));
        var ring = new AttendanceProgressView(Ui, courses.Count(c => c.Signed), courses.Count, Green, Pale)
        {
            ContentDescription = $"已完成 {courses.Count(c => c.Signed)} 门签到",
            LayoutParameters = new LinearLayout.LayoutParams(D(42), D(42))
        };
        var progressRow = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        progressRow.AddView(count, new LinearLayout.LayoutParams(0, -2, 1) { MarginEnd = D(12) });
        progressRow.AddView(ring, new LinearLayout.LayoutParams(D(42), D(42)));
        var progressCard = Card(progressRow, 0);
        progressRow.SetPadding(D(22), D(18), D(21), D(18));
        Add(progressCard, 26);
        Add(Across(Text("今日安排", 20, true), Tap(Text("查看课表 ↗", 12, color: Green), () => { Host.SelectPage(1); return Task.CompletedTask; }, "查看课表")), 16);
        if (courses.Count > 0) Timeline(courses);
        var syncHint = Model.IsDemo ? "示例数据，仅供体验" : Model.LastUpdated(today) is { } sync
            ? $"{(Model.IsCached(today) ? "缓存更新于" : "同步于")} {sync.ToOffset(CourseTime.ShanghaiOffset):HH:mm} · 下拉刷新" : null;
        if (syncHint is not null)
        {
            var syncLabel = Text(syncHint, 10, color: Secondary);
            syncLabel.Gravity = GravityFlags.Center;
            Add(syncLabel, 20);
        }
        CourseNotice(today);
        var footer = Text("专注课堂，把琐事交给果壳", 11, color: Secondary);
        footer.Gravity = GravityFlags.Center;
        Add(footer, 0);
        ArrangeColumns(i => i < summaryStart);
    }
    View SyncIndicator()
    {
        var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        var progress = new Google.Android.Material.ProgressIndicator.CircularProgressIndicator(Ui) { Indeterminate = true, IndicatorSize = D(20), TrackThickness = D(2) };
        progress.SetIndicatorColor(Green);
        row.AddView(progress, new LinearLayout.LayoutParams(D(28), D(28)) { MarginEnd = D(12) });
        row.AddView(Text("正在同步课程…", 14, color: Secondary));
        row.SetGravity(GravityFlags.Center);
        row.SetPadding(0, D(40), 0, D(40));
        return row;
    }
    void CourseNotice(DateOnly date)
    {
        if (!Model.IsCached(date) && !Model.IsLoadingCourses(date) && Model.CourseNotice(date) is { Length: > 0 } notice)
            Add(Text(notice, 12, color: Secondary), 20);
    }
    void Timeline(IReadOnlyList<Course> courses)
    {
        if (courses.Count == 0)
        {
            Add(Card(Column(Icon(Resource.Drawable.ic_coffee, 35), Text("这一天没有课程", 20, true), Text("切换日期，或下拉刷新学校课表。", 12, color: Secondary))));
            return;
        }
        var list = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
        foreach (var c in courses)
        {
            var row = Layout(Orientation.Horizontal, GravityFlags.Top);
            row.AddView(Column(Text(CourseTime.Display(c.BeginTime), 12, true), Text(CourseTime.Display(c.EndTime), 10, color: Secondary)), new LinearLayout.LayoutParams(D(39), -2) { MarginEnd = D(14), TopMargin = D(20) });
            var info = Column(Text(c.Name, 15, true), MetadataView(c));
            var inside = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
            var bar = new View(Ui);
            bar.SetBackgroundColor(c.Signed ? Pale : Green);
            inside.AddView(bar, new LinearLayout.LayoutParams(D(3), D(38)) { MarginEnd = D(12) });
            inside.AddView(info, new LinearLayout.LayoutParams(0, -2, 1));
            var badge = StatusBadge(c.Signed);
            var chevron = Icon(Resource.Drawable.ic_chevron_right, 9, Secondary);
            var status = Column(badge, chevron);
            status.SetGravity(GravityFlags.End);
            ((LinearLayout.LayoutParams)badge.LayoutParameters!).BottomMargin = D(11);
            ((LinearLayout.LayoutParams)chevron.LayoutParameters!).Gravity = GravityFlags.End;
            inside.AddView(status, new LinearLayout.LayoutParams(-2, -2) { MarginStart = D(4) });
            var card = Card(inside, 0);
            inside.SetPadding(D(13), D(17), D(13), D(17));
            Tap(card, () => { Detail(c); return Task.CompletedTask; }, c.Name + (c.Signed ? "，已签到" : "，未签到") + "，课程详情");
            row.AddView(card, new LinearLayout.LayoutParams(0, -2, 1));
            list.AddView(row, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(16) });
        }
        Add(list, 8);
    }
    void Schedule()
    {
        var date = Model.SelectedDate;
        var month = Text(date.ToString("yyyy 年 M 月"), 16, true);
        month.Gravity = GravityFlags.Center;
        var nav = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        nav.AddView(WeekButton(false), new LinearLayout.LayoutParams(D(44), D(44)));
        nav.AddView(month, new LinearLayout.LayoutParams(0, -2, 1));
        nav.AddView(WeekButton(true), new LinearLayout.LayoutParams(D(44), D(44)));
        var week = new LinearLayout(Ui) { Orientation = Orientation.Horizontal };
        var monday = date.AddDays(-(((int)date.DayOfWeek + 6) % 7));
        for (var i = 0; i < 7; i++)
        {
            var day = monday.AddDays(i);
            var active = day == date;
            var label = Column(Text(new[] { "一", "二", "三", "四", "五", "六", "日" }[i], 10, color: active ? Color.White : Secondary), Text(day.Day.ToString(), 18, true, active ? Color.White : Ink), Text(active ? "•" : " ", 10, color: C("C9E69C")));
            for (var j = 0; j < label.ChildCount; j++)
                ((TextView)label.GetChildAt(j)!).Gravity = GravityFlags.Center;
            var card = Card(label, 8, active ? C("1F4736") : Color.Transparent);
            card.Radius = D(17);
            Tap(card, () => Model.SelectDateAsync(day), day.ToString("M月d日"));
            week.AddView(card, new LinearLayout.LayoutParams(0, -2, 1) { MarginEnd = D(i == 6 ? 0 : 5) });
        }
        var dateControls = Column(nav, week);
        ((LinearLayout.LayoutParams)nav.LayoutParameters!).BottomMargin = D(24);
        dateControls.ContentDescription = "schedule.dateControls";
        dateControls.SetBackgroundColor(C(Dark ? "111A16" : "F6F7F2"));
        dateControls.SetPadding(0, D(12), 0, D(12));
        dateControls.TranslationZ = D(2);
        Add(dateControls, 24);
        var courseStart = body!.ChildCount;
        var courses = DayCourses(date);
        var syncing = Model.IsLoadingCourses(date);
        Add(Across(Text(date.ToString("M 月 d 日"), 20, true), Text($"{courses.Count} 门课程", 12, color: Secondary)), 16);
        if (!Model.IsConnected)
        {
            Add(Column(Icon(Resource.Drawable.ic_calendar, 35), Text("连接你的课堂", 20, true), Text("登录后即可查询学校课表。", 12, color: Secondary), Button("连接账户", () => { Login(); return Task.CompletedTask; }, true)));
            ArrangeColumns(i => i < courseStart);
            return;
        }
        if (Model.IsDemo)
            Add(Text("✧ 演示课表 · 所有日期均为示例数据", 12, color: Green), 24);
        else Banner(date);
        if (syncing && courses.Count == 0) Add(SyncIndicator());
        if (courses.Count > 0 || !syncing) Timeline(courses);
        CourseNotice(date);
        if (date != CourseTime.Today())
            Add(Button("回到今天", () => Model.SelectDateAsync(CourseTime.Today())));
        ArrangeColumns(i => i < courseStart);
        MaterialButton WeekButton(bool next)
        {
            var button = Button("", () => Model.SelectDateAsync(date.AddDays(next ? 7 : -7)));
            button.ContentDescription = next ? "下一周" : "上一周";
            button.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, next ? Resource.Drawable.ic_chevron_right : Resource.Drawable.ic_chevron_left);
            button.IconSize = D(16);
            button.IconPadding = 0;
            button.IconTint = ColorStateList.ValueOf(Green);
            button.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent);
            button.SetPadding(D(14), 0, D(14), 0);
            return button;
        }
    }
    void Account()
    {
        var a = Model.ActiveAccount;
        var avatar = new ImageView(Ui);
        avatar.SetImageResource(Resource.Drawable.ic_person_circle);
        avatar.ImageTintList = ColorStateList.ValueOf(Green);
        var identity = Column(Text(AccountName, 22, true), Text(Model.IsConnected ? "学号 " + Number(Model.IsDemo ? "2026123456" : a!.Id) : "点击登录，连接账户", 12, color: Secondary), Text(Model.IsDemo ? "演示模式 · 点击连接账户" : "中国科学院大学 · 轻新课堂", 11, color: Secondary));
        Tap(identity, () => { if (Model.IsDemo || a is null) Login(); else if (a.RequiresLogin || a.Session.Name is null) Login(a); return Task.CompletedTask; }, "账户信息");
        var eye = Button(Host.Vm.HideIdentity ? "显示" : "隐藏", () => { Host.Vm.HideIdentity = !Host.Vm.HideIdentity; Render(); return Task.CompletedTask; });
        eye.ContentDescription = "隐藏或显示姓名与学号";
        var identityRow = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
        identityRow.AddView(avatar, new LinearLayout.LayoutParams(D(53), D(53)) { MarginEnd = D(17) });
        identityRow.AddView(identity, new LinearLayout.LayoutParams(0, -2, 1));
        eye.Text = "";
        eye.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, Host.Vm.HideIdentity ? Resource.Drawable.ic_eye_off : Resource.Drawable.ic_eye);
        eye.IconSize = D(18);
        eye.SetPadding(D(13), 0, D(13), 0);
        eye.IconTint = ColorStateList.ValueOf(Secondary);
        eye.IconPadding = 0;
        eye.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent);
        identityRow.AddView(eye, new LinearLayout.LayoutParams(D(44), D(44)));
        Add(Card(identityRow));
        var menuStart = body!.ChildCount;
        var menu = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
        Menu(Resource.Drawable.ic_people, "切换与管理账户", () => { ManageAccounts(); return Task.CompletedTask; });
        Menu(Resource.Drawable.ic_settings, "设置", () => Navigate("settings"));
        Menu(Resource.Drawable.ic_history, "本机签到记录", () => Navigate("records"));
        AddMenuCard();
        menu = new LinearLayout(Ui) { Orientation = Orientation.Vertical };
        Menu(Resource.Drawable.ic_code, "项目源码与致谢", () => Navigate("source"));
        Menu(Resource.Drawable.ic_document, "免责声明", () => Navigate("disclaimer"));
        AddMenuCard();

        var menuEnd = body.ChildCount;
        Add(Column(Text("安心留在本机", 13, true, Green), Text("各账户的会话和可选密码由 Android Keystore 保护；课程缓存、签到记录与课堂偏好分别保留在此设备，移除账户时仅清除该账户的数据。App 不请求定位权限。", 12, color: Secondary)), 16);
        if (Model.IsConnected)
        {
            var exitAccount = Button(Model.IsDemo ? "退出演示模式" : "退出并移除此账户", () => { ConfirmRemove(Model.IsDemo ? null : a); return Task.CompletedTask; });
            exitAccount.SetTextColor(Model.IsDemo ? Secondary : new Color(Google.Android.Material.Color.MaterialColors.GetColor(exitAccount, Resource.Attribute.colorError)));
            exitAccount.BackgroundTintList = ColorStateList.ValueOf(Surface);
            exitAccount.Gravity = GravityFlags.Center;
            Add(exitAccount, 16);
        }
        var footer = Text("果壳签到 · 0.1.0\n开源许可 · AGPL-3.0", 10, color: Secondary);
        footer.Gravity = GravityFlags.Center;
        Add(footer, 0);
        ArrangeColumns(i => i < menuStart || i >= menuEnd);
        void AddMenuCard()
        {
            var menuCard = Card(menu, 0);
            menu.SetPadding(D(18), 0, D(18), 0);
            Add(menuCard, 16);
        }
        void Menu(int icon, string title, Func<Task> action)
        {
            if (menu.ChildCount > 0)
                {
                var rule = Rule();
                rule.LayoutParameters = new LinearLayout.LayoutParams(-1, D(1)) { MarginStart = D(35) };
                menu.AddView(rule);
            }
            var label = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
            label.AddView(Icon(icon), new LinearLayout.LayoutParams(D(22), D(22)) { MarginEnd = D(13) });
            label.AddView(Text(title, 14));
            var row = Across(label, Icon(Resource.Drawable.ic_chevron_right, 11, Secondary));
            row.SetPadding(0, D(20), 0, D(20));
            Tap(row, action, title);
            menu.AddView(row);
        }
    }
    void SettingsPage()
    {
        var appearance = Tap(Across(Text("主题", 14), Text(Host.Vm.Theme == "system" ? "跟随系统  ›" : Host.Vm.Theme == "dark" ? "深色  ›" : "浅色  ›", 13, color: Secondary)), () => { Appearance(); return Task.CompletedTask; }, "主题");
        appearance.SetMinimumHeight(D(48));
        Add(Card(Column(Text("外观", 20, true), appearance)));
        var prefs = Model.Preferences;
        var remind = new MaterialSwitch(Ui) { Checked = prefs.RemindersEnabled, Enabled = Model.IsConnected && Model.CanChangeAccount, ContentDescription = "课程提醒" };
        var auto = new MaterialSwitch(Ui) { Checked = prefs.AutoSignEnabled, Enabled = Model.IsConnected && Model.CanChangeAccount, ContentDescription = "前台自动签到" };
        remind.CheckedChange += async (_, _) => await Host.Run(() => Model.SetPreferencesAsync(auto.Checked, remind.Checked));
        auto.CheckedChange += async (_, _) => await Host.Run(() => Model.SetPreferencesAsync(auto.Checked, remind.Checked));
        Add(Card(Column(Text("课堂偏好", 20, true), Across(SettingLabel(Resource.Drawable.ic_bell, "课程提醒", "已同步课程将在开课前 10 分钟提醒"), remind), Rule(), Across(SettingLabel(Resource.Drawable.ic_check_circle, "前台自动签到", "App 打开时，进入签到时段后尝试一次"), auto), Text("请保持 App 在前台，并以学校返回的签到状态为准。普通提醒可能受系统省电策略影响。", 11, color: Secondary))));
        Add(Card(Column(Text("通知", 20, true), Button("系统通知设置", OpenNotificationSettings))));
        ArrangeColumns(i => i != 1);
    }
    Task OpenNotificationSettings()
    {
        Intent intent;
        if (OperatingSystem.IsAndroidVersionAtLeast(26))
        {
            intent = new Intent(global::Android.Provider.Settings.ActionAppNotificationSettings);
            intent.PutExtra(global::Android.Provider.Settings.ExtraAppPackage, Host.PackageName);
        }
        else
        {
            intent = new Intent(global::Android.Provider.Settings.ActionApplicationDetailsSettings);
            intent.SetData(global::Android.Net.Uri.Parse("package:" + Host.PackageName));
        }
        Host.StartActivity(intent);
        return Task.CompletedTask;
    }
    Task Navigate(string route)
    {
        Route = route;
        Render();
        scroll?.ScrollTo(0, 0);
        return Task.CompletedTask;
    }
    public bool Back()
    {
        if (Route is null)
            return false;
        Route = null;
        CurrentDetail = null;
        Host.DetailCourseId = null;
        Host.DetailCourseDay = null;
        Render();
        return true;
    }
    public void Detail(Course course)
    {
        CurrentDetail = course;
        Host.DetailCourseId = course.Id;
        Host.DetailCourseDay = course.Day;
        _ = Navigate("detail");
    }
    public void ToolbarAction(int id)
    {
        if (id == 10)
            QuickAccounts();
        else if (id == 11)
            _ = Host.Run(PickDate);
        else
            _ = Host.Run(() => Model.RefreshAsync(Host.Vm.Page == 1 ? Model.SelectedDate : CourseTime.Today()));
    }
}
