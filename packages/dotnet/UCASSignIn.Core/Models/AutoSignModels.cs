namespace UCASSignIn.Core;

public enum AutoSignMissedAction { Manual, TenMinuteGrace, UntilClassEnds }
public enum AutoSignNotification { Problems, All, None }
public enum AutoSignStage { Planned, Checking, Submitting, Verifying, RetryWaiting, Signed, Missed, NeedsAttention, Skipped }
public enum AutoSignEventKind { Legacy, ExecutionStarted, Verification, Submission, Result, Missed, ManualTakeover, PlanChanged, Pause }

public sealed record AutoSignPolicy(int OffsetMinutes = -5, AutoSignMissedAction MissedAction = AutoSignMissedAction.Manual,
    int MaxSubmissions = 3, int RetryMinutes = 2, AutoSignNotification Notification = AutoSignNotification.Problems)
{
    public bool IsValid => OffsetMinutes >= -25 && OffsetMinutes <= 240 && MaxSubmissions is >= 1 and <= 3
        && RetryMinutes is 1 or 2 or 5 && Enum.IsDefined(MissedAction) && Enum.IsDefined(Notification);
    public void Validate()
    {
        if (!IsValid) throw new ArgumentOutOfRangeException(nameof(AutoSignPolicy), "自动签到规则超出允许范围");
    }
}

public sealed record AutoSignPolicyOverride(int? OffsetMinutes = null, AutoSignMissedAction? MissedAction = null,
    int? MaxSubmissions = null, int? RetryMinutes = null, AutoSignNotification? Notification = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public bool HasValues => OffsetMinutes is not null || MissedAction is not null || MaxSubmissions is not null
        || RetryMinutes is not null || Notification is not null;
    public AutoSignPolicy Resolve(AutoSignPolicy parent)
    {
        var result = parent with
        {
            OffsetMinutes = OffsetMinutes ?? parent.OffsetMinutes,
            MissedAction = MissedAction ?? parent.MissedAction,
            MaxSubmissions = MaxSubmissions ?? parent.MaxSubmissions,
            RetryMinutes = RetryMinutes ?? parent.RetryMinutes,
            Notification = Notification ?? parent.Notification
        };
        result.Validate();
        return result;
    }
}

public sealed record AutoSignOccurrenceOverride(bool? Enabled = null, DateTimeOffset? At = null,
    AutoSignPolicyOverride? Policy = null, DateTimeOffset? EnabledSince = null);
public sealed record AutoSignEvent(DateTimeOffset At, AutoSignStage Stage, string Message,
    AutoSignEventKind Kind = AutoSignEventKind.Legacy)
{
    public bool IsPreview => Kind == AutoSignEventKind.PlanChanged || Kind == AutoSignEventKind.Pause
        || Kind == AutoSignEventKind.Legacy && (Message == "计划已生成"
            || Message.StartsWith("计划已更新：") || Message.StartsWith("计划已暂停或跳过："));
    public bool IsManualTakeover => Kind == AutoSignEventKind.ManualTakeover || Message == "用户已手动接管";
}
public sealed record AutoSignExecution(string Key, int Submissions, AutoSignStage Stage, DateTimeOffset? LastSubmissionAt,
    DateTimeOffset? NextAt, DateTimeOffset? FirstNegativeAt, int NegativeReads, string Message,
    List<AutoSignEvent> Events, DateTimeOffset? StartedAt = null, string? CourseName = null,
    DateTimeOffset? ClassStartAt = null, DateTimeOffset? ClassEndAt = null,
    DateTimeOffset? LastVerificationAttemptAt = null, AutoSignNotification? NotificationMode = null,
    DateTimeOffset? LastSchoolSubmissionAt = null, DateTimeOffset? FirstSchoolNegativeAt = null,
    DateTimeOffset? LastSchoolVerificationAttemptAt = null,
    long? LastSubmissionQuerySequence = null, long? LastNegativeQuerySequence = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public bool HasExecutionActivity => StartedAt is not null || Submissions > 0 || LastSubmissionAt is not null
        || NegativeReads > 0 || FirstNegativeAt is not null || LastVerificationAttemptAt is not null
        || LastSchoolSubmissionAt is not null || FirstSchoolNegativeAt is not null
        || Events.Any(e => !e.IsPreview && !e.IsManualTakeover)
        || Stage is not (AutoSignStage.Planned or AutoSignStage.Skipped);
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsPurePreview => !HasExecutionActivity && Events.Count > 0 && Events.All(e => e.IsPreview);
    public static AutoSignExecution New(string key, DateTimeOffset now) => new(key, 0, AutoSignStage.Planned,
        null, null, null, 0, "等待计划时间", []);
    public AutoSignExecution Begin(Course course, DateTimeOffset now, AutoSignNotification? notificationMode = null) => HasExecutionActivity ? this : this with
    {
        StartedAt = now, CourseName = course.Name, ClassStartAt = course.Start, ClassEndAt = course.End,
        NotificationMode = notificationMode,
        Stage = AutoSignStage.Checking, Message = "开始核实学校签到状态",
        Events = [.. Events, new(now, AutoSignStage.Checking, "开始核实学校签到状态", AutoSignEventKind.ExecutionStarted)]
    };
    public AutoSignExecution Transition(AutoSignStage stage, DateTimeOffset now, string message,
        DateTimeOffset? nextAt = null, AutoSignEventKind? kind = null) => this with
        {
            Stage = stage, NextAt = nextAt, Message = message,
            Events = [.. Events, new(now, stage, message, kind ?? (stage switch
            {
                AutoSignStage.Submitting => AutoSignEventKind.Submission,
                AutoSignStage.Checking or AutoSignStage.Verifying or AutoSignStage.RetryWaiting => AutoSignEventKind.Verification,
                AutoSignStage.Missed => AutoSignEventKind.Missed,
                AutoSignStage.Skipped => AutoSignEventKind.ManualTakeover,
                _ => AutoSignEventKind.Result
            }))]
        };
}
public sealed record AutoSignPlan(string Key, Course Course, DateTimeOffset PlannedAt, DateTimeOffset Deadline,
    AutoSignPolicy Policy, string Source, AutoSignStage Stage, string Reason, DateTimeOffset? NextAt,
    Dictionary<string, string> Sources, bool IsParticipating = true)
{
    public string StageTitle => Stage switch
    {
        AutoSignStage.Planned => "待执行", AutoSignStage.Checking => "正在核实",
        AutoSignStage.Submitting => "正在提交", AutoSignStage.Verifying => "等待核实",
        AutoSignStage.RetryWaiting => "等待重试", AutoSignStage.Signed => "已签到",
        AutoSignStage.Missed => "已错过", AutoSignStage.NeedsAttention => "需手动处理", _ => "未参与"
    };
    public string NextAction => Stage switch
    {
        AutoSignStage.Planned => "到计划时间后核实学校状态",
        AutoSignStage.Checking => "等待学校查询结果",
        AutoSignStage.Submitting => "等待本次提交结果",
        AutoSignStage.Verifying or AutoSignStage.RetryWaiting => "到重试时间后再次核实；确认未签到才提交",
        AutoSignStage.Signed => "已完成，无需操作",
        AutoSignStage.Missed or AutoSignStage.NeedsAttention => "请打开课程手动处理",
        _ => "当前不会自动执行"
    };
}
public sealed record AutoSignLedger(int Version, string AccountId, Dictionary<string, AutoSignExecution> Executions)
{
    public const int CurrentVersion = 2;
    public void Validate(string expectedAccountId)
    {
        if (Version is not (1 or CurrentVersion) || AccountId != expectedAccountId || Executions is null
            || Executions.Any(x => x.Value is null || string.IsNullOrWhiteSpace(x.Key) || x.Value.Key != x.Key
                || x.Value.Submissions is < 0 or > 3 || x.Value.NegativeReads is < 0 or > 2
                || x.Value.Submissions > 0 && x.Value.LastSubmissionAt is null
                || x.Value.Submissions == 0 && x.Value.LastSubmissionAt is not null
                || x.Value.NegativeReads > 0 && x.Value.FirstNegativeAt is null
                || x.Value.LastSubmissionQuerySequence is < 0 || x.Value.LastNegativeQuerySequence is < 0
                || x.Value.Submissions == 0 && (x.Value.LastSchoolSubmissionAt is not null || x.Value.LastSchoolVerificationAttemptAt is not null || x.Value.LastSubmissionQuerySequence is not null)
                || x.Value.NegativeReads == 0 && (x.Value.FirstSchoolNegativeAt is not null || x.Value.LastNegativeQuerySequence is not null)
                || !Enum.IsDefined(x.Value.Stage) || x.Value.NotificationMode is { } mode && !Enum.IsDefined(mode) || x.Value.Events is null
                || x.Value.Events.Any(e => e is null || !Enum.IsDefined(e.Stage) || !Enum.IsDefined(e.Kind))))
            throw new IOException("自动签到记录无法读取，已暂停自动提交");
    }
    public AutoSignLedger Cleaned() => new(CurrentVersion, AccountId,
        Executions.Where(x => !x.Value.IsPurePreview).ToDictionary(x => x.Key, x => x.Value));
}

public static class AutoSignPlanner
{
    public static string Key(string accountId, Course course) => accountId + "|" + (CourseTime.NormalizeDay(course.Day) ?? course.Day) + "|" + course.Id;
    public static AutoSignPlan? Create(string accountId, Course course, AutoSignPolicy accountPolicy,
        AutoSignPolicyOverride? courseRule, AutoSignOccurrenceOverride? occurrence,
        bool running, PreferenceOverride courseEnabled, bool signDisabled,
        DateTimeOffset now, AutoSignExecution? execution = null, DateTimeOffset? enabledSince = null)
    {
        if (course.Start is not { } start || course.End is not { } end || end <= start) return null;
        var policy = (occurrence?.Policy ?? new()).Resolve((courseRule ?? new()).Resolve(accountPolicy));
        var at = occurrence?.At ?? start.AddMinutes(policy.OffsetMinutes);
        var key = Key(accountId, course);
        var participating = !signDisabled && (occurrence?.Enabled ?? CoursePreferences.Resolve(courseEnabled, true));
        var afterActivation = enabledSince is null || at >= enabledSince;
        var enabled = running && participating && afterActivation;
        var source = occurrence is { Enabled: not null } || occurrence?.At is not null || occurrence?.Policy?.HasValues == true
            ? "本次调整" : courseRule?.HasValues == true || courseEnabled != PreferenceOverride.Inherit ? "课程设置" : "账户默认";
        var deadline = policy.MissedAction switch
        {
            AutoSignMissedAction.Manual => at.AddSeconds(60),
            AutoSignMissedAction.TenMinuteGrace => at.AddMinutes(10),
            _ => end
        };
        deadline = deadline < end ? deadline : end;
        var stage = execution?.Stage ?? AutoSignStage.Planned;
        var reason = execution?.Message ?? (enabled ? "等待计划时间" : signDisabled ? "本课程已禁用签到" : running ? "自动签到未启用" : "自动签到已暂停");
        if (!enabled)
        {
            stage = AutoSignStage.Skipped;
            reason = signDisabled ? "本课程已禁用签到" : !afterActivation ? "开启前的课次已略过"
                : !running ? "自动签到已暂停" : "自动签到未启用";
        }
        else if (at < start.AddMinutes(-25) || at >= end)
        {
            stage = AutoSignStage.NeedsAttention;
            reason = "计划时间已超出签到窗口，请调整";
        }
        else if (execution is null && now > deadline)
        {
            stage = AutoSignStage.Missed;
            reason = "已错过计划时间，请手动处理";
        }
        string SourceOf(bool once, bool perCourse) => once ? "本次调整" : perCourse ? "课程设置" : "账户默认";
        var sources = new Dictionary<string, string>
        {
            ["启用"] = SourceOf(occurrence?.Enabled is not null, courseEnabled != PreferenceOverride.Inherit),
            ["执行时间"] = SourceOf(occurrence?.At is not null || occurrence?.Policy?.OffsetMinutes is not null, courseRule?.OffsetMinutes is not null),
            ["错过处理"] = SourceOf(occurrence?.Policy?.MissedAction is not null, courseRule?.MissedAction is not null),
            ["提交次数"] = SourceOf(occurrence?.Policy?.MaxSubmissions is not null, courseRule?.MaxSubmissions is not null),
            ["重试间隔"] = SourceOf(occurrence?.Policy?.RetryMinutes is not null, courseRule?.RetryMinutes is not null),
            ["结果通知"] = SourceOf(occurrence?.Policy?.Notification is not null, courseRule?.Notification is not null)
        };
        return new(key, course, at, deadline, policy, source, stage, reason, execution?.NextAt ?? at, sources,
            participating && afterActivation);
    }
}
