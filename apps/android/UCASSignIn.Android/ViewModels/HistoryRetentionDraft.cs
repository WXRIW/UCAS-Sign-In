using System.Globalization;
using UCASSignIn.Core;

namespace UCASSignIn.Android.ViewModels;

// Keep raw text outside the view tree so background refreshes and activity
// recreation cannot turn an unfinished edit into the persisted setting.
public sealed class HistoryRetentionDraft(HistoryRetentionSettings settings)
{
    public string OperationCount { get; set; } = Format(settings.Operations.MaxCount);
    public string OperationDays { get; set; } = Format(settings.Operations.MaxAgeDays);
    public string AutomaticCount { get; set; } = Format(settings.Automatic.MaxCount);
    public string AutomaticDays { get; set; } = Format(settings.Automatic.MaxAgeDays);
    public bool IsSaving { get; set; }
    public string? Error { get; set; }
    public event Action? Changed;
    public void NotifyChanged() => Changed?.Invoke();

    static string Format(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "";

    public static bool TryLimit(string text, out int? value)
    {
        value = null;
        if (string.IsNullOrWhiteSpace(text)) return true;
        if (!int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number <= 0) return false;
        value = number;
        return true;
    }

    public bool TrySettings(out HistoryRetentionSettings? settings)
    {
        settings = null;
        if (!TryLimit(OperationCount, out var operationCount) || !TryLimit(OperationDays, out var operationDays)
            || !TryLimit(AutomaticCount, out var automaticCount) || !TryLimit(AutomaticDays, out var automaticDays)) return false;
        settings = new(new(operationCount, operationDays), new(automaticCount, automaticDays));
        return true;
    }
}
