using System.Text.Json;
using System.Text.RegularExpressions;
namespace UCASSignIn.Core;

public static class ResponseParser
{
    public static JsonElement Field(JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v : default;
    public static string Scalar(JsonElement e) => e.ValueKind is JsonValueKind.String ? e.GetString()!.Trim() : e.ValueKind is JsonValueKind.Number ? e.GetRawText() : "";
    public static string Text(JsonElement e, string key) => Scalar(Field(e, key));
    static bool Matches(string pattern, string value) => Regex.IsMatch(value, pattern, RegexOptions.IgnoreCase);
    public static SchoolSession Session(JsonElement json)
    {
        if (Text(json, "STATUS") != "0")
            throw new SchoolException("LOGIN_REJECTED", "账户验证失败，请检查学号或 SEP 邮箱及密码");
        var r = Field(json, "result");
        string id = Text(r, "id"), sid = Text(r, "sessionId"), no = Text(r, "studentNo");
        if (id.Length == 0 || sid.Length == 0 || no.Length == 0)
            throw new SchoolException("LOGIN_BAD_RESPONSE", "学校登录未返回完整身份，请重试");
        var name = Field(r, "realName").ValueKind == JsonValueKind.String ? Text(r, "realName") : "";
        return new(id, sid, no, name.Length == 0 ? null : name);
    }
    public static long Timestamp(JsonElement json)
    {
        var v = Field(json, "timestamp");
        if (Text(json, "STATUS") != "0" || v.ValueKind != JsonValueKind.Number || !v.TryGetDecimal(out var n)
            || n != decimal.Truncate(n) || n < 1_000_000_000_000 || n > 8_640_000_000_000_000)
            throw new SchoolException("TIME_SYNC_BAD_RESPONSE", "学校校时数据异常，请重试");
        return (long)n;
    }
    public static void RejectSessionError(JsonElement json)
    {
        var code = Text(json, "ERRCODE");
        var message = Text(json, "ERRMSG") + Text(json, "message") + Text(json, "msg") + Text(Field(json, "result"), "msg");
        if (code is "401" or "403" or "LOGIN_EXPIRED" or "SESSION_EXPIRED" || Matches("未登录|尚未登录|重新登录|登录.*(失效|过期)|session.*(expired|invalid)", message))
            throw new SchoolException("LOGIN_EXPIRED", "登录已失效，请重新登录");
    }
    public static List<Course> Courses(JsonElement entries, string day)
    {
        if (entries.ValueKind != JsonValueKind.Array)
            throw new SchoolException("SCHEDULE_BAD_RESPONSE", "学校课表数据不完整");
        var seen = new HashSet<string>();
        var courses = new List<Course>();
        foreach (var e in entries.EnumerateArray())
        {
            var id = Text(e, "id");
            if (id.Length == 0)
                throw new SchoolException("SCHEDULE_BAD_RESPONSE", "课表缺少课程 ID，请重新查询");
            if (!seen.Add(id))
                continue;
            var room = Field(e, "classroomName").ValueKind == JsonValueKind.String ? Text(e, "classroomName") : "";
            var name = Text(e, "courseName");
            courses.Add(new(id, Text(e, "uuid"), name.Length > 0 ? name : "未命名课程", Text(e, "teacherName"), room.Length == 0 ? null : room,
                Text(e, "classBeginTime"), Text(e, "classEndTime"), day, Text(e, "signStatus") == "1", EmptyToNull(Text(e, "courseId")),
                EmptyToNull(Text(e, "courseNum")), EmptyToNull(Text(e, "teacherId")), Text(e, "signStatus") is "0" or "1"));
        }
        return courses.OrderBy(c => c.Start ?? DateTimeOffset.MaxValue).ToList();
    }
    static string? EmptyToNull(string value) => value.Length == 0 ? null : value;
    static int? OptionalInt(JsonElement e, string key)
    {
        var text = Text(e, key);
        return int.TryParse(text, out var value) ? value : null;
    }
    public static IReadOnlyList<SchoolSemester> Semesters(JsonElement json)
    {
        RejectSessionError(json);
        var entries = Field(json, "result");
        if (Text(json, "STATUS") != "0" || entries.ValueKind != JsonValueKind.Array)
            throw new SchoolException("SEMESTER_REJECTED", "学校暂未返回可用学期，请稍后重试");
        var result = new List<SchoolSemester>();
        foreach (var entry in entries.EnumerateArray())
        {
            var id = Text(entry, "code"); var name = Text(entry, "name");
            var begin = CourseTime.NormalizeDay(Text(entry, "beginDate")); var end = CourseTime.NormalizeDay(Text(entry, "endDate"));
            if (id.Length == 0 || name.Length == 0 || begin is null || end is null || string.CompareOrdinal(begin, end) > 0 || result.Any(s => s.Id == id))
                throw new SchoolException("SEMESTER_BAD_RESPONSE", "学校学期数据不完整，请稍后重试");
            result.Add(new(id, name, begin, end, Text(entry, "yearStatus") == "1"));
        }
        if (result.Count == 0)
            throw new SchoolException("SEMESTER_EMPTY", "学校暂未返回可用学期，请稍后重试");
        return result;
    }
    public static IReadOnlyList<CatalogCourse> CatalogCourses(JsonElement json, string semesterId)
    {
        RejectSessionError(json);
        var entries = Field(json, "result");
        if (Text(json, "STATUS") != "0" || entries.ValueKind != JsonValueKind.Array)
            throw new SchoolException("COURSE_CATALOG_REJECTED", "学校暂未返回课程目录，请稍后重试");
        var result = new List<CatalogCourse>();
        foreach (var entry in entries.EnumerateArray())
        {
            var id = Text(entry, "course_id"); var name = Text(entry, "course_name"); var returnedSemester = Text(entry, "semesterId");
            if (id.Length == 0 || name.Length == 0)
                throw new SchoolException("COURSE_CATALOG_BAD_RESPONSE", "学校课程目录数据不完整，请稍后重试");
            if (returnedSemester.Length > 0 && returnedSemester != semesterId)
                throw new SchoolException("COURSE_CATALOG_SEMESTER_MISMATCH", "学校返回了其他学期的课程，请重新刷新");
            result.Add(new(id, Text(entry, "courseNum"), name, Text(entry, "teacher_name"), EmptyToNull(Text(entry, "course_address")), semesterId,
                CourseTime.NormalizeDay(Text(entry, "course_beignDate")) ?? "", CourseTime.NormalizeDay(Text(entry, "course_endDate")) ?? "",
                OptionalInt(entry, "jc_num"), OptionalInt(entry, "jc_num_studyed")));
        }
        var total = OptionalInt(json, "total");
        if (total is not null && total != result.Count)
            throw new SchoolException("COURSE_CATALOG_INCOMPLETE", "学校返回的课程目录不完整，请重新刷新");
        return result;
    }
    public static CourseAttendanceSummary CourseAttendance(JsonElement json, string courseId)
    {
        RejectSessionError(json);
        var entries = Field(json, "result");
        if (Text(json, "STATUS") != "0" || entries.ValueKind != JsonValueKind.Array)
            throw new SchoolException("ATTENDANCE_REJECTED", "学校暂未返回课程考勤，请稍后重试");
        var result = new List<CourseAttendance>();
        foreach (var entry in entries.EnumerateArray())
        {
            var id = Text(entry, "id"); var returnedCourse = Text(entry, "courseId"); var scheduled = Text(entry, "courseSchedId");
            var day = CourseTime.NormalizeDay(Text(entry, "teachTime"));
            if (id.Length == 0 || returnedCourse != courseId || scheduled.Length == 0 || day is null)
                throw new SchoolException("ATTENDANCE_BAD_RESPONSE", "学校课程考勤数据不完整，请稍后重试");
            result.Add(new(id, returnedCourse, scheduled, day, Text(entry, "classBeginTime"), Text(entry, "classEndTime"), Text(entry, "signStatus") == "1", Text(entry, "signStatus") is "0" or "1"));
        }
        var signed = OptionalInt(json, "mySignNum") ?? result.Count(x => x.Signed);
        var unsigned = OptionalInt(json, "myNoSignNum") ?? result.Count(x => !x.Signed && x.SignStatusKnown == true);
        return new(signed, unsigned, result);
    }
    public static CourseQueryResult Week(JsonElement json, string day)
    {
        RejectSessionError(json);
        var days = Field(json, "result");
        var success = Field(json, "success");
        if (Text(json, "STATUS") is not ("0" or "1") || Text(json, "ERRCODE") is not ("" or "0") || Text(json, "ERRMSG") != ""
            || days.ValueKind != JsonValueKind.Array || (success.ValueKind != JsonValueKind.Undefined && success.ValueKind != JsonValueKind.True))
            throw new SchoolException("SCHEDULE_REJECTED", "学校暂未返回可用课表，请重新查询");
        var all = new List<Course>();
        foreach (var d in days.EnumerateArray())
        {
            var date = CourseTime.NormalizeDay(Text(d, "dateStr")) ?? throw new SchoolException("SCHEDULE_BAD_RESPONSE", "学校周课表日期不完整");
            all.AddRange(Courses(Field(d, "schedData"), date));
        }
        var selected = all.Where(c => c.Day == day).ToList();
        if (selected.Count > 0)
            return new(selected, "已从周课表更新当天课程");
        return all.Count > 0 ? new(all.OrderBy(c => c.Start).ToList(), "当天没有课程，已显示本周课程", true) : new([], "当天及本周暂无课程");
    }
    public static WeeklyScheduleResult WeeklySchedule(JsonElement json)
    {
        RejectSessionError(json);
        var days = Field(json, "result");
        if (Text(json, "STATUS") is not ("0" or "1") || Text(json, "ERRCODE") is not ("" or "0")
            || Text(json, "ERRMSG") != "" || days.ValueKind != JsonValueKind.Array
            || Field(json, "success").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.True))
            throw new SchoolException("SCHEDULE_REJECTED", "学校暂未返回可用周课表");
        var covered = new HashSet<string>(); var courses = new List<Course>();
        foreach (var entry in days.EnumerateArray())
        {
            var day = CourseTime.NormalizeDay(Text(entry, "dateStr"));
            if (day is null || !covered.Add(day)) throw new SchoolException("SCHEDULE_BAD_RESPONSE", "学校周课表日期缺失或重复");
            courses.AddRange(Courses(Field(entry, "schedData"), day));
        }
        return new(courses.AsReadOnly(), covered.Order().ToArray());
    }
    public static SignResult Sign(JsonElement json)
    {
        var r = Field(json, "result");
        var status = Text(json, "STATUS");
        var error = Text(json, "ERRCODE");
        var message = new[] { Text(r, "msg"), Text(json, "ERRMSG"), Text(json, "msg"), Text(json, "message") }.FirstOrDefault(s => s.Length > 0) ?? "";
        var expired = Matches("(二维码|签到码).*(失效|过期)|timestamp.*(invalid|expired)", message);
        var outside = Matches("未在上课时间|不在.*签到时间|不是上课时间|未选.*课|不属于.*课|已签到|重复签到", message);
        var success = Field(json, "success");
        var outcome = expired ? SignOutcome.QrExpired : status == "0" && error is "" or "0" && Text(r, "stuSignStatus") == "1"
            && success.ValueKind is JsonValueKind.Undefined or JsonValueKind.True && !outside ? SignOutcome.Signed : outside ? SignOutcome.OutsideSignWindow : SignOutcome.Unknown;
        var display = outcome switch
        {
            SignOutcome.Signed => "签到成功",
            SignOutcome.QrExpired => "学校提示签到码已失效，请刷新后重试",
            SignOutcome.OutsideSignWindow when message.Contains("已签到") || message.Contains("重复签到") => "学校提示已签到，请刷新课程状态",
            SignOutcome.OutsideSignWindow when message.Contains("未选") || message.Contains("不属于") => "学校提示当前身份未选此课程",
            SignOutcome.OutsideSignWindow => "学校未完成签到，请确认上课时间和课程状态",
            _ => "学校未明确确认签到完成，请刷新课程状态后再决定是否重试"
        };
        return new(outcome, display, status, error[..Math.Min(64, error.Length)], Text(r, "stuSignId"));
    }
}
