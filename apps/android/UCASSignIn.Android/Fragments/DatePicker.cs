using Google.Android.Material.DatePicker;
namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    Task PickDate()
    {
        if (Host.DialogOpen || Host.SupportFragmentManager.IsStateSaved)
            return Task.CompletedTask;
        // The window can detach before DialogFragment processes its dismiss message.
        if (Host.SupportFragmentManager.FindFragmentByTag("date") is AndroidX.Fragment.App.DialogFragment previous)
            previous.DismissNow();
        var picker = MaterialDatePicker.Builder.DatePicker()!.SetTitleText("选择课程日期")!
            .SetSelection(Java.Lang.Long.ValueOf(new DateTimeOffset(Model.SelectedDate.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero).ToUnixTimeMilliseconds()))!.Build();
        picker.ShowNow(Host.SupportFragmentManager, "date");
        return Task.CompletedTask;
    }
}
