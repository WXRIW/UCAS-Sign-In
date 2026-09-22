namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly object catalogGate = new();
    Task? catalogRead;
    readonly Dictionary<string, Task> attendanceReads = [];
    readonly Dictionary<string, CourseAttendanceSummary> attendance = [];
    readonly Dictionary<string, DateTimeOffset> attendanceUpdates = [];
    readonly Dictionary<string, string> attendanceErrors = [];
    int catalogFailures;
    DateTimeOffset? catalogRetryAt;
    readonly Dictionary<string, int> attendanceFailures = [];
    readonly Dictionary<string, DateTimeOffset> attendanceRetryAt = [];
    public IReadOnlyList<SchoolSemester> Semesters
    {
        get => semesters;
        private set { semesters = value; UpdateScheduleMetadata(); }
    }
    public SchoolSemester? SelectedSemester { get; private set; }
    public IReadOnlyList<CatalogCourse> CatalogCourses { get; private set; } = [];
    public DateTimeOffset? CatalogUpdatedAt { get; private set; }
    public string? CatalogError { get; private set; }
    public bool IsCatalogRefreshing { get { lock (catalogGate) return catalogRead is not null; } }
    public bool IsCatalogStale => CatalogUpdatedAt is null || clock.GetUtcNow() - CatalogUpdatedAt >= TimeSpan.FromMinutes(30);
    public bool ShouldRefreshCatalog => IsCatalogStale && (catalogRetryAt is null || clock.GetUtcNow() >= catalogRetryAt);
    public bool IsAttendanceRefreshing(string courseId) { lock (catalogGate) return attendanceReads.ContainsKey(courseId); }
    public bool IsAttendanceStale(string courseId) => !attendanceUpdates.TryGetValue(courseId, out var updated) || clock.GetUtcNow() - updated >= TimeSpan.FromMinutes(5);
    public bool ShouldRefreshAttendance(string courseId) => IsAttendanceStale(courseId)
        && (!attendanceRetryAt.TryGetValue(courseId, out var retryAt) || clock.GetUtcNow() >= retryAt);
    public CourseAttendanceSummary? AttendanceFor(string courseId) => attendance.GetValueOrDefault(courseId);
    public DateTimeOffset? AttendanceUpdatedAt(string courseId) => attendanceUpdates.GetValueOrDefault(courseId);
    public string? AttendanceError(string courseId) => attendanceErrors.GetValueOrDefault(courseId);

    (long Arrangement, long Identity) aliasIndexVersion = (-1, -1);
    readonly Dictionary<string, List<string>> aliasIndex = [];
    IEnumerable<string> ProvenAliases(string courseId)
    {
        var version = (ArrangementVersion, IdentityVersion);
        if (aliasIndexVersion != version)
        {
            aliasIndex.Clear();
            var catalogCourses = AllCatalogCourses.ToArray();
            foreach (var group in Courses.Where(c => c.CourseId is not null).GroupBy(c => c.CourseId!))
            {
                var targets = group.Select(c => CourseIdentity.Resolve(c, Semesters, catalogCourses)?.Id).Distinct().Take(2).ToArray();
                if (targets.Length != 1 || targets[0] is not { } target || target == group.Key) continue;
                if (!aliasIndex.TryGetValue(target, out var aliases)) aliasIndex[target] = aliases = [];
                aliases.Add(group.Key);
            }
            aliasIndexVersion = version;
        }
        return aliasIndex.TryGetValue(courseId, out var result) ? result : [];
    }
    public CoursePreferences CoursePreferencesFor(string courseId)
    {
        if (Preferences.Courses.Count == 0) return new();
        var values = ProvenAliases(courseId).Append(courseId).Select(id => Preferences.Courses.GetValueOrDefault(id)).OfType<CoursePreferences>().ToArray();
        return values.Length == 0 ? new() : CourseIdentity.MergePreferences(values);
    }
    public bool IsSignInDisabled(string? courseId) => courseId is not null && CoursePreferencesFor(courseId).SignInDisabled;
    public bool EffectiveConfirmation(string? courseId) => !IsSignInDisabled(courseId) && (courseId is null
        ? Preferences.ConfirmBeforeSign : CoursePreferences.Resolve(CoursePreferencesFor(courseId).Confirmation, Preferences.ConfirmBeforeSign));
    public bool EffectiveAutoSign(string? courseId) => !IsSignInDisabled(courseId) && (courseId is null
        ? Preferences.AutoSignEnabled : CoursePreferences.Resolve(CoursePreferencesFor(courseId).AutoSign, Preferences.AutoSignEnabled));
    public bool EffectiveReminders(string? courseId) => courseId is null ? Preferences.RemindersEnabled
        : CoursePreferences.Resolve(CoursePreferencesFor(courseId).Reminders, Preferences.RemindersEnabled);
    public int EffectiveReminderLeadMinutes(string? courseId) => courseId is not null && CoursePreferencesFor(courseId).ReminderLeadMinutes is { } lead
        ? lead : Preferences.ReminderLeadMinutes;
    public bool NeedsAutoSignService => Preferences.AutoSignEnabled || Preferences.Courses.Any(x => !x.Value.SignInDisabled && x.Value.AutoSign == PreferenceOverride.Enabled);

    void ResetCatalogState()
    {
        lock (catalogGate) { catalogRead = null; attendanceReads.Clear(); }
        Semesters = []; SelectedSemester = null; CatalogCourses = []; CatalogUpdatedAt = null; CatalogError = null;
        attendance.Clear(); attendanceUpdates.Clear(); attendanceErrors.Clear();
        catalogFailures = 0; catalogRetryAt = null; attendanceFailures.Clear(); attendanceRetryAt.Clear();
    }

    void SetupDemoCatalog(SchoolSemester term)
    {
        semesters = [term]; UpdateScheduleMetadata(false); SelectedSemester ??= term;
        var names = new[] { "矩阵分析", "高级人工智能", "学术英语写作", "计算机体系结构", "模式识别", "自然语言处理", "现代密码学", "软件工程", "并行计算", "数据科学导论", "机器学习", "数字图像处理", "科技伦理", "创新创业", "学术交流英语", "随机过程", "高等数值分析", "跨学科前沿专题（长课程名称演示）" };
        CatalogCourses = names.Select((name, i) => new CatalogCourse(i switch { 0 => "demo-matrix", 1 => "demo-ai", 2 => "demo-english", _ => "demo-" + (i + 1) },
            $"DEMO{i + 1:000}", name, i % 5 == 0 ? "" : $"演示教师{i % 6 + 1}", i % 4 == 0 ? null : $"教学楼 {(char)('A' + i % 4)}{101 + i}", term.Id, term.BeginDate, term.EndDate, 16, i % 12)).ToArray();
        CatalogUpdatedAt = clock.GetUtcNow(); CatalogError = null;
    }

    public Task RefreshCatalogAsync(bool force = false)
    {
        if (IsDemo) { EnsureDemoSchedule(); Notify(); return Task.CompletedTask; }
        if (ActiveAccount is not { } account || catalog is null) return Task.CompletedTask;
        lock (catalogGate)
        {
            if (catalogRead is not null) return catalogRead;
            var epoch = Generation;
            catalogRead = CompleteCatalogRefreshAsync(account, epoch, force);
            Notify();
            return catalogRead;
        }
    }

    async Task CompleteCatalogRefreshAsync(StoredAccount account, Guid epoch, bool force)
    {
        await Task.Yield();
        try
        {
            await RefreshCatalogCoreAsync(account, epoch, force);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation)
            {
                CatalogError = e.Message;
                if (!force)
                {
                    catalogFailures++;
                    catalogRetryAt = clock.GetUtcNow() + TimeSpan.FromMinutes(catalogFailures == 1 ? 1 : catalogFailures == 2 ? 2 : 5);
                }
            }
        }
        finally { if (epoch == Generation) { lock (catalogGate) catalogRead = null; IdentityVersion++; Notify(); } }
    }

    async Task RefreshCatalogCoreAsync(StoredAccount account, Guid epoch, bool force)
    {
        var now = clock.GetUtcNow();
        if (Semesters.Count == 0)
        {
            var cached = await catalog!.LoadSemestersAsync(account.Id, lifetime.Token);
            if (epoch != Generation) return;
            if (cached is { Version: SemesterCache.CurrentVersion } && cached.AccountId == account.Id && cached.Semesters.Count > 0)
            {
                Semesters = cached.Semesters; SelectedSemester = SelectCurrentSemester(Semesters, now);
            }
        }
        if (SelectedSemester is { } cachedSemester)
        {
            var earlyCatalog = await catalog!.LoadCatalogAsync(account.Id, cachedSemester.Id, lifetime.Token);
            if (epoch != Generation) return;
            if (earlyCatalog is { Version: CourseCatalogCache.CurrentVersion } && earlyCatalog.AccountId == account.Id
                && earlyCatalog.SemesterId == cachedSemester.Id && earlyCatalog.Courses.All(x => x.SemesterId == cachedSemester.Id))
            { CatalogCourses = earlyCatalog.Courses; CatalogUpdatedAt = earlyCatalog.UpdatedAt; }
        }
        if (!force && catalogRetryAt is { } retryAt && now < retryAt) return;
        var semestersFresh = false;
        var semesterCache = await catalog!.LoadSemestersAsync(account.Id, lifetime.Token);
        if (semesterCache is { Version: SemesterCache.CurrentVersion } && semesterCache.AccountId == account.Id)
            semestersFresh = now - semesterCache.UpdatedAt < TimeSpan.FromHours(24);
        if (force || Semesters.Count == 0 || !semestersFresh)
        {
            var session = account.Session;
            IReadOnlyList<SchoolSemester> values;
            try { values = await school.SemestersAsync(session, lifetime.Token); }
            catch (SchoolException e) when (e.IsSessionExpired)
            {
                var recovered = await RecoverAsync(session, epoch);
                if (recovered is null) throw;
                session = recovered; values = await school.SemestersAsync(session, lifetime.Token);
            }
            if (epoch != Generation) return;
            Semesters = values; SelectedSemester = SelectCurrentSemester(values, now);
            await catalog.SaveSemestersAsync(account.Id, new(SemesterCache.CurrentVersion, account.Id, now, values.ToList()), lifetime.Token);
            account = ActiveAccount ?? account;
        }
        if (SelectedSemester is not { } semester) throw new SchoolException("SEMESTER_CURRENT_UNKNOWN", "无法确定当前学期，请稍后重试");
        var cachedCatalog = await catalog.LoadCatalogAsync(account.Id, semester.Id, lifetime.Token);
        if (epoch != Generation) return;
        if (cachedCatalog is { Version: CourseCatalogCache.CurrentVersion } && cachedCatalog.AccountId == account.Id && cachedCatalog.SemesterId == semester.Id
            && cachedCatalog.Courses.All(x => x.SemesterId == semester.Id))
        {
            CatalogCourses = cachedCatalog.Courses; CatalogUpdatedAt = cachedCatalog.UpdatedAt;
        }
        if (!force && cachedCatalog is not null && now - cachedCatalog.UpdatedAt < TimeSpan.FromMinutes(30))
        { CatalogError = null; catalogFailures = 0; catalogRetryAt = null; return; }
        IReadOnlyList<CatalogCourse> courses;
        try { courses = await school.CatalogCoursesAsync(account.Session, semester.Id, lifetime.Token); }
        catch (SchoolException e) when (e.IsSessionExpired)
        {
            var session = await RecoverAsync(account.Session, epoch);
            if (session is null) throw;
            courses = await school.CatalogCoursesAsync(session, semester.Id, lifetime.Token);
        }
        if (epoch != Generation) return;
        if (courses.Any(x => x.SemesterId != semester.Id)) throw new SchoolException("COURSE_CATALOG_SEMESTER_MISMATCH", "学校返回了其他学期的课程，请重新刷新");
        CatalogCourses = courses; CatalogUpdatedAt = now; CatalogError = null;
        catalogFailures = 0; catalogRetryAt = null;
        await catalog.SaveCatalogAsync(account.Id, semester.Id, new(CourseCatalogCache.CurrentVersion, account.Id, semester.Id, now, courses.ToList()), lifetime.Token);
    }

    static SchoolSemester SelectCurrentSemester(IReadOnlyList<SchoolSemester> values, DateTimeOffset now)
    {
        var marked = values.Where(x => x.IsCurrent).ToList(); if (marked.Count == 1) return marked[0];
        var day = CourseTime.DayKey(DateOnly.FromDateTime(now.ToOffset(TimeSpan.FromHours(8)).DateTime));
        var matching = values.Where(x => string.CompareOrdinal(x.BeginDate, day) <= 0 && string.CompareOrdinal(day, x.EndDate) <= 0).ToList();
        if (matching.Count == 1) return matching[0];
        throw new SchoolException("SEMESTER_CURRENT_UNKNOWN", "无法唯一确定当前学期，请稍后重试");
    }

    public Task RefreshAttendanceAsync(string courseId, bool force = false)
    {
        var courseSemester = AllCatalogCourses.FirstOrDefault(c => c.Id == courseId)?.SemesterId ?? SelectedSemester?.Id;
        if (string.IsNullOrWhiteSpace(courseId) || courseSemester is null) return Task.CompletedTask;
        if (IsDemo)
        {
            var records = Courses.Where(x => x.CourseId == courseId).Select(x => new CourseAttendance(x.Id, courseId, x.Id, x.Day, x.BeginTime, x.EndTime, x.Signed)).ToArray();
            attendance[courseId] = new(records.Count(x => x.Signed), records.Count(x => !x.Signed), records); attendanceUpdates[courseId] = clock.GetUtcNow(); Notify(); return Task.CompletedTask;
        }
        if (ActiveAccount is not { } account || catalog is null) return Task.CompletedTask;
        lock (catalogGate)
        {
            if (attendanceReads.TryGetValue(courseId, out var existing)) return existing;
            var task = CompleteAttendanceRefreshAsync(account, courseSemester, courseId, Generation, force);
            attendanceReads[courseId] = task; Notify(); return task;
        }
    }

    async Task CompleteAttendanceRefreshAsync(StoredAccount account, string semesterId, string courseId, Guid epoch, bool force)
    {
        await Task.Yield();
        try
        {
            var now = clock.GetUtcNow(); var cached = await catalog!.LoadAttendanceAsync(account.Id, semesterId, courseId, lifetime.Token);
            if (epoch != Generation) return;
            if (cached is { Version: CourseAttendanceCache.CurrentVersion } && cached.AccountId == account.Id && cached.SemesterId == semesterId && cached.CourseId == courseId
                && cached.Summary.Records.All(x => x.CourseId == courseId))
            { attendance[courseId] = cached.Summary; attendanceUpdates[courseId] = cached.UpdatedAt; }
            if (!force && attendanceRetryAt.TryGetValue(courseId, out var retryAt) && now < retryAt) return;
            if (!force && cached is not null && now - cached.UpdatedAt < TimeSpan.FromMinutes(5))
            { attendanceErrors.Remove(courseId); attendanceFailures.Remove(courseId); attendanceRetryAt.Remove(courseId); return; }
            CourseAttendanceSummary summary;
            try { summary = await school.CourseAttendanceAsync(account.Session, courseId, lifetime.Token); }
            catch (SchoolException e) when (e.IsSessionExpired)
            {
                var session = await RecoverAsync(account.Session, epoch);
                if (session is null) throw;
                summary = await school.CourseAttendanceAsync(session, courseId, lifetime.Token);
            }
            if (epoch != Generation || summary.Records.Any(x => x.CourseId != courseId)) return;
            attendance[courseId] = summary; attendanceUpdates[courseId] = now; attendanceErrors.Remove(courseId);
            attendanceFailures.Remove(courseId); attendanceRetryAt.Remove(courseId);
            await catalog.SaveAttendanceAsync(account.Id, semesterId, courseId, new(CourseAttendanceCache.CurrentVersion, account.Id, semesterId, courseId, now, summary), lifetime.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation)
            {
                attendanceErrors[courseId] = e.Message;
                if (!force)
                {
                    var failures = attendanceFailures.GetValueOrDefault(courseId) + 1;
                    attendanceFailures[courseId] = failures;
                    attendanceRetryAt[courseId] = clock.GetUtcNow() + TimeSpan.FromMinutes(failures == 1 ? 1 : failures == 2 ? 2 : 5);
                }
            }
        }
        finally { if (epoch == Generation) { lock (catalogGate) attendanceReads.Remove(courseId); Notify(); } }
    }

    void InvalidateAttendance(string? courseId)
    {
        if (courseId is null) return; attendanceUpdates.Remove(courseId);
    }

    public async Task SetCoursePreferencesAsync(string courseId, CoursePreferences preferences)
    {
        if (string.IsNullOrWhiteSpace(courseId)) return;
        preferences = preferences.Normalized();
        if (IsDemo)
        {
            var values = new Dictionary<string, CoursePreferences>(demoPreferences.Courses);
            foreach (var alias in ProvenAliases(courseId)) values.Remove(alias);
            if (preferences == new CoursePreferences()) values.Remove(courseId); else values[courseId] = preferences;
            demoPreferences = new(demoPreferences.AutoSignEnabled, demoPreferences.RemindersEnabled, demoPreferences.ConfirmBeforeSign, demoPreferences.ReminderLeadMinutes, values); Notify(); return;
        }
        if (!CanChangeAccount || ActiveAccount is not { } account) return;
        var epoch = Generation;
        var permissionGranted = preferences.Reminders != PreferenceOverride.Enabled && preferences.AutoSign != PreferenceOverride.Enabled
            || await reminders.RequestPermissionAsync();
        await mutations.WaitAsync();
        try
        {
            if (epoch != Generation || ActiveAccount is not { } current) return;
            IsBusy = true; Notify();
            var values = new Dictionary<string, CoursePreferences>(current.Preferences.Courses);
            foreach (var alias in ProvenAliases(courseId)) values.Remove(alias);
            if (preferences == new CoursePreferences()) values.Remove(courseId); else values[courseId] = preferences;
            var p = current.Preferences;
            await CommitAsync(Updated(current with { Settings = new(p.AutoSignEnabled, p.RemindersEnabled, p.ConfirmBeforeSign, p.ReminderLeadMinutes, values) }));
            await UpdateRemindersAsync();
            if (!permissionGranted) Message = "偏好已保存；通知权限未开启，可在系统设置中允许通知";
        }
        finally { IsBusy = false; mutations.Release(); Notify(); }
    }
}
