namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly IScheduleStore? scheduleStore = cache as IScheduleStore;
    readonly Dictionary<string, ScheduleSnapshot> snapshots = [];
    readonly Dictionary<string, long> successfulWrites = [];
    readonly Dictionary<string, DateTimeOffset> retryAt = [];
    readonly Dictionary<string, int> failures = [];
    readonly HashSet<string> checkedDays = [];
    readonly Dictionary<string, (string SessionId, HashSet<string> Days)> accountChecks = [];
    string? scheduleAccountId, scheduleSessionId;
    readonly HashSet<string> pendingSemesters = [], pendingWeeks = [];
    readonly HashSet<string> dirtyWeeks = [];
    readonly Dictionary<string, ScheduleColors> scheduleColors = [];
    readonly Dictionary<(DateOnly, string?, long, long, bool, bool), WeekSchedule> layouts = [];
    readonly Dictionary<string, IReadOnlyList<CatalogCourse>> semesterCatalogs = [];
    readonly Dictionary<string, Task> identityReads = [];
    Task? scheduleTask;
    string? syncingSemester;
    HashSet<string> syncingTargets = [];
    bool scheduleEntered;
    public ScheduleMode ScheduleMode { get; set; }
    public bool ShowOtherWeeks { get; set; }
    public long ArrangementVersion { get; private set; }
    public long IdentityVersion { get; private set; }
    public ScheduleProgress? ScheduleProgress { get; private set; }
    public string? ScheduleError
    {
        get => (scheduleErrorSemester is null || scheduleErrorSemester == ViewedSemester?.Id)
            && (scheduleErrorMonday is null || scheduleErrorMonday == ScheduleLayout.Monday(SelectedDate)) ? scheduleError : null;
        private set => SetScheduleError(value, ViewedSemester?.Id, ScheduleLayout.Monday(SelectedDate));
    }
    public event Action? ScheduleProgressChanged;
    public bool IsScheduleRefreshing => scheduleTask is not null;
    public SchoolSemester? ViewedSemester => CourseIdentity.Semester(SelectedDate, ScheduleSemesters);
    public DateTimeOffset? ScheduleUpdatedAt => ViewedSemester is { } term && snapshots.TryGetValue(term.Id, out var snapshot) ? snapshot.UpdatedAt : null;
    public bool HasCompleteWeek
    {
        get { var days = VisibleScheduleDays; return days.Count > 0 && (IsDemo || days.All(d => courseUpdates.ContainsKey(CourseTime.DayKey(d)))); }
    }
    public bool IsInitialScheduleLoading => IsScheduleRefreshing && !HasCompleteWeek;
    public IEnumerable<CatalogCourse> AllCatalogCourses =>
        (SelectedSemester is { } selected && identityUpdates.GetValueOrDefault(selected.Id) > CatalogUpdatedAt
            ? Array.Empty<CatalogCourse>() : CatalogCourses).Concat(semesterCatalogs
        .Where(x => x.Key != SelectedSemester?.Id || CatalogUpdatedAt is null || identityUpdates.GetValueOrDefault(x.Key) > CatalogUpdatedAt).SelectMany(x => x.Value)).Distinct();
    public CatalogCourse? CatalogFor(Course course) => CourseIdentity.Resolve(course, Semesters, AllCatalogCourses);
    public string? PreferenceId(Course course) => CatalogFor(course)?.Id ?? course.CourseId;
    public IEnumerable<AttendanceRecord> RecordsForCourse(string courseId) => Records.Where(r => r.CourseId == courseId
        || Courses.Any(c => c.Id == r.ScheduledCourseId && c.CourseId == r.CourseId && CatalogFor(c)?.Id == courseId));
    public WeekSchedule WeekSchedule()
    {
        var key = (ScheduleLayout.Monday(SelectedDate), ViewedSemester?.Id, ArrangementVersion, IdentityVersion, ShowOtherWeeks, IsInitialScheduleLoading);
        if (layouts.TryGetValue(key, out var result)) return result;
        var term = ViewedSemester?.Id ?? "unknown";
        if (!scheduleColors.TryGetValue(term, out var colors)) scheduleColors[term] = colors = new();
        var source = IsInitialScheduleLoading ? [] : Courses.ToArray();
        string ColorTerm(Course c) => CourseTime.NormalizeDay(c.Day) is { } day ? CourseIdentity.Semester(CourseTime.Date(day), Semesters)?.Id ?? "unknown" : "unknown";
        foreach (var group in source.GroupBy(ColorTerm))
        {
            if (!scheduleColors.TryGetValue(group.Key, out var allocator)) scheduleColors[group.Key] = allocator = new();
            allocator.Include(group);
        }
        result = ScheduleLayout.Build(SelectedDate, source, ScheduleSemesters, AllCatalogCourses, ShowOtherWeeks, colors, c => scheduleColors[ColorTerm(c)].Color(c));
        if (layouts.Count >= 8) layouts.Remove(layouts.Keys.First());
        layouts[key] = result; return result;
    }
    void ResetSchedule()
    {
        if (scheduleAccountId is not null && scheduleSessionId is not null)
            accountChecks[scheduleAccountId] = (scheduleSessionId, new(checkedDays));
        scheduleAccountId = scheduleSessionId = null;
        ResetCourseSchedules();
        snapshots.Clear(); successfulWrites.Clear(); retryAt.Clear(); failures.Clear(); checkedDays.Clear(); pendingSemesters.Clear(); pendingWeeks.Clear();
        dirtyWeeks.Clear(); pendingWeekSemesters.Clear();
        scheduleColors.Clear(); layouts.Clear(); semesterCatalogs.Clear(); identityReads.Clear(); scheduleTask = null; syncingSemester = null; syncingTargets = [];
        ScheduleProgress = null; ScheduleError = null; ArrangementVersion++; IdentityVersion++;
    }
    void RestoreAccountChecks(StoredAccount account)
    {
        scheduleAccountId = account.Id; scheduleSessionId = account.Session.SessionId;
        if (accountChecks.TryGetValue(account.Id, out var prior) && prior.SessionId == account.Session.SessionId)
        { checkedDays.UnionWith(prior.Days); freshDays.UnionWith(prior.Days); }
    }
    static IEnumerable<DateOnly> Dates(DateOnly first, DateOnly last)
    { for (var date = first; date <= last; date = date.AddDays(1)) yield return date; }
    bool CanRetry(string key, bool force) => force || !retryAt.TryGetValue(key, out var at) || clock.GetUtcNow() >= at;
    void RetryLater(string key)
    {
        var count = failures.GetValueOrDefault(key) + 1; failures[key] = count;
        retryAt[key] = clock.GetUtcNow().AddSeconds(count == 1 ? 60 : count == 2 ? 120 : 300);
    }
    async Task LoadScheduleCacheAsync(StoredAccount account, Guid epoch)
    {
        if (scheduleStore is null) return;
        var values = await scheduleStore.LoadSchedulesAsync(account.Id, lifetime.Token);
        if (epoch != Generation) return;
        foreach (var snapshot in values.Where(x => x.Version == ScheduleSnapshot.CurrentVersion && x.AccountId == account.Id && ScheduleCalendar.Range(x.Semester) is not null))
        {
            snapshots[snapshot.Semester.Id] = snapshot;
            requestSequence = Math.Max(requestSequence, snapshot.WriteSequence);
            foreach (var date in Dates(CourseTime.Date(snapshot.Semester.BeginDate), CourseTime.Date(snapshot.Semester.EndDate)))
            {
                var day = CourseTime.DayKey(date); Merge(snapshot.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == day), day); courseUpdates[day] = snapshot.UpdatedAt; successfulWrites[day] = snapshot.WriteSequence;
            }
        }
        if (catalog is not null)
        {
            var terms = await catalog.LoadSemestersAsync(account.Id, lifetime.Token);
            if (epoch != Generation) return;
            if (terms is { Version: SemesterCache.CurrentVersion } && terms.AccountId == account.Id) Semesters = terms.Semesters;
        }
        if (Semesters.Count == 0) Semesters = snapshots.Values.Select(x => x.Semester).ToArray();
        SelectScheduleCatalogSemester();
        if (catalog is not null)
        {
            foreach (var term in Semesters)
            {
                var stored = await catalog.LoadCatalogAsync(account.Id, term.Id, lifetime.Token);
                if (epoch != Generation) return;
                if (stored is { Version: CourseCatalogCache.CurrentVersion } && stored.AccountId == account.Id && stored.SemesterId == term.Id
                    && stored.Courses.All(c => c.SemesterId == term.Id)) { semesterCatalogs[term.Id] = stored.Courses; identityUpdates[term.Id] = stored.UpdatedAt; }
            }
            if (SelectedSemester is { } selected) UpdateSelectedCatalog(selected.Id);
            IdentityVersion++;
        }
        var days = await scheduleStore.CachedDaysAsync(account.Id, lifetime.Token);
        foreach (var day in days)
        {
            var overlay = await cache.LoadAsync(account.Id, day, lifetime.Token);
            if (epoch != Generation) return;
            if (overlay is not null)
            {
                requestSequence = Math.Max(requestSequence, overlay.WriteSequence);
                if (!courseUpdates.TryGetValue(day, out var updated) || overlay.WriteSequence > successfulWrites.GetValueOrDefault(day)
                    || overlay.WriteSequence == 0 && overlay.UpdatedAt > updated)
                { Merge(overlay.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == day), day); courseUpdates[day] = overlay.UpdatedAt; successfulWrites[day] = overlay.WriteSequence; }
            }
        }
        var pending = await scheduleStore.LoadScheduleRetriesAsync(account.Id, lifetime.Token);
        if (epoch != Generation) return;
        if (pending is not null) { pendingSemesters.UnionWith(pending.SemesterIds); pendingWeeks.UnionWith(pending.Mondays); dirtyWeeks.UnionWith(pending.DirtyMondays ?? []); }
        Notify();
    }
    public async Task EnterScheduleAsync()
    {
        scheduleEntered = true;
        if (IsDemo) { EnsureDemoSchedule(); Notify(); return; }
        if (ScheduleMode == ScheduleMode.Week) await RefreshScheduleAsync(false);
        else { await EnterDayAsync(SelectedDate); await MaintainScheduleAsync(); }
    }
    public async Task CheckDayAsync(DateOnly date, bool force = false)
    {
        var day = CourseTime.DayKey(date);
        if ((!force && checkedDays.Contains(day)) || !CanRetry("day:" + day, force)) return;
        await RefreshAsync(date);
    }
    public Task MaintainScheduleAsync()
    {
        if (!scheduleEntered || !IsConnected || IsDemo || paused) return Task.CompletedTask;
        return RefreshScheduleAsync(false, onlyDue: true);
    }
    public async Task RefreshScheduleAsync(bool force = true, bool onlyDue = false)
    {
        if (IsDemo) { EnsureDemoSchedule(); Notify(); return; }
        if (ActiveAccount is null || paused) return;
        var epoch = Generation;
        if (!force && ViewedSemester is { } term && term.Id != syncingSemester && NeedsSemesterSync(term)) pendingSemesters.Add(term.Id);
        foreach (var cachedTerm in ScheduleSemesters.Where(t => t.Id != syncingSemester && snapshots.ContainsKey(t.Id) && NeedsSemesterSync(t))) pendingSemesters.Add(cachedTerm.Id);
        if (!force && Semesters.Count > 0 && !HasCompleteWeek) QueueVisibleWeek();
        var joinedBatch = scheduleTask is not null;
        var joinedTargets = syncingTargets;
        var requestedSemester = ViewedSemester?.Id;
        await StartScheduleAsync(force);
        if (epoch != Generation) return;
        if (force && joinedBatch && (requestedSemester ?? ViewedSemester?.Id) is { } requested && !joinedTargets.Contains(requested))
            await StartScheduleAsync(true);
        if (epoch != Generation) return;
        await EnsureCatalogForDateAsync(SelectedDate, force);
        if (epoch != Generation) return;
        if (!onlyDue && ScheduleMode == ScheduleMode.Day) await EnterDayAsync(SelectedDate);
    }
    Task StartScheduleAsync(bool force, string? targetSemester = null)
    {
        if (scheduleTask is not null) return scheduleTask;
        if (ActiveAccount is not { } account || paused) return Task.CompletedTask;
        if (!force && !(Semesters.Count == 0 && CanRetry("semesters", force))
            && !pendingSemesters.Any(id => CanRetry("semester:" + id, force))
            && !pendingWeeks.Any(day => CanRetry("week:" + day, force))) return Task.CompletedTask;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        syncingTargets = [];
        scheduleTask = completion.Task;
        _ = RunScheduleAsync(account, Generation, lifetime.Token, force, completion, targetSemester);
        return completion.Task;
    }
    async Task SaveTargetsAsync(string id, CancellationToken ct)
    {
        if (scheduleStore is not null) await scheduleStore.SaveScheduleRetriesAsync(id, new(pendingSemesters.Order().ToList(), pendingWeeks.Order().ToList(), dirtyWeeks.Order().ToList()), ct);
    }
    async Task<T> ScheduleRequestAsync<T>(Func<SchoolSession, Task<T>> request, Guid epoch)
    {
        if (epoch != Generation || ActiveAccount is not { } a) throw new OperationCanceledException();
        try { return await request(a.Session); }
        catch (SchoolException e) when (e.IsSessionExpired)
        {
            var session = await RecoverAsync(a.Session, epoch);
            if (session is null || epoch != Generation) throw;
            return await request(session);
        }
    }
    async Task RunScheduleAsync(StoredAccount account, Guid epoch, CancellationToken ct, bool force, TaskCompletionSource completion, string? targetSemester)
    {
        await Task.Yield();
        try
        {
            if (epoch != Generation) return;
            ScheduleError = null;
            var visibleMonday = ScheduleLayout.Monday(SelectedDate);
            ScheduleProgress = new(ViewedSemester?.Name ?? "课表", visibleMonday, visibleMonday.AddDays(6));
            Notify();
            if (targetSemester is null && (force || Semesters.Count == 0) && CanRetry("semesters", force))
            {
                try
                {
                    var terms = await ReadSemestersAsync(force);
                    if (epoch != Generation) return;
                    Semesters = terms; SelectScheduleCatalogSemester();
                }
                catch (Exception e) when (e is not OperationCanceledException) { if (epoch != Generation) return; RetryLater("semesters"); ScheduleError = "无法确定学期，不能完成完整同步：" + e.Message; }
            }
            // Metadata can move the selected date. Choose targets only after applying it.
            if (targetSemester is null && (force || !HasCompleteWeek)) QueueVisibleWeek();
            foreach (var monday in pendingWeeks.ToArray())
                foreach (var term in PendingWeekDays(monday).Select(d => CourseIdentity.Semester(d, ScheduleSemesters)).OfType<SchoolSemester>().Distinct())
                    if (NeedsSemesterSync(term)) pendingSemesters.Add(term.Id);
            if (targetSemester is null && ViewedSemester is { } viewed && (force || NeedsSemesterSync(viewed))) pendingSemesters.Add(viewed.Id);
            await SaveTargetsAsync(account.Id, ct);
            var failed = new HashSet<string>();
            while (epoch == Generation)
            {
                var id = pendingSemesters.OrderBy(x => x == targetSemester || courseScheduleReads.ContainsKey(x) ? 0 : x == ViewedSemester?.Id ? 1 : 2).FirstOrDefault(x => !failed.Contains(x) && CanRetry("semester:" + x, force));
                if (id is null) break;
                var term = CourseSemester(id);
                if (term is null) { pendingSemesters.Remove(id); continue; }
                pendingSemesters.Remove(id);
                syncingSemester = id; syncingTargets.Add(id);
                try { await SyncSemesterAsync(account, term, epoch, ct); }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    if (epoch != Generation) return;
                    pendingSemesters.Add(id); failed.Add(id); RetryLater("semester:" + id);
                    courseScheduleErrors[id] = e.Message + "；已保留可用缓存";
                    SetScheduleError($"{ScheduleProgress}：{e.Message}；已保留可用缓存", id);
                }
                finally { if (epoch == Generation) syncingSemester = null; }
                if (epoch != Generation) return;
                await SaveTargetsAsync(account.Id, ct);
            }
            foreach (var monday in pendingWeeks.ToArray())
            {
                if (!CanRetry("week:" + monday, force)) continue;
                var first = CourseTime.Date(monday);
                var refreshKnownDays = dirtyWeeks.Contains(monday);
                // Missing visible boundary days and legacy weeks have independent coverage.
                try
                {
                    foreach (var day in PendingWeekDays(monday))
                    {
                        if (epoch != Generation) return;
                        if (refreshKnownDays || !courseUpdates.ContainsKey(CourseTime.DayKey(day)) || CourseIdentity.Semester(day, Semesters) is null)
                        {
                            await CheckDayAsync(day, force || refreshKnownDays);
                            if (!checkedDays.Contains(CourseTime.DayKey(day))) throw new IOException($"{day:yyyy年M月d日} 同步失败");
                        }
                    }
                    if (epoch != Generation) return;
                    pendingWeeks.Remove(monday); pendingWeekSemesters.Remove(monday);
                    dirtyWeeks.Remove(monday);
                }
                catch (Exception e) when (e is not OperationCanceledException)
                { if (epoch != Generation) return; RetryLater("week:" + monday); SetScheduleError($"{first:yyyy年M月d日} - {first.AddDays(6):yyyy年M月d日}：{e.Message}", pendingWeekSemesters.GetValueOrDefault(monday), first); }
            }
            if (epoch == Generation)
            {
                await SaveTargetsAsync(account.Id, ct);
                if (targetSemester is null) await EnsureCatalogForDateAsync(SelectedDate);
                if (targetSemester is null && epoch == Generation && ViewedSemester is null && ScheduleError is null) ScheduleError = "无法唯一确定所选日期的学期，已查询可见周；尚不能完成完整学期同步。";
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation)
            {
                ScheduleError = e.Message; RetryLater("semesters");
                if (targetSemester is { } target) { courseScheduleErrors[target] = e.Message; RetryLater("course:" + target); }
            }
        }
        finally
        {
            if (epoch == Generation) { scheduleTask = null; ScheduleProgress = null; ScheduleProgressChanged?.Invoke(); Notify(); }
            completion.TrySetResult();
        }
    }
    async Task SyncSemesterAsync(StoredAccount account, SchoolSemester term, Guid epoch, CancellationToken ct)
    {
        var begin = CourseTime.Date(term.BeginDate); var end = CourseTime.Date(term.EndDate);
        if (ScheduleCalendar.Range(term) is null) throw new IOException("学校学期日期范围无效");
        var sequence = ++requestSequence; var staged = new List<Course>();
        for (var monday = ScheduleLayout.Monday(begin); monday <= end; monday = monday.AddDays(7))
        {
            var first = monday < begin ? begin : monday; var last = monday.AddDays(6) > end ? end : monday.AddDays(6);
            ScheduleProgress = new(term.Name, first, last); ScheduleProgressChanged?.Invoke();
            var week = await ScheduleRequestAsync(s => school.WeeklyScheduleAsync(s, first, ct), epoch);
            if (epoch != Generation) throw new OperationCanceledException();
            if (week.CoveredDays.Distinct().Count() != week.CoveredDays.Count) throw new IOException("学校周课表包含重复日期");
            foreach (var date in Dates(first, last))
            {
                var day = CourseTime.DayKey(date);
                var values = week.CoveredDays.Contains(day) ? week.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == day)
                    : (await ScheduleRequestAsync(s => school.DailyScheduleAsync(s, date, ct), epoch)).Courses;
                if (epoch != Generation) throw new OperationCanceledException();
                staged.AddRange(values.Select(c => CourseIdentity.PreserveFields(c with { Day = day }, Courses.FirstOrDefault(x => x.Day == day && x.Id == c.Id))));
            }
        }
        if (epoch != Generation) throw new OperationCanceledException();
        var days = Dates(begin, end).Select(CourseTime.DayKey).ToHashSet();
        var newer = days.Where(d => successfulWrites.GetValueOrDefault(d) > sequence).ToHashSet();
        staged = staged.Where(c => !newer.Contains(c.Day)).Concat(Courses.Where(c => newer.Contains(c.Day))).ToList();
        var snapshot = new ScheduleSnapshot(ScheduleSnapshot.CurrentVersion, ScheduleSnapshot.CurrentIdentityVersion, account.Id, term, staged, clock.GetUtcNow(), sequence);
        if (scheduleStore is not null) await scheduleStore.SaveScheduleAsync(snapshot, ct);
        if (epoch != Generation) throw new OperationCanceledException();
        snapshots[term.Id] = snapshot;
        foreach (var day in days)
        {
            if (successfulWrites.GetValueOrDefault(day) > sequence) continue;
            Merge(staged.Where(c => c.Day == day), day); successfulWrites[day] = sequence;
            courseUpdates[day] = snapshot.UpdatedAt; courseNotices.Remove(day);
        }
        retryAt.Remove("semester:" + term.Id); failures.Remove("semester:" + term.Id);
        courseScheduleErrors.Remove(term.Id); retryAt.Remove("course:" + term.Id);
        Notify();
        await EnsureCatalogForSemesterAsync(term);
        if (epoch == Generation) await UpdateRemindersAsync();
    }
    void ScheduleArrangementChanged()
    {
        if (scheduleStore is null) return;
        foreach (var term in snapshots.Keys.Where(id => id != syncingSemester)) pendingSemesters.Add(term);
        foreach (var date in courseUpdates.Keys)
        {
            if (CourseIdentity.Semester(CourseTime.Date(date), Semesters) is { } term)
            { if (term.Id != syncingSemester) pendingSemesters.Add(term.Id); }
            else
            {
                var monday = CourseTime.DayKey(ScheduleLayout.Monday(CourseTime.Date(date)));
                pendingWeeks.Add(monday); dirtyWeeks.Add(monday);
            }
        }
        // Do not await the runner from a day request: it can itself be filling this day.
        _ = StartScheduleAsync(false);
    }
    public Task EnsureCatalogForDateAsync(DateOnly date, bool force = false)
        => CourseIdentity.Semester(date, Semesters) is { } term ? EnsureCatalogForSemesterAsync(term, force) : Task.CompletedTask;
    Task EnsureCatalogForSemesterAsync(SchoolSemester term, bool force = false)
    {
        if (IsDemo || ActiveAccount is null) return Task.CompletedTask;
        if (SelectedSemester?.Id == term.Id && CatalogUpdatedAt is { } updated
            && (!identityUpdates.TryGetValue(term.Id, out var previous) || updated > previous))
        { semesterCatalogs[term.Id] = CatalogCourses; identityUpdates[term.Id] = updated; }
        UpdateSelectedCatalog(term.Id);
        if (!force && identityUpdates.TryGetValue(term.Id, out var at) && CachePolicy.Fresh(at, clock.GetUtcNow()))
        { identityErrors.Remove(term.Id); retryAt.Remove("identity:" + term.Id); return Task.CompletedTask; }
        if (identityReads.TryGetValue(term.Id, out var existing)) return existing;
        if (!CanRetry("identity:" + term.Id, force)) return Task.CompletedTask;
        var task = LoadIdentityCatalogAsync(term, ActiveAccount, Generation, lifetime.Token, force);
        identityReads[term.Id] = task; return task;
    }
    void SelectScheduleCatalogSemester()
    {
        var marked = Semesters.Where(s => s.IsCurrent).Take(2).ToArray();
        SelectedSemester = marked.Length == 1 ? marked[0] : CourseIdentity.Semester(CourseTime.Today(clock), Semesters);
    }
    void UpdateSelectedCatalog(string semesterId)
    {
        // The schedule and course page share cached data, including valid empty catalogs.
        if (SelectedSemester?.Id == semesterId && semesterCatalogs.TryGetValue(semesterId, out var values)
            && identityUpdates.TryGetValue(semesterId, out var updated))
        { CatalogCourses = values; CatalogUpdatedAt = updated; }
    }
    async Task LoadIdentityCatalogAsync(SchoolSemester term, StoredAccount account, Guid epoch, CancellationToken ct, bool force)
    {
        await Task.Yield();
        try
        {
            var stored = catalog is null ? null : await catalog.LoadCatalogAsync(account.Id, term.Id, ct);
            if (epoch != Generation) return;
            if (stored is not null && (stored.AccountId != account.Id || stored.SemesterId != term.Id
                || stored.Version != CourseCatalogCache.CurrentVersion || stored.Courses.Any(c => c.SemesterId != term.Id))) stored = null;
            if (stored is not null && !identityUpdates.ContainsKey(term.Id))
            { semesterCatalogs[term.Id] = stored.Courses; identityUpdates[term.Id] = stored.UpdatedAt; UpdateSelectedCatalog(term.Id); IdentityVersion++; Notify(); }
            if (force || stored is not null && !CachePolicy.Fresh(stored.UpdatedAt, clock.GetUtcNow())) stored = null;
            var values = stored?.Courses ?? (await ScheduleRequestAsync(s => school.CatalogCoursesAsync(s, term.Id, ct), epoch)).ToList();
            if (epoch != Generation) return;
            if (values.Any(c => c.SemesterId != term.Id)) throw new IOException("学校返回了其他学期的课程");
            semesterCatalogs[term.Id] = values; identityUpdates[term.Id] = stored?.UpdatedAt ?? clock.GetUtcNow(); identityErrors.Remove(term.Id); IdentityVersion++; layouts.Clear();
            UpdateSelectedCatalog(term.Id);
            retryAt.Remove("identity:" + term.Id); failures.Remove("identity:" + term.Id);
            if (stored is null && catalog is not null) await catalog.SaveCatalogAsync(account.Id, term.Id, new(CourseCatalogCache.CurrentVersion, account.Id, term.Id, clock.GetUtcNow(), values.ToList()), ct);
            if (epoch == Generation) Notify();
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (epoch == Generation) { RetryLater("identity:" + term.Id); identityErrors[term.Id] = "课程关联暂不可用：" + e.Message; SetScheduleError("课程关联暂不可用：" + e.Message, term.Id); } }
        finally { if (epoch == Generation) identityReads.Remove(term.Id); }
    }
    void EnsureDemoSchedule(SchoolSemester? target = null)
    {
        var term = target ?? ScheduleCalendar.DemoSemester(SelectedDate);
        var range = ScheduleCalendar.Range(term)!.Value;
        var begin = range.Begin; var end = range.End;
        if (Semesters.Count == 1 && Semesters[0] == term && Courses.Count > 10) return;
        SetupDemoCatalog(term);
        var examples = DemoCourses(begin);
        CatalogCourses = CatalogCourses.Select((c, i) => c with { Teacher = i < examples.Count ? examples[i].Teacher : c.Teacher, Classroom = i < examples.Count ? examples[i].Classroom : c.Classroom }).ToArray();
        Courses = Dates(begin, end).Where(d => d.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday))
            .SelectMany(d => DemoCourses(d).Take(((d.DayNumber / 7) % 2) + 2).Select((c, i) => c with { Id = c.Id + "-" + c.Day, Uuid = c.Id + "-" + c.Day, CourseNumber = $"DEMO{i + 1:000}" })).ToArray();
        Courses = Courses.Select(c => c.CourseNumber == "DEMO001" && ScheduleCalendar.WeekNumber(CourseTime.Date(c.Day), term) % 3 == 0
            ? c with { Classroom = "教学楼 B203", BeginTime = "13:30", EndTime = "16:10" } : c)
            .SelectMany(c => c.CourseNumber == "DEMO001" && CourseTime.Date(c.Day).DayOfWeek == DayOfWeek.Wednesday
                ? new[] { c, c with { Id = c.Id + "-teacher2", Uuid = c.Uuid + "-teacher2", Teacher = "王雅文", TeacherId = "demo-teacher2" } } : new[] { c }).ToArray();
        ArrangementVersion++; IdentityVersion++; layouts.Clear();
    }
}
