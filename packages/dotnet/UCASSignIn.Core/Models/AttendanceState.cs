namespace UCASSignIn.Core;

public static class CachePolicy
{
    public static readonly TimeSpan ReferenceLifetime = TimeSpan.FromDays(7);
    public static bool Fresh(DateTimeOffset? updated, DateTimeOffset now, TimeSpan? lifetime = null)
        => updated is { } at && now >= at && now - at < (lifetime ?? ReferenceLifetime);
}

public enum AttendanceStatus { Unknown, Unsigned, Signed }
public enum AttendanceSource { Cache, Daily, Detail, Submission }

// Weekly/cache data never enters this reducer. Request revisions reject stale reads first.
public sealed record AttendanceEvidence(AttendanceStatus Status, AttendanceSource Source, DateTimeOffset ObservedAt,
    DateTimeOffset? LastSuccessfulSignAt = null, bool PendingVerification = false,
    AttendanceSource? NegativeSource = null)
{
    public AttendanceEvidence Observe(AttendanceStatus status, AttendanceSource source, DateTimeOffset now)
    {
        if (source == AttendanceSource.Submission)
            return new(AttendanceStatus.Signed, source, now, now, true);
        if (status == AttendanceStatus.Unknown)
            return Status == AttendanceStatus.Signed ? this with { NegativeSource = null }
                : new(status, source, now, LastSuccessfulSignAt);
        if (status == AttendanceStatus.Signed || Status != AttendanceStatus.Signed)
            return new(status, source, now, LastSuccessfulSignAt);
        // Keep the first conflict. A later independent read from the same source
        // can confirm the correction; no timers or elapsed-time assumptions.
        if (NegativeSource == source)
            return new(AttendanceStatus.Unsigned, source, now, LastSuccessfulSignAt);
        return this with { PendingVerification = true, NegativeSource = source };
    }
}

public sealed record AttendanceEvidenceCache(int Version, string AccountId,
    Dictionary<string, AttendanceEvidence> States, HashSet<string> InvalidatedCourses)
{
    public const int CurrentVersion = 1;
}

public interface IAttendanceStateStore
{
    Task<AttendanceEvidenceCache?> LoadAttendanceStateAsync(string accountId, CancellationToken ct = default);
    Task SaveAttendanceStateAsync(AttendanceEvidenceCache state, CancellationToken ct = default);
}
