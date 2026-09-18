using Microsoft.Toolkit.Uwp.Notifications;
using Windows.ApplicationModel;
using Windows.Services.Store;
using Windows.UI.Notifications;

namespace UCASSignIn.Windows.Services;

public enum StoreUpdateOption
{
    Ask,
    Download,
    DownloadAndInstall
}

public static class WindowsDistribution
{
    static readonly Lazy<bool> storePackage = new(DetectStorePackage);

    public static bool IsStorePackage => storePackage.Value;

    static bool DetectStorePackage()
    {
        try
        {
            // Both MSIX variants have package identity. The Store re-signs its
            // package, while the directly distributed bundle keeps a developer
            // signature, so package identity alone is not enough here.
            return Package.Current.SignatureKind == PackageSignatureKind.Store;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }
}

public sealed class WindowsStoreUpdater
{
    StoreContext? context;

    public async Task<StoreUpdateAvailability> CheckAsync()
    {
        if (!WindowsDistribution.IsStorePackage)
            return StoreUpdateAvailability.None;

        context ??= StoreContext.GetDefault();
        var updates = await context.GetAppAndOptionalStorePackageUpdatesAsync();
        return new(context, updates);
    }

    public static void ShowUpdateNotification(Action activated)
    {
        var content = new ToastContentBuilder()
            .AddText("发现新版本")
            .AddText("点击以在 Microsoft Store 中查看")
            .GetToastContent();
        var toast = new ToastNotification(content.GetXml());
        toast.Activated += (_, _) => activated();
        ToastNotificationManagerCompat.CreateToastNotifier().Show(toast);
    }
}

public sealed class StoreUpdateAvailability
{
    readonly StoreContext? context;
    readonly IReadOnlyList<StorePackageUpdate> updates;

    internal static StoreUpdateAvailability None { get; } = new(null, []);

    internal StoreUpdateAvailability(StoreContext? context, IReadOnlyList<StorePackageUpdate> updates)
    {
        this.context = context;
        this.updates = updates;
    }

    public bool HasUpdate => updates.Count > 0;
    public bool CanUpdateSilently => context?.CanSilentlyDownloadStorePackageUpdates == true;

    public Task<bool> TryDownloadAsync() => TryUpdateAsync(install: false);
    public Task<bool> TryDownloadAndInstallAsync() => TryUpdateAsync(install: true);

    async Task<bool> TryUpdateAsync(bool install)
    {
        if (context is null || !HasUpdate || !CanUpdateSilently)
            return false;

        try
        {
            StorePackageUpdateResult result;
            if (install)
                result = await context.TrySilentDownloadAndInstallStorePackageUpdatesAsync(updates);
            else
                result = await context.TrySilentDownloadStorePackageUpdatesAsync(updates);
            return result.OverallState == StorePackageUpdateState.Completed;
        }
        catch
        {
            return false;
        }
    }
}
