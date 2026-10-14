using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using UCASSignIn.Core;

namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    async Task EditHistoryRetention()
    {
        if (dialogOpen) return;
        var initial = Model.HistoryRetention;
        var saving = false;
        var saveFailed = false;
        var dialog = new ContentDialog
        {
            Title = "记录保留", PrimaryButtonText = "保存", CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.None, IsPrimaryButtonEnabled = false
        };
        AutomationProperties.SetAutomationId(dialog, "historyRetention.editor");
        Action updateSave = () => { };
        var operations = new HistoryRetentionPolicyEditor(this, "签到操作记录", "operations", initial.Operations, () => updateSave());
        var automatic = new HistoryRetentionPolicyEditor(this, "自动签到历史", "automatic", initial.Automatic, () => updateSave());
        var error = Text("", 13, color: Brush(dark ? "FF99A4" : "C42B1C"));
        error.Visibility = Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(error, AutomationLiveSetting.Polite);
        var body = Column(operations.Content, automatic.Content,
            SettingsNote("默认不限数量和时间，保留限制按账户分别计算。数量与时间限制可同时启用，关闭对应开关即不限。"),
            SettingsNote("点击“保存”后生效并清理超额或过期记录，已清理的记录不会恢复。未完成的记录会保留至结束，防止重复签到的本机状态不受影响。设置仅保存在这台设备。"), error);
        body.Spacing = 20;
        body.Width = Math.Min(400, Math.Max(240, Root.ActualWidth - 96));
        dialog.Content = new ScrollViewer
        {
            Content = body, MaxHeight = 500,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        };
        HistoryRetentionSettings? Proposed() => operations.Policy is { } operationPolicy && automatic.Policy is { } automaticPolicy
            ? new HistoryRetentionSettings(operationPolicy, automaticPolicy) : null;
        updateSave = () => dialog.IsPrimaryButtonEnabled = !saving && Proposed() is { } proposed
            && (proposed != Model.HistoryRetention || saveFailed);
        updateSave();
        // Keep the draft in this dialog: background Model.Changed notifications rebuild
        // the settings page, but must not replace partially entered values or focus.
        dialog.Closing += (_, args) => { if (saving) args.Cancel = true; };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (saving || Proposed() is not { } proposed) return;
            var deferral = args.GetDeferral();
            saving = true;
            saveFailed = false;
            operations.SetEnabled(false);
            automatic.SetEnabled(false);
            dialog.CloseButtonText = "";
            dialog.PrimaryButtonText = "正在保存…";
            error.Visibility = Visibility.Collapsed;
            updateSave();
            try
            {
                await Model.SetHistoryRetentionAsync(proposed);
                args.Cancel = false;
            }
            catch (Exception ex)
            {
                // The setting may already be durable when cleanup fails. Show the
                // coordinator's precise result and keep Save available for a retry.
                saveFailed = true;
                error.Text = ex.Message;
                error.Visibility = Visibility.Visible;
            }
            finally
            {
                saving = false;
                operations.SetEnabled(true);
                automatic.SetEnabled(true);
                dialog.CloseButtonText = "取消";
                dialog.PrimaryButtonText = "保存";
                updateSave();
                deferral.Complete();
            }
        };
        await Show(dialog);
    }

    sealed class HistoryRetentionPolicyEditor
    {
        readonly ToggleSwitch limitsCount;
        readonly ToggleSwitch limitsAge;
        readonly TextBox count;
        readonly TextBox days;
        readonly StackPanel countInput;
        readonly StackPanel ageInput;
        readonly TextBlock countError;
        readonly TextBlock ageError;
        public StackPanel Content { get; }

        public HistoryRetentionPolicyEditor(MainWindow window, string title, string identifier,
            HistoryRetentionPolicy initial, Action changed)
        {
            limitsCount = new ToggleSwitch { Header = "限制数量", IsOn = initial.MaxCount is not null, OnContent = "", OffContent = "" };
            limitsAge = new ToggleSwitch { Header = "限制保留时间", IsOn = initial.MaxAgeDays is not null, OnContent = "", OffContent = "" };
            count = NumberInput("最多保留（条）", initial.MaxCount);
            days = NumberInput("保留最近（天）", initial.MaxAgeDays);
            countError = window.Text("请输入大于 0 的整数", 12, color: window.Brush(window.dark ? "FF99A4" : "C42B1C"));
            ageError = window.Text("请输入大于 0 的整数", 12, color: window.Brush(window.dark ? "FF99A4" : "C42B1C"));
            countInput = window.Column(count, countError);
            ageInput = window.Column(days, ageError);
            Content = window.Column(window.Text(title, 14, true), limitsCount, countInput, limitsAge, ageInput);
            Content.Spacing = 12;
            Identify(limitsCount, "limitsCount", "限制数量");
            Identify(limitsAge, "limitsAge", "限制保留时间");
            Identify(count, "count", "最多保留条数");
            Identify(days, "days", "保留天数");
            AutomationProperties.SetAutomationId(countError, $"historyRetention.{identifier}.count.error");
            AutomationProperties.SetAutomationId(ageError, $"historyRetention.{identifier}.days.error");
            Update();
            limitsCount.Toggled += (_, _) => Updated();
            limitsAge.Toggled += (_, _) => Updated();
            count.TextChanged += (_, _) => Updated();
            days.TextChanged += (_, _) => Updated();

            void Identify(DependencyObject control, string field, string label)
            {
                AutomationProperties.SetAutomationId(control, $"historyRetention.{identifier}.{field}");
                AutomationProperties.SetName(control, title + label);
            }
            void Updated() { Update(); changed(); }
        }

        public HistoryRetentionPolicy? Policy
        {
            get
            {
                var maxCount = PositiveInteger(count.Text);
                var maxAgeDays = PositiveInteger(days.Text);
                if (limitsCount.IsOn && maxCount is null || limitsAge.IsOn && maxAgeDays is null) return null;
                return new HistoryRetentionPolicy(limitsCount.IsOn ? maxCount : null, limitsAge.IsOn ? maxAgeDays : null);
            }
        }

        public void SetEnabled(bool enabled)
        {
            limitsCount.IsEnabled = enabled; limitsAge.IsEnabled = enabled;
            count.IsEnabled = enabled; days.IsEnabled = enabled;
        }

        void Update()
        {
            countInput.Visibility = limitsCount.IsOn ? Visibility.Visible : Visibility.Collapsed;
            ageInput.Visibility = limitsAge.IsOn ? Visibility.Visible : Visibility.Collapsed;
            countError.Visibility = PositiveInteger(count.Text) is null ? Visibility.Visible : Visibility.Collapsed;
            ageError.Visibility = PositiveInteger(days.Text) is null ? Visibility.Visible : Visibility.Collapsed;
        }

        static int? PositiveInteger(string text) => int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value > 0 ? value : null;

        static TextBox NumberInput(string header, int? value)
        {
            var scope = new InputScope();
            scope.Names.Add(new InputScopeName { NameValue = InputScopeNameValue.Number });
            return new TextBox
            {
                Header = header, PlaceholderText = "请输入正整数", Text = value?.ToString(CultureInfo.InvariantCulture) ?? "",
                InputScope = scope, HorizontalAlignment = HorizontalAlignment.Stretch
            };
        }
    }
}
