namespace UCASSignIn.Core;

public sealed record SchoolSession(string UserId, string SessionId, string StudentNo, string? Name = null);
public sealed record Course(string Id, string Uuid, string Name, string Teacher, string? Classroom,
    string BeginTime, string EndTime, string Day, bool Signed = false, string? CourseId = null,
    string? CourseNumber = null, string? TeacherId = null, bool? SignStatusKnown = true)
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
public enum PreferenceOverride
{
    Inherit = 0,
    Enabled = 1,
    Disabled = 2
}
public sealed record CoursePreferences(
    PreferenceOverride Confirmation = PreferenceOverride.Inherit,
    PreferenceOverride AutoSign = PreferenceOverride.Inherit,
    PreferenceOverride Reminders = PreferenceOverride.Inherit,
    int? ReminderLeadMinutes = null,
    bool SignInDisabled = false,
    AutoSignPolicyOverride? AutoSignRule = null,
    DateTimeOffset? AutoSignEnabledSince = null)
{
    public CoursePreferences Normalized() => this with
    {
        Confirmation = Normalize(Confirmation),
        AutoSign = Normalize(AutoSign),
        Reminders = Normalize(Reminders),
        ReminderLeadMinutes = ReminderLeadMinutes is 5 or 10 or 15 or 30 ? ReminderLeadMinutes : null
    };
    public static PreferenceOverride Normalize(PreferenceOverride value) => value is PreferenceOverride.Inherit or PreferenceOverride.Enabled or PreferenceOverride.Disabled ? value : PreferenceOverride.Inherit;
    public static bool Resolve(PreferenceOverride value, bool inherited) => Normalize(value) switch
    {
        PreferenceOverride.Enabled => true,
        PreferenceOverride.Disabled => false,
        _ => inherited
    };
}
public sealed record AccountPreferences
{
    public bool AutoSignEnabled { get; init; }
    public bool RemindersEnabled { get; init; }
    public bool ConfirmBeforeSign { get; init; }
    public int ReminderLeadMinutes { get; init; }
    public Dictionary<string, CoursePreferences> Courses { get; init; }
    public bool? AutoSignRunning { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool AutoSignIsRunning => AutoSignRunning ??
        (AutoSignEnabled || Courses.Values.Any(x => !x.SignInDisabled && x.AutoSign == PreferenceOverride.Enabled)
         || AutoSignOccurrences.Values.Any(x => x.Enabled == true));
    public AutoSignPolicy AutoSignRule { get; init; }
    public Dictionary<string, AutoSignOccurrenceOverride> AutoSignOccurrences { get; init; }
    public DateTimeOffset? AutoSignPausedUntil { get; init; }
    public bool AutoSignV2Acknowledged { get; init; }
    public DateTimeOffset? AutoSignRunningSince { get; init; }
    public DateTimeOffset? AutoSignDefaultSince { get; init; }
    public bool AutoSignSinceUsesSchoolTime { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool NeedsAutoSignMigrationNotice => !AutoSignV2Acknowledged &&
        (AutoSignEnabled || Courses.Values.Any(x => x.AutoSign == PreferenceOverride.Enabled));
    public AccountPreferences UnifyingAutoSign(DateTimeOffset now)
    {
        var running = AutoSignIsRunning;
        if (AutoSignRunning is null && !running && !AutoSignEnabled) return this;
        return this with
        {
            AutoSignRunning = running,
            AutoSignEnabled = running,
            AutoSignDefaultSince = running && !AutoSignEnabled
                ? AutoSignDefaultSince is { } since && since > now ? since : now
                : AutoSignDefaultSince
        };
    }
    public AccountPreferences(bool AutoSignEnabled = false, bool RemindersEnabled = false, bool ConfirmBeforeSign = false,
        int ReminderLeadMinutes = 10, Dictionary<string, CoursePreferences>? Courses = null,
        bool? AutoSignRunning = null, AutoSignPolicy? AutoSignRule = null,
        Dictionary<string, AutoSignOccurrenceOverride>? AutoSignOccurrences = null,
        DateTimeOffset? AutoSignPausedUntil = null, bool AutoSignV2Acknowledged = false,
        DateTimeOffset? AutoSignRunningSince = null, DateTimeOffset? AutoSignDefaultSince = null,
        bool AutoSignSinceUsesSchoolTime = false)
    {
        this.AutoSignEnabled = AutoSignEnabled;
        this.RemindersEnabled = RemindersEnabled;
        this.ConfirmBeforeSign = ConfirmBeforeSign;
        this.ReminderLeadMinutes = ReminderLeadMinutes is 5 or 10 or 15 or 30 ? ReminderLeadMinutes : 10;
        this.Courses = (Courses ?? []).Where(x => !string.IsNullOrWhiteSpace(x.Key))
            .ToDictionary(x => x.Key, x => (x.Value ?? new()).Normalized());
        this.AutoSignRunning = AutoSignRunning;
        this.AutoSignRule = AutoSignRule ?? new();
        this.AutoSignOccurrences = AutoSignOccurrences ?? [];
        this.AutoSignPausedUntil = AutoSignPausedUntil;
        this.AutoSignV2Acknowledged = AutoSignV2Acknowledged;
        this.AutoSignRunningSince = AutoSignRunningSince;
        this.AutoSignDefaultSince = AutoSignDefaultSince;
        this.AutoSignSinceUsesSchoolTime = AutoSignSinceUsesSchoolTime;
    }
    public bool Equals(AccountPreferences? other) => other is not null
        && AutoSignEnabled == other.AutoSignEnabled && RemindersEnabled == other.RemindersEnabled
        && ConfirmBeforeSign == other.ConfirmBeforeSign && ReminderLeadMinutes == other.ReminderLeadMinutes
        && AutoSignRunning == other.AutoSignRunning && AutoSignRule == other.AutoSignRule
        && AutoSignPausedUntil == other.AutoSignPausedUntil
        && AutoSignV2Acknowledged == other.AutoSignV2Acknowledged
        && AutoSignRunningSince == other.AutoSignRunningSince && AutoSignDefaultSince == other.AutoSignDefaultSince
        && AutoSignSinceUsesSchoolTime == other.AutoSignSinceUsesSchoolTime
        && AutoSignOccurrences.Count == other.AutoSignOccurrences.Count && AutoSignOccurrences.All(x => other.AutoSignOccurrences.TryGetValue(x.Key, out var value) && value == x.Value)
        && Courses.Count == other.Courses.Count && Courses.All(x => other.Courses.TryGetValue(x.Key, out var value) && value == x.Value);
    public override int GetHashCode()
    {
        var hash = HashCode.Combine(AutoSignEnabled, RemindersEnabled, ConfirmBeforeSign, ReminderLeadMinutes, AutoSignRunning, AutoSignRule, AutoSignPausedUntil);
        hash = HashCode.Combine(hash, AutoSignV2Acknowledged, AutoSignRunningSince, AutoSignDefaultSince, AutoSignSinceUsesSchoolTime);
        foreach (var item in Courses.OrderBy(x => x.Key)) hash = HashCode.Combine(hash, item.Key, item.Value);
        foreach (var item in AutoSignOccurrences.OrderBy(x => x.Key)) hash = HashCode.Combine(hash, item.Key, item.Value);
        return hash;
    }
}
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
public sealed record AttendanceRecord(string CourseName, DateTimeOffset Date, string Message, bool Succeeded,
    string? CourseId = null, string? ScheduledCourseId = null);
public sealed record CourseCache(List<Course> Courses, DateTimeOffset UpdatedAt, bool FromWeeklyFallback = false, long WriteSequence = 0);
public sealed record Reminder(string Id, string AccountId, string CourseId, string Day, string Title, string Body, DateTimeOffset At);
public sealed class SchoolException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
    public bool IsSessionExpired => Code is "LOGIN_EXPIRED" or "HTTP_401" or "HTTP_403";
}
