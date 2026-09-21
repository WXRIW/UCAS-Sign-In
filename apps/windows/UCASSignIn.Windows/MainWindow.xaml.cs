using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Toolkit.Uwp.Notifications;
using QRCoder;
using UCASSignIn.Core;
using UCASSignIn.Windows.ViewModels;
using Windows.System;
using Windows.Storage.Streams;
namespace UCASSignIn.Windows;

public sealed partial class MainWindow : Window
{
    readonly MainViewModel vm = new();
    AccountCoordinator Model => vm.Model;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(15) };
    string section = "today";
    bool dialogOpen, ready, tickRunning, closed;
    ContentDialog? activeDialog;
    Guid renderedGeneration;
    string? notification;
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        Status.CloseButtonClick += (_, _) => Model.SetMessage(null);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "App.ico"));
        Model.Changed += () =>
        {
            if (renderedGeneration != Model.Generation)
            {
                CloseSchedulePickers();
                if (!Model.IsBusy)
                    activeDialog?.Hide();
                paths.Clear();
                route = null;
                detail = null;
                catalogDetail = null;
                qrCancellation?.Cancel();
                renderedGeneration = Model.Generation;
            }
            Render();
            ShowPendingSignInError();
        };
        renderedGeneration = Model.Generation;
        Model.ScheduleProgressChanged += UpdateWeekProgress;
        motionSettings.TextScaleFactorChanged += ScheduleTextScaleChanged;
        Activated += (_, e) =>
        {
            Model.IsForeground = e.WindowActivationState != WindowActivationState.Deactivated;
            if (Model.IsForeground)
            {
                ShowPendingSignInError(); _ = Run(Tick);
                if (section == "courses" && route == "catalog-detail" && catalogDetail is { } course) _ = Run(() => Model.RefreshAttendanceAsync(course.Id));
                else if (section == "courses") _ = Run(() => Model.RefreshCatalogAsync());
            }
        };
        Closed += (_, _) => { closed = true; Model.ScheduleProgressChanged -= UpdateWeekProgress; motionSettings.TextScaleFactorChanged -= ScheduleTextScaleChanged; Model.IsForeground = false; timer.Stop(); qrCancellation?.Cancel(); activeDialog?.Hide(); };
        Root.ActualThemeChanged += (_, _) => Render();
        timer.Tick += async (_, _) => await Run(Tick);
        AddKey(VirtualKey.R, () => Run(RefreshCurrentCoursesAsync));
        AddKey(VirtualKey.Number1, () => Select(0));
        AddKey(VirtualKey.Number2, () => Select(1));
        AddKey(VirtualKey.Number3, () => Select(2));
        AddKey(VirtualKey.Number4, () => Select(3));
        var browserBack = new KeyboardAccelerator { Key = VirtualKey.GoBack };
        browserBack.Invoked += (_, args) => args.Handled = TryMouseBack();
        Root.KeyboardAccelerators.Add(browserBack);
        Root.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(MouseBackReleased), true);
        Root.Loaded += async (_, _) =>
        {
            var scale = Root.XamlRoot.RasterizationScale;
            var work = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
            var width = (int)Math.Min(1120 * scale, work.Width * .9);
            var height = (int)Math.Min(800 * scale, work.Height * .9);
            // AppWindow bounds and the display work area both use physical pixels.
            AppWindow.MoveAndResize(new(work.X + (work.Width - width) / 2,
                work.Y + (work.Height - height) / 2, width, height));
            ApplyTheme();
            Navigation.SelectedItem = Navigation.MenuItems[0];
            await Run(Environment.GetCommandLineArgs().Contains("--demo") ? Model.InitializeDemoAsync : Model.InitializeAsync);
            ready = true;
            timer.Start();
            Render();
            if (notification is not null)
                OpenNotification(notification);
            _ = CheckForUpdates(false);
        };
    }
    async Task Tick()
    {
        if (!ready || tickRunning)
            return;
        tickRunning = true;
        try
        {
            // Desktop automatic attendance keeps running while this window is
            // minimized or another app is active. Closing the app still stops it.
            await Model.TickAsync(allowBackground: true);
        }
        finally { tickRunning = false; }
    }
    void AddKey(VirtualKey key, Func<Task> action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control };
        accelerator.Invoked += async (_, e) => { e.Handled = true; await action(); };
        Root.KeyboardAccelerators.Add(accelerator);
    }
    Task Select(int index)
    {
        Navigation.SelectedItem = Navigation.MenuItems[index];
        return Task.CompletedTask;
    }
    async Task Run(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception e) { Model.SetMessage(e.Message); }
    }
    void NavigationChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        paths[section] = (route, detail, catalogDetail);
        section = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString() ?? "today";
        (route, detail, catalogDetail) = paths.GetValueOrDefault(section);
        qrCancellation?.Cancel();
        if (section == "schedule" && route is null) _ = Run(Model.EnterScheduleAsync);
        if (PageFrame is not null)
            Render();
    }
    void NavigationDisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args)
    {
        // In Minimal mode the pane toggle overlays the content's top-left corner.
        if (ContentHeader is not null)
            ContentHeader.Margin = new(args.DisplayMode == NavigationViewDisplayMode.Minimal ? 48 : 0, 0, 0, 0);
    }
    void ContentSizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (Page is null || ContentHeader is null || Status is null) return;
        var compact = args.NewSize.Width < 600;
        var gutter = compact ? 16 : 32;
        Page.Padding = new(gutter, 8, gutter, 24);
        ContentHeader.Padding = new(gutter, 16, gutter, 16);
        Status.Margin = new(gutter, 0, gutter, 0);
        PageTitle.FontSize = compact ? 24 : 28;
        DatePicker.Width = compact ? 136 : 152;
    }
    void TitleBarBackRequested(TitleBar sender, object args) => GoBack(sender, new RoutedEventArgs());
    void MouseBackReleased(object sender, PointerRoutedEventArgs e)
    {
        if (e.GetCurrentPoint(Root).Properties.PointerUpdateKind != Microsoft.UI.Input.PointerUpdateKind.XButton1Released) return;
        if (TryMouseBack()) e.Handled = true;
    }
    bool TryMouseBack()
    {
        // Listen on the XAML root even when a child handles the pointer event.
        // Like Lyricify Connect, keep dialogs/flyouts modal and leave root-page
        // clicks unhandled. The existing route owns the return animation.
        if (!ready || closed || route is null || dialogOpen || activeDialog is not null || Root.XamlRoot is null) return false;
        if (VisualTreeHelper.GetOpenPopupsForXamlRoot(Root.XamlRoot).Any(p => p.IsOpen)) return false;
        GoBack(this, new RoutedEventArgs());
        return true;
    }
    public async void OpenNotification(string? args)
    {
        notification = args;
        if (!ready || args is null)
            return;
        notification = null;
        await Run(async () =>
        {
            var values = ToastArguments.Parse(args);
            if (!values.Contains("account") || Model.ActiveAccount?.Id != values["account"] || Model.IsDemo)
                return;
            if (values.Contains("day"))
                await Model.SelectDateAsync(CourseTime.Date(values["day"]));
            await Select(1);
            var course = Model.Courses.FirstOrDefault(c => c.Id == values["course"] && c.Day == values["day"]);
            if (course is not null)
                await Detail(course);
        });
    }
}
