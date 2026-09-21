namespace UCASSignIn.Core;

public readonly record struct ScheduleDateRange(DateOnly Begin, DateOnly End)
{
    public bool Contains(DateOnly date) => date >= Begin && date <= End;
    public DateOnly Clamp(DateOnly date) => date < Begin ? Begin : date > End ? End : date;
    public override string ToString() => $"{Begin:yyyy年M月d日} - {End:yyyy年M月d日}";
}

public static class ScheduleCalendar
{
    public static ScheduleDateRange? Range(SchoolSemester? semester)
    {
        if (semester is null || CourseTime.NormalizeDay(semester.BeginDate) is not { } first
            || CourseTime.NormalizeDay(semester.EndDate) is not { } last) return null;
        var begin = CourseTime.Date(first); var end = CourseTime.Date(last);
        return end >= begin && end.DayNumber - begin.DayNumber <= 366 ? new(begin, end) : null;
    }
    public static int? WeekNumber(DateOnly date, SchoolSemester? semester) => Range(semester) is { } range && range.Contains(date)
        ? (ScheduleLayout.Monday(date).DayNumber - ScheduleLayout.Monday(range.Begin).DayNumber) / 7 + 1 : null;
    public static int WeekCount(SchoolSemester? semester) => Range(semester) is { } range ? WeekNumber(range.End, semester)!.Value : 0;
    public static ScheduleDateRange? WeekRange(SchoolSemester? semester, int week)
    {
        if (Range(semester) is not { } range || week < 1 || week > WeekCount(semester)) return null;
        var monday = ScheduleLayout.Monday(range.Begin).AddDays((week - 1) * 7);
        return new(range.Clamp(monday), range.Clamp(monday.AddDays(6)));
    }
    public static DateOnly? DateInWeek(SchoolSemester? semester, int week, DateOnly preserving)
    {
        if (WeekRange(semester, week) is not { } range) return null;
        return range.Clamp(ScheduleLayout.Monday(range.Begin).AddDays(((int)preserving.DayOfWeek + 6) % 7));
    }
    public static DateOnly? SwitchSemester(DateOnly selected, SchoolSemester? current, SchoolSemester target)
        => DateInWeek(target, Math.Min(WeekNumber(selected, current) ?? 1, WeekCount(target)), selected);
    public static DateOnly? AdjacentWeek(DateOnly selected, bool next, ScheduleDateRange? range)
    {
        var number = Math.Clamp(selected.DayNumber + (next ? 7 : -7), DateOnly.MinValue.DayNumber, DateOnly.MaxValue.DayNumber);
        var target = DateOnly.FromDayNumber(number);
        target = range?.Clamp(target) ?? target;
        return ScheduleLayout.Monday(target) == ScheduleLayout.Monday(selected) ? null : target;
    }
    public static IReadOnlyList<DateOnly> VisibleDays(DateOnly selected, SchoolSemester? semester)
    {
        var monday = ScheduleLayout.Monday(selected); var range = Range(semester);
        return Enumerable.Range(0, 7).Select(monday.AddDays).Where(d => range is null || range.Value.Contains(d)).ToArray();
    }
    public static SchoolSemester DemoSemester(DateOnly date)
    {
        var begin = new DateOnly(date.Year, date.Month <= 6 ? 1 : 7, 1);
        var end = date.Month <= 6 ? new DateOnly(date.Year, 6, 30) : new DateOnly(date.Year, 12, 31);
        return new("demo", "演示学期", CourseTime.DayKey(begin), CourseTime.DayKey(end), true);
    }
}
