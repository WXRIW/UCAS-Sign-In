namespace UCASSignIn.Core.Tests;

public sealed class ScheduleNavigationTests
{
    static readonly SchoolSemester CrossYear = new("winter", "跨年", "20261230", "20270112", false);
    static SchoolSemester Term(string id, string begin, string end) => new(id, id, begin, end, false);
    [Fact] public void CrossYearWeeksAreClippedAndDoNotReset()
    {
        Assert.Equal(3, ScheduleCalendar.WeekCount(CrossYear));
        Assert.Equal(new ScheduleDateRange(new(2026, 12, 30), new(2027, 1, 3)), ScheduleCalendar.WeekRange(CrossYear, 1));
        Assert.Equal(new ScheduleDateRange(new(2027, 1, 4), new(2027, 1, 10)), ScheduleCalendar.WeekRange(CrossYear, 2));
        Assert.Equal("2027年1月11日 - 2027年1月12日", ScheduleCalendar.WeekRange(CrossYear, 3)!.Value.ToString());
        Assert.Equal(2, ScheduleCalendar.WeekNumber(new(2027, 1, 4), CrossYear));
        Assert.Null(ScheduleCalendar.WeekNumber(new(2027, 1, 13), CrossYear));
        Assert.Null(ScheduleCalendar.WeekRange(CrossYear, 4));
    }
    [Fact] public void AdjacentNavigationClampsIntoPartialWeeks()
    {
        var range = ScheduleCalendar.Range(CrossYear);
        Assert.Equal(new DateOnly(2026, 12, 30), ScheduleCalendar.AdjacentWeek(new(2027, 1, 4), false, range));
        Assert.Equal(new DateOnly(2027, 1, 12), ScheduleCalendar.AdjacentWeek(new(2027, 1, 10), true, range));
        Assert.Null(ScheduleCalendar.AdjacentWeek(new(2027, 1, 3), false, range));
        Assert.Null(ScheduleCalendar.AdjacentWeek(new(2027, 1, 11), true, range));
    }
    [Fact] public void SemesterSwitchPreservesWeekAndWeekdayThenClamps()
    {
        var origin = Term("long", "20260901", "20261031");
        Assert.Equal(4, ScheduleCalendar.WeekNumber(new(2026, 9, 23), origin));
        Assert.Equal(new DateOnly(2027, 1, 6), ScheduleCalendar.SwitchSemester(new(2026, 9, 23), origin, CrossYear with { EndDate = "20270110" }));
        Assert.Equal(new DateOnly(2027, 1, 5), ScheduleCalendar.SwitchSemester(new(2026, 9, 23), origin, CrossYear with { EndDate = "20270105" }));
        Assert.Equal(new DateOnly(2026, 12, 30), ScheduleCalendar.SwitchSemester(new(2026, 9, 23), null, CrossYear));
    }
    [Fact] public void RangesAcceptEndDateTimeAndRejectInvalidMetadata()
    {
        Assert.True(ScheduleCalendar.Range(CrossYear with { EndDate = "2027-01-12 23:59:59" })!.Value.Contains(new(2027, 1, 12)));
        Assert.Null(ScheduleCalendar.Range(CrossYear with { BeginDate = "invalid" }));
        Assert.Null(ScheduleCalendar.Range(CrossYear with { EndDate = "20261229" }));
        Assert.Null(ScheduleCalendar.Range(CrossYear with { EndDate = "20300101" }));
        Assert.Empty(ScheduleCalendar.VisibleDays(new(2026, 9, 16), CrossYear));
    }
    [Fact] public async Task HistoricalTermsDoNotExtendViewedTermNavigation()
    {
        var h = new Harness(CrossYear, Term("old", "20260101", "20260630"));
        await h.Model.InitializeAsync(); await h.Model.SelectDateAsync(new(2026, 12, 30));
        Assert.Null(h.Model.PreviousScheduleWeek); Assert.False(h.Model.CanSelectVisibleDate(new(2026, 12, 29)));
        Assert.Equal("winter", h.Model.ScheduleSemesters[0].Id);
        await h.Model.SelectDateAsync(new(2027, 1, 12)); Assert.Null(h.Model.NextScheduleWeek);
        Assert.True(h.Model.CanSelectVisibleDate(new(2027, 1, 12))); Assert.False(h.Model.CanSelectVisibleDate(new(2027, 1, 13)));
    }
    [Fact] public async Task OneDayTermDoesNotFillOutsideDatesAndHasCompleteCache()
    {
        var h = new Harness(Term("one", "20260916", "20260916"));
        await h.Model.InitializeAsync();
        Assert.True(h.Model.HasCompleteWeek); Assert.Single(h.Model.VisibleScheduleDays);
        Assert.All(h.DailyReads, d => Assert.Equal(new DateOnly(2026, 9, 16), d));
        Assert.Null(h.Model.PreviousScheduleWeek); Assert.Null(h.Model.NextScheduleWeek);
    }
    [Fact] public async Task UnknownGapAndOverlappingDatesHaveNoInventedWeek()
    {
        var h = new Harness(Term("a", "20260901", "20260916"), Term("b", "20260916", "20260930"), Term("c", "20261015", "20261031"));
        await h.Model.InitializeAsync(); Assert.Null(h.Model.ViewedSemester); Assert.Null(h.Model.ScheduleWeekNumber);
        await h.Model.SelectDateAsync(new(2026, 10, 7)); Assert.Null(h.Model.ViewedDateRange); Assert.Equal(7, h.Model.VisibleScheduleDays.Count);
        var missing = new Harness(Term("bad", "oops", "20261031")); await missing.Model.InitializeAsync();
        Assert.Empty(missing.Model.ScheduleSemesters); Assert.Null(missing.Model.ScheduleWeekNumber); Assert.NotNull(missing.Model.PreviousScheduleWeek);
    }
    [Fact] public async Task FirstMetadataClampsSelectionAndReturnTodayUsesTotalRange()
    {
        var h = new Harness(CrossYear); await h.Model.InitializeAsync();
        Assert.Equal(new DateOnly(2026, 12, 30), h.Model.SelectedDate); Assert.False(h.Model.CanReturnToToday);
        // Initial activation checks today once; discovery must not then fill that obsolete visible week.
        Assert.All(h.DailyReads, d => Assert.True(d == new DateOnly(2026, 9, 16) || ScheduleCalendar.Range(CrossYear)!.Value.Contains(d)));
        await h.Model.ReturnToScheduleTodayAsync(); Assert.Equal(new DateOnly(2026, 12, 30), h.Model.SelectedDate);
    }
    [Fact] public async Task WeekSelectionIsGuardedAndSameWeekHasNoRequests()
    {
        var h = new Harness(CrossYear); await h.Model.InitializeAsync();
        var reads = h.School.WeekReads; var daily = h.DailyReads.Count; var date = h.Model.SelectedDate;
        // Opening/changing a temporary picker only calls pure calendar functions.
        _ = ScheduleCalendar.WeekRange(h.Model.ViewedSemester, 3);
        Assert.Equal(date, h.Model.SelectedDate); Assert.Equal(reads, h.School.WeekReads);
        await h.Model.SelectScheduleWeekAsync(1, h.Model.Generation, "winter");
        Assert.Equal(reads, h.School.WeekReads); Assert.Equal(daily, h.DailyReads.Count);
        await h.Model.SelectScheduleWeekAsync(2, Guid.NewGuid(), "winter"); Assert.Equal(date, h.Model.SelectedDate);
        await h.Model.SelectScheduleWeekAsync(2, h.Model.Generation, "removed"); Assert.Equal(date, h.Model.SelectedDate);
        await h.Model.SelectScheduleWeekAsync(2, h.Model.Generation, "winter"); Assert.Equal(new DateOnly(2027, 1, 6), h.Model.SelectedDate);
        Assert.Equal(reads, h.School.WeekReads);
        await h.Model.SelectScheduleDateAsync(new(2027, 2, 1), h.Model.Generation, "winter"); Assert.Equal(new DateOnly(2027, 1, 6), h.Model.SelectedDate);
    }
    [Fact] public async Task ManualRefreshAppliesChangedRangeBeforeChoosingTargets()
    {
        var h = new Harness(Term("one", "20260916", "20260916")); await h.Model.InitializeAsync();
        var oldLayout = h.Model.WeekSchedule(); h.Terms = [Term("two", "20270112", "20270112")];
        h.DailyReads.Clear(); await h.Model.RefreshScheduleAsync();
        Assert.Equal(new DateOnly(2027, 1, 12), h.Model.SelectedDate); Assert.True(h.Model.HasCompleteWeek);
        Assert.Equal("two", h.Model.WeekSchedule().ViewedSemesterId); Assert.NotSame(oldLayout, h.Model.WeekSchedule());
        Assert.All(h.DailyReads, d => Assert.Equal(new DateOnly(2027, 1, 12), d));
        await h.Model.SelectScheduleWeekAsync(1, h.Model.Generation, "one"); Assert.Equal("two", h.Model.ViewedSemester!.Id);
    }
    [Fact] public async Task RangeExtensionInvalidatesFreshSnapshotAndSameWeekLayout()
    {
        var h = new Harness(Term("one", "20260916", "20260916")); await h.Model.InitializeAsync(); var layout = h.Model.WeekSchedule();
        h.Terms = [Term("one", "20260916", "20260918")]; await h.Model.RefreshCatalogAsync(true); await h.Model.RefreshScheduleAsync(false);
        Assert.Equal(2, h.School.WeekReads); Assert.Equal("20260918", h.Data.Schedules["a|one"].Semester.EndDate);
        Assert.NotSame(layout, h.Model.WeekSchedule()); Assert.Equal(3, h.Model.VisibleScheduleDays.Count);
    }
    [Fact] public async Task SameNaturalWeekTermsHaveSeparateFilteredLayouts()
    {
        var h = new Harness(Term("a", "20260914", "20260916"), Term("b", "20260917", "20260920"));
        h.School.WeekQuery = (_, d) => Task.FromResult(new WeeklyScheduleResult(
            [Course("20260916"), Course("20260917"), Course("20260924")], Enumerable.Range(0, 7).Select(i => CourseTime.DayKey(ScheduleLayout.Monday(d).AddDays(i))).ToArray()));
        await h.Model.InitializeAsync(); h.Model.ShowOtherWeeks = true; var first = h.Model.WeekSchedule();
        await h.Model.SelectScheduleSemesterAsync("b", h.Model.Generation); var second = h.Model.WeekSchedule();
        Assert.Equal("a", first.ViewedSemesterId); Assert.Equal("b", second.ViewedSemesterId); Assert.NotSame(first, second);
        Assert.Single(first.Blocks); Assert.Single(second.Blocks);
        Assert.All(first.Blocks, b => Assert.InRange(b.Day, new DateOnly(2026, 9, 14), new(2026, 9, 16)));
        Assert.All(second.Blocks, b => Assert.InRange(b.Day, new DateOnly(2026, 9, 17), new(2026, 9, 20)));
    }
    [Fact] public void BoundaryLayoutOmitsOutsideActualUnplacedAndProjectedPreview()
    {
        var source = new[] { Course("20261230"), Course("20261228"), Course("20261229") with { BeginTime = "invalid" }, Course("20270104") };
        var layout = ScheduleLayout.Build(new(2026, 12, 30), source, [CrossYear], [], true, new());
        Assert.Equal("winter", layout.ViewedSemesterId);
        Assert.Equal(new DateOnly(2026, 12, 30), Assert.Single(layout.Blocks).Day);
        Assert.Empty(layout.Unplaced);
    }
    [Fact] public async Task SnapshotMetadataIsFallbackWhenSemesterListIsAbsent()
    {
        var h = new Harness();
        h.Data.Schedules["a|winter"] = new(1, 1, "a", CrossYear, [], TestData.Now);
        h.School.SemesterQuery = () => throw new IOException("offline");
        await h.Model.InitializeAsync();
        Assert.Equal(CrossYear, Assert.Single(h.Model.ScheduleSemesters));
        Assert.Equal(new DateOnly(2026, 12, 30), h.Model.SelectedDate);
        Assert.True(h.Model.HasCompleteWeek); Assert.Equal(0, h.School.WeekReads);
    }
    [Fact] public async Task FailedHistoricalSyncDoesNotPolluteCurrentWeek()
    {
        var h = new Harness(Term("now", "20260914", "20260920"), Term("old", "20260801", "20260802")); await h.Model.InitializeAsync();
        h.School.WeekQuery = (_, d) => d.Month == 8 ? throw new IOException("old failed") : Task.FromResult(Week(d));
        await h.Model.SelectScheduleSemesterAsync("old", h.Model.Generation); Assert.NotNull(h.Model.ScheduleError);
        await h.Model.SelectScheduleSemesterAsync("now", h.Model.Generation); Assert.Null(h.Model.ScheduleError);
    }
    [Fact] public async Task AccountSwitchRejectsAllStalePickerCommits()
    {
        var h = new Harness(CrossYear); await h.Model.InitializeAsync(); var generation = h.Model.Generation;
        await h.Model.SwitchAsync("b"); var selected = h.Model.SelectedDate;
        await h.Model.SelectScheduleWeekAsync(2, generation, "winter");
        await h.Model.SelectScheduleDateAsync(new(2027, 1, 6), generation, "winter");
        await h.Model.SelectScheduleSemesterAsync("winter", generation);
        Assert.Equal(selected, h.Model.SelectedDate);
    }
    [Fact] public async Task EmptyVisibleDaySetIsNotComplete()
    {
        var h = new Harness(CrossYear); await h.Model.InitializeAsync();
        await h.Model.SelectDateAsync(new(2028, 1, 1));
        Assert.Empty(h.Model.VisibleScheduleDays); Assert.False(h.Model.HasCompleteWeek);
    }
    [Fact] public async Task DemoCatalogAndScheduleUseSameHalfYear()
    {
        var h = new Harness(); await h.Model.InitializeDemoAsync(); await h.Model.EnterScheduleAsync();
        Assert.Equal(new ScheduleDateRange(new(2026, 7, 1), new(2026, 12, 31)), h.Model.ViewedDateRange);
        Assert.All(h.Model.CatalogCourses, c => { Assert.Equal("20260701", c.BeginDate); Assert.Equal("20261231", c.EndDate); });
        Assert.True(h.Model.HasCompleteWeek); Assert.Equal(0, h.School.WeekReads);
    }
    static Course Course(string day) => new("id-" + day, "uuid-" + day, "课程", "教师", "A101", "08:00", "09:00", day, false, CourseNumber: "CS1");
    static WeeklyScheduleResult Week(DateOnly d) => new([], Enumerable.Range(0, 7).Select(i => CourseTime.DayKey(ScheduleLayout.Monday(d).AddDays(i))).ToArray());
    sealed class Harness
    {
        public IReadOnlyList<SchoolSemester> Terms;
        public readonly MemoryScheduleData Data = new();
        public readonly FakeSchool School = new();
        public readonly List<DateOnly> DailyReads = [];
        public readonly AccountCoordinator Model;
        public Harness(params SchoolSemester[] terms)
        {
            Terms = terms;
            School.SemesterQuery = () => Task.FromResult(Terms);
            School.Query = (_, d) => { DailyReads.Add(d); return Task.FromResult(new CourseQueryResult([], "")); };
            School.WeekQuery = (_, d) => Task.FromResult(Week(d));
            Model = new(School, new MemoryAccounts { Vault = new(1, [TestData.Account(), TestData.Account("b")], "a") }, Data, Data, new FakeReminders(), new FakeClock(TestData.Now));
            Model.ScheduleMode = ScheduleMode.Week;
        }
    }
}
