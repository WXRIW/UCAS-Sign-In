namespace UCASSignIn.Core;

public enum ScheduleMode { Day, Week }
public sealed record WeeklyScheduleResult(IReadOnlyList<Course> Courses, IReadOnlyList<string> CoveredDays);
public sealed record ScheduleSnapshot(int Version, int IdentityVersion, string AccountId, SchoolSemester Semester,
    List<Course> Courses, DateTimeOffset UpdatedAt, long WriteSequence = 0)
{
    public const int CurrentVersion = 1, CurrentIdentityVersion = 1;
    public bool IsDue(DateTimeOffset now) => Version != CurrentVersion || IdentityVersion != CurrentIdentityVersion
        || now < UpdatedAt || now - UpdatedAt >= TimeSpan.FromDays(7);
}
public sealed record ScheduleRetryTargets(List<string> SemesterIds, List<string> Mondays, List<string>? DirtyMondays = null);
public interface IScheduleStore
{
    Task<IReadOnlyList<ScheduleSnapshot>> LoadSchedulesAsync(string accountId, CancellationToken ct = default);
    Task SaveScheduleAsync(ScheduleSnapshot snapshot, CancellationToken ct = default);
    Task<IReadOnlyList<string>> CachedDaysAsync(string accountId, CancellationToken ct = default);
    Task<ScheduleRetryTargets?> LoadScheduleRetriesAsync(string accountId, CancellationToken ct = default);
    Task SaveScheduleRetriesAsync(string accountId, ScheduleRetryTargets targets, CancellationToken ct = default);
}
public sealed record ScheduleProgress(string SemesterName, DateOnly Begin, DateOnly End)
{
    public override string ToString() => $"{SemesterName} · {Begin:yyyy年M月d日} - {End:yyyy年M月d日}";
}
public sealed record ScheduleEntry(DateOnly DisplayDate, IReadOnlyList<Course> Courses,
    bool Preview, int StartMinute, int EndMinute, int Color)
{
    public Course Course => Courses[0];
    public string AccessibleName => $"{Course.Name}，{Course.Day}，{Course.TimeRange}，{Course.Classroom}，{string.Join("、", Courses.Select(x => x.Teacher).Distinct())}{(Preview ? "，非本周" : "")}";
}
public sealed record ScheduleBlock(DateOnly Day, int StartMinute, int EndMinute, IReadOnlyList<ScheduleEntry> Entries);
public sealed record WeekSchedule(DateOnly Monday, int StartHour, int EndHour,
    IReadOnlyList<ScheduleBlock> Blocks, IReadOnlyList<ScheduleEntry> Unplaced, string? ViewedSemesterId = null);
