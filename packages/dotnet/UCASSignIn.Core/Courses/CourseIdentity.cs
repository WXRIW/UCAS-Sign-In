namespace UCASSignIn.Core;

public static class CourseIdentity
{
    public static string Normalize(string? text) => (text ?? "").Trim();
    public static SchoolSemester? Semester(DateOnly date, IEnumerable<SchoolSemester> semesters)
    {
        var day = CourseTime.DayKey(date);
        var matches = semesters.Where(s => CourseTime.NormalizeDay(s.BeginDate) is { } begin && CourseTime.NormalizeDay(s.EndDate) is { } end
            && string.CompareOrdinal(begin, day) <= 0 && string.CompareOrdinal(day, end) <= 0).Take(2).ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }
    public static CatalogCourse? Resolve(Course course, IEnumerable<SchoolSemester> semesters, IEnumerable<CatalogCourse> catalog)
    {
        if (CourseTime.NormalizeDay(course.Day) is not { } day || Semester(CourseTime.Date(day), semesters) is not { } semester) return null;
        var number = Normalize(course.CourseNumber);
        var matches = catalog.Where(c => c.SemesterId == semester.Id && (number.Length > 0
            ? Normalize(c.Number) == number : !string.IsNullOrWhiteSpace(course.CourseId) && c.Id == course.CourseId)).Distinct().Take(2).ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }
    public static Course PreserveFields(Course incoming, Course? previous) => previous is null
        || incoming.Id != previous.Id || CourseTime.NormalizeDay(incoming.Day) != CourseTime.NormalizeDay(previous.Day) ? incoming : incoming with
        { CourseId = incoming.CourseId ?? previous.CourseId, CourseNumber = incoming.CourseNumber ?? previous.CourseNumber, TeacherId = incoming.TeacherId ?? previous.TeacherId };
    public static bool SameArrangement(IEnumerable<Course> left, IEnumerable<Course> right)
    {
        static string Key(Course c) => System.Text.Json.JsonSerializer.Serialize(new[] { CourseTime.NormalizeDay(c.Day), Normalize(c.Id), Normalize(c.Uuid),
            Normalize(c.CourseId), Normalize(c.CourseNumber), Normalize(c.TeacherId), Normalize(c.Name), Normalize(c.Teacher), Normalize(c.Classroom),
            c.Start?.ToString("O") ?? Normalize(c.BeginTime), c.End?.ToString("O") ?? Normalize(c.EndTime) });
        return left.Select(Key).Order(StringComparer.Ordinal).SequenceEqual(right.Select(Key).Order(StringComparer.Ordinal));
    }
    public static CoursePreferences MergePreferences(IEnumerable<CoursePreferences> source)
    {
        var values = source.Select(x => x.Normalized()).ToArray();
        static PreferenceOverride Pick(IEnumerable<PreferenceOverride> values, PreferenceOverride strict) => values.Contains(strict) ? strict
            : values.FirstOrDefault(x => x != PreferenceOverride.Inherit);
        return new(Pick(values.Select(x => x.Confirmation), PreferenceOverride.Enabled), Pick(values.Select(x => x.AutoSign), PreferenceOverride.Disabled),
            Pick(values.Select(x => x.Reminders), PreferenceOverride.Disabled), values.Select(x => x.ReminderLeadMinutes).Max(), values.Any(x => x.SignInDisabled));
    }
}
