namespace UCASSignIn.Core;

// Platform-neutral account workflows. Views and observable UI state live in each application.
// Call public operations on the platform UI context; asynchronous completions retain that context.
public sealed partial class AccountCoordinator(ISchoolClient school, IAccountStore accounts, ICourseStore cache,
    IRecordStore records, IReminderScheduler reminders, TimeProvider? timeProvider = null, ICourseCatalogStore? catalogStore = null)
{
    readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    readonly ICourseCatalogStore? catalog = catalogStore ?? cache as ICourseCatalogStore;
    readonly SemaphoreSlim mutations = new(1);
    readonly SemaphoreSlim reminderGate = new(1);
    readonly object recoveryGate = new();
    readonly object readGate = new();
    AccountVault vault = AccountVault.Empty;
    CancellationTokenSource lifetime = new();
    readonly HashSet<string> freshDays = [];
    readonly Dictionary<string, DateTimeOffset> courseUpdates = [];
    readonly Dictionary<string, string?> courseNotices = [];
    readonly HashSet<string> autoAttempts = [];
    readonly HashSet<string> signPreparations = [];
    bool AddSignPreparation(string key) { lock (signPreparations) return signPreparations.Add(key); }
    void RemoveSignPreparation(string key) { lock (signPreparations) signPreparations.Remove(key); }
    readonly HashSet<string> recoveryAttempts = [];
    readonly Dictionary<string, (Task Task, long Revision)> reads = [];
    Task<SchoolSession?>? recovery;
    bool loaded, paused;
    long requestSequence;
    readonly Dictionary<string, long> versions = [];
    public event Action? Changed;
    public Guid Generation { get; private set; } = Guid.NewGuid();
    public bool IsDemo
    {
        get; private set;
    }
    public bool IsBusy
    {
        get; private set;
    }
    public bool IsRecovering
    {
        get; private set;
    }
    public bool IsRefreshing
    {
        get
        {
            lock (readGate)
                return reads.Count > 0;
        }
    }
    public bool IsForeground
    {
        get; set;
    }
    public bool IsLoadingCourses(DateOnly date)
    {
        lock (readGate)
            return reads.ContainsKey(CourseTime.DayKey(date));
    }
    public string? Message
    {
        get; private set;
    }
    public SignInFailure? SignInError { get; private set; }
    public DateTimeOffset? LastSyncAt
    {
        get; private set;
    }
    AccountPreferences demoPreferences = new();
    public AccountPreferences Preferences => IsDemo ? demoPreferences : ActiveAccount?.Preferences ?? new();
    public DateOnly SelectedDate { get; private set; } = CourseTime.Today(timeProvider);
    public IReadOnlyList<Course> Courses { get; private set; } = [];
    public IReadOnlyList<AttendanceRecord> Records { get; private set; } = [];
    public IReadOnlyList<StoredAccount> Accounts => vault.Accounts;
    public StoredAccount? ActiveAccount => vault.Accounts.FirstOrDefault(a => a.Id == vault.ActiveAccountId);
    public bool IsConnected => IsDemo || ActiveAccount is not null;
    public bool CanChangeAccount => !IsBusy && !IsRecovering;
    public IReadOnlyList<Course> DisplayCourses(DateOnly date)
    {
        var day = CourseTime.DayKey(date);
        return Courses.Where(c => c.Day == day).ToList();
    }
    public bool IsFresh(Course course) => IsDemo || freshDays.Contains(CourseTime.NormalizeDay(course.Day) ?? "");
    public bool IsCached(DateOnly date) => !IsDemo && courseUpdates.ContainsKey(CourseTime.DayKey(date)) && !freshDays.Contains(CourseTime.DayKey(date));
    public DateTimeOffset? LastUpdated(DateOnly date) => courseUpdates.TryGetValue(CourseTime.DayKey(date), out var updated) ? updated : null;
    public string? CourseNotice(DateOnly date) => courseNotices.GetValueOrDefault(CourseTime.DayKey(date));
    public bool CanSign(Course c) => IsConnected && !IsBusy && !IsRecovering && !paused && ActiveAccount?.RequiresLogin != true
        && !IsSignInDisabled(PreferenceId(c))
        && AttendanceStatusFor(c) == AttendanceStatus.Unsigned
        && (IsDemo || dayVerifiedAt.ContainsKey(c.Day)) && IsFresh(c) && Courses.Any(x => x.Id == c.Id && x.Day == c.Day && !x.Signed);
    void Notify() => Changed?.Invoke();
    public void SetMessage(string? text)
    {
        Message = text;
        Notify();
    }
    public void AcknowledgeSignInError(Guid id)
    {
        if (SignInError?.Id != id) return;
        SignInError = null;
        Notify();
    }
    void ReportSignInError(string day, string message)
    {
        Message = null;
        courseNotices.Remove(day);
        SignInError = new(Guid.NewGuid(), message);
        Notify();
    }
    public async Task InitializeAsync()
    {
        if (loaded)
            return;
        vault = await accounts.LoadAsync();
        vault.Validate();
        await LoadHistoryRetentionAsync();
        loaded = true;
        if (ActiveAccount is { } a)
        {
            await ActivateAsync(a);
        }
        else { await MaintainHistoryRetentionIfDueAsync(true); Notify(); }
    }
    public async Task InitializeDemoAsync()
    {
        if (!loaded) { vault = await accounts.LoadAsync(); vault.Validate(); await LoadHistoryRetentionAsync(); loaded = true; }
        await EnterDemoAsync();
    }
    async Task CommitAsync(AccountVault next)
    {
        await accounts.SaveAsync(next);
        vault = next;
    }
    AccountVault Updated(StoredAccount a, bool active = false) => new(1, vault.Accounts.Where(x => x.Id != a.Id).Append(a).ToList(), active ? a.Id : vault.ActiveAccountId);
    public async Task LoginAsync(string username, string password, bool remember, string? expectedAccountId = null)
    {
        if (!CanChangeAccount)
            return;
        await mutations.WaitAsync();
        IsBusy = true;
        Notify();
        try
        {
            StoredAccount next;
            try
            {
                var session = await school.LoginAsync(username, password);
                if (expectedAccountId is not null && session.StudentNo != expectedAccountId)
                    throw new SchoolException("ACCOUNT_MISMATCH", "请使用此账户对应的学校身份登录");
                var prior = vault.Accounts.FirstOrDefault(a => a.Id == session.StudentNo);
                next = new(session, remember ? new(username.Trim(), password) : null, username.Trim(), clock.GetUtcNow(), false, prior?.Preferences);
                await CommitAsync(Updated(next, true));
            }
            finally { mutations.Release(); }
            await ActivateAsync(next);
        }
        finally { IsBusy = false; Notify(); }
    }
    public async Task SwitchAsync(string id)
    {
        if (!CanChangeAccount || (!IsDemo && ActiveAccount?.Id == id))
            return;
        await mutations.WaitAsync();
        IsBusy = true;
        Notify();
        try
        {
            StoredAccount a;
            try
            {
                a = vault.Accounts.First(x => x.Id == id) with { LastUsedAt = clock.GetUtcNow() };
                await CommitAsync(Updated(a, true));
            }
            finally { mutations.Release(); }
            await ActivateAsync(a);
        }
        finally { IsBusy = false; Notify(); }
    }
    async Task ResetAsync()
    {
        ResetSchedule();
        ResetAttendanceState();
        lifetime.Cancel();
        lifetime.Dispose();
        lifetime = new();
        Generation = Guid.NewGuid();
        recovery = null;
        IsRecovering = false;
        paused = false;
        freshDays.Clear();
        courseUpdates.Clear();
        courseNotices.Clear();
        signPreparations.Clear();
        reads.Clear();
        versions.Clear();
        Courses = [];
        Records = [];
        loadedHistoryAccountId = null;
        LastSyncAt = null;
        SelectedDate = CourseTime.Today(clock);
        school.ClearClock();
        Message = null;
        SignInError = null;
        autoSignExecutions.Clear(); autoSignQueryStartedAt.Clear();
        pendingAutoSignResults.Clear();
        AutoSignResultRevision = 0;
        autoSignQuerySchoolStartedAt.Clear(); autoSignQuerySchoolVerifiedAt.Clear(); autoSignVerifiedQuerySequence.Clear();
        autoSignSchoolOffset = null; autoSignSchoolSample = null; autoSignActivationMarks.Clear();
        autoSignClockRetryTimestamp = null;
        AutoSignError = null; autoSignNetworkIssue = false; autoSignStoreAvailable = autoSignStore is not null;
        ResetCatalogState();
        await UpdateRemindersAsync();
    }
    async Task ActivateAsync(StoredAccount a)
    {
        IsDemo = false;
        await ResetAsync();
        var epoch = Generation;
        RestoreAccountChecks(a);
        paused = a.RequiresLogin;
        Records = await records.LoadAsync(a.Id, lifetime.Token);
        if (epoch != Generation)
            return;
        await LoadAttendanceStateAsync(a.Id, epoch);
        if (epoch != Generation) return;
        await LoadAutoSignAsync(a.Id, epoch);
        if (epoch != Generation) return;
        loadedHistoryAccountId = a.Id;
        await MaintainActivatedHistoryAsync(epoch);
        if (epoch != Generation) return;
        await UnifyAutoSignPreferencesAsync(epoch);
        if (epoch != Generation) return;
        await LoadScheduleCacheAsync(a, epoch);
        if (epoch != Generation) return;
        if (checkedDays.Contains(CourseTime.DayKey(SelectedDate))) await LoadCacheAsync(a.Id, SelectedDate, epoch);
        if (epoch != Generation) return;
        await EnterDayAsync(SelectedDate);
        if (epoch == Generation && scheduleStore is not null) { scheduleEntered = true; await RefreshScheduleAsync(false, onlyDue: true); }
    }
    public async Task EnterDemoAsync()
    {
        if (!CanChangeAccount)
            return;
        IsDemo = true;
        demoPreferences = new();
        await ResetAsync();
        EnsureDemoSchedule();
        Notify();
    }
    public async Task ExitDemoAsync()
    {
        if (ActiveAccount is { } a)
        {
            await ActivateAsync(a);
        }
        else
        {
            IsDemo = false;
            await ResetAsync();
            Notify();
        }
    }
    public async Task SelectDateAsync(DateOnly date)
    {
        SelectedDate = date;
        if (IsDemo)
        {
            EnsureDemoSchedule();
            Notify();
            return;
        }
        if (ActiveAccount is not null)
        {
            if (ScheduleMode == ScheduleMode.Week) { var pending = RefreshScheduleAsync(false); Notify(); await pending; }
            else { await EnterDayAsync(date); Notify(); }
        }
        else
            Notify();
    }
    async Task LoadCacheAsync(string id, DateOnly date, Guid epoch)
    {
        var value = await cache.LoadAsync(id, CourseTime.DayKey(date), lifetime.Token);
        if (epoch != Generation || value is null)
            return;
        if (courseUpdates.TryGetValue(CourseTime.DayKey(date), out var updated) && (value.WriteSequence > 0
            ? successfulWrites.GetValueOrDefault(CourseTime.DayKey(date)) >= value.WriteSequence : updated >= value.UpdatedAt)) return;
        Merge(value.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == CourseTime.DayKey(date)), CourseTime.DayKey(date));
        courseUpdates[CourseTime.DayKey(date)] = value.UpdatedAt;
        requestSequence = Math.Max(requestSequence, value.WriteSequence);
        successfulWrites[CourseTime.DayKey(date)] = value.WriteSequence;
    }
    void Merge(IEnumerable<Course> courses, string day)
    {
        var incoming = courses.Select(c => CourseIdentity.PreserveFields(c with { Day = CourseTime.NormalizeDay(c.Day) ?? day },
            Courses.FirstOrDefault(x => x.Day == day && x.Id == c.Id))).Select(ProjectAttendance).ToList();
        var days = incoming.Select(c => c.Day).Append(day).ToHashSet();
        var previous = Courses.Where(c => days.Contains(c.Day)).ToArray();
        var changed = !CourseIdentity.SameArrangement(previous, incoming);
        if (!changed && previous.OrderBy(c => c.Id).Select(c => c.Signed).SequenceEqual(incoming.OrderBy(c => c.Id).Select(c => c.Signed))) return;
        Courses = Courses.Where(c => !days.Contains(c.Day)).Concat(incoming).OrderBy(c => c.Start).ToList();
        if (changed) { ArrangementVersion++; }
    }
    void MergeDemo(DateOnly date)
    {
        var day = CourseTime.DayKey(date);
        var existing = Courses.Where(c => c.Day == day).ToList();
        Merge(existing.Count > 0 ? existing : DemoCourses(date), day);
    }
    public Task RefreshAsync(DateOnly? date = null)
    {
        var target = date ?? SelectedDate;
        if (IsDemo)
        {
            EnsureDemoSchedule();
            Notify();
            return Task.CompletedTask;
        }
        if (ActiveAccount is not { } account)
            return Task.CompletedTask;
        var day = CourseTime.DayKey(target);
        lock (readGate)
        {
            if (reads.TryGetValue(day, out var existing))
                return JoinDayAsync(existing.Task, existing.Revision, target, Generation);
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var sequence = ++requestSequence;
            versions[day] = sequence;
            autoSignQueryStartedAt[day] = clock.GetUtcNow();
            autoSignQuerySchoolStartedAt[day] = AutoSignNow;
            reads[day] = (completion.Task, sequence);
            var epoch = Generation;
            var ct = lifetime.Token;
            Notify();
            _ = CompleteReadAsync(completion, account, target, epoch, sequence, ct);
            return completion.Task;
        }
    }
    async Task CompleteReadAsync(TaskCompletionSource completion, StoredAccount account, DateOnly date, Guid epoch, long sequence, CancellationToken ct)
    {
        try
        {
            await RefreshCoreAsync(account, date, epoch, sequence, ct);
            completion.TrySetResult();
        }
        catch (Exception e) { completion.TrySetException(e); }
    }
    async Task RefreshCoreAsync(StoredAccount account, DateOnly date, Guid epoch, long sequence, CancellationToken ct)
    {
        var day = CourseTime.DayKey(date);
        try
        {
            if (epoch != Generation || ct.IsCancellationRequested) return;
            if (!freshDays.Contains(day))
            {
                await LoadCacheAsync(account.Id, date, epoch);
                if (epoch != Generation || ct.IsCancellationRequested) return;
                Notify();
            }
            if (account.RequiresLogin || paused)
            {
                Message = "登录已过期，请在账户页重新验证";
                courseNotices[day] = Message;
                return;
            }
            CourseQueryResult result;
            try
            {
                result = await school.DailyScheduleAsync(account.Session, date, ct);
            }
            catch (SchoolException e) when (e.IsSessionExpired)
            {
                var session = await RecoverAsync(account.Session, epoch);
                if (session is null)
                    return;
                result = await school.DailyScheduleAsync(session, date, ct);
            }
            if (epoch != Generation || paused || versions.GetValueOrDefault(day) != sequence)
                return;
            autoSignVerifiedQuerySequence[day] = sequence;
            autoSignQuerySchoolVerifiedAt[day] = AutoSignNow;
            result = result with { Courses = result.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == day).Select(c => CourseIdentity.PreserveFields(c with { Day = day }, Courses.FirstOrDefault(x => x.Day == day && x.Id == c.Id))).ToArray(), FromWeeklyFallback = false };
            foreach (var course in result.Courses) ObserveAttendance(course, AttendanceSource.Daily, sequence);
            await ReconcileAutoSignSuccessAsync(result.Courses, epoch);
            if (epoch != Generation) return;
            dayVerifiedAt[day] = clock.GetUtcNow();
            invalidatedDays.Remove(day);
            await SaveAttendanceStateAsync(epoch);
            if (epoch != Generation || versions.GetValueOrDefault(day) != sequence) return;
            result = result with { Courses = result.Courses.Select(ProjectAttendance).ToArray() };
            var arrangementChanged = courseUpdates.ContainsKey(day) && !CourseIdentity.SameArrangement(Courses.Where(c => c.Day == day), result.Courses);
            var updatedAt = clock.GetUtcNow();
            await cache.SaveAsync(account.Id, day, new(result.Courses.ToList(), updatedAt, false, sequence), ct);
            if (epoch != Generation || paused || versions.GetValueOrDefault(day) != sequence)
                return;
            var previousAutoSignPlans = arrangementChanged ? AutoSignPlans.ToDictionary(x => x.Key) : null;
            Merge(result.Courses, day);
            if (previousAutoSignPlans is not null) await RecordAutoSignPlanChangesAsync(previousAutoSignPlans, epoch);
            successfulWrites[day] = sequence;
            checkedDays.Add(day); retryAt.Remove("day:" + day); failures.Remove("day:" + day);
            freshDays.Add(day);
            courseUpdates[day] = updatedAt;
            courseNotices.Remove(day);
            LastSyncAt = updatedAt;
            Message = null;
            if (arrangementChanged) ScheduleArrangementChanged();
            await UpdateRemindersAsync();
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation)
            {
                freshDays.Remove(day);
                checkedDays.Remove(day);
                RetryLater("day:" + day);
                Message = e.Message;
                courseNotices[day] = e.Message;
                if (e is SchoolException se && se.IsSessionExpired)
                    await RequireLoginAsync(account.Id, epoch);
            }
        }
        finally { if (epoch == Generation) { lock (readGate) reads.Remove(day); Notify(); } }
    }
    Task<SchoolSession?> RecoverAsync(SchoolSession failed, Guid epoch)
    {
        lock (recoveryGate)
        {
            if (epoch != Generation)
                return Task.FromResult<SchoolSession?>(null);
            if (recovery is not null)
                return recovery;
            if (ActiveAccount is { } current && current.Session.SessionId != failed.SessionId)
                return Task.FromResult<SchoolSession?>(current.Session);
            IsRecovering = true;
            var completion = new TaskCompletionSource<SchoolSession?>(TaskCreationOptions.RunContinuationsAsynchronously);
            recovery = completion.Task;
            _ = CompleteRecoveryAsync(completion, failed, epoch);
            return completion.Task;
        }
    }
    async Task CompleteRecoveryAsync(TaskCompletionSource<SchoolSession?> completion, SchoolSession failed, Guid epoch)
    {
        try
        {
            completion.TrySetResult(await RecoverCoreAsync(failed, epoch));
        }
        catch (Exception e) { completion.TrySetException(e); }
    }
    async Task<SchoolSession?> RecoverCoreAsync(SchoolSession failed, Guid epoch)
    {
        paused = true;
        freshDays.Clear();
        checkedDays.Clear();
        Notify();
        try
        {
            await UpdateRemindersAsync();
            var a = ActiveAccount;
            if (a?.Credentials is not { } credential || a.RequiresLogin || !recoveryAttempts.Add(a.Id + "|" + failed.SessionId))
            {
                await RequireLoginAsync(failed.StudentNo, epoch);
                return null;
            }
            var result = await school.LoginAsync(credential.Username, credential.Password, lifetime.Token);
            if (epoch != Generation)
                return null;
            if (result.StudentNo != failed.StudentNo)
                throw new SchoolException("ACCOUNT_MISMATCH", "保存的凭据与账户不符，请重新登录");
            await mutations.WaitAsync(lifetime.Token);
            try
            {
                if (epoch != Generation || ActiveAccount is not { } current || current.Id != failed.StudentNo) return null;
                await CommitAsync(Updated(current with { Session = result, RequiresLogin = false }));
            }
            finally { mutations.Release(); }
            paused = false;
            scheduleSessionId = result.SessionId;
            return result;
        }
        catch (Exception) { if (epoch == Generation) await RequireLoginAsync(failed.StudentNo, epoch); return null; }
        finally { lock (recoveryGate) { if (epoch == Generation) { recovery = null; IsRecovering = false; Notify(); } } }
    }
    async Task RequireLoginAsync(string id, Guid epoch)
    {
        if (epoch != Generation || ActiveAccount is not { } a || a.Id != id)
            return;
        paused = true;
        freshDays.Clear();
        Message = "登录已过期，请在账户页重新验证";
        try
        {
            await mutations.WaitAsync(lifetime.Token);
            try
            {
                if (epoch != Generation || ActiveAccount is not { } current || current.Id != id) return;
                await CommitAsync(Updated(current with { RequiresLogin = true }));
            }
            finally { mutations.Release(); }
        }
        catch (Exception e) { Message += "；账户状态保存失败：" + e.Message; }
        await UpdateRemindersAsync();
    }
    public async Task SignAsync(Course course, Guid expectedGeneration, bool automatically = false)
    {
        if (expectedGeneration != Generation || !CanSign(course)) return;
        if (automatically && !IsDemo && !CachePolicy.Fresh(dayVerifiedAt.GetValueOrDefault(course.Day), clock.GetUtcNow(), TimeSpan.FromSeconds(60)))
            await EnterDayAsync(CourseTime.Date(course.Day));
        var preparationKey = course.Day + "|" + course.Id;
        if (expectedGeneration != Generation || !CanSign(course) || automatically && !AutoSignAllowed(course) || !AddSignPreparation(preparationKey))
            return;
        var epoch = Generation;
        var id = ActiveAccount?.Id ?? "demo";
        var attemptKey = AutoSignPlanner.Key(id, course);
        if (!automatically && autoSignStoreAvailable && (autoSignExecutions.GetValueOrDefault(attemptKey)?.HasExecutionActivity == true
            || AutoSignPlans.Any(x => x.Key == attemptKey && x.IsParticipating)))
            await SetAutoSignStageAsync(autoSignExecutions.GetValueOrDefault(attemptKey) ?? AutoSignExecution.New(attemptKey, clock.GetUtcNow()),
                AutoSignStage.Skipped, "用户已手动接管", epoch);
        var authorized = false;
        var submitted = false;
        bool Authorize()
        {
            var current = Courses.FirstOrDefault(x => x.Id == course.Id && x.Day == course.Day);
            if (epoch != Generation || paused || ActiveAccount?.RequiresLogin == true || current is null || current.Signed
                || AttendanceStatusFor(current) != AttendanceStatus.Unsigned
                || automatically && !CachePolicy.Fresh(dayVerifiedAt.GetValueOrDefault(course.Day), clock.GetUtcNow(), TimeSpan.FromSeconds(60))
                || !IsFresh(current) || IsSignInDisabled(PreferenceId(current)) || automatically && !AutoSignAllowed(current)) return false;
            authorized = true;
            submitted = !automatically;
            IsBusy = true;
            if (automatically) autoAttempts.Add(attemptKey);
            Notify();
            return true;
        }
        Notify();
        async Task<bool> ReserveAutomaticSubmission(DateTimeOffset schoolNow)
        {
            if (!await ReserveAutoSignSubmissionAsync(course, epoch, schoolNow)) return false;
            submitted = true;
            return true;
        }
        try
        {
            SignResult result;
            if (IsDemo)
            {
                if (!Authorize()) return;
                result = new(SignOutcome.Signed, "演示签到成功 · 未向学校提交");
            }
            else result = await school.SignAsync(course, ActiveAccount!.Session, lifetime.Token, Authorize,
                authorizeAt: automatically ? ReserveAutomaticSubmission : null);
            if (epoch != Generation)
                return;
            Records = new[] { new AttendanceRecord(course.Name, clock.GetUtcNow(), result.Message, result.Outcome == SignOutcome.Signed, course.CourseId, course.Id) }.Concat(Records).ToList();
            if (result.Outcome == SignOutcome.Signed)
            {
                invalidatedDays.Add(course.Day);
                InvalidateAttendance(PreferenceId(course));
                Courses = Courses.Select(c => c.Id == course.Id && c.Day == course.Day ? c with { Signed = true } : c).ToList();
                successfulWrites[course.Day] = ++requestSequence;
                versions[course.Day] = requestSequence;
                ObserveAttendance(course, AttendanceSource.Submission, requestSequence);
                await SaveAttendanceStateAsync(epoch);
                if (epoch != Generation) return;
                Notify();
            }
            else ReportSignInError(course.Day, result.Message);
            if (automatically && autoSignExecutions.TryGetValue(attemptKey, out var completed))
                await SetAutoSignStageAsync(completed, result.Outcome == SignOutcome.Signed ? AutoSignStage.Signed
                    : result.Outcome == SignOutcome.OutsideSignWindow ? AutoSignStage.NeedsAttention : AutoSignStage.Verifying,
                    result.Message, epoch, result.Outcome is SignOutcome.Signed or SignOutcome.OutsideSignWindow
                        ? null : clock.GetUtcNow().AddMinutes(AutoSignPlans.FirstOrDefault(x => x.Key == attemptKey)?.Policy.RetryMinutes ?? Preferences.AutoSignRule.RetryMinutes));
            if (!IsDemo)
            {
                try { await SaveOperationRecordsAsync(id, epoch); }
                catch (Exception e) { if (epoch == Generation) Message = "操作记录保存失败：" + e.Message; }
            }
            if (!IsDemo)
            {
                if (reads.TryGetValue(course.Day, out var inFlight))
                    await inFlight.Task;
                await RefreshAsync(CourseTime.Date(course.Day));
            }
            if (result.Outcome == SignOutcome.Signed)
            {
                Message = result.Message;
                courseNotices[course.Day] = result.Message;
            }
        }
        catch (OperationCanceledException) when (!submitted) { }
        catch (Exception e)
        {
            if (epoch != Generation)
                return;
            if (automatically && !autoSignStoreAvailable) return;
            ReportSignInError(course.Day, "未能确认签到结果：" + e.Message + " 请先刷新课程状态，再决定是否重试。");
            if (automatically && autoSignExecutions.TryGetValue(attemptKey, out var uncertain))
                await SetAutoSignStageAsync(uncertain, AutoSignStage.Verifying, "提交结果未知，等待学校状态核实", epoch,
                    clock.GetUtcNow().AddMinutes(AutoSignPlans.FirstOrDefault(x => x.Key == attemptKey)?.Policy.RetryMinutes ?? Preferences.AutoSignRule.RetryMinutes));
            if (e is SchoolException se && se.IsSessionExpired && ActiveAccount is { } a)
            {
                if (await RecoverAsync(a.Session, epoch) is not null)
                    await RefreshAsync(CourseTime.Date(course.Day));
            }
        }
        finally
        {
            RemoveSignPreparation(preparationKey);
            if (epoch == Generation) { if (authorized) IsBusy = false; Notify(); }
        }
    }
    public async Task TickAsync(bool allowBackground = false)
    {
        if (!await autoSignTickGate.WaitAsync(0)) return;
        try { await TickCoreAsync(allowBackground); }
        finally { autoSignTickGate.Release(); }
    }
    async Task TickCoreAsync(bool allowBackground)
    {
        bool Active() => IsForeground || allowBackground;
        if (Active()) await MaintainHistoryRetentionIfDueAsync();
        if (IsDemo && IsForeground)
        {
            var demoToday = CourseTime.Today(clock);
            if (CourseIdentity.Semester(demoToday, Semesters) is null && demoToday.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday))
            {
                MergeDemo(demoToday);
                Notify();
            }
            return;
        }
        if (!Active() || IsDemo || IsBusy || IsRecovering || IsRefreshing || paused || ActiveAccount is not { } a)
            return;
        var epoch = Generation;
        if (!IsScheduleRefreshing) await MaintainScheduleAsync();
        if (epoch != Generation || !Active() || paused) return;
        if (!Preferences.AutoSignIsRunning || !autoSignStoreAvailable
            || Preferences.AutoSignPausedUntil is { } until && until > AutoSignNow) return;
        if (autoSignClockRetryAt is { } retry && clock.GetUtcNow() < retry) return;
        if (autoSignSchoolOffset is null && Courses.Concat(snapshots.Values.SelectMany(s => s.Courses))
            .Any(c => AutoSignConfigured(c) && CourseTime.InSignWindow(c, clock.GetUtcNow())))
        {
            if (await ReadAutoSignClockAsync(epoch) is null || epoch != Generation) return;
        }
        var today = DateOnly.FromDateTime(AutoSignNow.ToOffset(CourseTime.ShanghaiOffset).DateTime);
        // Avoid waking the school clock endpoint all day. Device time is only a
        // coarse gate; the signed request still uses the authoritative school time.
        var schoolNow = AutoSignNow;
        var candidates = AutoSignPlans.Where(p => p.Course.Day == CourseTime.DayKey(today)
            && p.Stage != AutoSignStage.Signed && (p.Stage != AutoSignStage.Skipped || CanVerifyExisting(p))
            && (p.Stage != AutoSignStage.NeedsAttention || autoSignExecutions.GetValueOrDefault(p.Key) is { Submissions: > 0 })
            && (p.Stage != AutoSignStage.NeedsAttention || p.Course.End > schoolNow)
            && p.NextAt <= schoolNow
            && attendanceStates.GetValueOrDefault(AttendanceKey(p.Course))?.LastSuccessfulSignAt is null).ToList();
        if (candidates.Count == 0)
            return;
        foreach (var plan in candidates.OrderBy(x => x.NextAt).ThenBy(x => x.Key))
        {
            if (epoch != Generation || !Active()) return;
            await EvaluateAutoSignAsync(plan.Course, epoch);
        }
    }
    public async Task SetPreferencesAsync(bool autoSign, bool enableReminders, bool? confirmBeforeSign = null, int? reminderLeadMinutes = null)
    {
        var lead = reminderLeadMinutes is 5 or 10 or 15 or 30 ? reminderLeadMinutes : null;
        if (IsDemo)
        {
            demoPreferences = StampParticipation(demoPreferences, demoPreferences with
            {
                AutoSignRunning = autoSign, AutoSignEnabled = autoSign, RemindersEnabled = enableReminders,
                ConfirmBeforeSign = confirmBeforeSign ?? demoPreferences.ConfirmBeforeSign,
                ReminderLeadMinutes = lead ?? demoPreferences.ReminderLeadMinutes
            }, clock.GetUtcNow());
            Notify();
            return;
        }
        if (IsDemo || !CanChangeAccount || ActiveAccount is not { } a)
            return;
        var epoch = Generation;
        var permissionGranted = !enableReminders || await reminders.RequestPermissionAsync();
        if (epoch != Generation)
            return;
        await mutations.WaitAsync();
        try
        {
            if (epoch != Generation || !CanChangeAccount || ActiveAccount is not { } current)
                return;
            IsBusy = true;
            Notify();
            var beforeAutoSignPlans = AutoSignPlans.ToDictionary(x => x.Key);
            var preferences = StampParticipation(current.Preferences, current.Preferences with
            {
                AutoSignRunning = autoSign,
                AutoSignEnabled = autoSign, RemindersEnabled = enableReminders,
                ConfirmBeforeSign = confirmBeforeSign ?? current.Preferences.ConfirmBeforeSign,
                ReminderLeadMinutes = lead ?? current.Preferences.ReminderLeadMinutes,
                AutoSignV2Acknowledged = current.Preferences.AutoSignV2Acknowledged || autoSign != current.Preferences.AutoSignEnabled
            }, clock.GetUtcNow());
            await CommitAsync(Updated(current with
            {
                Settings = preferences
            }));
            await RecordAutoSignPlanChangesAsync(beforeAutoSignPlans, epoch);
            await UpdateRemindersAsync();
            if (!permissionGranted)
                Message = "偏好已保存；通知权限未开启，可在系统设置中允许通知";
        }
        finally { IsBusy = false; mutations.Release(); Notify(); }
    }
    async Task UpdateRemindersAsync()
    {
        await reminderGate.WaitAsync();
        try
        {
            var a = ActiveAccount;
            var list = new List<Reminder>();
            if (!IsDemo && !paused && a is not null)
            {
                var now = clock.GetUtcNow();
                var prefs = Preferences;
                var settings = new Dictionary<string, CoursePreferences>();
                foreach (var c in Courses)
                {
                    if (!ArrangementFresh(c) || c.Start is not { } start || start <= now) continue;
                    CoursePreferences? coursePrefs = null;
                    if (prefs.Courses.Count > 0 && PreferenceId(c) is { } id)
                    {
                        if (!settings.TryGetValue(id, out coursePrefs)) settings[id] = coursePrefs = CoursePreferencesFor(id);
                    }
                    if (!CoursePreferences.Resolve(coursePrefs?.Reminders ?? PreferenceOverride.Inherit, prefs.RemindersEnabled)) continue;
                    var at = start.AddMinutes(-(coursePrefs?.ReminderLeadMinutes ?? prefs.ReminderLeadMinutes));
                    if (at <= now) continue;
                    list.Add(new(a.Id + "|" + c.Day + "|" + c.Id, a.Id, c.Id, c.Day, c.Name,
                        $"{c.TimeRange} · {c.Classroom ?? "教室暂未提供"}", at));
                }
            }
            try
            {
                await reminders.ReplaceAsync(list);
            }
            catch (Exception e) { Message = "课程提醒更新失败：" + e.Message; }
        }
        finally { reminderGate.Release(); }
    }
    public async Task RemoveAsync(string id)
    {
        if (!CanChangeAccount)
            return;
        await mutations.WaitAsync();
        IsBusy = true;
        Notify();
        try
        {
            var active = vault.ActiveAccountId == id;
            await CommitAsync(new(1, vault.Accounts.Where(a => a.Id != id).ToList(), active ? null : vault.ActiveAccountId));
            if (active && !IsDemo)
                await ResetAsync();
            await cache.RemoveAsync(id);
            if (catalog is not null)
                await catalog.RemoveCatalogAsync(id);
            await records.RemoveAsync(id);
            accountChecks.Remove(id);
        }
        finally { IsBusy = false; mutations.Release(); Notify(); }
    }
    public Task<QrSnapshot> QrAsync(Course c, CancellationToken ct) => IsDemo
        ? Task.FromResult(new QrSnapshot("ucas-signin://demo?course=" + c.Id, 0, clock.GetUtcNow().AddSeconds(5), TimeSpan.FromSeconds(5))) : school.QrAsync(c, ct);
    public static List<Course> DemoCourses(DateOnly date)
    {
        var day = CourseTime.DayKey(date);
        return [new("1000001", "", "矩阵分析", "李明远", "教学楼 A101", "08:30", "10:10", day, true, "demo-matrix"),
            new("1000002", "", "高级人工智能", "陈思远", "教学楼 B203", "10:30", "12:10", day, false, "demo-ai"),
            new("1000003", "", "学术英语写作", "王雅文", null, "13:30", "15:10", day, false, "demo-english")];
    }
}
