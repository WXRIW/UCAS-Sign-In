using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.OS;
using Android.Views;
using Android.Widget;
using AndroidX.AppCompat.App;
using AndroidX.Core.View;
using Google.Android.Material.AppBar;
using Google.Android.Material.BottomNavigation;
using Google.Android.Material.Navigation;
using Google.Android.Material.NavigationRail;
using Google.Android.Material.Color;
using UCASSignIn.Core;
using UCASSignIn.Android.Services;
using UCASSignIn.Android.ViewModels;
using UCASSignIn.Android.Fragments;
using OperationCanceledException = System.OperationCanceledException;
namespace UCASSignIn.Android;

[Activity(Label = "果壳签到", Theme = "@style/AppTheme", MainLauncher = true, Exported = true, LaunchMode = LaunchMode.SingleTop, WindowSoftInputMode = SoftInput.AdjustResize)]
public sealed class MainActivity : AppCompatActivity
{
    public MainViewModel Vm { get; private set; } = null!;
    public AccountCoordinator Model => Vm.Model;
    public Context UiContext { get; private set; } = null!;
    public bool DialogOpen => ActiveDialog?.IsShowing == true
        || SupportFragmentManager.Fragments.OfType<AndroidX.Fragment.App.DialogFragment>().Any(f => f.Dialog?.IsShowing == true);
    CancellationTokenSource? foreground;
    TaskCompletionSource<bool>? permission;
    MainPageFragment? page;
    int hostId = 0x554341;
    NavigationBarView? navigation;
    InsetsListener? insetsListener;
    NavigationListener? navigationListener;
    BackCallback? backCallback;
    DialogLifecycle? dialogLifecycle;
    Guid renderedGeneration;
    bool ready;
    public string? DetailCourseId
    {
        get; set;
    }
    public string? DetailCourseDay
    {
        get; set;
    }
    public global::AndroidX.AppCompat.App.AlertDialog? ActiveDialog
    {
        get; set;
    }
    protected override void AttachBaseContext(Context? newBase)
    {
        var theme = newBase!.GetSharedPreferences("appearance", FileCreationMode.Private)!.GetString("theme", "system")!;
        Delegate.SetLocalNightMode(NightMode(theme));
        base.AttachBaseContext(newBase);
    }
    protected override void OnCreate(Bundle? savedInstanceState)
    {
        Vm = MainViewModel.Get(this);
        if (savedInstanceState is not null)
            Vm.Page = savedInstanceState.GetInt("page", Vm.Page);
        base.OnCreate(savedInstanceState);
        UiContext = this;
        renderedGeneration = Model.Generation;
        AndroidReminderScheduler.PermissionRequest = RequestNotificationPermission;
        var root = new LinearLayout(UiContext) { Orientation = Orientation.Vertical };
        root.SetBackgroundColor(global::Android.Graphics.Color.Transparent);
        backCallback = new BackCallback(this);
        OnBackPressedDispatcher.AddCallback(this, backCallback);
        dialogLifecycle = new DialogLifecycle(this);
        SupportFragmentManager.RegisterFragmentLifecycleCallbacks(dialogLifecycle, false);
        var row = new LinearLayout(UiContext) { Orientation = Orientation.Horizontal };
        root.AddView(row, new LinearLayout.LayoutParams(-1, 0, 1));
        bool wide = Resources!.Configuration!.ScreenWidthDp >= 600;
        navigation = wide ? new NavigationRailView(UiContext, null, 0, Resource.Style.AppNavigationRail) : new BottomNavigationView(UiContext, null, 0, Resource.Style.AppBottomNavigation);
        if (navigation is NavigationRailView rail)
        {
            rail.SetMinimumWidth(Dp(80));
            rail.MenuGravity = (int)GravityFlags.Center;
        }
        navigation.ItemIconSize = Dp(24);
        navigation.ItemActiveIndicatorWidth = Dp(56);
        navigation.ItemActiveIndicatorHeight = Dp(28);
        navigation.ItemTextAppearanceActive = Resource.Style.NavigationLabel;
        navigation.ItemTextAppearanceInactive = Resource.Style.NavigationLabel;
        navigation.LabelVisibilityMode = Google.Android.Material.BottomNavigation.LabelVisibilityMode.LabelVisibilityLabeled;
        if (navigation is BottomNavigationView bottomBar) bottomBar.ItemHorizontalTranslationEnabled = false;
        navigation.Menu!.Add(0, 1, 0, "今日")!.SetIcon(Resource.Drawable.ic_today);
        navigation.Menu.Add(0, 2, 1, "课表")!.SetIcon(Resource.Drawable.ic_calendar);
        navigation.Menu.Add(0, 3, 2, "账户")!.SetIcon(Resource.Drawable.ic_account);
        navigation.SelectedItemId = Vm.Page + 1;
        navigationListener = new NavigationListener(id => { Vm.Page = id - 1; ShowPage(); });
        navigation.SetOnItemSelectedListener(navigationListener);
        if (wide)
            row.AddView(navigation, new LinearLayout.LayoutParams(Dp(80), -1)
            {
                MarginStart = Dp(8), MarginEnd = Dp(8), TopMargin = Dp(8), BottomMargin = Dp(8)
            });
        var host = new FrameLayout(UiContext) { Id = hostId };
        row.AddView(host, new LinearLayout.LayoutParams(0, -1, 1));
        if (!wide)
            root.AddView(navigation, new LinearLayout.LayoutParams(-1, -2));
        WindowCompat.SetDecorFitsSystemWindows(Window!, false);
        var isDark = (Resources.Configuration.UiMode & global::Android.Content.Res.UiMode.NightMask) == global::Android.Content.Res.UiMode.NightYes;
        var navigationSurface = global::Android.Graphics.Color.ParseColor(isDark ? "#1D2922" : "#FFFFFF");
        navigation.SetBackgroundColor(navigationSurface);
        if (wide)
        {
            var railBackground = new global::Android.Graphics.Drawables.GradientDrawable();
            railBackground.SetColor(navigationSurface);
            railBackground.SetCornerRadius(Dp(24));
            navigation.Background = railBackground;
            navigation.ClipToOutline = true;
        }
        var colors = new global::Android.Content.Res.ColorStateList(
            [ [ global::Android.Resource.Attribute.StateChecked ], [] ],
            [ MaterialColors.GetColor(UiContext, Resource.Attribute.colorPrimary, "primary"), global::Android.Graphics.Color.ParseColor(isDark ? "#A0ADA4" : "#7B8780").ToArgb() ]);
        navigation.ItemIconTintList = navigation.ItemTextColor = colors;
        var windowRoot = new FrameLayout(UiContext);
        windowRoot.SetBackgroundColor(global::Android.Graphics.Color.ParseColor(isDark ? "#111A16" : "#F6F7F2"));
        var navigationInset = new View(UiContext);
        navigationInset.SetBackgroundColor(wide ? global::Android.Graphics.Color.ParseColor(isDark ? "#111A16" : "#F6F7F2") : navigationSurface);
        windowRoot.AddView(navigationInset, new FrameLayout.LayoutParams(-1, 0, GravityFlags.Bottom));
        windowRoot.AddView(root, new FrameLayout.LayoutParams(-1, -1));
        var barsController = WindowCompat.GetInsetsController(Window!, Window!.DecorView!);
        barsController!.AppearanceLightStatusBars = !isDark;
        barsController!.AppearanceLightNavigationBars = !isDark;
        if (OperatingSystem.IsAndroidVersionAtLeast(29))
            Window.NavigationBarContrastEnforced = false;
        insetsListener = new InsetsListener(insets =>
        {
            var bars = insets.GetInsets(WindowInsetsCompat.Type.SystemBars() | WindowInsetsCompat.Type.DisplayCutout());
            var keyboard = insets.GetInsets(WindowInsetsCompat.Type.Ime());
            var gestures = insets.GetInsets(WindowInsetsCompat.Type.MandatorySystemGestures());
            var bottom = Math.Max(bars!.Bottom, gestures!.Bottom);
            root.SetPadding(bars.Left, bars.Top, bars.Right, Math.Max(bottom, keyboard!.Bottom));
            navigationInset.LayoutParameters = new FrameLayout.LayoutParams(-1, bottom, GravityFlags.Bottom);
        });
        ViewCompat.SetOnApplyWindowInsetsListener(windowRoot, insetsListener);
        ViewCompat.SetOnApplyWindowInsetsListener(navigation, null);
        navigation.SetPadding(0, 0, 0, 0);
        SetContentView(windowRoot);
        Window.DecorView!.Post(ClearNavigationBarBackground);
        ViewCompat.RequestApplyInsets(windowRoot);
        Model.Changed += Changed;
        ShowPage();
        _ = Run(async () =>
        {
            await Model.InitializeAsync();
            if (savedInstanceState?.GetBoolean("demoState", false) == true && !Model.IsDemo)
                await Model.EnterDemoAsync();
            if (Intent?.GetBooleanExtra("demo", false) == true)
            {
                Intent.RemoveExtra("demo");
                await Model.EnterDemoAsync();
            }
            ready = true;
            // The retained view model already owns this date after rotation/theme changes.
            // Restoring the same selection must not act like an explicit date selection.
            if (savedInstanceState?.GetString("selectedDate") is { } selected && CourseTime.Date(selected) != Model.SelectedDate)
                await Model.SelectDateAsync(CourseTime.Date(selected));
            if (savedInstanceState is not null && savedInstanceState.GetString("accountState") == (Model.IsDemo ? "demo" : Model.ActiveAccount?.Id))
            {
                for (var index = 0; index < 3; index++)
                {
                    Vm.Routes[index] = savedInstanceState.GetString("route" + index);
                    var json = savedInstanceState.GetString("detail" + index);
                    Vm.Details[index] = json is null ? null : System.Text.Json.JsonSerializer.Deserialize<Course>(json);
                }
                page?.Render();
            }
            await OpenNotification(Intent);
            if (page is not null)
                await page.CheckForUpdates(false);
        });
    }
    public int Dp(int value) => (int)(value * Resources!.DisplayMetrics!.Density + .5f);
    static int NightMode(string theme) => theme == "dark" ? AppCompatDelegate.ModeNightYes : theme == "light" ? AppCompatDelegate.ModeNightNo : AppCompatDelegate.ModeNightFollowSystem;
    public void SetAppearance(string theme)
    {
        Vm.Theme = theme;
        Delegate.SetLocalNightMode(NightMode(theme));
    }
    void ClearNavigationBarBackground()
    {
        if (Window?.DecorView?.FindViewById(global::Android.Resource.Id.NavigationBarBackground) is not { } layer) return;
        layer.SetBackgroundColor(global::Android.Graphics.Color.Transparent);
        layer.Alpha = 0;
    }
    public override void OnWindowFocusChanged(bool hasFocus)
    {
        base.OnWindowFocusChanged(hasFocus);
        if (hasFocus) Window?.DecorView?.Post(ClearNavigationBarBackground);
    }
    void Changed()
    {
        RunOnUiThread(() =>
        {
            if (renderedGeneration != Model.Generation)
            {
                if (!Model.IsBusy)
                    ActiveDialog?.Dismiss();
                Array.Clear(Vm.Routes);
                Array.Clear(Vm.Details);
                DetailCourseId = null;
                DetailCourseDay = null;
                renderedGeneration = Model.Generation;
            }
            page?.Render();
        });
    }
    void ShowPage()
    {
        page = SupportFragmentManager.FindFragmentByTag("page") as MainPageFragment;
        if (page is null)
        {
            page = new MainPageFragment();
            SupportFragmentManager.BeginTransaction().Replace(hostId, page, "page").CommitNow();
        }
        page.Render();
    }
    public void SelectPage(int index)
    {
        Vm.Page = index;
        navigation!.SelectedItemId = index + 1;
        ShowPage();
    }
    public (MaterialToolbar Toolbar, LinearLayout Brand) CreatePageToolbar(int tab, string? title)
    {
        var toolbar = new MaterialToolbar(UiContext) { Title = title ?? "" };
        toolbar.SetBackgroundColor(new(MaterialColors.GetColor(UiContext, Resource.Attribute.colorSurface, "surface")));
        toolbar.NavigationClick += (_, _) => page?.Back();
        toolbar.MenuItemClick += (_, e) => page?.ToolbarAction(e.Item!.ItemId);
        var brand = new LinearLayout(UiContext) { Orientation = Orientation.Horizontal, Visibility = title is null && tab == 0 ? ViewStates.Visible : ViewStates.Gone };
        brand.SetGravity(GravityFlags.CenterVertical);
        var mark = new ImageView(UiContext);
        mark.SetImageResource(Resource.Drawable.brand_mark);
        mark.ImageTintList = global::Android.Content.Res.ColorStateList.ValueOf(new(MaterialColors.GetColor(UiContext, Resource.Attribute.colorPrimary, "primary")));
        brand.AddView(mark, new LinearLayout.LayoutParams(Dp(24), Dp(24)) { MarginEnd = Dp(6) });
        var brandText = new TextView(UiContext) { Text = "U C A S", TextSize = 10 };
        brandText.SetTextColor(global::Android.Graphics.Color.ParseColor("#7B8780"));
        brand.AddView(brandText);
        toolbar.AddView(brand);
        if (title is not null)
        {
            var back = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(UiContext, Resource.Drawable.ic_back)!;
            back.SetTint(MaterialColors.GetColor(UiContext, Resource.Attribute.colorPrimary, "primary"));
            toolbar.NavigationIcon = back;
            toolbar.NavigationContentDescription = "返回";
            return (toolbar, brand);
        }
        if (tab == 0)
        {
            var icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(UiContext, Resource.Drawable.ic_account)!;
            icon.SetTint(MaterialColors.GetColor(UiContext, Resource.Attribute.colorPrimary, "primary"));
            toolbar.Menu!.Add(0, 10, 0, "切换账户")!.SetIcon(icon)!.SetShowAsAction(ShowAsAction.Always);
        }
        if (tab == 1)
            toolbar.Menu!.Add(0, 11, 0, "选择日期")!.SetIcon(Resource.Drawable.ic_calendar)!.SetShowAsAction(ShowAsAction.Always);
        return (toolbar, brand);
    }
    public void SetBackEnabled(bool enabled)
    {
        if (backCallback is not null) backCallback.Enabled = enabled;
    }
    sealed class DialogLifecycle(MainActivity host) : AndroidX.Fragment.App.FragmentManager.FragmentLifecycleCallbacks
    {
        public override void OnFragmentStarted(AndroidX.Fragment.App.FragmentManager fm, AndroidX.Fragment.App.Fragment f)
        {
            // MaterialDatePicker's application listeners are not saved with the fragment.
            // Rebind them to the current Activity after recreation as well as first show.
            if (f is Google.Android.Material.DatePicker.MaterialDatePicker picker)
            {
                picker.ClearOnPositiveButtonClickListeners();
                picker.AddOnPositiveButtonClickListener(new DateSelected(host));
            }
            if (OperatingSystem.IsAndroidVersionAtLeast(34) && f is AndroidX.Fragment.App.DialogFragment { Dialog: { } dialog } fragment)
                PredictiveDialogBack.Attach(dialog, () => fragment.Cancelable);
        }
    }
    sealed class DateSelected(MainActivity host) : Java.Lang.Object, Google.Android.Material.DatePicker.IMaterialPickerOnPositiveButtonClickListener
    {
        public void OnPositiveButtonClick(Java.Lang.Object? selection)
        {
            if (selection is Java.Lang.Long value)
                _ = host.Run(() => host.Model.SelectDateAsync(DateOnly.FromDateTime(DateTimeOffset.FromUnixTimeMilliseconds(value.LongValue()).UtcDateTime)));
        }
    }
    public View AccountMenuAnchor => page!.ActiveToolbar;
    sealed class BackCallback(MainActivity host) : AndroidX.Activity.OnBackPressedCallback(false)
    {
        public override void HandleOnBackStarted(AndroidX.Activity.BackEventCompat backEvent) => host.page?.BeginBackPreview(backEvent.SwipeEdge);
        public override void HandleOnBackProgressed(AndroidX.Activity.BackEventCompat backEvent) => host.page?.ProgressBackPreview(backEvent.Progress);
        public override void HandleOnBackCancelled() => host.page?.CancelBackPreview();
        public override void HandleOnBackPressed()
        {
            host.page?.CompleteBackPreview();
        }
    }
    public async Task Run(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Model.SetMessage(e.Message); }
    }
    protected override void OnResume()
    {
        base.OnResume();
        Model.IsForeground = true;
        Window?.DecorView?.Post(() => page?.ShowPendingSignInError());
        foreground?.Cancel();
        foreground = new();
        _ = Ticks(foreground.Token);
    }
    async Task Ticks(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (ready && !DialogOpen)
                    await Run(Model.TickAsync);
                await Task.Delay(15000, ct);
            }
        }
        catch (OperationCanceledException) { }
    }
    protected override void OnPause()
    {
        Model.IsForeground = false;
        foreground?.Cancel();
        base.OnPause();
    }
    protected override void OnSaveInstanceState(Bundle outState)
    {
        outState.PutString("selectedDate", CourseTime.DayKey(Model.SelectedDate));
        outState.PutInt("page", Vm.Page);
        outState.PutBoolean("demoState", Model.IsDemo);
        outState.PutString("accountState", Model.IsDemo ? "demo" : Model.ActiveAccount?.Id);
        for (var index = 0; index < 3; index++)
        {
            outState.PutString("route" + index, Vm.Routes[index]);
            outState.PutString("detail" + index, Vm.Details[index] is { } course ? System.Text.Json.JsonSerializer.Serialize(course) : null);
        }
        base.OnSaveInstanceState(outState);
    }
    protected override void OnDestroy()
    {
        Model.Changed -= Changed;
        foreground?.Cancel();
        foreground?.Dispose();
        ActiveDialog?.Dismiss();
        if (dialogLifecycle is not null) SupportFragmentManager.UnregisterFragmentLifecycleCallbacks(dialogLifecycle);
        permission?.TrySetResult(false);
        AndroidReminderScheduler.PermissionRequest = null;
        base.OnDestroy();
    }
    protected override void OnNewIntent(Intent? intent)
    {
        base.OnNewIntent(intent);
        Intent = intent;
        _ = Run(() => OpenNotification(intent));
    }
    async Task OpenNotification(Intent? intent)
    {
        if (intent?.Action != "cn.ucas.signin.OPEN_COURSE" || intent.GetStringExtra("account") != Model.ActiveAccount?.Id || Model.IsDemo)
            return;
        var day = intent.GetStringExtra("day");
        if (day is null)
            return;
        await Model.SelectDateAsync(CourseTime.Date(day));
        Vm.Page = 1;
        navigation!.SelectedItemId = 2;
        ShowPage();
        var course = Model.Courses.FirstOrDefault(c => c.Id == intent.GetStringExtra("course") && c.Day == day);
        if (course is not null)
            page?.Detail(course);
        intent.SetAction("");
    }
    Task<bool> RequestNotificationPermission()
    {
        if (!OperatingSystem.IsAndroidVersionAtLeast(33) || CheckSelfPermission(global::Android.Manifest.Permission.PostNotifications) == Permission.Granted)
            return Task.FromResult(AndroidX.Core.App.NotificationManagerCompat.From(this)!.AreNotificationsEnabled());
        permission = new(TaskCreationOptions.RunContinuationsAsynchronously);
        RequestPermissions([global::Android.Manifest.Permission.PostNotifications], 23);
        return permission.Task;
    }
    public override void OnRequestPermissionsResult(int requestCode, string[] permissions, Permission[] grantResults)
    {
        base.OnRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == 23)
        {
            permission?.TrySetResult(grantResults.Length > 0 && grantResults[0] == Permission.Granted);
            permission = null;
        }
    }
    sealed class NavigationListener(Action<int> select) : Java.Lang.Object, NavigationBarView.IOnItemSelectedListener
    {
        public bool OnNavigationItemSelected(IMenuItem item)
        {
            select(item.ItemId);
            return true;
        }
    }
    sealed class InsetsListener(Action<WindowInsetsCompat> apply) : Java.Lang.Object, IOnApplyWindowInsetsListener
    {
        public WindowInsetsCompat? OnApplyWindowInsets(View? view, WindowInsetsCompat? insets)
        {
            if (insets is not null)
                apply(insets);
            return insets;
        }
    }
}
