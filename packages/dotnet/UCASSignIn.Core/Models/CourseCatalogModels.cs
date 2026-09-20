namespace UCASSignIn.Core;

public sealed record SchoolSemester(string Id, string Name, string BeginDate, string EndDate, bool IsCurrent);

public sealed record CatalogCourse(string Id, string Number, string Name, string Teacher, string? Classroom,
    string SemesterId, string BeginDate, string EndDate, int? TotalSessions = null, int? CompletedSessions = null);

public sealed record CourseAttendance(string Id, string CourseId, string ScheduledCourseId, string Day,
    string BeginTime, string EndTime, bool Signed);

public sealed record CourseAttendanceSummary(int SignedCount, int UnsignedCount, IReadOnlyList<CourseAttendance> Records);

public sealed record SemesterCache(int Version, string AccountId, DateTimeOffset UpdatedAt, List<SchoolSemester> Semesters)
{
    public const int CurrentVersion = 1;
}

public sealed record CourseCatalogCache(int Version, string AccountId, string SemesterId, DateTimeOffset UpdatedAt,
    List<CatalogCourse> Courses)
{
    public const int CurrentVersion = 1;
}

public sealed record CourseAttendanceCache(int Version, string AccountId, string SemesterId, string CourseId,
    DateTimeOffset UpdatedAt, CourseAttendanceSummary Summary)
{
    public const int CurrentVersion = 1;
}
