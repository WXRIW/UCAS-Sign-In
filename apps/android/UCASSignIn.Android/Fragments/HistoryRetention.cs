using Android.Text;
using Android.Views;
using Android.Widget;
using Google.Android.Material.TextField;
using UCASSignIn.Android.ViewModels;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    internal const string HistoryRetentionRoute = "history-retention";
    LinearLayout? historyRetentionEditorBody;
    HistoryRetentionDraft? historyRetentionEditorDraft;
    Action? updateHistoryRetentionEditor;

    bool RetainHistoryRetentionEditor()
    {
        if (Route != HistoryRetentionRoute || !ReferenceEquals(historyRetentionEditorBody, body)
            || !ReferenceEquals(historyRetentionEditorDraft, Host.Vm.HistoryRetentionDraft)) return false;
        updateHistoryRetentionEditor?.Invoke();
        return true;
    }

    void DetachHistoryRetentionEditor()
    {
        if (historyRetentionEditorDraft is { } draft && updateHistoryRetentionEditor is { } update)
            draft.Changed -= update;
        historyRetentionEditorBody = null;
        historyRetentionEditorDraft = null;
        updateHistoryRetentionEditor = null;
    }

    void HistoryRetentionPage()
    {
        DetachHistoryRetentionEditor();
        var vm = Host.Vm;
        var editorTab = vm.Page;
        var model = Model;
        var draft = vm.HistoryRetentionDraft ??= new(model.HistoryRetention);
        var inputs = new List<TextInputEditText>();
        var validators = new List<Action>();
        Action update = () => { };

        TextInputLayout Field(string section, string label, string value, Action<string> assign)
        {
            var box = new TextInputLayout(Ui) { Hint = label, HelperText = "留空表示不限" };
            var input = new TextInputEditText(Ui)
            {
                Text = value,
                InputType = InputTypes.ClassNumber,
                ContentDescription = section + "，" + label
            };
            input.SetSingleLine(true);
            box.AddView(input);
            inputs.Add(input);
            validators.Add(() => box.Error = HistoryRetentionDraft.TryLimit(input.Text ?? "", out _)
                ? null : "请输入可保存的正整数，或留空表示不限");
            input.TextChanged += (_, _) =>
            {
                assign(input.Text ?? "");
                draft.Error = null;
                update();
            };
            return box;
        }

        Add(Text("默认不限。设置仅保存在本机，适用于所有账户；各账户分别计数。修改后点击保存，返回不保存。", 13, color: Secondary));
        Add(MaterialSettingsSection("操作记录", Column(
            Field("操作记录", "最多保留条数", draft.OperationCount, value => draft.OperationCount = value),
            Field("操作记录", "最多保留天数", draft.OperationDays, value => draft.OperationDays = value))));
        Add(MaterialSettingsSection("自动签到执行记录", Column(
            Field("自动签到执行记录", "最多保留条数", draft.AutomaticCount, value => draft.AutomaticCount = value),
            Field("自动签到执行记录", "最多保留天数", draft.AutomaticDays, value => draft.AutomaticDays = value)),
            "尚未完成的执行会保留。清理只移除历史详情，防止重复签到所需的状态仍会保留。"));
        Add(Text("数量与天数可以同时设置，按先达到的限制清理。已清理的历史无法恢复。", 12, color: Secondary), 16);
        if (model.IsDemo) Add(Text("演示模式下可预览设置，退出演示模式后才能保存。", 12, color: Secondary), 16);
        var error = Text(draft.Error ?? "", 12, color: new global::Android.Graphics.Color(
            Google.Android.Material.Color.MaterialColors.GetColor(body!, Resource.Attribute.colorError)));
        Add(error, 12);
        var reset = Button("移除所有限制", () =>
        {
            foreach (var input in inputs) input.Text = "";
            return Task.CompletedTask;
        });
        var save = Button("保存", async () =>
        {
            if (draft.IsSaving || model.IsDemo || !model.CanChangeAccount || !draft.TrySettings(out var settings)) return;
            draft.IsSaving = true;
            draft.Error = null;
            draft.NotifyChanged();
            try
            {
                await model.SetHistoryRetentionAsync(settings!);
                if (ReferenceEquals(vm.HistoryRetentionDraft, draft))
                {
                    vm.HistoryRetentionDraft = null;
                    if (vm.Routes[editorTab] == HistoryRetentionRoute) vm.Routes[editorTab] = "settings";
                }
            }
            catch (Exception exception)
            {
                draft.Error = exception.Message;
            }
            finally
            {
                draft.IsSaving = false;
                draft.NotifyChanged();
            }
        }, true);
        var cancel = Button("取消", () => { Back(); return Task.CompletedTask; });
        Add(Column(save, reset, cancel), 0);
        update = () =>
        {
            if (!IsAdded) return;
            if (!ReferenceEquals(vm.HistoryRetentionDraft, draft)) { Render(); return; }
            foreach (var validate in validators) validate();
            foreach (var input in inputs) input.Enabled = !draft.IsSaving;
            save.Enabled = !draft.IsSaving && !model.IsDemo && model.CanChangeAccount && draft.TrySettings(out _);
            save.Text = draft.IsSaving ? "正在保存…" : "保存";
            reset.Enabled = cancel.Enabled = !draft.IsSaving;
            error.Text = draft.Error ?? "";
            error.Visibility = string.IsNullOrWhiteSpace(draft.Error) ? ViewStates.Gone : ViewStates.Visible;
        };
        historyRetentionEditorBody = body;
        historyRetentionEditorDraft = draft;
        updateHistoryRetentionEditor = update;
        draft.Changed += update;
        update();
    }
}
