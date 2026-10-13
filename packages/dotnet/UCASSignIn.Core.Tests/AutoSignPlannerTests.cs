namespace UCASSignIn.Core.Tests;

public sealed class AutoSignPlannerTests
{
    [Fact]
    public void SharedPlanCasesMatchSwift()
    {
        var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../../shared/fixtures/auto-sign-plans.json"));
        using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
        foreach (var item in doc.RootElement.EnumerateArray())
        {
            string Read(string key) => item.GetProperty(key).GetString()!;
            var course = TestData.Course() with { BeginTime = Read("start"), EndTime = Read("end") };
            var now = CourseTime.Parse(course.Day, Read("now"))!.Value;
            var offset = item.GetProperty("courseOffset");
            var occurrenceEnabled = item.GetProperty("occurrenceEnabled");
            var plan = AutoSignPlanner.Create("a", course, new(),
                offset.ValueKind == System.Text.Json.JsonValueKind.Null ? null : new(OffsetMinutes: offset.GetInt32()),
                occurrenceEnabled.ValueKind == System.Text.Json.JsonValueKind.Null ? null : new(Enabled: occurrenceEnabled.GetBoolean()),
                item.GetProperty("running").GetBoolean(),
                Enum.Parse<PreferenceOverride>(Read("courseEnabled"), true), false, now,
                enabledSince: item.TryGetProperty("enabledSince", out var since) ? CourseTime.Parse(course.Day, since.GetString()!) : null)!;
            Assert.Equal(Read("expectedAt"), plan.PlannedAt.ToOffset(CourseTime.ShanghaiOffset).ToString("HH:mm"));
            Assert.Equal(Read("expectedStage"), char.ToLowerInvariant(plan.Stage.ToString()[0]) + plan.Stage.ToString()[1..]);
            if (item.TryGetProperty("expectedParticipating", out var participating))
                Assert.Equal(participating.GetBoolean(), plan.IsParticipating);
        }
    }
    [Fact]
    public void DefaultPlanIsFiveMinutesBeforeClassAndDoesNotCatchUp()
    {
        var course = TestData.Course();
        var at = course.Start!.Value.AddMinutes(-5);
        var plan = AutoSignPlanner.Create("a", course, new(), null, null, true,
            PreferenceOverride.Inherit, false, at, null)!;
        Assert.Equal(at, plan.PlannedAt);
        Assert.Equal(at.AddSeconds(60), plan.Deadline);
        var missed = AutoSignPlanner.Create("a", course, new(), null, null, true,
            PreferenceOverride.Inherit, false, at.AddMinutes(4), null)!;
        Assert.Equal(AutoSignStage.Missed, missed.Stage);
    }

    [Fact]
    public void OccurrenceOverridesCourseAndAccountButCannotBypassPauseOrCourseDisable()
    {
        var course = TestData.Course();
        var at = course.Start!.Value.AddMinutes(-10);
        var courseRule = new AutoSignPolicyOverride(-15, MaxSubmissions: 2);
        var occurrence = new AutoSignOccurrenceOverride(true, at, new(RetryMinutes: 5));
        var plan = AutoSignPlanner.Create("a", course, new(), courseRule, occurrence, true,
            PreferenceOverride.Disabled, false, at, null)!;
        Assert.Equal(at, plan.PlannedAt);
        Assert.Equal(2, plan.Policy.MaxSubmissions);
        Assert.Equal(5, plan.Policy.RetryMinutes);
        Assert.Equal("本次调整", plan.Source);
        Assert.Equal(AutoSignStage.Planned, plan.Stage);
        Assert.Equal(AutoSignStage.Skipped, AutoSignPlanner.Create("a", course, new(), courseRule,
            occurrence, false, PreferenceOverride.Disabled, false, at, null)!.Stage);
        Assert.Equal(AutoSignStage.Skipped, AutoSignPlanner.Create("a", course, new(), courseRule,
            occurrence, true, PreferenceOverride.Disabled, true, at, null)!.Stage);
    }

    [Fact]
    public void InvalidPolicyIsRejectedInsteadOfSilentlyChanged()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new AutoSignPolicy(OffsetMinutes: -26).Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new AutoSignPolicy(MaxSubmissions: 4).Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new AutoSignPolicy(RetryMinutes: 3).Validate());
    }
}
