namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    IReadOnlyList<SchoolSemester> semesters = [];
    public IReadOnlyList<SchoolSemester> ScheduleSemesters { get; private set; } = [];
    public ScheduleDateRange? ScheduleDateRange { get; private set; }
    public ScheduleDateRange? ViewedDateRange => ScheduleCalendar.Range(ViewedSemester);
    public int? ScheduleWeekNumber => ScheduleCalendar.WeekNumber(SelectedDate, ViewedSemester);
    public int ScheduleWeekCount => ScheduleCalendar.WeekCount(ViewedSemester);
    public IReadOnlyList<DateOnly> VisibleScheduleDays => ScheduleDays(SelectedDate, ViewedSemester);
    IReadOnlyList<DateOnly> ScheduleDays(DateOnly date, SchoolSemester? term) => ScheduleCalendar.VisibleDays(date, term)
        .Where(d => ScheduleDateRange?.Contains(d) ?? true).ToArray();
    public DateOnly? PreviousScheduleWeek => ScheduleCalendar.AdjacentWeek(SelectedDate, false, ViewedDateRange ?? ScheduleDateRange);
    public DateOnly? NextScheduleWeek => ScheduleCalendar.AdjacentWeek(SelectedDate, true, ViewedDateRange ?? ScheduleDateRange);
    public bool CanReturnToToday => ScheduleDateRange?.Contains(CourseTime.Today(clock)) ?? true;
    public bool CanSelectVisibleDate(DateOnly date) => ViewedDateRange?.Contains(date) ?? true;
    void UpdateScheduleMetadata()
    {
        ScheduleSemesters = semesters.Where(s => ScheduleCalendar.Range(s) is not null)
            .OrderByDescending(s => ScheduleCalendar.Range(s)!.Value.Begin).ThenBy(s => s.Id, StringComparer.Ordinal).ToArray();
        var ranges = ScheduleSemesters.Select(s => ScheduleCalendar.Range(s)!.Value).ToArray();
        ScheduleDateRange = ranges.Length == 0 ? null : new(ranges.Min(r => r.Begin), ranges.Max(r => r.End));
        if (ScheduleDateRange is { } range) SelectedDate = range.Clamp(SelectedDate);
        IdentityVersion++; layouts.Clear();
    }
    public Task SelectScheduleDateAsync(DateOnly date, Guid generation, string? semesterId)
        => generation == Generation && semesterId == ViewedSemester?.Id && CanSelectVisibleDate(date)
            ? NavigateScheduleAsync(date) : Task.CompletedTask;
    public Task SelectScheduleSemesterAsync(string id, Guid generation)
    {
        if (generation != Generation || ScheduleSemesters.FirstOrDefault(s => s.Id == id) is not { } target) return Task.CompletedTask;
        return ScheduleCalendar.SwitchSemester(SelectedDate, ViewedSemester, target) is { } date ? NavigateScheduleAsync(date) : Task.CompletedTask;
    }
    public Task SelectScheduleWeekAsync(int week, Guid generation, string semesterId)
    {
        if (generation != Generation || ViewedSemester is not { } term || term.Id != semesterId) return Task.CompletedTask;
        return ScheduleCalendar.DateInWeek(term, week, SelectedDate) is { } date ? NavigateScheduleAsync(date) : Task.CompletedTask;
    }
    public Task MoveScheduleWeekAsync(bool next)
        => (next ? NextScheduleWeek : PreviousScheduleWeek) is { } date ? NavigateScheduleAsync(date) : Task.CompletedTask;
    public Task ReturnToScheduleTodayAsync() => CanReturnToToday ? NavigateScheduleAsync(CourseTime.Today(clock)) : Task.CompletedTask;
    Task NavigateScheduleAsync(DateOnly date) => date == SelectedDate ? Task.CompletedTask : SelectDateAsync(date);
    bool NeedsSemesterSync(SchoolSemester term) => !snapshots.TryGetValue(term.Id, out var snapshot)
        || ScheduleCalendar.Range(snapshot.Semester) != ScheduleCalendar.Range(term) || snapshot.IsDue(clock.GetUtcNow());
    readonly Dictionary<string, string?> pendingWeekSemesters = [];
    void QueueVisibleWeek()
    {
        var monday = CourseTime.DayKey(ScheduleLayout.Monday(SelectedDate));
        pendingWeeks.Add(monday); pendingWeekSemesters[monday] = ViewedSemester?.Id;
    }
    IReadOnlyList<DateOnly> PendingWeekDays(string monday)
    {
        var first = CourseTime.Date(monday);
        var term = first == ScheduleLayout.Monday(SelectedDate) ? ViewedSemester
            : pendingWeekSemesters.TryGetValue(monday, out var id) ? ScheduleSemesters.FirstOrDefault(s => s.Id == id)
            : CourseIdentity.Semester(first.AddDays(3), ScheduleSemesters);
        return ScheduleDays(first, term);
    }
    string? scheduleError;
    string? scheduleErrorSemester;
    DateOnly? scheduleErrorMonday;
    void SetScheduleError(string? error, string? semesterId = null, DateOnly? monday = null)
    { scheduleError = error; scheduleErrorSemester = semesterId; scheduleErrorMonday = monday; }
}
