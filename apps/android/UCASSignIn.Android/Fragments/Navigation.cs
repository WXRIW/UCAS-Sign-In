using Android.Animation;
using Android.Views;
using AndroidX.Transitions;
using Google.Android.Material.Transition;
using Android.Widget;
using AndroidX.SwipeRefreshLayout.Widget;
using Google.Android.Material.AppBar;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    sealed record Scene(string Key, int Tab, string? Route, LinearLayout Root, MaterialToolbar Toolbar, LinearLayout Brand, ScrollView Scroll, LinearLayout Body, SwipeRefreshLayout Refresh);
    readonly Dictionary<string, Scene> scenes = [];
    FrameLayout? sceneHost;
    Scene? activeScene, previewScene;
    Guid sceneGeneration;
    bool scenePrivacy, backPreview;
    ITransitionSeekController? backSeek;
    bool AnimationsEnabled => !OperatingSystem.IsAndroidVersionAtLeast(26) || ValueAnimator.AreAnimatorsEnabled();
    static int Depth(string? route) => route is null ? 0 : 1;
    string SceneKey(string? route) => Host.Vm.Page + ":" + (route ?? "root");
    public MaterialToolbar ActiveToolbar => activeScene!.Toolbar;

    Scene GetScene(string? route)
    {
        var scene = scenes.GetValueOrDefault(SceneKey(route));
        // A predictive back animation can still own the outgoing root in its overlay
        // after committing the route. EndTransitions does not release that seek animation.
        // Leave its view alone so its remaining callbacks cannot change the reopened page.
        return scene is null || (scene.Root.Parent is not null && scene.Root.Parent != sceneHost)
            ? CreateScene(route)
            : scene;
    }

    Scene CreateScene(string? route)
    {
        var scroller = new ScrollView(Ui) { FillViewport = true };
        var content = Column();
        content.SetPadding(D(16), D(Landscape || route is null ? 8 : 24), D(16), D(28));
        var centered = Layout(global::Android.Widget.Orientation.Horizontal, GravityFlags.CenterHorizontal);
        var width = Resources!.Configuration!.ScreenWidthDp;
        if (width >= 600) width -= 96;
        var availableWidth = sceneHost?.Width > 0 ? sceneHost.Width : D(width);
        centered.AddView(content, new LinearLayout.LayoutParams(Math.Min(availableWidth, D(ContentWidthLimit)), -2));
        scroller.AddView(centered);
        var pull = new SwipeRefreshLayout(Ui);
        pull.SetBackgroundColor(C(Dark ? "111A16" : "F6F7F2"));
        pull.SetColorSchemeColors(Green);
        pull.AddView(scroller);
        pull.Refresh += async (_, _) =>
        {
            try { await Host.Run(() => Model.RefreshAsync(Host.Vm.Page == 0 ? UCASSignIn.Core.CourseTime.Today() : Model.SelectedDate)); }
            finally { pull.Refreshing = false; }
        };
        var root = new LinearLayout(Ui) { Orientation = global::Android.Widget.Orientation.Vertical };
        root.SetBackgroundColor(C(Dark ? "111A16" : "F6F7F2"));
        var (toolbar, brand) = Host.CreatePageToolbar(Host.Vm.Page, PageTitle(route));
        root.AddView(toolbar, new LinearLayout.LayoutParams(-1, D(48)));
        root.AddView(pull, new LinearLayout.LayoutParams(-1, 0, 1));
        var scene = new Scene(SceneKey(route), Host.Vm.Page, route, root, toolbar, brand, scroller, content, pull);
        scroller.ScrollChange += (_, _) =>
        {
            if (!Landscape && scene.Tab == 1 && scene.Route is null)
                for (var i = 0; i < content.ChildCount; i++)
                {
                    var header = content.GetChildAt(i)!;
                    if (header.ContentDescription == "schedule.dateControls")
                        header.TranslationY = Math.Max(0, scroller.ScrollY - header.Top);
                }
            if (activeScene == scene && !backPreview && scene.Route is null)
                UpdateScrolledTitle(scene);
        };
        scenes[scene.Key] = scene;
        return scene;
    }
    void UseScene(Scene scene)
    {
        activeScene = scene;
        body = scene.Body;
        scroll = scene.Scroll;
        refresh = scene.Refresh;
    }
    public void Render()
    {
        if (sceneHost is null || !IsAdded) return;
        if (sceneGeneration != Model.Generation || scenePrivacy != Host.Vm.HideIdentity)
        {
            ClearScenes();
            sceneGeneration = Model.Generation;
            scenePrivacy = Host.Vm.HideIdentity;
        }
        if (backPreview) return;
        qrCancellation?.Cancel();
        var previous = activeScene;
        var next = GetScene(Route);
        UseScene(next);
        RenderContent();
        UpdatePageToolbar();
        if (previous != next) PresentScene(previous, next);
        else if (next.Root.Parent is null) sceneHost.AddView(next.Root, new FrameLayout.LayoutParams(-1, -1));
        ShowPendingSignInError();
    }
    void ClearScenes()
    {
        if (sceneHost is not null) TransitionManager.EndTransitions(sceneHost);
        sceneHost?.RemoveAllViews();
        scenes.Clear();
        activeScene = previewScene = null;
        backSeek = null;
        backPreview = false;
    }
    Transition PageTransition(Scene from, Scene to, bool forward, bool predictive = false)
    {
        Transition transition = new MaterialSharedAxis(MaterialSharedAxis.X, forward);
        if (predictive && !transition.IsSeekingSupported) transition = new Fade();
        from.Root.TransitionGroup = true;
        to.Root.TransitionGroup = true;
        transition.AddTarget(from.Root);
        transition.AddTarget(to.Root);
        return transition;
    }
    void PresentScene(Scene? previous, Scene next)
    {
        TransitionManager.EndTransitions(sceneHost!);
        if (previous is not null && previous.Tab == next.Tab && AnimationsEnabled)
        {
            var forward = Depth(next.Route) >= Depth(previous.Route);
            TransitionManager.BeginDelayedTransition(sceneHost!, PageTransition(previous, next, forward));
        }
        sceneHost!.RemoveAllViews();
        sceneHost.AddView(next.Root, new FrameLayout.LayoutParams(-1, -1));
    }
    public void BeginBackPreview(int edge)
    {
        if (Route is null || activeScene is null || Host.DialogOpen || backPreview || !AnimationsEnabled) return;
        var current = activeScene;
        var route = Route;
        string? parent = null;
        TransitionManager.EndTransitions(sceneHost!);
        qrCancellation?.Cancel();
        var preview = GetScene(parent);
        Route = parent;
        UseScene(preview);
        RenderContent();
        UpdateScrolledTitle(preview);
        Route = route;
        UseScene(current);
        backSeek = TransitionManager.ControlDelayedTransition(sceneHost!, PageTransition(current, preview, false, true));
        sceneHost!.RemoveAllViews();
        sceneHost.AddView(preview.Root, new FrameLayout.LayoutParams(-1, -1));
        previewScene = preview;
        backPreview = true;
    }
    public void ProgressBackPreview(float progress)
    {
        if (backSeek?.IsReady == true) backSeek.CurrentFraction = Math.Clamp(progress, 0, 1);
    }
    public void CancelBackPreview()
    {
        if (!backPreview || activeScene is null) return;
        var original = activeScene;
        void Restore()
        {
            backPreview = false;
            backSeek = null;
            previewScene = null;
            if (sceneHost is null || !IsAdded) return;
            sceneHost.RemoveAllViews();
            sceneHost.AddView(original.Root, new FrameLayout.LayoutParams(-1, -1));
            UseScene(original);
            Render();
        }
        if (backSeek is not null) backSeek.AnimateToStart(new Java.Lang.Runnable(Restore));
        else Restore();
    }
    public void CompleteBackPreview()
    {
        if (!backPreview || previewScene is null) { Back(); return; }
        Route = previewScene.Route;
        CurrentDetail = null;
        Host.DetailCourseId = Host.DetailCourseDay = null;
        UseScene(previewScene);
        backSeek?.AnimateToEnd();
        backSeek = null;
        previewScene = null;
        backPreview = false;
        UpdatePageToolbar();
    }
    void UpdatePageToolbar()
    {
        Host.SetBackEnabled(Route is not null);
        if (activeScene is { } scene) UpdateScrolledTitle(scene);
    }
    void UpdateScrolledTitle(Scene scene)
    {
        if (scene.Route is not null) return;
        var collapsed = Landscape || scene.Scroll.ScrollY > D(48);
        scene.Toolbar.Title = collapsed ? new[] { "果壳签到", "课表", "账户" }[scene.Tab] : "";
        scene.Brand.Visibility = !collapsed && scene.Tab == 0 ? ViewStates.Visible : ViewStates.Gone;
    }
    string? PageTitle(string? route) => route switch
    {
        "detail" => "课程签到",
        "settings" => "设置",
        "records" => Model.IsDemo ? "演示签到记录" : "本机签到记录",
        "source" => "项目源码与致谢",
        "disclaimer" => "免责声明",
        _ => null
    };
}
