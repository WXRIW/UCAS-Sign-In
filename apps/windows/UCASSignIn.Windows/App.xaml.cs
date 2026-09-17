using Microsoft.UI.Xaml;
using Microsoft.Toolkit.Uwp.Notifications;
namespace UCASSignIn.Windows;

public partial class App : Application
{
    MainWindow? window;
    string? pendingActivation;
    public App()
    {
        InitializeComponent();
        ToastNotificationManagerCompat.OnActivated += args =>
        {
            pendingActivation = args.Argument;
            window?.DispatcherQueue.TryEnqueue(() => { window.Activate(); window.OpenNotification(pendingActivation); pendingActivation = null; });
        };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
        if (pendingActivation is not null)
        {
            window.OpenNotification(pendingActivation);
            pendingActivation = null;
        }
    }
}
