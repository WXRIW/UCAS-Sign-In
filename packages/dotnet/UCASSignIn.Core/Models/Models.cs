namespace UCASSignIn.Core;

public sealed record SchoolSession(string UserId, string SessionId, string StudentNo, string? Name = null);
public sealed record Course(string Id, string Uuid, string Name, string Teacher, string? Classroom,
    string BeginTime, string EndTime, string Day, bool Signed = false)
{
    public DateTimeOffset? Start => CourseTime.Parse(Day, BeginTime);
    public DateTimeOffset? End => CourseTime.Parse(Day, EndTime);
    public string TimeRange => $"{CourseTime.Display(BeginTime)}–{CourseTime.Display(EndTime)}";
    public string QrIdentifier => System.Text.RegularExpressions.Regex.IsMatch(Id, "^[0-9]{7}$") ? Id : Uuid;
}
public sealed record CourseQueryResult(IReadOnlyList<Course> Courses, string Message, bool FromWeeklyFallback = false, bool FromCache = false);
public enum SignOutcome
{
    Signed, QrExpired, OutsideSignWindow, Unknown
}
public sealed record SignResult(SignOutcome Outcome, string Message, string Status = "", string ErrCode = "", string StuSignId = "");
public sealed record SignInFailure(Guid Id, string Message);
public sealed record QrSnapshot(string Url, long SchoolTimestampMs, DateTimeOffset ExpiresAt, TimeSpan ValidityDuration);
public sealed record Credentials(string Username, string Password);
public sealed record AccountPreferences(bool AutoSignEnabled = false, bool RemindersEnabled = false);
public sealed record StoredAccount(SchoolSession Session, Credentials? Credentials, string LoginUsername,
    DateTimeOffset LastUsedAt, bool RequiresLogin = false, AccountPreferences? Settings = null)
{
    public string Id => Session.StudentNo;
    public AccountPreferences Preferences => Settings ?? new();
}
public sealed record AccountVault(int Version, List<StoredAccount> Accounts, string? ActiveAccountId)
{
    public static AccountVault Empty => new(1, [], null);
    public void Validate()
    {
        if (Version != 1)
            throw new SchoolException("ACCOUNT_STORE_VERSION", "本机账户数据版本不受支持，请更新应用");
        if (Accounts is null || Accounts.Any(a => a?.Session is null || string.IsNullOrWhiteSpace(a.Id) || string.IsNullOrWhiteSpace(a.Session.UserId) || string.IsNullOrWhiteSpace(a.Session.SessionId))
            || Accounts.Select(a => a.Id).Distinct().Count() != Accounts.Count
            || (ActiveAccountId is not null && !Accounts.Any(a => a.Id == ActiveAccountId)))
            throw new SchoolException("ACCOUNT_STORE_INVALID", "本机账户数据无法读取，原始数据已保留");
    }
}
public sealed record AttendanceRecord(string CourseName, DateTimeOffset Date, string Message, bool Succeeded);
public sealed record CourseCache(List<Course> Courses, DateTimeOffset UpdatedAt, bool FromWeeklyFallback = false);
public sealed record Reminder(string Id, string AccountId, string CourseId, string Day, string Title, string Body, DateTimeOffset At);
public sealed class SchoolException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
    public bool IsSessionExpired => Code is "LOGIN_EXPIRED" or "HTTP_401" or "HTTP_403";
}
