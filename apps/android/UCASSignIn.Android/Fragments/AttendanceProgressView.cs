using Android.Content;
using Android.Content.Res;
using Android.Graphics;
using Android.Views;
using Android.Widget;
using Google.Android.Material.ProgressIndicator;

namespace UCASSignIn.Android.Fragments;

internal sealed class AttendanceProgressView : FrameLayout
{
    public AttendanceProgressView(Context context, int completed, int total, Color foreground, Color track) : base(context)
    {
        var density = context.Resources!.DisplayMetrics!.Density;
        int D(float value) => (int)Math.Round(value * density);
        var progress = new CircularProgressIndicator(context)
        {
            Indeterminate = false, Max = 1000,
            IndicatorSize = D(42), IndicatorInset = 0,
            TrackThickness = D(5), TrackCornerRadius = D(2.5f),
            IndicatorTrackGapSize = D(4), TrackColor = track,
            ImportantForAccessibility = ImportantForAccessibility.No
        };
        progress.SetIndicatorColor(foreground);
        progress.SetProgressCompat(total > 0 ? (int)Math.Round(Math.Clamp((double)completed / total, 0, 1) * progress.Max) : 0, false);
        AddView(progress, new LayoutParams(D(42), D(42), GravityFlags.Center));
        var check = new ImageView(context) { ImageTintList = ColorStateList.ValueOf(foreground), ImportantForAccessibility = ImportantForAccessibility.No };
        check.SetImageResource(Resource.Drawable.ic_check);
        check.SetScaleType(ImageView.ScaleType.FitCenter);
        AddView(check, new LayoutParams(D(20), D(20), GravityFlags.Center));
    }
}
