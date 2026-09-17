using System.Security.Cryptography;
using Microsoft.Toolkit.Uwp.Notifications;
using Windows.UI.Notifications;
using UCASSignIn.Core;
namespace UCASSignIn.Windows.Services;

public sealed class WindowsAccountStore(string path) : EncryptedAccountStore(path)
{
    protected override byte[] Protect(byte[] plain) => ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
    protected override byte[] Unprotect(byte[] cipher) => ProtectedData.Unprotect(cipher, null, DataProtectionScope.CurrentUser);
}
public sealed class WindowsReminderScheduler : IReminderScheduler
{
    public Task<bool> RequestPermissionAsync() => Task.FromResult(ToastNotificationManagerCompat.CreateToastNotifier().Setting == NotificationSetting.Enabled);
    public Task ReplaceAsync(IReadOnlyList<Reminder> reminders)
    {
        var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
        foreach (var old in notifier.GetScheduledToastNotifications())
            notifier.RemoveFromSchedule(old);
        ToastNotificationManagerCompat.History.Clear();
        foreach (var r in reminders.Take(64))
        {
            if (r.At <= DateTimeOffset.Now)
                continue;
            var content = new ToastContentBuilder().AddArgument("account", r.AccountId).AddArgument("course", r.CourseId).AddArgument("day", r.Day)
                .AddText("果壳签到 · 课程即将开始").AddText(r.Title).AddText(r.Body).GetToastContent();
            notifier.AddToSchedule(new ScheduledToastNotification(content.GetXml(), r.At));
        }
        return Task.CompletedTask;
    }
}
