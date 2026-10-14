namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly Dictionary<string, (DateTimeOffset At, AutoSignResultNotification Result)> pendingAutoSignResults = [];
    internal long AutoSignResultRevision { get; private set; }

    /// <summary>Consumes new persisted execution results from this account generation.
    /// Display-history cleanup never removes a pending result. Loading old history does not enqueue it.</summary>
    public IReadOnlyList<AutoSignResultNotification> ConsumeAutoSignResults()
    {
        var results = pendingAutoSignResults.Values.OrderBy(x => x.At)
            .ThenBy(x => x.Result.Key, StringComparer.Ordinal).Select(x => x.Result).ToArray();
        pendingAutoSignResults.Clear();
        return results;
    }

    void QueueAutoSignResult(AutoSignExecution execution, AutoSignEvent entry)
    {
        if (!AutoSignRuntime.IsResult(entry) || IsDemo || ActiveAccount is not { } account
            || !execution.Key.StartsWith(account.Id + "|", StringComparison.Ordinal)) return;
        // Match the existing last-result-per-course behavior, including suppression when a later
        // successful result replaces a queued problem under the Problems-only preference.
        pendingAutoSignResults.Remove(execution.Key);
        AutoSignResultRevision++;
        var plan = AutoSignPlans.FirstOrDefault(x => x.Key == execution.Key);
        var mode = plan?.Policy.Notification
            ?? Preferences.AutoSignOccurrences.GetValueOrDefault(execution.Key)?.Policy?.Notification
            ?? execution.NotificationMode ?? Preferences.AutoSignRule.Notification;
        var succeeded = entry.Stage == AutoSignStage.Signed;
        if (mode == AutoSignNotification.None || succeeded && mode != AutoSignNotification.All) return;
        pendingAutoSignResults[execution.Key] = (entry.At, new(execution.Key,
            execution.CourseName ?? plan?.Course.Name ?? "课程签到", entry.Message, succeeded));
    }
}
