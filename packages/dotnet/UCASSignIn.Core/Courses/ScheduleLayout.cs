using System.Text;
namespace UCASSignIn.Core;

// A semester owns its allocator: additions never change colors already on screen.
public sealed class ScheduleColors
{
    readonly Dictionary<string, int> slots = new(StringComparer.Ordinal);
    readonly int[] uses = new int[7];
    public static string Key(Course c) => !string.IsNullOrWhiteSpace(c.CourseNumber) ? c.CourseNumber.Trim()
        : new string(c.Name.Where(x => !char.IsWhiteSpace(x)).ToArray());
    public static int Hash(string key)
    {
        var hash = 0; foreach (var value in Encoding.UTF8.GetBytes(key)) hash = (hash * 31 + value) % 65521;
        return hash % 7;
    }
    public void Include(IEnumerable<Course> courses)
    {
        foreach (var key in courses.Select(Key).Distinct().Order(StringComparer.Ordinal))
        {
            if (slots.ContainsKey(key)) continue;
            var minimum = uses.Min(); var start = Hash(key);
            var slot = Enumerable.Range(0, 7).Select(i => (start + i) % 7).First(i => uses[i] == minimum);
            slots[key] = slot; uses[slot]++;
        }
    }
    public int Color(Course c) => slots.GetValueOrDefault(Key(c), Hash(Key(c)));
}
public static class ScheduleLayout
{
    public static DateOnly Monday(DateOnly date) => date.AddDays(-((int)date.DayOfWeek + 6) % 7);
    public static double HourHeight(double columnWidth, double fontScale = 1) => 48 * Math.Clamp(80 / Math.Max(1, columnWidth), 1, 1.5) * Math.Max(1, fontScale);
    static (int Start, int End) Minutes(Course c)
    {
        if (c.Start is not { } start || c.End is not { } end || end <= start) return (-1, -1);
        var date = CourseTime.Date(c.Day); var midnight = new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue), CourseTime.ShanghaiOffset);
        var begin = (int)(start - midnight).TotalMinutes; var finish = (int)(end - midnight).TotalMinutes;
        return begin < 0 || begin >= 1440 || finish > 1440 ? (-1, -1) : (begin, finish);
    }
    public static WeekSchedule Build(DateOnly selected, IEnumerable<Course> source, IEnumerable<SchoolSemester> semesters,
        IEnumerable<CatalogCourse> catalog, bool previews, ScheduleColors colors, Func<Course, int>? colorFor = null)
    {
        var monday = Monday(selected); var last = monday.AddDays(6); var all = source.Where(c => CourseTime.NormalizeDay(c.Day) is not null).ToArray();
        var terms = semesters.Where(s => ScheduleCalendar.Range(s) is not null).ToArray(); var courses = catalog.ToArray();
        var semester = CourseIdentity.Semester(selected, terms);
        if (ScheduleCalendar.Range(semester) is { } range) all = all.Where(c => range.Contains(CourseTime.Date(c.Day))).ToArray();
        colors.Include(all.Where(c => CourseIdentity.Semester(CourseTime.Date(c.Day), terms)?.Id == semester?.Id));
        string Identity(Course c) => CourseIdentity.Resolve(c, terms, courses) is { } link ? link.SemesterId + "|" + link.Id : "unresolved|" + c.Day + "|" + c.Id;
        string? PreviewIdentity(Course c) => CourseIdentity.Semester(CourseTime.Date(c.Day), terms) is not { } term ? null
            : !string.IsNullOrWhiteSpace(c.CourseNumber) ? term.Id + "|number:" + c.CourseNumber.Trim()
            : CourseIdentity.Resolve(c, terms, courses) is { } link ? term.Id + "|id:" + link.Id : null;
        string Slot(Course c) => PreviewIdentity(c) + "|" + (int)CourseTime.Date(c.Day).DayOfWeek + "|" + Minutes(c);
        var actual = all.Where(c => CourseTime.Date(c.Day) >= monday && CourseTime.Date(c.Day) <= last).ToArray();
        var items = actual.Select(c => (Course: c, Date: CourseTime.Date(c.Day), Preview: false)).ToList();
        if (previews && semester is not null)
        {
            var present = actual.Select(Slot).ToHashSet();
            items.AddRange(all.Where(c => (CourseTime.Date(c.Day) < monday || CourseTime.Date(c.Day) > last)
                && CourseIdentity.Semester(CourseTime.Date(c.Day), terms)?.Id == semester.Id && PreviewIdentity(c) is not null
                && !present.Contains(Slot(c)))
                .GroupBy(Slot).SelectMany(g =>
                {
                    var nearest = g.OrderBy(c => Math.Abs(CourseTime.Date(c.Day).DayNumber - monday.AddDays(((int)CourseTime.Date(c.Day).DayOfWeek + 6) % 7).DayNumber))
                        .ThenBy(c => c.Day, StringComparer.Ordinal).ThenBy(c => c.Id, StringComparer.Ordinal).First();
                    return g.Where(c => c.Day == nearest.Day);
                })
                .Select(c => (c, monday.AddDays(((int)CourseTime.Date(c.Day).DayOfWeek + 6) % 7), true))
                .Where(x => CourseIdentity.Semester(x.Item2, terms)?.Id == semester.Id));
        }
        var entries = items.GroupBy(x => (x.Date, x.Preview, Identity: Identity(x.Course), Time: Minutes(x.Course),
            Room: string.IsNullOrWhiteSpace(x.Course.Classroom) ? "unknown|" + x.Course.Id : x.Course.Classroom.Trim()))
            .Select(g => new ScheduleEntry(g.Key.Date, Array.AsReadOnly(g.Select(x => x.Course).OrderBy(c => c.Id, StringComparer.Ordinal).ToArray()),
                g.Key.Preview, g.Key.Time.Start, g.Key.Time.End, (colorFor ?? colors.Color)(g.First().Course))).ToArray();
        var blocks = new List<ScheduleBlock>();
        foreach (var day in entries.Where(e => e.StartMinute >= 0).GroupBy(e => e.DisplayDate).OrderBy(g => g.Key))
        {
            var group = new List<ScheduleEntry>(); var begin = 0; var end = 0;
            void Flush() { if (group.Count > 0) blocks.Add(new(day.Key, begin, end, Array.AsReadOnly(group.ToArray()))); }
            foreach (var entry in day.OrderBy(e => e.StartMinute).ThenBy(e => e.EndMinute).ThenBy(e => e.Course.Id, StringComparer.Ordinal))
            {
                if (group.Count == 0 || entry.StartMinute >= end) { Flush(); group = []; begin = entry.StartMinute; end = entry.EndMinute; }
                group.Add(entry); end = Math.Max(end, entry.EndMinute);
            }
            Flush();
        }
        return new(monday, Math.Min(8, blocks.Select(b => b.StartMinute / 60).DefaultIfEmpty(8).Min()),
            Math.Max(22, blocks.Select(b => (b.EndMinute + 59) / 60).DefaultIfEmpty(22).Max()), blocks.AsReadOnly(),
            Array.AsReadOnly(entries.Where(e => e.StartMinute < 0).ToArray()), semester?.Id);
    }
}
