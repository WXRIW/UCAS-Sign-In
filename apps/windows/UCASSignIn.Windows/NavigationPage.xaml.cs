using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace UCASSignIn.Windows;

public sealed partial class NavigationPage : Page
{
    internal StackPanel ContentPanel => Body;
    internal ScrollViewer ScrollHost => Scroller;
    internal StackPanel FixedPanel => FixedHeader;

    public NavigationPage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Disabled;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ((Action<NavigationPage>)e.Parameter)(this);
    }
}
