namespace UCASSignIn.Core.Tests;

public sealed class AutoSignSuspendTests
{
    // Matches Android elapsedRealtimeNanos: sleep advances the timestamp even
    // though the application's timer does not run during that interval.
    sealed class SuspendClock(DateTimeOffset now) : TimeProvider
    {
        DateTimeOffset utcNow = now;
        long nanoseconds;
        public override DateTimeOffset GetUtcNow() => utcNow;
        public override long GetTimestamp() => nanoseconds;
        public override long TimestampFrequency => 1_000_000_000;
        public void Suspend(TimeSpan duration)
        {
            utcNow += duration;
            nanoseconds += checked(duration.Ticks * 100);
        }
    }

    [Fact]
    public async Task SchoolClockSampleExpiresDuringSleep()
    {
        var clock = new SuspendClock(TestData.Now);
        using var handler = new FakeHttp(_ => "{\"STATUS\":0,\"timestamp\":" + clock.GetUtcNow().ToUnixTimeMilliseconds() + "}");
        using var client = new SchoolClient(handler, clock);
        Assert.Equal(clock.GetUtcNow(), await client.SchoolNowAsync());

        clock.Suspend(TimeSpan.FromMinutes(20));

        Assert.Equal(clock.GetUtcNow(), await client.SchoolNowAsync());
        Assert.Equal(2, handler.Requests.Count);
    }

    [Theory]
    [InlineData(20, AutoSignStage.Signed, 1)]
    [InlineData(22, AutoSignStage.Missed, 0)]
    public async Task CalibratedSchoolClockReevaluatesImmediatelyAfterSleep(int sleepMinutes, AutoSignStage expectedStage, int signs)
    {
        var start = TestData.Now.AddMinutes(-25);
        var clock = new SuspendClock(start);
        var preferences = new AccountPreferences(AutoSignEnabled: true, AutoSignRunning: true,
            AutoSignRunningSince: start.AddHours(-1));
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account() with { Settings = preferences }], "a") };
        var data = new MemoryData();
        var school = new FakeSchool { Now = start, Query = (_, day) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(day), CourseId = "course-1", CourseNumber = "CS001" }], "同步成功")) };
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock) { IsForeground = true };
        await model.InitializeAsync();
        await model.TickAsync();
        Assert.Equal(1, school.ClockReads);
        Assert.Empty(model.AutoSignHistory);
        Assert.Equal(TestData.Now.AddMinutes(-5), model.NextAutoSignWakeAt);

        // No Tick runs while asleep; the first resumed tick must use all of the
        // elapsed time instead of waiting sleepMinutes more while awake.
        clock.Suspend(TimeSpan.FromMinutes(sleepMinutes));
        school.Now = clock.GetUtcNow();
        await model.TickAsync();

        Assert.Equal(signs, school.Signs);
        Assert.Equal(expectedStage, Assert.Single(model.AutoSignHistory).Stage);
    }
}
