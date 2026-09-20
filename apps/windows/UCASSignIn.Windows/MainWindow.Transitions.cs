using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.UI.ViewManagement;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    enum NavigationMotion { Entrance, Forward, Back }

    readonly UISettings motionSettings = new();
    StackPanel Page = null!;
    ScrollViewer PageScroll = null!;
    (string Section, string? Route, string? CourseId, string? Day, Guid Generation)? displayedPage;
    NavigationTransitionInfo? lastPageTransition;
    bool rendering;

    void Render(NavigationMotion motion = NavigationMotion.Entrance)
    {
        if (PageFrame is null || rendering) return;
        rendering = true;
        try
        {
            var destination = (section, route, route == "detail" ? detail?.Id : route == "catalog-detail" ? catalogDetail?.Id : null,
                route == "detail" ? detail?.Day : null, Model.Generation);
            if (displayedPage == destination)
            {
                // Data, theme and QR updates do not constitute navigation.
                RenderCurrentPage();
                return;
            }

            lastPageTransition = displayedPage is null || !ready || !motionSettings.AnimationsEnabled
                ? new SuppressNavigationTransitionInfo()
                : motion == NavigationMotion.Entrance ? new EntranceNavigationTransitionInfo()
                : new SlideNavigationTransitionInfo
                {
                    Effect = motion == NavigationMotion.Back
                        ? SlideNavigationTransitionEffect.FromLeft
                        : SlideNavigationTransitionEffect.FromRight
                };
            displayedPage = destination;

            // The app already owns each section's route. Keep Frame history disabled
            // and use an explicit reverse slide for Back. A fresh uncached Page keeps
            // outgoing content intact while WinUI animates the incoming content.
            PageFrame.NavigateToType(typeof(NavigationPage), (Action<NavigationPage>)(view =>
            {
                Page = view.ContentPanel;
                PageScroll = view.ScrollHost;
                var gutter = ContentSurface.ActualWidth < 600 ? 16 : 32;
                Page.Padding = new(gutter, 8, gutter, 24);
                RenderCurrentPage();
            }), new FrameNavigationOptions
            {
                IsNavigationStackEnabled = false,
                TransitionInfoOverride = lastPageTransition
            });
        }
        finally { rendering = false; }
    }
}
