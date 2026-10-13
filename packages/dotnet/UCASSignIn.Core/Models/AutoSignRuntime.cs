using System.Text.Json;

namespace UCASSignIn.Core;

public sealed record AutoSignNotificationSnapshot(Guid Generation, string? AccountId,
    IReadOnlyDictionary<string, int> EventCounts)
{
    public static AutoSignNotificationSnapshot Capture(Guid generation, string? accountId,
        IEnumerable<AutoSignExecution> executions) => new(generation, accountId,
            executions.ToDictionary(x => x.Key, x => x.Events.Count));
}

public sealed record AutoSignResultNotification(string Key, string CourseName, string Message, bool Succeeded);

public static class AutoSignRuntime
{
    public static bool IsResult(AutoSignEvent entry) => entry.Kind == AutoSignEventKind.Result
        && entry.Stage is AutoSignStage.Signed or AutoSignStage.NeedsAttention
        || entry.Kind == AutoSignEventKind.Missed && entry.Stage == AutoSignStage.Missed;

    public static IReadOnlyList<AutoSignResultNotification> Results(AutoSignNotificationSnapshot before,
        Guid generation, string? accountId, IEnumerable<AutoSignExecution> executions,
        Func<AutoSignExecution, AutoSignNotification> notification)
    {
        if (before.Generation != generation || before.AccountId != accountId || accountId is null) return [];
        var results = new List<(DateTimeOffset At, AutoSignResultNotification Value)>();
        foreach (var execution in executions)
        {
            if (!execution.Key.StartsWith(accountId + "|", StringComparison.Ordinal)) continue;
            var count = before.EventCounts.GetValueOrDefault(execution.Key);
            if (execution.Events.Count <= count) continue;
            var entry = execution.Events.Skip(count).LastOrDefault(IsResult);
            if (entry is null) continue;
            var mode = notification(execution);
            var succeeded = entry.Stage == AutoSignStage.Signed;
            if (mode == AutoSignNotification.None || succeeded && mode != AutoSignNotification.All) continue;
            results.Add((entry.At, new(execution.Key, execution.CourseName ?? "课程签到", entry.Message, succeeded)));
        }
        return results.OrderBy(x => x.At).ThenBy(x => x.Value.Key, StringComparer.Ordinal).Select(x => x.Value).ToArray();
    }

    public static string WakeState(AccountCoordinator model, DateTimeOffset? nextWakeAt)
    {
        var preferences = model.Preferences;
        return JsonSerializer.Serialize(new
        {
            model.Generation, AccountId = model.ActiveAccount?.Id, model.IsDemo, model.IsBusy,
            model.IsRecovering, model.IsRefreshing, model.NeedsAutoSignService, model.AutoSignRuntimeStatus,
            // Device projections of the same school deadline can differ by a few ticks.
            // This fingerprint only signals changes; the actual wait keeps full precision.
            NextWakeAt = nextWakeAt is { } wake
                ? (long?)((wake.UtcTicks + TimeSpan.TicksPerSecond / 2) / TimeSpan.TicksPerSecond) : null,
            Running = preferences.AutoSignIsRunning,
            preferences.AutoSignPausedUntil, preferences.AutoSignRule,
            Courses = preferences.Courses.Where(x => x.Value.AutoSign != PreferenceOverride.Inherit
                || x.Value.SignInDisabled || x.Value.AutoSignRule?.HasValues == true || x.Value.AutoSignEnabledSince is not null)
                .OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => new
            { x.Key, x.Value.AutoSign, x.Value.SignInDisabled, x.Value.AutoSignRule, x.Value.AutoSignEnabledSince }),
            Occurrences = preferences.AutoSignOccurrences.OrderBy(x => x.Key, StringComparer.Ordinal),
            Plans = model.AutoSignPlans.Select(x => new
            { x.Key, x.PlannedAt, x.NextAt, x.Deadline, x.Stage, x.IsParticipating, x.Policy, x.Course.Start, x.Course.End }),
            Results = model.AutoSignHistory.Select(x => new
            {
                x.Key, Count = x.Events.Count(IsResult), Last = x.Events.LastOrDefault(IsResult)
            }).OrderBy(x => x.Key, StringComparer.Ordinal)
        });
    }
}

public sealed class AutoSignWakeSignal<T>(T state)
{
    readonly object gate = new();
    T current = state;
    TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public T State { get { lock (gate) return current; } }

    public void Update(T value)
    {
        TaskCompletionSource previous;
        lock (gate)
        {
            if (EqualityComparer<T>.Default.Equals(current, value)) return;
            current = value;
            previous = changed;
            changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        previous.TrySetResult();
    }

    public async Task WaitAsync(T expected, TimeSpan delay, CancellationToken cancellationToken,
        Func<TimeSpan, CancellationToken, Task>? wait = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Task pending;
        lock (gate)
        {
            if (!EqualityComparer<T>.Default.Equals(current, expected)) return;
            pending = changed.Task;
        }
        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var elapsed = (wait ?? Task.Delay)(delay, timer.Token);
        try
        {
            var completed = await Task.WhenAny(pending, elapsed);
            if (completed == elapsed) await elapsed;
            cancellationToken.ThrowIfCancellationRequested();
        }
        finally { timer.Cancel(); }
    }
}
