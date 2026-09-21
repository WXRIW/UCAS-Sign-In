using System.Globalization;
using System.Text.RegularExpressions;
namespace UCASSignIn.Core;

public static class CourseTime
{
    static readonly BoundedCache<string, string?> days = new(2048);
    static readonly BoundedCache<(string Day, string Time), DateTimeOffset?> times = new(4096);
    public static readonly TimeSpan ShanghaiOffset = TimeSpan.FromHours(8);
    public static DateOnly Today(TimeProvider? clock = null) => DateOnly.FromDateTime((clock ?? TimeProvider.System).GetUtcNow().ToOffset(ShanghaiOffset).DateTime);
    public static string DayKey(DateOnly date) => date.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
    public static string? NormalizeDay(string? raw) => days.Get(raw ?? "", NormalizeDayCore);
    static string? NormalizeDayCore(string raw)
    {
        var m = Regex.Match(raw?.Trim() ?? "", @"^(\d{4})[-/]?(\d{2})[-/]?(\d{2})(?:[T ].*)?$");
        return m.Success && DateOnly.TryParseExact($"{m.Groups[1]}{m.Groups[2]}{m.Groups[3]}", "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? DayKey(d) : null;
    }
    public static DateOnly Date(string day) => DateOnly.ParseExact(NormalizeDay(day) ?? throw new FormatException("无效课程日期"), "yyyyMMdd", CultureInfo.InvariantCulture);
    public static DateTimeOffset? Parse(string day, string time) => times.Get((day, time), key => ParseCore(key.Day, key.Time));
    static DateTimeOffset? ParseCore(string day, string time)
    {
        var value = (time ?? "").Trim().Replace('：', ':').Replace('．', '.');
        var full = Regex.Match(value, @"^(\d{4}[-/]\d{2}[-/]\d{2})[T ]+(.+)$");
        if (full.Success)
        {
            day = full.Groups[1].Value;
            value = full.Groups[2].Value;
        }
        if (NormalizeDay(day) is not { } key)
            return null;
        var offset = ShanghaiOffset;
        var zone = Regex.Match(value, @"^(.*?)(Z|[+-]\d{2}:?\d{2})$");
        if (zone.Success)
        {
            value = zone.Groups[1].Value;
            var z = zone.Groups[2].Value.Replace(":", "");
            if (z == "Z")
                offset = TimeSpan.Zero;
            else
            {
                int h = int.Parse(z[1..3]), m = int.Parse(z[3..5]);
                if (h > 23 || m > 59)
                    return null;
                offset = TimeSpan.FromMinutes((h * 60 + m) * (z[0] == '-' ? -1 : 1));
            }
        }
        if (Regex.IsMatch(value, @"^\d{3,4}$"))
        {
            value = value.PadLeft(4, '0');
            value = value[..2] + ":" + value[2..];
        }
        else if (Regex.IsMatch(value, @"^\d{6}$"))
            value = value[..2] + ":" + value[2..4] + ":" + value[4..];
        var match = Regex.Match(value, @"^(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?$");
        if (!match.Success)
            return null;
        int hour = int.Parse(match.Groups[1].Value), minute = int.Parse(match.Groups[2].Value), second = match.Groups[3].Success ? int.Parse(match.Groups[3].Value) : 0;
        if (hour > 23 || minute > 59 || second > 59)
            return null;
        try
        {
            return new DateTimeOffset(Date(key).ToDateTime(new TimeOnly(hour, minute, second)), TimeSpan.Zero).Subtract(offset);
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }
    public static string Display(string time) => Parse("20000101", time)?.ToOffset(ShanghaiOffset).ToString("HH:mm") ?? "—";
    public static bool InSignWindow(Course c, DateTimeOffset now) => c.Start is { } s && c.End is { } e && e > s && now >= s.AddMinutes(-25) && now < e;
    public static (Course? Current, Course? Next) CurrentAndNext(IEnumerable<Course> courses, DateTimeOffset now)
    {
        var today = DayKey(DateOnly.FromDateTime(now.ToOffset(ShanghaiOffset).DateTime));
        var sorted = courses.Where(c => NormalizeDay(c.Day) == today && c.Start is not null).OrderBy(c => c.Start).ThenBy(c => c.End).ToList();
        var current = sorted.FirstOrDefault(c => InSignWindow(c, now));
        return (current, sorted.FirstOrDefault(c => current is null ? c.Start > now : c.Id != current.Id && c.Name.Trim() != current.Name.Trim() && c.Start > current.Start));
    }
}
