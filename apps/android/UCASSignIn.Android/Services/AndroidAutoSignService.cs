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
    AccountCoordinator? observedModel;
    Action? observeState;

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
                && preferences.AutoSignIsRunning)
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
        Action? changed = null;
        var epoch = model.Generation;
        var accountId = model.ActiveAccount?.Id;
        try
        {
            await model.InitializeAsync();
            cancellationToken.ThrowIfCancellationRequested();
            var previous = AutoSignNotificationSnapshot.Capture(model.Generation, model.ActiveAccount?.Id, model.AutoSignHistory);
            var wake = new AutoSignWakeSignal<string>(AutoSignRuntime.WakeState(model, model.NextAutoSignWakeAt));
            changed = () => wake.Update(AutoSignRuntime.WakeState(model, model.NextAutoSignWakeAt));
            observedModel = model;
            observeState = changed;
            model.Changed += changed;
            while (!cancellationToken.IsCancellationRequested)
            {
                if (model.IsDemo || model.ActiveAccount is null || !model.NeedsAutoSignService)
                {
                    StopSelf();
                    return;
                }

                epoch = model.Generation;
                accountId = model.ActiveAccount?.Id;
                var iterationState = wake.State;
                // Account activation loads its existing journal while busy. Establish
                // the new baseline only after that load, so history is never replayed.
                if (model.IsBusy || model.IsRecovering || model.IsRefreshing)
                {
                    await wake.WaitAsync(iterationState, TimeSpan.FromSeconds(30), cancellationToken);
                    continue;
                }
                if (previous.Generation != epoch || previous.AccountId != accountId)
                    previous = AutoSignNotificationSnapshot.Capture(epoch, accountId, model.AutoSignHistory);
                await model.TickAsync(allowBackground: true);
                cancellationToken.ThrowIfCancellationRequested();
                if (epoch != model.Generation || accountId != model.ActiveAccount?.Id) continue;
                var policies = model.AutoSignPlans.ToDictionary(x => x.Key, x => x.Policy.Notification);
                var results = AutoSignRuntime.Results(previous, epoch, accountId, model.AutoSignHistory,
                    item => policies.GetValueOrDefault(item.Key,
                        model.Preferences.AutoSignOccurrences.GetValueOrDefault(item.Key)?.Policy?.Notification
                            ?? item.NotificationMode ?? model.Preferences.AutoSignRule.Notification));
                previous = AutoSignNotificationSnapshot.Capture(epoch, accountId, model.AutoSignHistory);
                foreach (var result in results)
                {
                    if (cancellationToken.IsCancellationRequested || epoch != model.Generation || accountId != model.ActiveAccount?.Id) break;
                    NotifyResult(result.CourseName, result.Message, result.Succeeded);
                }

                var next = model.AutoSignPlans.Where(x => x.IsParticipating
                    && x.Stage is AutoSignStage.Planned or AutoSignStage.Checking or AutoSignStage.Submitting or AutoSignStage.Verifying or AutoSignStage.RetryWaiting)
                    .OrderBy(x => x.NextAt ?? x.PlannedAt).ThenBy(x => x.Key, StringComparer.Ordinal).FirstOrDefault();
                var runtimeStatus = model.AutoSignRuntimeStatus;
                var status = runtimeStatus == "运行中"
                    ? next is null ? runtimeStatus + " · 暂无待执行计划"
                        : $"{runtimeStatus} · 下一项：{next.Course.Name} {(next.NextAt ?? next.PlannedAt).ToOffset(CourseTime.ShanghaiOffset):HH:mm}"
                    : runtimeStatus == "需要登录" ? runtimeStatus + " · 请打开果壳签到重新验证" : runtimeStatus;
                NotificationManagerCompat.From(this)!.Notify(StatusNotificationId, StatusNotification(status));
                // Acknowledge the latest state after this evaluation. Tick's own
                // progress events then do not cause another immediate iteration.
                var expectedState = wake.State;
                await wake.WaitAsync(expectedState, NextDelay(model), cancellationToken);
            }
        }
        catch (System.OperationCanceledException) { }
        catch (Exception error)
        {
            // Infrastructure failures are not course execution results. In
            // particular they must not bypass an occurrence's notification mode.
            if (!cancellationToken.IsCancellationRequested && epoch == model.Generation && accountId == model.ActiveAccount?.Id)
                model.SetMessage("自动签到服务已暂停：" + error.Message);
            StopSelf();
        }
        finally
        {
            if (changed is not null) model.Changed -= changed;
            if (ReferenceEquals(observeState, changed)) { observedModel = null; observeState = null; }
        }
    }

    static TimeSpan NextDelay(AccountCoordinator model)
    {
        var now = DateTimeOffset.UtcNow;
        if (model.NextAutoSignWakeAt is not { } next) return TimeSpan.FromMinutes(15);
        if (next <= now) return TimeSpan.FromSeconds(30);
        var remaining = next - now;
        return remaining < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1)
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
        if (observedModel is { } model && observeState is { } changed) model.Changed -= changed;
        observedModel = null;
        observeState = null;
        lifetime?.Cancel();
        lifetime?.Dispose();
        lifetime = null;
        base.OnDestroy();
    }

    public override global::Android.OS.IBinder? OnBind(Intent? intent) => null;
}
