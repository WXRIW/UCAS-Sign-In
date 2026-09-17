using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    readonly HashSet<(Guid Generation, string Section, DateOnly Date)> requestedRefreshes = [];

    DateOnly RefreshDate => section == "schedule" ? Model.SelectedDate : CourseTime.Today();

    void UpdateRefreshButton()
    {
        if (RefreshButton is null) return;
        var date = RefreshDate;
        var visible = section is "today" or "schedule";
        var refreshing = Model.IsLoadingCourses(date) || requestedRefreshes.Contains((Model.Generation, section, date));
        var title = section == "schedule" ? "刷新课表" : "刷新课程";
        RefreshButton.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.IsEnabled = Model.IsConnected && !refreshing;
        RefreshIcon.Visibility = refreshing ? Visibility.Collapsed : Visibility.Visible;
        RefreshProgress.Visibility = refreshing ? Visibility.Visible : Visibility.Collapsed;
        RefreshProgress.IsActive = visible && refreshing;
        RefreshProgress.Foreground = Green;
        AutomationProperties.SetName(RefreshButton, title);
        AutomationProperties.SetItemStatus(RefreshButton, refreshing ? "正在刷新" : "");
        ToolTipService.SetToolTip(RefreshButton, title + "（Ctrl+R）");
    }

    async Task RefreshCurrentCoursesAsync()
    {
        var model = Model;
        var date = RefreshDate;
        var request = (model.Generation, section, date);
        if (!model.IsConnected || dialogOpen || model.IsLoadingCourses(date) || !requestedRefreshes.Add(request)) return;

        // Match macOS CourseRefreshButton: update data immediately, but keep even
        // a fast response visible for 450 ms. Scope feedback to its account and date.
        var minimumFeedback = Task.Delay(450);
        UpdateRefreshButton();
        try { await model.RefreshAsync(date); }
        finally
        {
            await minimumFeedback;
            requestedRefreshes.Remove(request);
            if (!closed) UpdateRefreshButton();
        }
    }
}
