namespace UCASSignIn.Core.Tests;

public sealed class AccountCoordinatorTests
{
    sealed class Harness
    {
        public MemoryAccounts Accounts = new() { Vault = new(1, [TestData.Account("a", true), TestData.Account("b")], "a") };
        public MemoryData Data = new(); public FakeSchool School = new(); public FakeReminders Reminders = new();
        public AccountCoordinator Model
        {
            get;
        }
        public Harness() => Model = new(School, Accounts, Data, Data, Reminders, new FakeClock(TestData.Now));
    }
    static async Task WaitFor(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!condition())
            await Task.Delay(5, timeout.Token);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DailyRefreshWritesEachCacheOnceIncludingEmptyDays(bool hasCourse)
    {
        var h = new Harness();
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult(hasCourse ? [TestData.Course()] : [], ""));
        await h.Model.InitializeAsync();
        Assert.Equal(1, h.Data.CourseCacheWrites);
        await h.Model.RefreshAsync();
        Assert.Equal(2, h.Data.CourseCacheWrites);
        Assert.Equal(hasCourse ? 1 : 0, h.Data.Cache["a|20260916"].Courses.Count);
        Assert.False(h.Model.IsCached(h.Model.SelectedDate));
    }
    [Fact]
    public async Task SuccessfulSyncDoesNotPublishServiceMessagesAsNotices()
    {
        var h = new Harness();
        h.School.Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(date) }], "已更新当天课程"));
        await h.Model.InitializeAsync();
        Assert.Null(h.Model.Message);
        Assert.Null(h.Model.CourseNotice(h.Model.SelectedDate));
        Assert.Equal(TestData.Now, h.Model.LastUpdated(h.Model.SelectedDate));
    }
    [Fact]
    public async Task DateNoticesAndCacheStateDoNotLeakBetweenTodayAndSchedule()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var today = h.Model.SelectedDate;
        var target = today.AddDays(1);
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([], "合法空日"));
        await h.Model.SelectDateAsync(target);
        Assert.Null(h.Model.CourseNotice(target));
        Assert.Null(h.Model.CourseNotice(today));
        h.School.Query = (_, _) => throw new IOException("offline");
        await h.Model.RefreshAsync(target);
        Assert.True(h.Model.IsCached(target));
        Assert.False(h.Model.IsCached(today));
        Assert.Equal("offline", h.Model.CourseNotice(target));
        h.Model.IsForeground = true;
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([], "已更新当天课程"));
        var reads = h.School.Reads;
        await h.Model.TickAsync();
        Assert.Equal(reads, h.School.Reads); // Automatic retries respect the daily failure cooldown.
        await h.Model.CheckDayAsync(target, true);
        Assert.Equal(reads + 1, h.School.Reads);
        Assert.False(h.Model.IsCached(target));
        Assert.Null(h.Model.CourseNotice(target));
    }
    [Fact]
    public async Task CachedEmptyDayRetainsItsOwnTimestampAndAccountSwitchClearsIt()
    {
        var h = new Harness();
        var today = h.Model.SelectedDate;
        var cachedAt = TestData.Now.AddDays(-1);
        h.Data.Cache["a|" + CourseTime.DayKey(today)] = new([], cachedAt);
        h.School.Query = (_, _) => throw new IOException("offline");
        await h.Model.InitializeAsync();
        Assert.True(h.Model.IsCached(today));
        Assert.Equal(cachedAt, h.Model.LastUpdated(today));
        await h.Model.SwitchAsync("b");
        Assert.False(h.Model.IsCached(today));
        Assert.Null(h.Model.LastUpdated(today));
    }
    [Fact]
    public async Task SelectingActiveAccountPreservesDateGenerationAndDoesNotFetchAgain()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var selected = h.Model.SelectedDate.AddDays(1);
        await h.Model.SelectDateAsync(selected);
        var generation = h.Model.Generation;
        var reads = h.School.Reads;
        h.Accounts.FailSave = true;
        await h.Model.SwitchAsync("a");
        Assert.Equal(reads, h.School.Reads);
        Assert.Equal(generation, h.Model.Generation);
        Assert.Equal(selected, h.Model.SelectedDate);
    }
    [Fact]
    public async Task SelectingSavedActiveAccountFromDemoReusesSuccessfulSessionCheck()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.EnterDemoAsync();
        var reads = h.School.Reads;
        await h.Model.SwitchAsync("a");
        Assert.False(h.Model.IsDemo);
        Assert.Equal(reads, h.School.Reads);
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        Assert.NotEmpty(h.Model.Courses);
    }
    [Fact]
    public async Task RestoresSessionWithoutRememberedPassword()
    {
        var h = new Harness();
        h.Accounts.Vault = new(1, [TestData.Account()], "a");
        await h.Model.InitializeAsync();
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        Assert.Equal(0, h.School.Logins);
        Assert.Single(h.Model.Courses);
    }
    [Fact]
    public async Task DateSelectionIsLoadingBeforeCacheAndUntilNetworkCompletes()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var target = new DateOnly(2026, 9, 17);
        var cache = new TaskCompletionSource<CourseCache?>();
        var network = new TaskCompletionSource<CourseQueryResult>();
        h.Data.LoadCourses = (_, _) => cache.Task;
        h.School.Query = (_, _) => network.Task;
        var states = new List<bool>();
        h.Model.Changed += () => { if (h.Model.SelectedDate == target) states.Add(h.Model.IsLoadingCourses(target)); };
        var pending = h.Model.SelectDateAsync(target);
        Assert.True(h.Model.IsLoadingCourses(target));
        Assert.False(h.Model.IsLoadingCourses(target.AddDays(1)));
        Assert.All(states, Assert.True);
        cache.SetResult(null);
        await WaitFor(() => h.School.Reads == 2);
        Assert.True(h.Model.IsLoadingCourses(target));
        Assert.All(states, Assert.True);
        network.SetResult(new([], ""));
        await pending;
        Assert.False(h.Model.IsLoadingCourses(target));
        Assert.Empty(h.Model.DisplayCourses(target));
        Assert.False(states[^1]);
    }
    [Fact]
    public async Task OverlappingDatesKeepTheirOwnLoadingStateAndFailureClearsIt()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var first = new DateOnly(2026, 9, 17);
        var second = first.AddDays(1);
        var response1 = new TaskCompletionSource<CourseQueryResult>();
        var response2 = new TaskCompletionSource<CourseQueryResult>();
        h.School.Query = (_, d) => d == first ? response1.Task : response2.Task;
        var pending1 = h.Model.SelectDateAsync(first);
        var pending2 = h.Model.SelectDateAsync(second);
        Assert.True(h.Model.IsLoadingCourses(first));
        Assert.True(h.Model.IsLoadingCourses(second));
        response1.SetResult(new([], ""));
        await pending1;
        Assert.False(h.Model.IsLoadingCourses(first));
        Assert.True(h.Model.IsLoadingCourses(second));
        response2.SetException(new IOException("offline"));
        await pending2;
        Assert.False(h.Model.IsRefreshing);
        Assert.Equal("offline", h.Model.Message);
    }
    [Fact]
    public async Task RestoredAccountReportsLoadingBeforeTheFirstEmptyCourseView()
    {
        var h = new Harness();
        var response = new TaskCompletionSource<CourseQueryResult>();
        h.School.Query = (_, _) => response.Task;
        var states = new List<bool>();
        h.Model.Changed += () => states.Add(h.Model.IsLoadingCourses(h.Model.SelectedDate));
        var pending = h.Model.InitializeAsync();
        Assert.NotEmpty(states);
        Assert.All(states, Assert.True);
        response.SetResult(new([], ""));
        await pending;
        Assert.False(states[^1]);
    }
    [Fact]
    public async Task FailedSwitchWritePreservesCurrentAccountAndCourses()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var epoch = h.Model.Generation;
        h.Accounts.FailSave = true;
        await Assert.ThrowsAsync<IOException>(() => h.Model.SwitchAsync("b"));
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        Assert.Equal(epoch, h.Model.Generation);
        Assert.Single(h.Model.Courses);
    }
    [Fact]
    public async Task ExpiredRestoredAccountStillLoadsCacheWithoutQueryingSchool()
    {
        var h = new Harness();
        h.Accounts.Vault = new(1, [TestData.Account() with { RequiresLogin = true }], "a");
        h.Data.Cache["a|20260916"] = new([TestData.Course()], TestData.Now);
        await h.Model.InitializeAsync();
        Assert.Single(h.Model.Courses);
        Assert.Equal(0, h.School.Reads);
        Assert.False(h.Model.IsRefreshing);
        Assert.False(h.Model.CanSign(h.Model.Courses[0]));
        Assert.Contains("登录已过期", h.Model.Message);
    }
    [Fact]
    public async Task LateOldAccountResponseCannotReplaceNewCoursesOrCache()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var response = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Query = (s, _) => s.StudentNo == "a" ? response.Task : Task.FromResult(new CourseQueryResult([TestData.Course() with { Name = "B课程" }], "B"));
        var old = h.Model.RefreshAsync();
        await WaitFor(() => h.School.Reads == 2);
        await h.Model.SwitchAsync("b");
        response.SetResult(new([TestData.Course() with { Name = "过期响应" }], "旧"));
        await old;
        Assert.Equal("B课程", Assert.Single(h.Model.Courses).Name);
        Assert.DoesNotContain(h.Data.Cache.Values.SelectMany(v => v.Courses), c => c.Name == "过期响应");
    }
    [Fact]
    public async Task CachedCoursesCannotSignBeforeSynchronization()
    {
        var h = new Harness();
        h.Data.Cache["a|20260916"] = new([TestData.Course()], TestData.Now);
        h.School.Query = (_, _) => throw new IOException("offline");
        await h.Model.InitializeAsync();
        Assert.False(h.Model.CanSign(Assert.Single(h.Model.Courses)));
        await h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        Assert.Equal(0, h.School.Signs);
    }
    [Fact]
    public async Task PreferencesRecordsAndRemovalStayWithAccount()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, true);
        await h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        Assert.Single(h.Model.Records);
        await h.Model.SwitchAsync("b");
        Assert.False(h.Model.ActiveAccount!.Preferences.AutoSignEnabled);
        Assert.Empty(h.Model.Records);
        await h.Model.RemoveAsync("a");
        Assert.Equal("b", h.Model.ActiveAccount.Id);
        Assert.DoesNotContain("a", h.Data.Records.Keys);
        await h.Model.RemoveAsync("b");
        Assert.Null(h.Model.ActiveAccount);
        Assert.Empty(h.Model.Courses);
    }
    [Fact]
    public async Task FailedRemovalDoesNotDeleteData()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.Accounts.FailSave = true;
        await Assert.ThrowsAsync<IOException>(() => h.Model.RemoveAsync("a"));
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        Assert.Contains("a|20260916", h.Data.Cache.Keys);
    }
    [Fact]
    public async Task LoginAliasUpdatesSchoolIdentityAndRememberOffRemovesPassword()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Login = _ => Task.FromResult(TestData.Session());
        await h.Model.LoginAsync("demo@example.invalid", "password", false);
        Assert.Equal(2, h.Model.Accounts.Count);
        Assert.Null(h.Model.ActiveAccount!.Credentials);
        Assert.Equal("demo@example.invalid", h.Model.ActiveAccount.LoginUsername);
    }
    [Fact]
    public async Task FailedLoginSavePreservesPreviousAccount()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.Accounts.FailSave = true;
        await Assert.ThrowsAsync<IOException>(() => h.Model.LoginAsync("c", "p", true));
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        Assert.Equal(2, h.Model.Accounts.Count);
    }
    [Fact]
    public async Task ExpiredReadRecoversOnceAndOnlyRetriesRead()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var count = 0;
        h.School.Query = (_, _) => ++count == 1 ? throw new SchoolException("LOGIN_EXPIRED", "expired") : Task.FromResult(new CourseQueryResult([TestData.Course()], "ok"));
        h.School.Login = _ => Task.FromResult(TestData.Session() with { SessionId = "new" });
        await h.Model.RefreshAsync();
        Assert.Equal(1, h.School.Logins);
        Assert.Equal(2, count);
        Assert.Equal(0, h.School.Signs);
    }
    [Fact]
    public async Task ConcurrentExpiredReadsShareRecoveryAndBlockSwitch()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var login = new TaskCompletionSource<SchoolSession>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Login = _ => login.Task;
        h.School.Query = (s, d) => s.SessionId == "s-a" ? throw new SchoolException("LOGIN_EXPIRED", "expired") : Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(d) }], "ok"));
        var read1 = h.Model.RefreshAsync(new(2026, 9, 16));
        var read2 = h.Model.RefreshAsync(new(2026, 9, 17));
        await WaitFor(() => h.School.Logins == 1);
        Assert.False(h.Model.CanChangeAccount);
        await h.Model.SwitchAsync("b");
        Assert.Equal("a", h.Model.ActiveAccount?.Id);
        login.SetResult(TestData.Session() with
        {
            SessionId = "new"
        });
        await Task.WhenAll(read1, read2);
        Assert.Equal(1, h.School.Logins);
    }
    [Fact]
    public async Task FailedRecoveryDoesNotLoop()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Query = (_, _) => throw new SchoolException("LOGIN_EXPIRED", "expired");
        h.School.Login = _ => throw new SchoolException("LOGIN_REJECTED", "wrong password");
        await h.Model.RefreshAsync();
        await h.Model.RefreshAsync();
        h.Model.IsForeground = true;
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Logins);
        Assert.True(h.Model.ActiveAccount!.RequiresLogin);
        Assert.False(h.Model.CanSign(TestData.Course()));
    }
    [Fact]
    public async Task ExpiredSignNeverResubmitsAfterRecovery()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Sign = () => throw new SchoolException("LOGIN_EXPIRED", "expired");
        h.School.Login = _ => Task.FromResult(TestData.Session() with { SessionId = "new" });
        await h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(1, h.School.Logins);
        Assert.Contains("未能确认", h.Model.SignInError?.Message);
        Assert.Null(h.Model.Message);
    }
    [Theory]
    [InlineData(SignOutcome.QrExpired)]
    [InlineData(SignOutcome.OutsideSignWindow)]
    [InlineData(SignOutcome.Unknown)]
    public async Task FailedSignUsesAcknowledgedAlertInsteadOfInlineMessage(SignOutcome outcome)
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Sign = () => Task.FromResult(new SignResult(outcome, "学校返回的失败原因"));
        var refresh = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Query = (_, _) => refresh.Task;
        var signing = h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        var error = Assert.IsType<SignInFailure>(h.Model.SignInError);
        Assert.Equal("学校返回的失败原因", error.Message);
        Assert.False(signing.IsCompleted); // Feedback is available before the follow-up read finishes.
        refresh.SetResult(new([TestData.Course()], ""));
        await signing;
        Assert.Equal(error, h.Model.SignInError);
        Assert.Null(h.Model.Message);
        Assert.Null(h.Model.CourseNotice(new(2026, 9, 16)));
        Assert.False(Assert.Single(h.Model.Records).Succeeded);
        h.Model.AcknowledgeSignInError(Guid.NewGuid());
        Assert.Equal(error, h.Model.SignInError);
        h.Model.AcknowledgeSignInError(error.Id);
        Assert.Null(h.Model.SignInError);
        await h.Model.RefreshAsync();
        Assert.Null(h.Model.SignInError);
        Assert.Equal(1, h.School.Signs);
    }
    [Fact]
    public async Task PendingSignAlertClearsWhenChangingAccounts()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Sign = () => throw new IOException("连接中断");
        await h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        var old = Assert.IsType<SignInFailure>(h.Model.SignInError);
        Assert.Contains("请先刷新课程状态", old.Message);
        await h.Model.SwitchAsync("b");
        Assert.Null(h.Model.SignInError);
        await h.Model.SignAsync(TestData.Course(), h.Model.Generation);
        var next = Assert.IsType<SignInFailure>(h.Model.SignInError);
        h.Model.AcknowledgeSignInError(old.Id);
        Assert.Equal(next, h.Model.SignInError);
        Assert.Equal(2, h.School.Signs);
    }
    [Fact]
    public async Task LatePermissionResultCannotChangeNewAccount()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var permission = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.Reminders.Permission = () => permission.Task;
        var change = h.Model.SetPreferencesAsync(true, true);
        await h.Model.SwitchAsync("b");
        permission.SetResult(true);
        await change;
        Assert.False(h.Model.ActiveAccount!.Preferences.RemindersEnabled);
        Assert.False(h.Model.ActiveAccount.Preferences.AutoSignEnabled);
    }
    [Fact]
    public async Task AutoAttemptIsNotRepeatedAfterSwitchingAwayAndBack()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        h.Model.IsForeground = true;
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        await h.Model.SwitchAsync("b");
        await h.Model.SwitchAsync("a");
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }
    [Fact]
    public async Task BackgroundTickDoesNotSign()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
    }
    [Fact]
    public async Task PlatformBackgroundTickCanSignWhenExplicitlyAllowed()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.TickAsync(allowBackground: true);
        Assert.Equal(1, h.School.Signs);
    }
    [Fact]
    public async Task AutomaticTickDoesNotSyncSchoolClockFarFromAnySignWindow()
    {
        var h = new Harness();
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { BeginTime = "12:00", EndTime = "13:40" }], "ok"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.TickAsync(allowBackground: true);
        Assert.Equal(0, h.School.ClockReads);
        Assert.Equal(0, h.School.Signs);
    }
    [Fact]
    public async Task StaleDetailCannotSignAfterSwitch()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var epoch = h.Model.Generation;
        await h.Model.SwitchAsync("b");
        await h.Model.SignAsync(TestData.Course(), epoch);
        Assert.Equal(0, h.School.Signs);
    }
    [Fact]
    public async Task DemoNeverCallsSchoolOrMutatesAccounts()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var reads = h.School.Reads;
        await h.Model.EnterDemoAsync();
        await h.Model.SelectDateAsync(new(2026, 9, 17));
        await h.Model.SignAsync(h.Model.Courses.First(c => !c.Signed), h.Model.Generation);
        var qr = await h.Model.QrAsync(h.Model.Courses[0], default);
        Assert.StartsWith("ucas-signin://demo", qr.Url);
        Assert.Equal(0, h.School.Signs);
        Assert.Equal(reads, h.School.Reads);
        Assert.Equal("a", h.Accounts.Vault.ActiveAccountId);
        Assert.Empty(h.Data.Records);
    }
    [Fact]
    public void VaultRejectsDuplicatesFutureVersionsAndMissingActiveAccount()
    {
        Assert.Throws<SchoolException>(() => new AccountVault(2, [], null).Validate());
        Assert.Throws<SchoolException>(() => new AccountVault(1, [TestData.Account(), TestData.Account()], "a").Validate());
        Assert.Throws<SchoolException>(() => new AccountVault(1, [], "missing").Validate());
    }
    [Fact]
    public async Task DemoDateChangesAndRefreshKeepSimulatedAttendance()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        await h.Model.EnterDemoAsync();
        var course = h.Model.DisplayCourses(new(2026, 9, 16)).First(c => !c.Signed);
        await h.Model.SignAsync(course, h.Model.Generation);
        await h.Model.SelectDateAsync(new(2026, 9, 17));
        await h.Model.SelectDateAsync(new(2026, 9, 16));
        await h.Model.RefreshAsync();
        Assert.True(h.Model.DisplayCourses(new(2026, 9, 16)).Single(c => c.Id == course.Id).Signed);
        Assert.Single(h.Model.Records);
        Assert.InRange(h.Model.DisplayCourses(new(2026, 9, 17)).Count, 2, 3);
    }
    [Fact]
    public async Task EmptyDateDoesNotDisplayUnrelatedCachedCourses()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([], "当天及本周暂无课程"));
        await h.Model.SelectDateAsync(new(2026, 10, 20));
        Assert.Empty(h.Model.DisplayCourses(new(2026, 10, 20)));
        Assert.Single(h.Model.DisplayCourses(new(2026, 9, 16)));
    }
    [Fact]
    public async Task DemoPreferencesRemainSeparateFromSavedAccount()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        var original = h.Model.ActiveAccount!.Preferences;
        await h.Model.EnterDemoAsync();
        await h.Model.SetPreferencesAsync(true, true);
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.True(h.Model.Preferences.RemindersEnabled);
        Assert.Equal(original, h.Accounts.Vault.Accounts.Single(a => a.Id == "a").Preferences);
        await h.Model.ExitDemoAsync();
        Assert.Equal(original, h.Model.Preferences);
    }
    [Fact]
    public async Task DemoCrossingShanghaiMidnightLoadsNewDayWithoutSchoolRequests()
    {
        var clock = new FakeClock(new(2026, 9, 16, 23, 59, 59, CourseTime.ShanghaiOffset));
        var school = new FakeSchool();
        var data = new MemoryData();
        var model = new AccountCoordinator(school, new MemoryAccounts(), data, data, new FakeReminders(), clock);
        await model.EnterDemoAsync();
        model.IsForeground = true;
        clock.Now = clock.Now.AddSeconds(2);
        await model.TickAsync();
        Assert.InRange(model.DisplayCourses(new(2026, 9, 17)).Count, 2, 3);
        Assert.Equal(0, school.Reads);
    }
    [Fact]
    public async Task DeniedNotificationPermissionStillSavesReminderPreference()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.Reminders.Permission = () => Task.FromResult(false);
        await h.Model.SetPreferencesAsync(false, true);
        Assert.True(h.Model.Preferences.RemindersEnabled);
        Assert.Empty(h.Reminders.Scheduled);
        Assert.Contains("通知权限", h.Model.Message);
    }
    [Fact]
    public async Task SwitchingAccountsCancelsFormerAccountsScheduledReminders()
    {
        var h = new Harness();
        h.School.Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(date), BeginTime = "10:00", EndTime = "11:40" }], ""));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(false, true);
        Assert.Equal("a", Assert.Single(h.Reminders.Scheduled).AccountId);
        await h.Model.SwitchAsync("b");
        Assert.Empty(h.Reminders.Scheduled);
    }
    [Fact]
    public async Task StrictDailyReadRejectsUnrelatedWeeklyFallback()
    {
        var h = new Harness();
        await h.Model.InitializeAsync();
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = "20261021" }], "周课表", true));
        await h.Model.SelectDateAsync(new(2026, 10, 20));
        Assert.Empty(h.Model.DisplayCourses(new(2026, 10, 20)));
        Assert.NotNull(h.Model.CourseNotice(new(2026, 10, 20)));
    }
}
