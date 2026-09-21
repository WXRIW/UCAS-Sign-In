using Android.App;
using Android.Content;
using Android.OS;
using AndroidX.Core.App;
using UCASSignIn.Core;
using System.Security.Cryptography;
using System.Text;
namespace UCASSignIn.Android.Services;

public sealed class AndroidReminderScheduler(Context context, string storageName = "reminders.json") : IReminderScheduler
{
    const string Channel = "courses";
    static readonly SemaphoreSlim updates = new(1);
    string Path => System.IO.Path.Combine(context.FilesDir!.AbsolutePath, storageName);
    public static Func<Task<bool>>? PermissionRequest
    {
        get; set;
    }
    public Task<bool> RequestPermissionAsync() => PermissionRequest?.Invoke() ?? Task.FromResult(NotificationManagerCompat.From(context)!.AreNotificationsEnabled());
    static int RequestId(string id) => BitConverter.ToInt32(SHA256.HashData(Encoding.UTF8.GetBytes(id)), 0) & int.MaxValue;
    PendingIntent Alarm(Reminder r) => PendingIntent.GetBroadcast(context, RequestId(r.Id),
        new Intent(context, typeof(CourseReminderReceiver)).SetAction("cn.ucas.signin.REMINDER").SetData(global::Android.Net.Uri.Parse("ucas-signin://reminder/" + Uri.EscapeDataString(r.Id))).PutExtra("id", r.Id),
        PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable)!;
    public Task ReplaceAsync(IReadOnlyList<Reminder> reminders) => UpdateAsync(reminders.ToArray(), false);
    Task UpdateAsync(IReadOnlyList<Reminder>? requested, bool restore) => Task.Run(async () =>
    {
        await updates.WaitAsync().ConfigureAwait(false);
        try
        {
            var old = AtomicFile.ReadJson<List<Reminder>>(Path) ?? [];
            var pendingPath = Path + ".pending";
            var pending = AtomicFile.ReadJson<List<Reminder>>(pendingPath);
            var changes = ReminderChanges.Create(old.Concat(pending ?? []), requested ?? old, DateTimeOffset.UtcNow, restore || pending is not null);
            if (changes.Cancel.Count == 0 && changes.Schedule.Count == 0)
            {
                if (pending is not null) File.Delete(pendingPath);
                return;
            }
            var alarms = (AlarmManager)context.GetSystemService(Context.AlarmService)!;
            var manager = (NotificationManager)context.GetSystemService(Context.NotificationService)!;
            if (OperatingSystem.IsAndroidVersionAtLeast(26))
                manager.CreateNotificationChannel(new NotificationChannel(Channel, "课程提醒", NotificationImportance.Default));
            // Remember incomplete OS updates so a failure/restart retries all registrations.
            AtomicFile.WriteJson(pendingPath, old.Concat(pending ?? []).DistinctBy(r => r.Id).ToArray());
            AtomicFile.WriteJson(Path, changes.Current);
            foreach (var r in changes.Cancel)
            {
                using var pendingAlarm = Alarm(r);
                alarms.Cancel(pendingAlarm);
                manager.Cancel(RequestId(r.Id));
            }
            foreach (var r in changes.Schedule)
            {
                using var pendingAlarm = Alarm(r);
                alarms.SetAndAllowWhileIdle(AlarmType.RtcWakeup, r.At.ToUnixTimeMilliseconds(), pendingAlarm);
            }
            File.Delete(pendingPath);
        }
        finally { updates.Release(); }
    });
    public void Deliver(string id)
    {
        var r = (AtomicFile.ReadJson<List<Reminder>>(Path) ?? []).FirstOrDefault(r => r.Id == id);
        if (r is null || r.At > DateTimeOffset.UtcNow.AddSeconds(2) || DateTimeOffset.UtcNow > r.At.AddMinutes(20))
            return;
        if (!NotificationManagerCompat.From(context)!.AreNotificationsEnabled())
            return;
        var intent = new Intent(context, typeof(MainActivity)).SetAction("cn.ucas.signin.OPEN_COURSE")
            .PutExtra("account", r.AccountId).PutExtra("course", r.CourseId).PutExtra("day", r.Day)
            .SetFlags(ActivityFlags.ClearTop | ActivityFlags.SingleTop);
        var open = PendingIntent.GetActivity(context, RequestId(r.Id), intent, PendingIntentFlags.UpdateCurrent | PendingIntentFlags.Immutable);
        var notification = new NotificationCompat.Builder(context, Channel).SetSmallIcon(Resource.Drawable.ic_notification)!
            .SetContentTitle("即将上课 · " + r.Title)!.SetContentText(r.Body)!.SetContentIntent(open)!.SetAutoCancel(true)!.Build();
        NotificationManagerCompat.From(context)!.Notify(RequestId(r.Id), notification);
    }
    public Task RestoreAsync() => UpdateAsync(null, true);
}
[BroadcastReceiver(Enabled = true, Exported = false)]
public sealed class CourseReminderReceiver : BroadcastReceiver
{
    public override void OnReceive(Context? context, Intent? intent)
    {
        if (context is not null && intent?.GetStringExtra("id") is { } id)
            new AndroidReminderScheduler(context).Deliver(id);
    }
}
[BroadcastReceiver(Enabled = true, Exported = true)]
[IntentFilter([Intent.ActionBootCompleted, Intent.ActionMyPackageReplaced])]
public sealed class RestoreRemindersReceiver : BroadcastReceiver
{
    public override void OnReceive(Context? context, Intent? intent)
    {
        if (context is null || intent?.Action is not (Intent.ActionBootCompleted or Intent.ActionMyPackageReplaced))
            return;
        var pending = GoAsync();
        _ = Restore();
        async Task Restore()
        {
            try
            {
                await new AndroidReminderScheduler(context).RestoreAsync();
                await AndroidAutoSignService.RestoreIfEnabledAsync(context);
            }
            finally { pending?.Finish(); }
        }
    }
}
