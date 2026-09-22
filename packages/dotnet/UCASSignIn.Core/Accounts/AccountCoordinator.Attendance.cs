namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly IAttendanceStateStore? attendanceStore = cache as IAttendanceStateStore;
    readonly Dictionary<string, AttendanceEvidence> attendanceStates = [];
    readonly HashSet<string> invalidatedAttendance = [], invalidatedDays = [];
    readonly Dictionary<string, long> attendanceVersions = [], attendanceRevisions = [];
    readonly Dictionary<string, DateTimeOffset> dayVerifiedAt = [];
    readonly SemaphoreSlim attendanceSaveGate = new(1);
    static string AttendanceKey(Course c) => (CourseTime.NormalizeDay(c.Day) ?? c.Day) + "|" + c.Id;
    public AttendanceStatus AttendanceStatusFor(Course c) => IsDemo ? (c.Signed ? AttendanceStatus.Signed : AttendanceStatus.Unsigned)
        : attendanceStates.TryGetValue(AttendanceKey(c), out var state) ? state.Status : c.Signed ? AttendanceStatus.Signed : AttendanceStatus.Unknown;
    public string AttendanceLabel(Course c)
    {
        var key = AttendanceKey(c);
        if (!IsDemo && attendanceStates.TryGetValue(key, out var state) && state.PendingVerification)
            return "已签到 · 待核验";
        return AttendanceStatusFor(c) switch { AttendanceStatus.Signed => "已签到", AttendanceStatus.Unsigned => "未签到", _ => "状态待同步" };
    }
    bool ArrangementFresh(Course course) => IsDemo || freshDays.Contains(course.Day)
        || snapshots.Values.Any(s => !s.IsDue(clock.GetUtcNow()) && string.CompareOrdinal(s.Semester.BeginDate, course.Day) <= 0 && string.CompareOrdinal(course.Day, s.Semester.EndDate) <= 0);
    void ResetAttendanceState()
    {
        attendanceStates.Clear(); invalidatedAttendance.Clear(); invalidatedDays.Clear(); attendanceVersions.Clear(); attendanceRevisions.Clear();
        dayVerifiedAt.Clear();
    }
    async Task LoadAttendanceStateAsync(string id, Guid epoch)
    {
        if (attendanceStore is null) return;
        try
        {
            var stored = await attendanceStore.LoadAttendanceStateAsync(id, lifetime.Token);
            if (epoch != Generation || stored is not { Version: AttendanceEvidenceCache.CurrentVersion } || stored.AccountId != id) return;
            foreach (var pair in stored.States) attendanceStates[pair.Key] = pair.Value;
            invalidatedAttendance.UnionWith(stored.InvalidatedCourses);
        }
        catch (Exception e) when (e is not OperationCanceledException) { if (epoch == Generation) Message = "签到状态缓存暂不可用：" + e.Message; }
    }
    async Task SaveAttendanceStateAsync(Guid epoch)
    {
        if (attendanceStore is null || IsDemo) return;
        await attendanceSaveGate.WaitAsync();
        try
        {
            if (epoch != Generation || ActiveAccount is not { } account) return;
            await attendanceStore.SaveAttendanceStateAsync(new(AttendanceEvidenceCache.CurrentVersion, account.Id,
                new(attendanceStates), new(invalidatedAttendance)), lifetime.Token);
        }
        catch (Exception e) when (e is not OperationCanceledException) { if (epoch == Generation) Message = "当前结果仍可查看，状态缓存保存失败：" + e.Message; }
        finally { attendanceSaveGate.Release(); }
    }
    Course ProjectAttendance(Course c) => IsDemo ? c : c with { Signed = AttendanceStatusFor(c) == AttendanceStatus.Signed };
    void ProjectAttendance() { Courses = Courses.Select(ProjectAttendance).ToArray(); }
    void ObserveAttendance(Course c, AttendanceSource source, long sequence)
    {
        var key = AttendanceKey(c);
        if (attendanceVersions.GetValueOrDefault(key) >= sequence) return;
        var status = source == AttendanceSource.Submission ? AttendanceStatus.Signed
            : c.SignStatusKnown == true ? (c.Signed ? AttendanceStatus.Signed : AttendanceStatus.Unsigned) : AttendanceStatus.Unknown;
        var now = clock.GetUtcNow();
        var previous = attendanceStates.GetValueOrDefault(key) ?? new(AttendanceStatus.Unknown, AttendanceSource.Cache, now);
        var state = previous.Observe(status, source, now);
        attendanceStates[key] = state; attendanceVersions[key] = sequence;
    }
    async Task JoinDayAsync(Task previous, long revision, DateOnly date, Guid epoch)
    {
        await previous;
        var day = CourseTime.DayKey(date);
        if (epoch == Generation && invalidatedDays.Contains(day) && versions.GetValueOrDefault(day) != revision)
            await RefreshAsync(date);
    }
    public async Task EnterDayAsync(DateOnly date)
    {
        if (IsDemo) return;
        var day = CourseTime.DayKey(date);
        if (freshDays.Contains(day) && CachePolicy.Fresh(dayVerifiedAt.GetValueOrDefault(day), clock.GetUtcNow(), TimeSpan.FromSeconds(30))) return;
        await RefreshAsync(date);
    }
}
