using System.Text.Json.Serialization;

namespace UCASSignIn.Core;

/// <summary>Missing limits retain every row. Age is inclusive and is applied before count.</summary>
public sealed record HistoryRetentionPolicy(int? MaxCount = null, int? MaxAgeDays = null)
{
    [JsonIgnore]
    public bool IsUnlimited => MaxCount is null && MaxAgeDays is null;

    public void Validate()
    {
        if (MaxCount is <= 0 || MaxAgeDays is <= 0)
            throw new ArgumentOutOfRangeException(nameof(HistoryRetentionPolicy), "记录保留数量和天数必须为正整数，或设为不限");
    }

    public IReadOnlyList<T> Retain<T>(IEnumerable<T> values, DateTimeOffset now,
        Func<T, DateTimeOffset> date, Func<T, string> key, Func<T, bool>? isProtected = null)
    {
        Validate();
        // Saturate instead of AddDays(int.MaxValue), which overflows the calendar range.
        var cutoff = MaxAgeDays is { } days && days < (now.UtcDateTime - DateTime.MinValue).TotalDays
            ? now.ToUniversalTime().AddDays(-days) : DateTimeOffset.MinValue;
        var ordered = values.OrderByDescending(date).ThenBy(key, StringComparer.Ordinal).ToArray();
        var retained = new List<T>();
        var eligibleCount = 0;
        foreach (var value in ordered)
        {
            var eligible = date(value) >= cutoff;
            var selected = eligible && (MaxCount is null || eligibleCount < MaxCount);
            if (eligible) eligibleCount++;
            // Select by position, not value equality: identical operation rows are still separate rows.
            if (selected || isProtected?.Invoke(value) == true) retained.Add(value);
        }
        return retained;
    }
}

public sealed record HistoryRetentionSettings
{
    public HistoryRetentionPolicy Operations { get; init; }
    public HistoryRetentionPolicy Automatic { get; init; }

    [JsonConstructor]
    public HistoryRetentionSettings(HistoryRetentionPolicy? operations = null, HistoryRetentionPolicy? automatic = null)
    {
        Operations = operations ?? new();
        Automatic = automatic ?? new();
    }

    [JsonIgnore]
    public bool IsUnlimited => Operations.IsUnlimited && Automatic.IsUnlimited;

    public void Validate()
    {
        ArgumentNullException.ThrowIfNull(Operations);
        ArgumentNullException.ThrowIfNull(Automatic);
        Operations.Validate();
        Automatic.Validate();
    }
}
