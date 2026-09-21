namespace UCASSignIn.Core;

public sealed record ReminderChanges(IReadOnlyList<Reminder> Current, IReadOnlyList<Reminder> Cancel, IReadOnlyList<Reminder> Schedule)
{
    public static ReminderChanges Create(IEnumerable<Reminder> previous, IEnumerable<Reminder> requested, DateTimeOffset now, bool restore = false)
    {
        var old = previous.DistinctBy(r => r.Id).ToDictionary(r => r.Id);
        var next = requested.Where(r => r.At > now).DistinctBy(r => r.Id).ToDictionary(r => r.Id);
        return new(next.Values.ToArray(),
            old.Values.Where(r => restore || !next.TryGetValue(r.Id, out var replacement) || replacement != r).ToArray(),
            next.Values.Where(r => restore || !old.TryGetValue(r.Id, out var existing) || existing != r).ToArray());
    }
}
