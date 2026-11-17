using System.Net;
using System.Text.Json;
namespace UCASSignIn.Core.Tests;

public class SchoolClientTests
{
    static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();
    static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", name + ".json"));
    [Fact]
    public async Task LoginEncodesReservedCharactersAndRetainsRealName()
    {
        using var handler = new FakeHttp(_ => Fixture("login"));
        using var client = new SchoolClient(handler);
        var session = await client.LoginAsync(" demo+test@example.invalid ", "p&=+ 空");
        var req = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, req.Method);
        Assert.Contains("phone=demo%2Btest%40example.invalid", req.Body);
        Assert.Contains("password=p%26%3D%2B%20%E7%A9%BA", req.Body);
        Assert.Contains("verificationType=1", req.Body);
        Assert.Equal("演示同学", session.Name);
        Assert.DoesNotContain("sessionId", req.Headers.Keys);
        Assert.Equal("iclass.ucas.edu.cn", req.Uri.Host);
        Assert.Equal("https", req.Uri.Scheme);
    }
    [Fact]
    public void IncompleteSessionIsRejected()
    {
        Assert.Throws<SchoolException>(() => ResponseParser.Session(Json("""{"STATUS":0,"result":{"id":"x"}}""")));
    }
    [Theory]
    [InlineData("123")]
    [InlineData("true")]
    [InlineData("null")]
    public void NonStringNameIsNotPromoted(string value)
    {
        Assert.Null(ResponseParser.Session(Json("{\"STATUS\":0,\"result\":{\"id\":1,\"sessionId\":\"s\",\"studentNo\":\"n\",\"realName\":" + value + "}}")).Name);
    }
    [Fact]
    public async Task DailyRequestUsesSessionAndDate()
    {
        using var handler = new FakeHttp(_ => Fixture("daily-courses"));
        using var client = new SchoolClient(handler);
        var result = await client.CoursesAsync(TestData.Session(), new(2026, 9, 16));
        var request = Assert.Single(handler.Requests);
        Assert.Equal("s-a", request.Headers["sessionId"]);
        Assert.Contains("dateStr=20260916", request.Body);
        Assert.Equal("教学楼 201", Assert.Single(result.Courses).Classroom);
    }
    [Fact]
    public async Task EmptyDailyFallsBackToWeek()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("_week.action") ? Fixture("weekly-courses") : """{"STATUS":0,"result":[]}""");
        using var client = new SchoolClient(handler);
        var result = await client.CoursesAsync(TestData.Session(), new(2026, 9, 17));
        Assert.True(result.FromWeeklyFallback);
        Assert.Single(result.Courses);
        Assert.Equal(2, handler.Requests.Count);
    }
    [Theory]
    [InlineData("""{"STATUS":1,"ERRMSG":"failed","result":[]}""")]
    [InlineData("""{"STATUS":1,"success":"true","result":[]}""")]
    [InlineData("""{"STATUS":0,"result":[{"dateStr":"20260230","schedData":[]}]}""")]
    public void MalformedWeeklyDataIsNotAnEmptySchedule(string json) => Assert.Throws<SchoolException>(() => ResponseParser.Week(Json(json), "20260916"));
    [Fact]
    public async Task ExpiredDailyDoesNotFallBack()
    {
        using var handler = new FakeHttp(_ => """{"ERRCODE":"401"}""");
        using var client = new SchoolClient(handler);
        Assert.True((await Assert.ThrowsAsync<SchoolException>(() => client.CoursesAsync(TestData.Session(), new(2026, 9, 16)))).IsSessionExpired);
        Assert.Single(handler.Requests);
    }
    [Theory]
    [InlineData("""{"STATUS":0,"result":{}}""")]
    [InlineData("""{"STATUS":0,"success":false,"result":{"stuSignStatus":1}}""")]
    [InlineData("""{"STATUS":0,"success":"true","result":{"stuSignStatus":1}}""")]
    [InlineData("""{"STATUS":1,"result":{"stuSignStatus":1}}""")]
    [InlineData("""{"STATUS":0,"ERRCODE":4,"result":{"stuSignStatus":1}}""")]
    [InlineData("""{"STATUS":0,"result":{"stuSignStatus":1,"msg":"已签到"}}""")]
    public void AmbiguousSignNeverClaimsSuccess(string json) => Assert.NotEqual(SignOutcome.Signed, ResponseParser.Sign(Json(json)).Outcome);
    [Fact] public void ExplicitSignSuccess() => Assert.Equal(SignOutcome.Signed, ResponseParser.Sign(Json(Fixture("sign-success"))).Outcome);
    [Theory]
    [InlineData("true")]
    [InlineData("\"1700000000000\"")]
    [InlineData("1700000000")]
    [InlineData("1700000000000.1")]
    public void InvalidTimestampRejected(string value) => Assert.Throws<SchoolException>(() => ResponseParser.Timestamp(Json("{\"STATUS\":0,\"timestamp\":" + value + "}")));
    [Fact]
    public void QrCanonicalizationHasNoStudentIdentity()
    {
        var url = SchoolClient.QrUrl("00112233-4455-6677-8899-aabbccddeeff", 123);
        Assert.Contains("timeTableId=00112233445566778899AABBCCDDEEFF", url);
        Assert.DoesNotContain("student", url);
        Assert.DoesNotContain("&id=", url);
        Assert.Throws<SchoolException>(() => SchoolClient.QrUrl("12&studentNo=x", 123));
    }
    [Fact]
    public async Task QrShortensAtClockExpiryAndRefreshesAfterReversal()
    {
        var clock = new FakeClock(TestData.Now);
        using var handler = new FakeHttp(_ => """{"STATUS":0,"timestamp":1789518600000}""");
        using var client = new SchoolClient(handler, clock);
        Assert.Equal(TimeSpan.FromSeconds(5), (await client.QrAsync(TestData.Course())).ValidityDuration);
        clock.Now += TimeSpan.FromSeconds(28);
        Assert.Equal(TimeSpan.FromSeconds(2), (await client.QrAsync(TestData.Course())).ValidityDuration);
        clock.Now -= TimeSpan.FromSeconds(29);
        await client.SchoolNowAsync();
        Assert.Equal(2, handler.Requests.Count);
    }
    [Fact]
    public async Task ConcurrentClockUsersShareOneRequest()
    {
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttp(async _ => await release.Task);
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now));
        var a = client.QrAsync(TestData.Course());
        var b = client.SchoolNowAsync();
        release.SetResult("""{"STATUS":0,"timestamp":1789518600000}""");
        await Task.WhenAll(a, b);
        Assert.Single(handler.Requests);
    }
    [Fact]
    public async Task WallClockAdjustmentCannotAdvanceCachedSchoolTimeOrExpireItsMonotonicSample()
    {
        var clock = new FakeClock(TestData.Now);
        using var handler = new FakeHttp(_ => """{"STATUS":0,"timestamp":1789518600000}""");
        using var client = new SchoolClient(handler, clock);
        var sample = await client.SchoolNowAsync();
        clock.Now += TimeSpan.FromSeconds(15);
        clock.ShiftDeviceClock(TimeSpan.FromSeconds(10));
        Assert.Equal(sample.AddSeconds(15), await client.SchoolNowAsync());
        Assert.Single(handler.Requests);
        clock.ShiftDeviceClock(TimeSpan.FromMinutes(-2));
        Assert.Equal(sample.AddSeconds(15), await client.SchoolNowAsync());
        Assert.Single(handler.Requests);
    }
    [Fact]
    public async Task FinalAutomaticAuthorizationReceivesSchoolReadingAndDecliningItDoesNotSendSign()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do")
            ? """{"STATUS":0,"timestamp":1789518600000}""" : Fixture("sign-success"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now.AddMinutes(2)));
        DateTimeOffset? observed = null;
        await Assert.ThrowsAsync<OperationCanceledException>(() => client.SignAsync(TestData.Course(), TestData.Session(),
            authorizeAt: at => { observed = at; return Task.FromResult(false); }));
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1789518600000), observed);
        Assert.Single(handler.Requests);
    }
    [Fact]
    public async Task ClockClearRejectsOldSync()
    {
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var handler = new FakeHttp(async _ => await release.Task);
        using var client = new SchoolClient(handler);
        var task = client.QrAsync(TestData.Course());
        client.ClearClock();
        release.SetResult("""{"STATUS":0,"timestamp":1789518600000}""");
        await Assert.ThrowsAsync<OperationCanceledException>(() => task);
    }
    [Fact]
    public async Task SuccessfulSignUsesClockAndDoesNotRetry()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? """{"STATUS":0,"timestamp":1789518600000}""" : Fixture("sign-success"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now));
        Assert.Equal(SignOutcome.Signed, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal(HttpMethod.Get, handler.Requests[1].Method);
        Assert.Contains("timestamp=1789518600000", handler.Requests[1].Uri.Query);
        Assert.Contains("&id=u-a", handler.Requests[1].Uri.Query);
    }
    static Task NoDelay(TimeSpan delay, CancellationToken ct) => Task.CompletedTask;
    const string SchoolClock = """{"STATUS":0,"timestamp":1789518600000}""";
    static string SignState(string status) => "{\"STATUS\":0,\"result\":[{\"id\":\"1234567\",\"signStatus\":\"" + status + "\"}]}";
    static bool IsSign(FakeHttp.Request r) => r.Uri.AbsolutePath.EndsWith("stu_scan_sign.action");

    [Fact]
    public async Task UnclearSignReconcilesSuccessWithoutResubmitting()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock : IsSign(r) ? "{}" : SignState("1"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        var result = await client.SignAsync(TestData.Course(), TestData.Session());
        Assert.Equal(SignOutcome.Signed, result.Outcome);
        Assert.Single(handler.Requests, IsSign);
        Assert.Equal(3, handler.Requests.Count);
    }
    [Fact]
    public async Task UnclearSignRequiresTwoUnsignedReadsAndNewClockBeforeRetry()
    {
        var fixtures = new Queue<string>([SchoolClock, "{}", SignState("0"), SignState("0"),
            """{"STATUS":0,"timestamp":1789518605000}""", Fixture("sign-success")]);
        using var handler = new FakeHttp(_ => fixtures.Dequeue());
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        var authorizations = 0;
        var result = await client.SignAsync(TestData.Course(), TestData.Session(), authorize: () => { authorizations++; return true; });
        Assert.Equal(SignOutcome.Signed, result.Outcome);
        Assert.Equal(new[] { "get_timestamp.do", "stu_scan_sign.action", "get_stu_course_sched.action",
            "get_stu_course_sched.action", "get_timestamp.do", "stu_scan_sign.action" }, handler.Requests.Select(r => r.Uri.Segments.Last()));
        Assert.Contains("timestamp=1789518605000", handler.Requests.Last().Uri.Query);
        Assert.Equal(2, authorizations);
    }
    [Theory]
    [InlineData("{}")]
    [InlineData("""{"STATUS":0,"result":[]}""")]
    [InlineData("""{"STATUS":0,"result":[{"id":"7654321","signStatus":"0"}]}""")]
    [InlineData("""{"STATUS":0,"result":[{"id":"1234567","signStatus":false}]}""")]
    [InlineData("""{"STATUS":0,"success":false,"result":[{"id":"1234567","signStatus":"0"}]}""")]
    [InlineData("""{"STATUS":0,"result":[{"id":"1234567","signStatus":"0"},{"id":"1234567","signStatus":"1"}]}""")]
    [InlineData("bad gateway")]
    public async Task MissingOrUnknownAttendanceNeverAuthorizesRetry(string state)
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock : IsSign(r) ? "{}" : state);
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Unknown, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Single(handler.Requests, IsSign);
        Assert.Equal(3, handler.Requests.Count);
    }
    [Fact]
    public async Task SecondReadCanConfirmDelayedSuccess()
    {
        var fixtures = new Queue<string>([SchoolClock, "{}", SignState("0"), SignState("1")]);
        using var handler = new FakeHttp(_ => fixtures.Dequeue());
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Signed, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Single(handler.Requests, IsSign);
    }
    [Theory]
    [InlineData(true, 3)]
    [InlineData(false, 1)]
    public async Task SubmissionRetryLimitRespectsScheduledBudget(bool retry, int attempts)
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock : IsSign(r) ? "{}" : SignState("0"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Unknown, (await client.SignAsync(TestData.Course(), TestData.Session(), retryUnconfirmed: retry)).Outcome);
        Assert.Equal(attempts, handler.Requests.Count(IsSign));
        Assert.Equal(retry ? attempts * 4 : 2, handler.Requests.Count);
    }
    [Fact]
    public async Task TimestampRejectionForcesCalibrationBeforeRetry()
    {
        const string rejected = """{"STATUS":1,"ERRCODE":100,"ERRMSG":"时间戳传入异常！"}""";
        Assert.Equal(SignOutcome.TimestampRejected, ResponseParser.Sign(Json(rejected)).Outcome);
        var fixtures = new Queue<string>([SchoolClock, rejected, """{"STATUS":0,"timestamp":1789518605000}""", Fixture("sign-success")]);
        using var handler = new FakeHttp(_ => fixtures.Dequeue());
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Signed, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Equal(4, handler.Requests.Count);
        Assert.Contains("timestamp=1789518605000", handler.Requests.Last().Uri.Query);
    }
    [Fact]
    public async Task RetryRechecksAuthorization()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock : IsSign(r) ? "{}" : SignState("0"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        var authorizations = 0;
        Assert.Equal(SignOutcome.Unknown, (await client.SignAsync(TestData.Course(), TestData.Session(), authorize: () => ++authorizations == 1)).Outcome);
        Assert.Single(handler.Requests, IsSign);
        Assert.Equal(2, authorizations);
    }
    [Fact]
    public async Task RetryStopsWhenSchoolSignWindowEnds()
    {
        var fixtures = new Queue<string>([SchoolClock, "{}", SignState("0"), SignState("0"),
            "{\"STATUS\":0,\"timestamp\":" + TestData.Course().End!.Value.ToUnixTimeMilliseconds() + "}"]);
        using var handler = new FakeHttp(_ => fixtures.Dequeue());
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Unknown, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Single(handler.Requests, IsSign);
        Assert.Equal(5, handler.Requests.Count);
    }
    [Fact]
    public async Task LostNetworkResponseChecksAttendanceBeforeAnotherSubmit()
    {
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock
            : IsSign(r) ? throw new HttpRequestException("connection reset") : SignState("1"));
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.Signed, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Single(handler.Requests, IsSign);
    }
    [Fact]
    public async Task TransientClockFailureRetriesWithoutAddingBackoffToOffset()
    {
        var clock = new FakeClock(TestData.Now);
        var requests = 0;
        using var handler = new FakeHttp(_ => { clock.Now += TimeSpan.FromMilliseconds(200); return ++requests == 1 ? "bad gateway" : SchoolClock; });
        using var client = new SchoolClient(handler, clock, (delay, _) => { clock.Now += delay; return Task.CompletedTask; });
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1789518600100), await client.SchoolNowAsync());
        Assert.Equal(2, handler.Requests.Count);
    }
    [Fact]
    public async Task CancellationDuringVerificationNeverResubmits()
    {
        using var cancel = new CancellationTokenSource();
        using var handler = new FakeHttp(r => r.Uri.AbsolutePath.EndsWith("get_timestamp.do") ? SchoolClock : "{}");
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), (_, ct) => { cancel.Cancel(); ct.ThrowIfCancellationRequested(); return Task.CompletedTask; });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.SignAsync(TestData.Course(), TestData.Session(), cancel.Token));
        Assert.Equal(2, handler.Requests.Count);
    }
    [Theory]
    [InlineData("未在上课时间")]
    [InlineData("请使用扫码签到")]
    [InlineData("用户不存在")]
    public async Task ExplicitRefusalIsNotRetried(string message)
    {
        using var handler = new FakeHttp(r => IsSign(r) ? JsonSerializer.Serialize(new { STATUS = "1", ERRMSG = message }) : SchoolClock);
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.Equal(SignOutcome.OutsideSignWindow, (await client.SignAsync(TestData.Course(), TestData.Session())).Outcome);
        Assert.Equal(2, handler.Requests.Count);
    }
    [Fact]
    public async Task ExpiredSubmissionDoesNotResubmit()
    {
        using var handler = new FakeHttp(r => IsSign(r) ? """{"ERRCODE":"401"}""" : SchoolClock);
        using var client = new SchoolClient(handler, new FakeClock(TestData.Now), NoDelay);
        Assert.True((await Assert.ThrowsAsync<SchoolException>(() => client.SignAsync(TestData.Course(), TestData.Session()))).IsSessionExpired);
        Assert.Equal(2, handler.Requests.Count);
    }
    [Fact]
    public void UnclearResponseRetainsSchoolExplanation()
    {
        var result = ResponseParser.Sign(Json("""{"STATUS":1,"ERRMSG":"学校服务繁忙"}"""));
        Assert.Equal(SignOutcome.Unknown, result.Outcome);
        Assert.Contains("学校服务繁忙", result.Message);
    }
    [Fact]
    public async Task HttpAuthenticationAndInvalidJsonAreActionable()
    {
        using var h = new FakeHttp(_ => "{}") { Status = HttpStatusCode.Unauthorized };
        using var c = new SchoolClient(h);
        Assert.True((await Assert.ThrowsAsync<SchoolException>(() => c.LoginAsync("a", "b"))).IsSessionExpired);
        h.Status = HttpStatusCode.OK;
        h.Respond = _ => Task.FromResult("<html>");
        Assert.Equal("BAD_RESPONSE", (await Assert.ThrowsAsync<SchoolException>(() => c.LoginAsync("a", "b"))).Code);
    }
}
