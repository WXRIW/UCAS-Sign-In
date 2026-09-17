using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using Android.Animation;
using Android.App;
using Android.Views;
using Android.Window;
using AndroidX.Core.View;

namespace UCASSignIn.Android.Fragments;

// Dialogs own a separate window/dispatcher from the Activity. Do not replace their
// cancel/dismiss listeners: DialogFragment and MaterialDatePicker use those too.
[SupportedOSPlatform("android34.0")]
internal sealed class PredictiveDialogBack : Java.Lang.Object, IOnBackAnimationCallback, View.IOnAttachStateChangeListener
{
    static readonly ConditionalWeakTable<Dialog, PredictiveDialogBack> attached = new();
    readonly Dialog dialog;
    readonly Func<bool> canCancel;
    readonly View view;
    readonly IOnBackInvokedDispatcher dispatcher;
    readonly float scaleX, scaleY, alpha, translationX;
    ValueAnimator? animator;
    float progress, direction;
    bool registered, released, tracking, finishing, keyboardAtStart;

    public static void Attach(Dialog dialog, Func<bool> canCancel)
    {
        if (!attached.TryGetValue(dialog, out _))
            attached.Add(dialog, new PredictiveDialogBack(dialog, canCancel));
    }


    PredictiveDialogBack(Dialog dialog, Func<bool> canCancel)
    {
        this.dialog = dialog;
        this.canCancel = canCancel;
        view = dialog.Window!.DecorView!;
        dispatcher = dialog.OnBackInvokedDispatcher;
        scaleX = view.ScaleX;
        scaleY = view.ScaleY;
        alpha = view.Alpha;
        translationX = view.TranslationX;
        view.AddOnAttachStateChangeListener(this);
        if (view.IsAttachedToWindow) Register();
    }

    bool KeyboardVisible => ViewCompat.GetRootWindowInsets(view)?.IsVisible(WindowInsetsCompat.Type.Ime()) == true;
    bool AnimationsEnabled => ValueAnimator.AreAnimatorsEnabled();

    void Register()
    {
        if (registered || released) return;
        // Default priority lets the IME consume Back before the dialog does.
        dispatcher.RegisterOnBackInvokedCallback(0, this);
        registered = true;
    }

    public void OnViewAttachedToWindow(View? v) => Register();
    public void OnViewDetachedFromWindow(View? v)
    {
        released = true;
        StopAnimation();
        Restore();
        if (registered) dispatcher.UnregisterOnBackInvokedCallback(this);
        registered = false;
        view.RemoveOnAttachStateChangeListener(this);
        attached.Remove(dialog);
    }

    public void OnBackStarted(BackEvent backEvent)
    {
        if (released || finishing) return;
        StopAnimation();
        Restore();
        keyboardAtStart = KeyboardVisible;
        tracking = dialog.IsShowing && canCancel() && !keyboardAtStart && AnimationsEnabled;
        direction = backEvent.SwipeEdge == BackEventEdge.Left ? 1 : -1;
    }

    public void OnBackProgressed(BackEvent backEvent)
    {
        if (!tracking || finishing || released) return;
        if (!canCancel() || KeyboardVisible)
        {
            tracking = false;
            Restore();
            return;
        }
        Apply(backEvent.Progress);
    }

    public void OnBackCancelled()
    {
        if (released || finishing) return;
        tracking = false;
        keyboardAtStart = false;
        AnimateTo(0, false);
    }

    public void OnBackInvoked()
    {
        if (released || finishing || !dialog.IsShowing) return;
        if (keyboardAtStart || KeyboardVisible)
        {
            keyboardAtStart = false;
            tracking = false;
            StopAnimation();
            Restore();
            new WindowInsetsControllerCompat(dialog.Window!, view).Hide(WindowInsetsCompat.Type.Ime());
            return;
        }
        if (!canCancel())
        {
            tracking = false;
            AnimateTo(0, false);
            return;
        }
        if (!tracking || !AnimationsEnabled)
        {
            StopAnimation();
            Restore();
            dialog.Cancel();
            return;
        }
        tracking = false;
        finishing = true;
        AnimateTo(1, true);
    }

    void Apply(float value)
    {
        progress = Math.Clamp(value, 0, 1);
        var eased = 1 - MathF.Pow(1 - progress, 3);
        view.ScaleX = scaleX * (1 - .08f * eased);
        view.ScaleY = scaleY * (1 - .08f * eased);
        view.TranslationX = translationX + direction * Math.Min(12 * view.Resources!.DisplayMetrics!.Density, view.Width * .03f) * eased;
        // Keep text and the dialog surface opaque during the preview. Fade only
        // after committing, so the underlying page does not bleed through labels.
        view.Alpha = alpha;
    }

    void AnimateTo(float target, bool close)
    {
        StopAnimation();
        if (!AnimationsEnabled || Math.Abs(progress - target) < .001f)
        {
            Finish();
            return;
        }
        var from = progress;
        var animation = ValueAnimator.OfFloat(0, 1)!;
        animator = animation;
        animation.SetDuration(close ? 120 : 180);
        animation.Update += (_, _) =>
        {
            var fraction = (float)animation.AnimatedValue!;
            Apply(from + (target - from) * fraction);
            if (close) view.Alpha *= 1 - fraction;
        };
        animation.AnimationEnd += (_, _) =>
        {
            if (animator != animation || released) return;
            animator = null;
            animation.RemoveAllListeners();
            animation.RemoveAllUpdateListeners();
            animation.Dispose();
            Finish();
        };
        animation.Start();

        void Finish()
        {
            finishing = false;
            if (close && !released && dialog.IsShowing && canCancel()) dialog.Cancel();
            else Restore();
        }
    }

    void StopAnimation()
    {
        if (animator is not { } animation) return;
        animator = null;
        animation.RemoveAllListeners();
        animation.RemoveAllUpdateListeners();
        animation.Cancel();
        animation.Dispose();
    }

    void Restore()
    {
        progress = 0;
        view.ScaleX = scaleX;
        view.ScaleY = scaleY;
        view.Alpha = alpha;
        view.TranslationX = translationX;
    }
}
