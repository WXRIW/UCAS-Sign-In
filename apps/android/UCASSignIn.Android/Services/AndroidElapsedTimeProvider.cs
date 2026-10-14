namespace UCASSignIn.Android.Services;

public sealed class AndroidElapsedTimeProvider : TimeProvider
{
    // Stopwatch's CLOCK_MONOTONIC excludes Android deep sleep. School-clock
    // samples must keep advancing while the device sleeps, without relying on
    // the adjustable wall clock for elapsed time.
    public override long GetTimestamp() => global::Android.OS.SystemClock.ElapsedRealtimeNanos();
    public override long TimestampFrequency => 1_000_000_000;
}
