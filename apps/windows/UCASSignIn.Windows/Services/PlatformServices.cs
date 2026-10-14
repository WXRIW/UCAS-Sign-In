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
    internal const string NotificationGroup = "reminders";
    public Task<bool> RequestPermissionAsync() => Task.FromResult(ToastNotificationManagerCompat.CreateToastNotifier().Setting == NotificationSetting.Enabled);
    public Task ReplaceAsync(IReadOnlyList<Reminder> reminders)
    {
        var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
        foreach (var old in notifier.GetScheduledToastNotifications())
            // Earlier versions scheduled course reminders without a group.
            if (string.IsNullOrEmpty(old.Group) || old.Group == NotificationGroup)
                notifier.RemoveFromSchedule(old);
        ToastNotificationManagerCompat.History.RemoveGroup(NotificationGroup);
        foreach (var r in reminders.Take(64))
        {
            if (r.At <= DateTimeOffset.Now)
                continue;
            notifier.AddToSchedule(CreateNotification(r));
        }
        return Task.CompletedTask;
    }
    internal static ScheduledToastNotification CreateNotification(Reminder reminder)
    {
        var content = new ToastContentBuilder().AddArgument("account", reminder.AccountId).AddArgument("course", reminder.CourseId).AddArgument("day", reminder.Day)
            .AddText("果壳签到 · 课程即将开始").AddText(reminder.Title).AddText(reminder.Body).GetToastContent();
        return new(content.GetXml(), reminder.At) { Group = NotificationGroup, Tag = Guid.NewGuid().ToString("N")[..16] };
    }
}
internal static class WindowsAutoSignNotifications
{
    internal const string NotificationGroup = "autosign";
    internal static ToastNotification Create(AutoSignResultNotification result, AutoSignExecution? execution, string? accountId)
    {
        var builder = new ToastContentBuilder();
        // The execution key preserves the original account/day/lesson identity,
        // even after the lesson has left the current seven-day plan.
        if (execution is not null && execution.Key == result.Key && accountId is not null)
        {
            var identity = execution.Key.Split('|');
            if (identity.Length == 3 && identity[0] == accountId
                && CourseTime.NormalizeDay(identity[1]) is { } day && !string.IsNullOrWhiteSpace(identity[2])
                && (execution.ClassStartAt is null || CourseTime.DayKey(DateOnly.FromDateTime(
                    execution.ClassStartAt.Value.ToOffset(CourseTime.ShanghaiOffset).DateTime)) == day))
                builder.AddArgument("account", accountId).AddArgument("course", identity[2]).AddArgument("day", day);
        }
        var content = builder.AddText("果壳签到 · 自动签到").AddText(result.CourseName).AddText(result.Message).GetToastContent();
        return new(content.GetXml()) { Group = NotificationGroup, Tag = Guid.NewGuid().ToString("N")[..16] };
    }
}
