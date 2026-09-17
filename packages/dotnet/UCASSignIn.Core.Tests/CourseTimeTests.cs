namespace UCASSignIn.Core.Tests;

public class CourseTimeTests
{
    [Theory]
    [InlineData("8:30")]
    [InlineData("08:30:00")]
    [InlineData("830")]
    [InlineData("0830")]
    [InlineData("083000")]
    [InlineData("08：30")]
    [InlineData("2026-09-16T00:30:00Z")]
    [InlineData("2026/09/16 08:30:00+0800")]
    public void ParsesSchoolTimes(string input) => Assert.Equal(new DateTimeOffset(2026, 9, 16, 8, 30, 0, TimeSpan.FromHours(8)), CourseTime.Parse("20260916", input));
    [Theory]
    [InlineData("20260230", "08:30")]
    [InlineData("invalid", "08:30")]
    [InlineData("20260916", "24:00")]
    [InlineData("20260916", "12:60")]
    [InlineData("20260916", "8")]
    [InlineData("20260916", "08:30+2460")]
    public void RejectsInvalidTimes(string day, string time) => Assert.Null(CourseTime.Parse(day, time));
    [Fact]
    public void SignWindowUsesInclusiveStartExclusiveEnd()
    {
        var c = TestData.Course();
        Assert.False(CourseTime.InSignWindow(c, c.Start!.Value.AddMinutes(-25).AddTicks(-1)));
        Assert.True(CourseTime.InSignWindow(c, c.Start.Value.AddMinutes(-25)));
        Assert.False(CourseTime.InSignWindow(c, c.End!.Value));
        Assert.False(CourseTime.InSignWindow(c with
        {
            EndTime = "07:00"
        }, c.Start.Value));
    }
    [Fact]
    public void NextSkipsConsecutiveSameNameAndOtherDays()
    {
        var c = TestData.Course();
        var (_, next) = CourseTime.CurrentAndNext([c, c with { Id = "1234568", BeginTime = "09:00" }, c with { Id = "1234569", Name = "另一门课", BeginTime = "10:30" }], c.Start!.Value);
        Assert.Equal("1234569", next?.Id);
    }
    [Fact]
    public void DayUsesShanghaiInsteadOfDeviceZone()
    {
        Assert.Equal(new DateOnly(2026, 9, 17), CourseTime.Today(new FakeClock(new DateTimeOffset(2026, 9, 16, 16, 0, 0, TimeSpan.Zero))));
    }
}
