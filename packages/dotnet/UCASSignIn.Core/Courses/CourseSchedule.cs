using System.Collections.Immutable;
using System.Text.Json;

namespace UCASSignIn.Core;

public sealed record CourseScheduleMeeting(string Id, DateOnly Date, int Week, DateTimeOffset? Start,
    string Time, string Classroom, ImmutableArray<string> Teachers, ImmutableArray<string> SourceIds, string ArrangementKey)
{
    public DateTimeOffset? End { get; init; }
    public string Weekday => CourseSchedule.Weekday(Date.DayOfWeek);
    public string TeacherText => Teachers.Length == 0 ? "教师暂未提供" : string.Join("、", Teachers);
    public string ClassroomText => Classroom.Length == 0 ? "教室暂未提供" : Classroom;
    internal bool HasValidTime => Start is { } start && End is { } end && end > start
        && DateOnly.FromDateTime(start.ToOffset(CourseTime.ShanghaiOffset).DateTime) == Date
        && DateOnly.FromDateTime(end.ToOffset(CourseTime.ShanghaiOffset).DateTime) == Date;
    public bool HasEnded(DateTimeOffset now) => HasValidTime && End <= now;
}
public sealed record CourseScheduleSummary(string Weeks, string Weekday, string Time, string Classroom);
public sealed record CourseScheduleProgress(int Total, int Ended, int UnknownTime)
{
    public double Fraction => Total == 0 ? 0 : (double)Ended / Total;
}
public sealed record CourseSchedulePresentation(ImmutableArray<CourseScheduleMeeting> Meetings,
    ImmutableArray<CourseScheduleSummary> Summaries, string? UnavailableReason)
{
    public CourseScheduleProgress ProgressAt(DateTimeOffset now) => new(Meetings.Length,
        Meetings.Count(m => m.HasEnded(now)), Meetings.Count(m => !m.HasValidTime));
}

/// <summary>Only actual schedule records participate; attendance and catalog room descriptions are never inputs.</summary>
public static class CourseSchedule
{
    public static string Weekday(DayOfWeek day) => "周" + "日一二三四五六"[(int)day];
    static string Key(params string?[] fields) => JsonSerializer.Serialize(fields);
    public static bool SameCourse(CatalogCourse a, CatalogCourse b) => a.SemesterId == b.SemesterId
        && a.Id == b.Id && CourseIdentity.Normalize(a.Number) == CourseIdentity.Normalize(b.Number);

    public static CourseSchedulePresentation Build(CatalogCourse target, IEnumerable<SchoolSemester> semesters,
        IEnumerable<CatalogCourse> catalog, IEnumerable<Course> courses)
    {
        var terms = semesters.ToArray();
        var candidates = terms.Where(t => t.Id == target.SemesterId).ToArray();
        if (candidates.Length != 1 || ScheduleCalendar.Range(candidates[0]) is not { } range)
            return new([], [], "无法确定课程所属学期的有效日期范围");
        var term = candidates[0];
        var directory = catalog.ToArray();
        var matching = directory.Where(c => c.SemesterId == target.SemesterId &&
            (CourseIdentity.Normalize(target.Number).Length > 0 ? CourseIdentity.Normalize(c.Number) == CourseIdentity.Normalize(target.Number)
                : !string.IsNullOrWhiteSpace(target.Id) && c.Id == target.Id)).Distinct().ToArray();
        if (matching.Length != 1 || !SameCourse(matching[0], target))
            return new([], [], "课程身份尚未唯一关联，暂时无法确定排课");
        if (terms.Any(t => t.Id != term.Id && ScheduleCalendar.Range(t) is { } other && other.Begin <= range.End && other.End >= range.Begin))
            return new([], [], "学期日期范围重叠，无法可靠关联排课");

        var rows = new List<CourseScheduleMeeting>();
        foreach (var c in courses)
        {
            if (CourseTime.NormalizeDay(c.Day) is not { } day || CourseIdentity.Resolve(c, terms, directory) is not { } resolved
                || !SameCourse(resolved, target)) continue;
            var date = CourseTime.Date(day);
            var start = c.Start?.ToOffset(CourseTime.ShanghaiOffset); var end = c.End?.ToOffset(CourseTime.ShanghaiOffset);
            var valid = start is { } s && end is { } e && e > s && DateOnly.FromDateTime(s.DateTime) == date && DateOnly.FromDateTime(e.DateTime) == date;
            var rawStart = CourseIdentity.Normalize(c.BeginTime); var rawEnd = CourseIdentity.Normalize(c.EndTime);
            var time = valid ? $"{start:HH:mm}–{end:HH:mm}" : rawStart.Length == 0 && rawEnd.Length == 0 ? "暂未提供"
                : $"{(rawStart.Length == 0 ? "暂未提供" : rawStart)}–{(rawEnd.Length == 0 ? "暂未提供" : rawEnd)} · 时间待确认";
            var room = CourseIdentity.Normalize(c.Classroom); var teacher = CourseIdentity.Normalize(c.Teacher);
            var source = Key(day, c.Id, c.Uuid, c.CourseId, c.TeacherId);
            var arrangement = valid ? Key("valid", start!.Value.ToString("HH:mm:ss"), end!.Value.ToString("HH:mm:ss"), room)
                : Key("invalid", rawStart, rawEnd, room);
            // Incomplete records retain their own identity and are never merged with another teacher's record.
            var id = Key(day, arrangement, valid && room.Length > 0 ? null : Key(source, teacher));
            rows.Add(new(id, date, ScheduleCalendar.WeekNumber(date, term)!.Value, valid ? start : null,
                time, room, teacher.Length == 0 ? [] : [teacher], [source], arrangement) { End = valid ? end : null });
        }
        var meetings = rows.GroupBy(r => r.Id).Select(g =>
        {
            var row = g.OrderBy(x => x.SourceIds[0], StringComparer.Ordinal).First();
            var sources = g.SelectMany(x => x.SourceIds).Distinct().Order(StringComparer.Ordinal).ToImmutableArray();
            return row with { Id = Key(row.Date.ToString("yyyyMMdd"), Key(sources.ToArray())), SourceIds = sources,
                Teachers = g.SelectMany(x => x.Teachers).Distinct().Order(StringComparer.Ordinal).ToImmutableArray() };
        }).OrderBy(r => r.Date).ThenBy(r => r.Start is null).ThenBy(r => r.Start).ThenBy(r => r.ArrangementKey, StringComparer.Ordinal)
            .ThenBy(r => r.Id, StringComparer.Ordinal).ToImmutableArray();
        var summaries = meetings.GroupBy(r => (r.Date.DayOfWeek, r.ArrangementKey)).OrderBy(g => ((int)g.Key.DayOfWeek + 6) % 7)
            .ThenBy(g => g.First().Start is null).ThenBy(g => g.First().Start?.TimeOfDay).ThenBy(g => g.Key.ArrangementKey, StringComparer.Ordinal)
            .Select(g => new CourseScheduleSummary(CompressWeeks(g.Select(r => r.Week)), Weekday(g.Key.DayOfWeek), g.First().Time, g.First().ClassroomText)).ToImmutableArray();
        return new(meetings, summaries, null);
    }

    public static string CompressWeeks(IEnumerable<int> source)
    {
        var weeks = source.Distinct().Order().ToArray(); var parts = new List<string>();
        for (var i = 0; i < weeks.Length; i++)
        {
            var first = weeks[i]; var last = first;
            while (i + 1 < weeks.Length && weeks[i + 1] == last + 1) last = weeks[++i];
            parts.Add(first == last ? first.ToString() : $"{first}–{last}");
        }
        return "第 " + string.Join("、", parts) + " 周";
    }
}
