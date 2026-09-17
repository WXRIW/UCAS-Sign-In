using Android.Views;
using Google.Android.Material.ProgressIndicator;

namespace UCASSignIn.Android.Fragments;

// This is a live clock: animation-duration settings must not change QR expiry.
sealed class QrCountdownAnimation(LinearProgressIndicator progress, DateTimeOffset expiresAt,
    Func<bool> canDisplay, Action<int> updateSeconds) : Java.Lang.Object, Choreographer.IFrameCallback
{
    readonly Choreographer frames = Choreographer.Instance!;
    bool running;
    int lastSeconds = -1;

    public void Start()
    {
        Stop();
        running = true;
        DoFrame(0);
    }

    public void DoFrame(long frameTimeNanos)
    {
        if (!running) return;
        if (!canDisplay())
        {
            Stop();
            progress.Visibility = ViewStates.Invisible;
            return;
        }

        var remaining = Math.Max(0, (expiresAt - DateTimeOffset.UtcNow).TotalMilliseconds);
        // Choreographer already supplies the animation frames; avoid a second spring animation.
        progress.SetProgressCompat((int)Math.Min(progress.Max, remaining), false);
        var seconds = (int)Math.Ceiling(remaining / 1000);
        if (seconds != lastSeconds)
        {
            lastSeconds = seconds;
            updateSeconds(seconds);
        }
        if (remaining > 0) frames.PostFrameCallback(this);
        else running = false;
    }

    public void Stop()
    {
        running = false;
        frames.RemoveFrameCallback(this);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) Stop();
        base.Dispose(disposing);
    }
}
