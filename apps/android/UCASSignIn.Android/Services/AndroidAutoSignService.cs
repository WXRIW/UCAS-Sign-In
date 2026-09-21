using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.OS;
using AndroidX.Core.App;
using UCASSignIn.Android.ViewModels;
using UCASSignIn.Core;

namespace UCASSignIn.Android.Services;

[Service(Name = "cn.ucas.signin.AutoSignService", Enabled = true, Exported = false,
    ForegroundServiceType = ForegroundService.TypeSpecialUse)]
public sealed class AndroidAutoSignService : Service
{
    const string StatusChannel = "automatic-attendance";
    const string ResultChannel = "automatic-attendance-results";
    const int StatusNotificationId = 0x554341;
    const int ResultNotificationId = 0x554342;
    static int running;
    CancellationTokenSource? lifetime;

    public static void Sync(Context context, AccountCoordinator model)
    {
        if (!model.IsDemo && model.ActiveAccount is not null && model.NeedsAutoSignService
            && NotificationManagerCompat.From(context)!.AreNotificationsEnabled())
        {
            if (Volatile.Read(ref running) == 0)
                Start(context);
        }
        else
            context.StopService(new Intent(context, typeof(AndroidAutoSignService)));
    }

    public static void Start(Context context)
    {
        var intent = new Intent(context, typeof(AndroidAutoSignService));
        if (OperatingSystem.IsAndroidVersionAtLeast(26))
            context.StartForegroundService(intent);
        else
            context.StartService(intent);
    }

    public static async Task RestoreIfEnabledAsync(Context context)
    {
        try
        {
            var path = Path.Combine(context.FilesDir!.AbsolutePath, "accounts.dat");
            var vault = await new AndroidAccountStore(path).LoadAsync();
            if (vault.Accounts.FirstOrDefault(account => account.Id == vault.ActiveAccountId)?.Preferences is { } preferences
                && NotificationManagerCompat.From(context)!.AreNotificationsEnabled()
                && (preferences.AutoSignEnabled || preferences.Courses.Any(x => !x.Value.SignInDisabled && x.Value.AutoSign == PreferenceOverride.Enabled)))
                Start(context);
        }
        catch
        {
            // Account-store errors are shown when the user opens the app. A boot
            // receiver must not replace or discard the encrypted source file.
        }
    }

    public override void OnCreate()
    {
        base.OnCreate();
        Interlocked.Exchange(ref running, 1);
        CreateChannels();
        StartForeground(StatusNotificationId, StatusNotification("正在准备自动签到…"));
    }

    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        if (lifetime is null || lifetime.IsCancellationRequested)
        {
            lifetime?.Dispose();
            lifetime = new();
            _ = RunAsync(lifetime.Token);
        }
        return StartCommandResult.Sticky;
    }

    async Task RunAsync(CancellationToken cancellationToken)
    {
        var model = MainViewModel.Get(this).Model;
        try
        {
            await model.InitializeAsync();
            while (!cancellationToken.IsCancellationRequested)
            {
                if (model.IsDemo || model.ActiveAccount is null || !model.NeedsAutoSignService)
                {
                    StopSelf();
                    return;
                }

                var before = model.Records.FirstOrDefault();
                var beforeError = model.SignInError?.Id;
                await model.TickAsync(allowBackground: true);
                if (model.Records.FirstOrDefault() is { } result && !ReferenceEquals(result, before))
                    NotifyResult(result.CourseName, result.Message, result.Succeeded);
                else if (model.SignInError is { } error && error.Id != beforeError)
                    NotifyResult("自动签到", error.Message, false);

                var status = model.ActiveAccount?.RequiresLogin == true
                    ? "登录已过期，请打开果壳签到重新验证"
                    : "后台自动签到运行中";
                NotificationManagerCompat.From(this)!.Notify(StatusNotificationId, StatusNotification(status));
                await Task.Delay(NextDelay(model), cancellationToken);
            }
        }
        catch (System.OperationCanceledException) { }
        catch (Exception error)
        {
            NotifyResult("自动签到已暂停", error.Message, false);
            StopSelf();
        }
    }

    static TimeSpan NextDelay(AccountCoordinator model)
    {
        var now = DateTimeOffset.UtcNow;
        var today = CourseTime.DayKey(CourseTime.Today());
        var courses = model.Courses.Where(course => course.Day == today && !course.Signed
            && model.EffectiveAutoSign(model.PreferenceId(course))
            && course.Start is not null && course.End is not null).ToList();
        if (courses.Any(course => now >= course.Start!.Value.AddMinutes(-30) && now < course.End!.Value.AddMinutes(5)))
            return TimeSpan.FromSeconds(30);
        var next = courses.Select(course => course.Start!.Value.AddMinutes(-30))
            .Where(start => start > now).DefaultIfEmpty().Min();
        if (next == default)
            return TimeSpan.FromMinutes(15);
        var remaining = next - now;
        return remaining < TimeSpan.FromSeconds(30) ? TimeSpan.FromSeconds(30)
            : remaining < TimeSpan.FromMinutes(15) ? remaining : TimeSpan.FromMinutes(15);
    }

    Notification StatusNotification(string text)
    {
        var open = PendingIntent.GetActivity(this, StatusNotificationId,
            new Intent(this, typeof(MainActivity)).SetFlags(ActivityFlags.ClearTop | ActivityFlags.SingleTop),
            PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
        return new NotificationCompat.Builder(this, StatusChannel)
            .SetSmallIcon(Resource.Drawable.ic_notification)!
            .SetContentTitle("果壳签到")!
            .SetContentText(text)!
            .SetContentIntent(open)!
            .SetOngoing(true)!
            .SetOnlyAlertOnce(true)!
            .SetCategory(NotificationCompat.CategoryService)!
            .Build()!;
    }

    void NotifyResult(string title, string message, bool succeeded)
    {
        var open = PendingIntent.GetActivity(this, ResultNotificationId,
            new Intent(this, typeof(MainActivity)).SetFlags(ActivityFlags.ClearTop | ActivityFlags.SingleTop),
            PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
        var notification = new NotificationCompat.Builder(this, ResultChannel)
            .SetSmallIcon(Resource.Drawable.ic_notification)!
            .SetContentTitle((succeeded ? "自动签到成功 · " : "自动签到未完成 · ") + title)!
            .SetContentText(message)!
            .SetStyle(new NotificationCompat.BigTextStyle().BigText(message))!
            .SetContentIntent(open)!
            .SetAutoCancel(true)!
            .Build();
        NotificationManagerCompat.From(this)!.Notify(ResultNotificationId, notification);
    }

    void CreateChannels()
    {
        if (!OperatingSystem.IsAndroidVersionAtLeast(26)) return;
        var manager = (NotificationManager)GetSystemService(NotificationService)!;
        manager.CreateNotificationChannel(new NotificationChannel(StatusChannel, "自动签到状态", NotificationImportance.Low)
        {
            Description = "显示后台自动签到正在运行"
        });
        manager.CreateNotificationChannel(new NotificationChannel(ResultChannel, "自动签到结果", NotificationImportance.Default)
        {
            Description = "通知自动签到是否完成"
        });
    }

    public override void OnDestroy()
    {
        Interlocked.Exchange(ref running, 0);
        lifetime?.Cancel();
        lifetime?.Dispose();
        lifetime = null;
        base.OnDestroy();
    }

    public override global::Android.OS.IBinder? OnBind(Intent? intent) => null;
}
