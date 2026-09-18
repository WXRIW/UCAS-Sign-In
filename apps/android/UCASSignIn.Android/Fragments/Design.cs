using Android.Content.Res;
using Android.Graphics;
using Android.Views;
using Android.Widget;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    ImageView Icon(int resource, int size = 22, Color? color = null)
    {
        var icon = new ImageView(Ui);
        icon.SetImageResource(resource);
        icon.ImageTintList = ColorStateList.ValueOf(color ?? Green);
        icon.SetScaleType(ImageView.ScaleType.FitCenter);
        icon.LayoutParameters = new LinearLayout.LayoutParams(D(size), D(size));
        icon.ImportantForAccessibility = ImportantForAccessibility.No;
        return icon;
    }
    View IconLabel(int resource, string value, float size, Color? color = null)
    {
        var row = Layout(global::Android.Widget.Orientation.Horizontal, GravityFlags.CenterVertical);
        row.AddView(Icon(resource, (int)size + 2, color), new LinearLayout.LayoutParams(D((int)size + 2), D((int)size + 2)) { MarginEnd = D(6) });
        row.AddView(Text(value, size, color: color), new LinearLayout.LayoutParams(0, -2, 1));
        return row;
    }
    View LicenseBadge(string license)
    {
        var badge = Text(license, 12, true, Green);
        badge.LayoutParameters = new LinearLayout.LayoutParams(-2, -2);
        badge.SetSingleLine(true);
        badge.SetPadding(D(10), D(6), D(10), D(6));
        var shape = new global::Android.Graphics.Drawables.GradientDrawable();
        shape.SetColor(Pale);
        shape.SetCornerRadius(D(20));
        badge.Background = shape;
        return badge;
    }
    View StatusBadge(bool signed)
    {
        var color = signed ? Secondary : Green;
        var label = Text(signed ? "已签到" : "未签到", 11, color: color);
        // The status column wraps its contents; the badge must contribute its own text width.
        label.LayoutParameters = new LinearLayout.LayoutParams(-2, -2);
        label.SetSingleLine(true);
        if (signed)
        {
            var check = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui, Resource.Drawable.ic_check)!.Mutate();
            check.SetTint(color.ToArgb());
            check.SetBounds(0, 0, D(12), D(12));
            label.SetCompoundDrawablesRelative(check, null, null, null);
            label.CompoundDrawablePadding = D(6);
        }
        label.SetPadding(D(9), D(5), D(9), D(5));
        var shape = new global::Android.Graphics.Drawables.GradientDrawable();
        shape.SetColor(new Color(color.R, color.G, color.B, (byte)20));
        shape.SetCornerRadius(D(20));
        label.Background = shape;
        return label;
    }
    View MetadataView(UCASSignIn.Core.Course course, float size = 11, Color? color = null, bool missing = false)
    {
        var row = Layout(global::Android.Widget.Orientation.Horizontal, GravityFlags.CenterVertical);
        var classroom = course.Classroom ?? (missing ? "教室暂未提供" : null);
        if (classroom is not null)
            row.AddView(IconLabel(Resource.Drawable.ic_location, classroom, size, color ?? Secondary), new LinearLayout.LayoutParams(-2, -2) { MarginEnd = D(15) });
        if (!string.IsNullOrWhiteSpace(course.Teacher))
            row.AddView(IconLabel(Resource.Drawable.ic_person, course.Teacher, size, color ?? Secondary), new LinearLayout.LayoutParams(-2, -2));
        else if (classroom is null) row.AddView(Text("课程详情", size, color: color ?? Secondary));
        return row;
    }
}
