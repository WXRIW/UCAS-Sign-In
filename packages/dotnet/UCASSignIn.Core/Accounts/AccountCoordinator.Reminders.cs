namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    public async Task<Course?> LoadReminderCourseAsync(string accountId, string courseId, string day)
    {
        if (IsDemo || ActiveAccount?.Id != accountId || string.IsNullOrWhiteSpace(courseId)
            || CourseTime.NormalizeDay(day) is not { } normalized) return null;
        var epoch = Generation;
        var date = CourseTime.Date(normalized);
        // A reminder explicitly needs this day even when the visible schedule is weekly.
        // Do not chain SelectDateAsync and EnterDayAsync: a failed first read would retry.
        SelectedDate = date;
        Notify();
        await EnterDayAsync(date);
        if (epoch != Generation || SelectedDate != date || !freshDays.Contains(normalized)) return null;
        return Courses.FirstOrDefault(c => c.Id == courseId && c.Day == normalized);
    }
}
