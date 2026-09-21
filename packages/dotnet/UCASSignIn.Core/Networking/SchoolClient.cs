using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace UCASSignIn.Core;

public sealed class SchoolClient : ISchoolClient, IDisposable
{
    public static readonly Uri BaseUri = new("https://iclass.ucas.edu.cn:8181/app/");
    const string VerificationUrl = "http://iclass.ucas.edu.cn:88/ve/webservices/mobileCheck.shtml?method=mobileLogin&username=${0}&password=${1}&lx=${2}";
    readonly HttpClient http; readonly TimeProvider clock; readonly object clockLock = new();
    ClockSample? sample; Task<ClockSample>? pending; int generation;
    sealed record ClockSample(long Timestamp, DateTimeOffset Received);
    public SchoolClient(HttpMessageHandler? handler = null, TimeProvider? timeProvider = null)
    {
        // Redirects are rejected, so credentials can never leave the configured HTTPS origin.
        http = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });
        http.Timeout = TimeSpan.FromSeconds(20);
        clock = timeProvider ?? TimeProvider.System;
    }
    public async Task<SchoolSession> LoginAsync(string username, string password, CancellationToken ct = default)
    {
        username = username.Trim();
        if (username.Length == 0 || password.Length == 0)
            throw new SchoolException("LOGIN_INPUT_INVALID", "请输入学号或 SEP 邮箱和密码");
        return ResponseParser.Session(await ExecuteAsync("user/login.action", fields: new()
        {
            ["phone"] = username,
            ["password"] = password,
            ["verificationType"] = "1",
            ["verificationUrl"] = VerificationUrl,
            ["userLevel"] = "1"
        }, login: true, ct: ct));
    }
    public async Task<CourseQueryResult> CoursesAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
    {
        var day = CourseTime.DayKey(date);
        var fields = new Dictionary<string, string> { ["id"] = session.UserId, ["dateStr"] = day };
        var daily = await ExecuteAsync("course/get_stu_course_sched.action", session, fields, ct: ct);
        ResponseParser.RejectSessionError(daily);
        if (ResponseParser.Text(daily, "STATUS") == "0" && ResponseParser.Field(daily, "result").ValueKind == JsonValueKind.Array)
        {
            var courses = ResponseParser.Courses(ResponseParser.Field(daily, "result"), day);
            if (courses.Count > 0)
                return new(courses, "已更新当天课程");
        }
        return ResponseParser.Week(await ExecuteAsync("course/get_stu_course_sched_week.action", session, fields, ct: ct), day);
    }
    public async Task<IReadOnlyList<SchoolSemester>> SemestersAsync(SchoolSession session, CancellationToken ct = default)
        => ResponseParser.Semesters(await ExecuteAsync("course/get_base_school_year.action", session, new()
        {
            ["userId"] = session.UserId,
            ["type"] = "2"
        }, ct: ct));
    public async Task<WeeklyScheduleResult> WeeklyScheduleAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
        => ResponseParser.WeeklySchedule(await ExecuteAsync("course/get_stu_course_sched_week.action", session,
            new() { ["id"] = session.UserId, ["dateStr"] = CourseTime.DayKey(date) }, ct: ct));
    public async Task<CourseQueryResult> DailyScheduleAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
    {
        var day = CourseTime.DayKey(date);
        var json = await ExecuteAsync("course/get_stu_course_sched.action", session,
            new() { ["id"] = session.UserId, ["dateStr"] = day }, ct: ct);
        ResponseParser.RejectSessionError(json);
        if (ResponseParser.Text(json, "STATUS") == "0" && ResponseParser.Text(json, "ERRCODE") is "" or "0"
            && ResponseParser.Field(json, "success").ValueKind is JsonValueKind.Undefined or JsonValueKind.True
            && ResponseParser.Field(json, "result").ValueKind == JsonValueKind.Array)
            return new(ResponseParser.Courses(ResponseParser.Field(json, "result"), day), "已更新当天课程");
        var week = await WeeklyScheduleAsync(session, date, ct);
        if (!week.CoveredDays.Contains(day)) throw new SchoolException("SCHEDULE_UNKNOWN_DAY", "学校未明确返回所选日期");
        return new(week.Courses.Where(x => x.Day == day).ToArray(), "已从周课表更新当天课程");
    }
    public async Task<IReadOnlyList<CatalogCourse>> CatalogCoursesAsync(SchoolSession session, string semesterId, CancellationToken ct = default)
        => ResponseParser.CatalogCourses(await ExecuteAsync("choosecourse/get_myall_course.action", session, new()
        {
            ["id"] = session.UserId,
            ["xq_code"] = semesterId
        }, new() { ["user_type"] = "1" }, ct: ct), semesterId);
    public async Task<CourseAttendanceSummary> CourseAttendanceAsync(SchoolSession session, string courseId, CancellationToken ct = default)
        => ResponseParser.CourseAttendance(await ExecuteAsync("my/get_my_course_sign_detail.action", session, new()
        {
            ["id"] = session.UserId,
            ["courseId"] = courseId
        }, ct: ct), courseId);
    public async Task<SignResult> SignAsync(Course course, SchoolSession session, CancellationToken ct = default, Func<bool>? authorize = null)
    {
        if (!Regex.IsMatch(course.Id, "^[0-9]{7}$"))
            throw new SchoolException("COURSE_ID_INVALID", "课程缺少有效的 7 位签到 ID，请刷新课表");
        var reading = await ReadingAsync(ct);
        if (authorize is not null && !authorize())
            throw new OperationCanceledException("签到设置已改变，未向学校提交", ct);
        var json = await ExecuteAsync("course/stu_scan_sign.action", session, query: new()
        {
            ["courseSchedId"] = course.Id,
            ["timestamp"] = reading.Timestamp.ToString(),
            ["id"] = session.UserId
        }, timeout: 10, ct: ct);
        ResponseParser.RejectSessionError(json);
        return ResponseParser.Sign(json);
    }
    public static string QrUrl(string identifier, long timestamp)
    {
        identifier = identifier.Trim();
        var compact = identifier.Replace("-", "");
        var pair = Regex.IsMatch(identifier, "^[0-9]{7}$") ? "courseSchedId=" + identifier
            : Regex.IsMatch(compact, "^[0-9a-fA-F]{32}$") ? "timeTableId=" + compact.ToUpperInvariant()
            : throw new SchoolException("COURSE_ID_INVALID", "请输入 7 位课程 ID 或 32 位 UUID");
        return $"{BaseUri}course/stu_scan_sign.action?{pair}&timestamp={timestamp}";
    }
    public async Task<QrSnapshot> QrAsync(Course course, CancellationToken ct = default)
    {
        _ = QrUrl(course.QrIdentifier, 0);
        var r = await ReadingAsync(ct);
        var duration = TimeSpan.FromSeconds(Math.Min(5, 30 - r.Age.TotalSeconds));
        return new(QrUrl(course.QrIdentifier, r.Timestamp), r.Timestamp, clock.GetUtcNow() + duration, duration);
    }
    public async Task<DateTimeOffset> SchoolNowAsync(CancellationToken ct = default) => DateTimeOffset.FromUnixTimeMilliseconds((await ReadingAsync(ct)).Timestamp);
    public void ClearClock()
    {
        lock (clockLock)
        {
            generation++;
            sample = null;
            pending = null;
        }
    }
    async Task<(long Timestamp, TimeSpan Age)> ReadingAsync(CancellationToken ct)
    {
        Task<ClockSample> task;
        int epoch;
        lock (clockLock)
        {
            var age = sample is null ? TimeSpan.MaxValue : clock.GetUtcNow() - sample.Received;
            if (sample is not null && age >= TimeSpan.Zero && age < TimeSpan.FromSeconds(30))
                return (sample.Timestamp + (long)age.TotalMilliseconds, age);
            epoch = generation;
            task = pending ??= SyncAsync();
        }
        try
        {
            var result = await task.WaitAsync(ct);
            lock (clockLock)
            {
                if (epoch != generation)
                    throw new OperationCanceledException();
                sample = result;
                pending = null;
                var age = clock.GetUtcNow() - result.Received;
                if (age < TimeSpan.Zero || age >= TimeSpan.FromSeconds(30))
                    throw new SchoolException("TIME_SYNC_EXPIRED", "学校校时已过期，请重试");
                return (result.Timestamp + (long)age.TotalMilliseconds, age);
            }
        }
        catch { lock (clockLock) { if (epoch == generation && task.IsCompleted) pending = null; } throw; }
    }
    async Task<ClockSample> SyncAsync()
    {
        var start = clock.GetUtcNow();
        var json = await ExecuteAsync("common/get_timestamp.do", fields: [], query: new()
        {
            ["id"] = "0"
        }, timeout: 6);
        var timestamp = ResponseParser.Timestamp(json);
        var received = clock.GetUtcNow();
        var trip = received - start;
        if (trip < TimeSpan.Zero || trip >= TimeSpan.FromSeconds(30))
            throw new SchoolException("TIME_SYNC_EXPIRED", "学校校时已过期，请重试");
        return new(timestamp + (long)(trip.TotalMilliseconds / 2), received);
    }
    async Task<JsonElement> ExecuteAsync(string path, SchoolSession? session = null, Dictionary<string, string>? fields = null,
        Dictionary<string, string>? query = null, bool login = false, int timeout = 15, CancellationToken ct = default)
    {
        var uri = new Uri(BaseUri, path + (query is null ? "" : "?" + Encode(query)));
        using var request = new HttpRequestMessage(fields is null ? HttpMethod.Get : HttpMethod.Post, uri);
        request.Headers.TryAddWithoutValidation("User-Agent", login ? "student_5.0.1.2_android_12_20__110000" : "student_5.0.1.2_android_12_20_100000000000000_110000");
        request.Headers.TryAddWithoutValidation("Cache-Control", "no-store");
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        if (session is not null)
            request.Headers.TryAddWithoutValidation("sessionId", session.SessionId);
        if (fields is not null)
            request.Content = new StringContent(Encode(fields), Encoding.UTF8, "application/x-www-form-urlencoded");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(timeout));
        try
        {
            using var response = await http.SendAsync(request, deadline.Token);
            if (!response.IsSuccessStatusCode)
                throw new SchoolException($"HTTP_{(int)response.StatusCode}", response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden ? "登录已失效，请重新登录" : $"学校服务请求失败（{(int)response.StatusCode}）");
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(deadline.Token));
            if (json.RootElement.ValueKind != JsonValueKind.Object)
                throw new JsonException();
            return json.RootElement.Clone();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { throw new SchoolException("NETWORK_TIMEOUT", "学校服务连接超时，请重试"); }
        catch (HttpRequestException) { throw new SchoolException("NETWORK_UNAVAILABLE", "暂时无法连接学校服务，请检查网络后重试"); }
        catch (JsonException) { throw new SchoolException("BAD_RESPONSE", "学校返回的数据无法读取，请稍后重试"); }
    }
    static string Encode(Dictionary<string, string> fields) => string.Join("&", fields.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
    public void Dispose() => http.Dispose();
}
