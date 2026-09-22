namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly Dictionary<string, Task> courseScheduleReads = [];
    readonly Dictionary<string, string> courseScheduleErrors = [], identityErrors = [];
    readonly Dictionary<string, DateTimeOffset> identityUpdates = [];
    BoundedCache<(Guid, string, string, string, long, long), CourseSchedulePresentation> coursePresentations = new(16);
    readonly Dictionary<(Guid, string, string, string, long, long), Task<CourseSchedulePresentation>> coursePresentationTasks = [];
    Task? courseMetadataRead;

    SchoolSemester? CourseSemester(string id)
    {
        var known = Semesters.FirstOrDefault(t => t.Id == id);
        return ScheduleCalendar.Range(known) is not null ? known : snapshots.GetValueOrDefault(id)?.Semester ?? known;
    }
    IReadOnlyList<SchoolSemester> CourseSemesters => Semesters.Select(t => CourseSemester(t.Id) ?? t)
        .Concat(snapshots.Values.Select(s => s.Semester).Where(s => !Semesters.Any(t => t.Id == s.Id))).ToArray();
    public bool CourseScheduleLoading(string semesterId) => courseScheduleReads.ContainsKey(semesterId);
    public string? CourseScheduleError(string semesterId) => courseScheduleErrors.GetValueOrDefault(semesterId) ?? identityErrors.GetValueOrDefault(semesterId);
    (Guid, string, string, string, long, long) CoursePresentationKey(CatalogCourse course) =>
        (Generation, course.SemesterId, course.Id, course.Number, ArrangementVersion, IdentityVersion);
    public CourseSchedulePresentation? CachedCourseScheduleFor(CatalogCourse course) =>
        coursePresentations.TryGet(CoursePresentationKey(course), out var value) ? value : null;
    public CourseSchedulePresentation CourseScheduleFor(CatalogCourse course) => coursePresentations.Get(CoursePresentationKey(course),
        _ => CourseSchedule.Build(course, CourseSemesters, AllCatalogCourses, Courses));
    public async Task<CourseSchedulePresentation> PrepareCourseScheduleAsync(CatalogCourse course)
    {
        var key = CoursePresentationKey(course);
        var cache = coursePresentations;
        if (cache.TryGet(key, out var value)) return value;
        Task<CourseSchedulePresentation> task;
        lock (coursePresentationTasks)
        {
            if (!coursePresentationTasks.TryGetValue(key, out task!))
            {
                // Capture coordinator-owned collections on the caller's thread. Workers only see immutable records.
                var terms = CourseSemesters; var directory = AllCatalogCourses.ToArray(); var courses = Courses.ToArray();
                task = Task.Run(() => CourseSchedule.Build(course, terms, directory, courses));
                coursePresentationTasks[key] = task;
            }
        }
        try
        {
            var result = await task;
            return cache.Get(key, _ => result);
        }
        finally
        {
            lock (coursePresentationTasks)
                if (coursePresentationTasks.GetValueOrDefault(key) == task) coursePresentationTasks.Remove(key);
        }
    }
    bool CourseScheduleComplete(string id) => CourseSemester(id) is { } term && snapshots.TryGetValue(id, out var snapshot)
        && snapshot.IdentityVersion == ScheduleSnapshot.CurrentIdentityVersion && ScheduleCalendar.Range(term) == ScheduleCalendar.Range(snapshot.Semester);
    public string? CourseScheduleStatus(CatalogCourse course, CourseSchedulePresentation? presentation = null)
    {
        var value = presentation ?? CourseScheduleFor(course);
        if (CourseScheduleLoading(course.SemesterId) && value.Meetings.Length == 0) return "正在加载排课…";
        if (value.UnavailableReason is { } reason) return reason;
        if (!IsDemo && !CourseScheduleComplete(course.SemesterId)) return "排课尚未完整同步";
        return value.Meetings.Length == 0 ? "本学期暂无排课" : null;
    }
    public Task EnsureCourseScheduleAsync(CatalogCourse course)
    {
        if (IsDemo) { EnsureDemoSchedule(CourseSemester(course.SemesterId)); return Task.CompletedTask; }
        if (ActiveAccount is not { } account || paused) return Task.CompletedTask;
        lock (courseScheduleReads)
        {
            if (courseScheduleReads.TryGetValue(course.SemesterId, out var existing)) return existing;
            // Register before starting: even a synchronous cache hit must be able to remove its entry.
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            courseScheduleReads[course.SemesterId] = completion.Task;
            _ = CompleteCourseScheduleReadAsync(completion, course, account, Generation, lifetime.Token);
            return completion.Task;
        }
    }
    async Task CompleteCourseScheduleReadAsync(TaskCompletionSource completion, CatalogCourse course, StoredAccount account, Guid epoch, CancellationToken ct)
    {
        try { await LoadCourseScheduleAsync(course, account, epoch, ct); completion.TrySetResult(); }
        catch (Exception e) { completion.TrySetException(e); }
    }
    async Task LoadCourseMetadataAsync(StoredAccount account, Guid epoch, CancellationToken ct)
    {
        await Task.Yield();
        try
        {
            var values = await ReadSemestersAsync(true);
            if (epoch != Generation) return;
            semesters = values; UpdateScheduleMetadata(false);
        }
        finally { if (epoch == Generation) courseMetadataRead = null; }
    }
    async Task LoadCourseScheduleAsync(CatalogCourse course, StoredAccount account, Guid epoch, CancellationToken ct)
    {
        await Task.Yield();
        try
        {
            var id = course.SemesterId;
            var term = CourseSemester(id);
            // Recovery is checked before cooldown: a successful timetable refresh repairs detail state immediately.
            if (term is not null && !NeedsSemesterSync(term)) courseScheduleErrors.Remove(id);
            else if (!CanRetry("course:" + id, false)) return;
            Notify();
            if (ScheduleCalendar.Range(term) is null)
            {
                courseMetadataRead ??= LoadCourseMetadataAsync(account, epoch, ct);
                await courseMetadataRead;
                if (epoch != Generation) return;
                term = CourseSemester(id);
            }
            if (term is null || ScheduleCalendar.Range(term) is null) throw new IOException("无法确定课程所属学期的有效日期范围");
            if (SelectedSemester?.Id == id && catalogRead is { } currentCatalogRead) await currentCatalogRead;
            if (epoch != Generation) return;
            await EnsureCatalogForSemesterAsync(term);
            if (epoch != Generation) return;
            if (scheduleTask is { } running && syncingTargets.Contains(id)) await running;
            if (epoch != Generation) return;
            if (NeedsSemesterSync(term))
            {
                if (syncingSemester != id) pendingSemesters.Add(id);
                foreach (var cached in CourseSemesters.Where(t => snapshots.ContainsKey(t.Id) && t.Id != syncingSemester && NeedsSemesterSync(t))) pendingSemesters.Add(cached.Id);
                await StartScheduleAsync(false, id);
                if (epoch != Generation) return;
                // The previous batch may have already passed its semester loop when this request joined.
                if (pendingSemesters.Contains(id) && CanRetry("semester:" + id, false)) await StartScheduleAsync(false, id);
            }
            if (epoch != Generation) return;
            if (!NeedsSemesterSync(term)) { courseScheduleErrors.Remove(id); retryAt.Remove("course:" + id); }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation) { courseScheduleErrors[course.SemesterId] = e.Message; RetryLater("course:" + course.SemesterId); }
        }
        finally { if (epoch == Generation) { lock (courseScheduleReads) courseScheduleReads.Remove(course.SemesterId); Notify(); } }
    }
    void ResetCourseSchedules()
    {
        courseScheduleReads.Clear(); courseScheduleErrors.Clear(); identityErrors.Clear(); identityUpdates.Clear();
        courseMetadataRead = null; coursePresentations = new(16);
        lock (coursePresentationTasks) coursePresentationTasks.Clear();
    }
}
