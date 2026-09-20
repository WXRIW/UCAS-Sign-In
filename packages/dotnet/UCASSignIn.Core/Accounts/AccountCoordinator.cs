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
    readonly Dictionary<string, HashSet<string>> weeklyFallbackDays = [];
    readonly HashSet<string> autoAttempts = [];
    readonly HashSet<string> signPreparations = [];
    readonly HashSet<string> recoveryAttempts = [];
    readonly Dictionary<string, Task> reads = [];
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
        var selected = Courses.Where(c => c.Day == day).ToList();
        return selected.Count > 0 || !weeklyFallbackDays.TryGetValue(day, out var fallback) ? selected
            : Courses.Where(c => fallback.Contains(c.Day)).ToList();
    }
    public bool IsFresh(Course course) => IsDemo || freshDays.Contains(CourseTime.NormalizeDay(course.Day) ?? "");
    public bool IsCached(DateOnly date) => !IsDemo && courseUpdates.ContainsKey(CourseTime.DayKey(date)) && !freshDays.Contains(CourseTime.DayKey(date));
    public DateTimeOffset? LastUpdated(DateOnly date) => courseUpdates.TryGetValue(CourseTime.DayKey(date), out var updated) ? updated : null;
    public string? CourseNotice(DateOnly date) => courseNotices.GetValueOrDefault(CourseTime.DayKey(date));
    public bool CanSign(Course c) => IsConnected && !IsBusy && !IsRecovering && !paused && ActiveAccount?.RequiresLogin != true
        && !IsSignInDisabled(c.CourseId)
        && IsFresh(c) && Courses.Any(x => x.Id == c.Id && x.Day == c.Day && !x.Signed);
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
        loaded = true;
        if (ActiveAccount is { } a)
        {
            await ActivateAsync(a);
        }
        else
            Notify();
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
            var session = await school.LoginAsync(username, password);
            if (expectedAccountId is not null && session.StudentNo != expectedAccountId)
                throw new SchoolException("ACCOUNT_MISMATCH", "请使用此账户对应的学校身份登录");
            var prior = vault.Accounts.FirstOrDefault(a => a.Id == session.StudentNo);
            var next = new StoredAccount(session, remember ? new(username.Trim(), password) : null, username.Trim(), clock.GetUtcNow(), false, prior?.Preferences);
            await CommitAsync(Updated(next, true));
            await ActivateAsync(next);
        }
        finally { IsBusy = false; mutations.Release(); Notify(); }
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
            var a = vault.Accounts.First(x => x.Id == id) with
            {
                LastUsedAt = clock.GetUtcNow()
            };
            await CommitAsync(Updated(a, true));
            await ActivateAsync(a);
        }
        finally { IsBusy = false; mutations.Release(); Notify(); }
    }
    async Task ResetAsync()
    {
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
        weeklyFallbackDays.Clear();
        signPreparations.Clear();
        reads.Clear();
        versions.Clear();
        Courses = [];
        Records = [];
        LastSyncAt = null;
        SelectedDate = CourseTime.Today(clock);
        school.ClearClock();
        Message = null;
        SignInError = null;
        ResetCatalogState();
        await UpdateRemindersAsync();
    }
    async Task ActivateAsync(StoredAccount a)
    {
        IsDemo = false;
        await ResetAsync();
        var epoch = Generation;
        paused = a.RequiresLogin;
        Records = await records.LoadAsync(a.Id, lifetime.Token);
        if (epoch != Generation)
            return;
        await RefreshAsync();
    }
    public async Task EnterDemoAsync()
    {
        if (!CanChangeAccount)
            return;
        IsDemo = true;
        demoPreferences = new();
        await ResetAsync();
        Courses = DemoCourses(SelectedDate);
        SetupDemoCatalog();
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
            MergeDemo(date);
            Notify();
            return;
        }
        if (ActiveAccount is not null)
            await RefreshAsync(date);
        else
            Notify();
    }
    async Task LoadCacheAsync(string id, DateOnly date, Guid epoch)
    {
        var value = await cache.LoadAsync(id, CourseTime.DayKey(date), lifetime.Token);
        if (epoch != Generation || value is null)
            return;
        SetFallback(CourseTime.DayKey(date), value.Courses, value.FromWeeklyFallback);
        Merge(value.Courses, CourseTime.DayKey(date));
        courseUpdates[CourseTime.DayKey(date)] = value.UpdatedAt;
        Message = "正在显示本机缓存，同步成功后才能签到";
    }
    void Merge(IEnumerable<Course> courses, string day)
    {
        var incoming = courses.ToList();
        var days = incoming.Select(c => c.Day).Append(day).ToHashSet();
        Courses = Courses.Where(c => !days.Contains(c.Day)).Concat(incoming).OrderBy(c => c.Start).ToList();
    }
    void SetFallback(string day, IEnumerable<Course> courses, bool fallback)
    {
        if (fallback)
            weeklyFallbackDays[day] = courses.Select(c => c.Day).ToHashSet();
        else
            weeklyFallbackDays.Remove(day);
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
            MergeDemo(target);
            Notify();
            return Task.CompletedTask;
        }
        if (ActiveAccount is not { } account)
            return Task.CompletedTask;
        var day = CourseTime.DayKey(target);
        lock (readGate)
        {
            if (reads.TryGetValue(day, out var existing))
                return existing;
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            reads[day] = completion.Task;
            var epoch = Generation;
            var ct = lifetime.Token;
            Notify();
            _ = CompleteReadAsync(completion, account, target, epoch, ct);
            return completion.Task;
        }
    }
    async Task CompleteReadAsync(TaskCompletionSource completion, StoredAccount account, DateOnly date, Guid epoch, CancellationToken ct)
    {
        try
        {
            await RefreshCoreAsync(account, date, epoch, ct);
            completion.TrySetResult();
        }
        catch (Exception e) { completion.TrySetException(e); }
    }
    async Task RefreshCoreAsync(StoredAccount account, DateOnly date, Guid epoch, CancellationToken ct)
    {
        var day = CourseTime.DayKey(date);
        var sequence = ++requestSequence;
        versions[day] = sequence;
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
                result = await school.CoursesAsync(account.Session, date, ct);
            }
            catch (SchoolException e) when (e.IsSessionExpired)
            {
                var session = await RecoverAsync(account.Session, epoch);
                if (session is null)
                    return;
                result = await school.CoursesAsync(session, date, ct);
            }
            if (epoch != Generation || paused || versions.GetValueOrDefault(day) != sequence)
                return;
            await cache.SaveAsync(account.Id, day, new(result.Courses.ToList(), clock.GetUtcNow(), result.FromWeeklyFallback), ct);
            if (epoch != Generation || paused)
                return;
            Merge(result.Courses, day);
            SetFallback(day, result.Courses, result.FromWeeklyFallback);
            freshDays.Add(day);
            courseUpdates[day] = clock.GetUtcNow();
            courseNotices[day] = result.FromWeeklyFallback ? "所选日期没有课程，课表中可查看学校返回的本周课程。" : null;
            foreach (var group in result.Courses.GroupBy(c => c.Day))
            {
                freshDays.Add(group.Key);
                courseUpdates[group.Key] = clock.GetUtcNow();
                if (group.Key != day) courseNotices[group.Key] = null;
                await cache.SaveAsync(account.Id, group.Key, new(group.ToList(), clock.GetUtcNow()), ct);
                if (epoch != Generation)
                    return;
            }
            LastSyncAt = clock.GetUtcNow();
            Message = null;
            await UpdateRemindersAsync();
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (epoch == Generation)
            {
                freshDays.Remove(day);
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
            await CommitAsync(Updated(a with
            {
                Session = result,
                RequiresLogin = false
            }));
            paused = false;
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
            await CommitAsync(Updated(a with
            {
                RequiresLogin = true
            }));
        }
        catch (Exception e) { Message += "；账户状态保存失败：" + e.Message; }
        await UpdateRemindersAsync();
    }
    public async Task SignAsync(Course course, Guid expectedGeneration, bool automatically = false)
    {
        var preparationKey = course.Day + "|" + course.Id;
        if (expectedGeneration != Generation || !CanSign(course) || automatically && !EffectiveAutoSign(course.CourseId) || !signPreparations.Add(preparationKey))
            return;
        var epoch = Generation;
        var id = ActiveAccount?.Id ?? "demo";
        var attemptKey = id + "|" + course.Day + "|" + course.Id;
        var submitted = false;
        bool Authorize()
        {
            var current = Courses.FirstOrDefault(x => x.Id == course.Id && x.Day == course.Day);
            if (epoch != Generation || paused || ActiveAccount?.RequiresLogin == true || current is null || current.Signed
                || !IsFresh(current) || IsSignInDisabled(current.CourseId) || automatically && !EffectiveAutoSign(current.CourseId)) return false;
            submitted = true;
            IsBusy = true;
            if (automatically) autoAttempts.Add(attemptKey);
            Notify();
            return true;
        }
        Notify();
        try
        {
            SignResult result;
            if (IsDemo)
            {
                if (!Authorize()) return;
                result = new(SignOutcome.Signed, "演示签到成功 · 未向学校提交");
            }
            else result = await school.SignAsync(course, ActiveAccount!.Session, lifetime.Token, Authorize);
            if (epoch != Generation)
                return;
            Records = new[] { new AttendanceRecord(course.Name, clock.GetUtcNow(), result.Message, result.Outcome == SignOutcome.Signed, course.CourseId, course.Id) }.Concat(Records).Take(100).ToList();
            if (!IsDemo)
                await records.SaveAsync(id, Records, lifetime.Token);
            if (result.Outcome == SignOutcome.Signed)
            {
                InvalidateAttendance(course.CourseId);
                Courses = Courses.Select(c => c.Id == course.Id && c.Day == course.Day ? c with { Signed = true } : c).ToList();
            }
            else ReportSignInError(course.Day, result.Message);
            if (!IsDemo)
            {
                if (reads.TryGetValue(course.Day, out var inFlight))
                    await inFlight;
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
            ReportSignInError(course.Day, "未能确认签到结果：" + e.Message + " 请先刷新课程状态，再决定是否重试。");
            if (e is SchoolException se && se.IsSessionExpired && ActiveAccount is { } a)
            {
                if (await RecoverAsync(a.Session, epoch) is not null)
                    await RefreshAsync(CourseTime.Date(course.Day));
            }
        }
        finally
        {
            signPreparations.Remove(preparationKey);
            if (epoch == Generation) { if (submitted) IsBusy = false; Notify(); }
        }
    }
    public async Task TickAsync(bool allowBackground = false)
    {
        bool Active() => IsForeground || allowBackground;
        if (IsDemo && IsForeground)
        {
            var demoToday = CourseTime.Today(clock);
            if (!Courses.Any(c => c.Day == CourseTime.DayKey(demoToday)))
            {
                MergeDemo(demoToday);
                Notify();
            }
            return;
        }
        if (!Active() || IsDemo || IsBusy || IsRecovering || IsRefreshing || paused || ActiveAccount is not { } a)
            return;
        var epoch = Generation;
        var today = CourseTime.Today(clock);
        if (!freshDays.Contains(CourseTime.DayKey(today)))
            await RefreshAsync(today);
        if (epoch != Generation || !Active() || paused) return;
        if (SelectedDate != today && IsCached(SelectedDate))
            await RefreshAsync(SelectedDate);
        if (epoch != Generation || !Active() || paused || IsBusy)
            return;
        // Avoid waking the school clock endpoint all day. Device time is only a
        // coarse gate; the signed request still uses the authoritative school time.
        var localNow = clock.GetUtcNow();
        var candidates = Courses.Where(c => c.Day == CourseTime.DayKey(today) && CanSign(c) && EffectiveAutoSign(c.CourseId)
            && c.Start is { } start && c.End is { } end
            && localNow >= start.AddMinutes(-30) && localNow < end.AddMinutes(5)
            && !autoAttempts.Contains(a.Id + "|" + c.Day + "|" + c.Id)).ToList();
        if (candidates.Count == 0)
            return;
        var now = await school.SchoolNowAsync(lifetime.Token);
        if (epoch != Generation || !Active())
            return;
        var course = candidates.FirstOrDefault(c => CanSign(c) && EffectiveAutoSign(c.CourseId) && CourseTime.InSignWindow(c, now)
            && !autoAttempts.Contains(a.Id + "|" + c.Day + "|" + c.Id));
        if (course is not null)
            await SignAsync(course, epoch, true);
    }
    public async Task SetPreferencesAsync(bool autoSign, bool enableReminders, bool? confirmBeforeSign = null, int? reminderLeadMinutes = null)
    {
        var lead = reminderLeadMinutes is 5 or 10 or 15 or 30 ? reminderLeadMinutes : null;
        if (IsDemo)
        {
            demoPreferences = new(autoSign, enableReminders, confirmBeforeSign ?? demoPreferences.ConfirmBeforeSign,
                lead ?? demoPreferences.ReminderLeadMinutes, demoPreferences.Courses);
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
            await CommitAsync(Updated(current with
            {
                Settings = new(autoSign, enableReminders, confirmBeforeSign ?? current.Preferences.ConfirmBeforeSign,
                    lead ?? current.Preferences.ReminderLeadMinutes, current.Preferences.Courses)
            }));
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
            var list = IsDemo || paused || a is null ? [] : Courses.Where(c => IsFresh(c) && EffectiveReminders(c.CourseId)
                    && c.Start?.AddMinutes(-EffectiveReminderLeadMinutes(c.CourseId)) > clock.GetUtcNow())
                .Select(c => new Reminder(a.Id + "|" + c.Day + "|" + c.Id, a.Id, c.Id, c.Day, c.Name,
                    $"{c.TimeRange} · {c.Classroom ?? "教室暂未提供"}", c.Start!.Value.AddMinutes(-EffectiveReminderLeadMinutes(c.CourseId)))).ToArray();
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
