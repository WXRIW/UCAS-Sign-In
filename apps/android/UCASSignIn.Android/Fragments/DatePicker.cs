using Google.Android.Material.DatePicker;
namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    Task PickDate()
    {
        if (Host.DialogOpen || Host.SupportFragmentManager.IsStateSaved || Model.ViewedDateRange is not { } range)
            return Task.CompletedTask;
        // The window can detach before DialogFragment processes its dismiss message.
        if (Host.SupportFragmentManager.FindFragmentByTag("date") is AndroidX.Fragment.App.DialogFragment previous)
            previous.DismissNow();
        static long UtcDate(DateOnly date) => new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero).ToUnixTimeMilliseconds();
        var constraints = new CalendarConstraints.Builder().SetStart(UtcDate(range.Begin))!.SetEnd(UtcDate(range.End))!
            .SetOpenAt(UtcDate(Model.SelectedDate))!.SetValidator(CompositeDateValidator.AllOf(
                [DateValidatorPointForward.From(UtcDate(range.Begin))!, DateValidatorPointBackward.Before(UtcDate(range.End))!]))!.Build();
        var picker = MaterialDatePicker.Builder.DatePicker()!.SetTitleText("选择课程日期")!
            .SetCalendarConstraints(constraints)!
            .SetSelection(Java.Lang.Long.ValueOf(UtcDate(Model.SelectedDate)))!.Build();
        picker.Arguments!.PutString("schedule.generation", Model.Generation.ToString());
        picker.Arguments.PutString("schedule.semester", Model.ViewedSemester?.Id);
        picker.ShowNow(Host.SupportFragmentManager, "date");
        return Task.CompletedTask;
    }
}
