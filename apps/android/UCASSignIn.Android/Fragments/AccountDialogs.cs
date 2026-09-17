using Android.Content.Res;
using Android.Graphics;
using Android.Views;
using Android.Widget;
using Orientation = Android.Widget.Orientation;
using Google.Android.Material.Dialog;

namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    void ManageAccounts()
    {
        if (Host.DialogOpen)
            return;

        var managing = false;
        var content = Layout(Orientation.Vertical, GravityFlags.NoGravity);
        content.SetPadding(D(24), D(24), D(24), 0);
        var scroller = new ScrollView(Ui) { FillViewport = false };
        scroller.AddView(content);
        var footer = Layout(Orientation.Vertical, GravityFlags.NoGravity);
        footer.SetPadding(D(24), D(16), D(24), D(8));
        var panel = Layout(Orientation.Vertical, GravityFlags.NoGravity);
        panel.AddView(scroller, new LinearLayout.LayoutParams(-1, -2, 1));
        panel.AddView(footer, new LinearLayout.LayoutParams(-1, -2));
        var dialog = new MaterialAlertDialogBuilder(Ui).SetView(panel)!
            .SetPositiveButton("关闭", (_, _) => { })!.Create()!;

        void Populate()
        {
            content.RemoveAllViews();
            footer.RemoveAllViews();
            var privacy = Button("", () =>
            {
                Host.Vm.HideIdentity = !Host.Vm.HideIdentity;
                Render();
                Populate();
                return Task.CompletedTask;
            });
            privacy.ContentDescription = Host.Vm.HideIdentity ? "显示账户信息" : "隐藏账户信息";
            privacy.Icon = AndroidX.AppCompat.Content.Res.AppCompatResources.GetDrawable(Ui,
                Host.Vm.HideIdentity ? Resource.Drawable.ic_eye_off : Resource.Drawable.ic_eye);
            privacy.IconSize = D(22);
            privacy.IconPadding = 0;
            privacy.IconTint = ColorStateList.ValueOf(Secondary);
            privacy.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent);
            privacy.SetPadding(D(13), 0, D(13), 0);
            var heading = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
            heading.AddView(Text(managing ? "管理账户" : "切换账户", 26, true), new LinearLayout.LayoutParams(0, -2, 1));
            heading.AddView(privacy, new LinearLayout.LayoutParams(D(48), D(48)));
            Append(heading, 4);
            Append(Text(managing ? "管理保存在这台设备上的账户。" : "选择一个账户，继续你的课堂。", 14, color: Secondary), 20);

            if (Model.IsDemo)
                Append(Card(Across(Text("正在体验演示模式", 13, true, Green),
                    Icon(Resource.Drawable.ic_leaf, 20)), 14, Pale), 16);

            var count = Text($"本机账户 · {Model.Accounts.Count}", 12, true, Secondary);
            var edit = Button(managing ? "完成管理" : "管理", () =>
            {
                managing = !managing;
                Populate();
                return Task.CompletedTask;
            });
            edit.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent);
            edit.Visibility = Model.Accounts.Count == 0 ? ViewStates.Gone : ViewStates.Visible;
            Append(Across(count, edit), 8);

            if (Model.Accounts.Count == 0)
            {
                var empty = Column(Icon(Resource.Drawable.ic_people, 40),
                    Text("你的课堂，从这里开始", 18, true),
                    Text("添加学校账户后，就能在这里快捷切换。", 13, color: Secondary));
                for (var i = 0; i < empty.ChildCount; i++)
                    if (empty.GetChildAt(i) is TextView label) label.Gravity = GravityFlags.Center;
                Append(Card(empty, 24), 20);
            }

            foreach (var account in Model.Accounts.OrderByDescending(a => !Model.IsDemo && a.Id == Model.ActiveAccount?.Id))
            {
                var current = !Model.IsDemo && account.Id == Model.ActiveAccount?.Id;
                var error = new Color(Google.Android.Material.Color.MaterialColors.GetColor(Ui, Resource.Attribute.colorError, "account status"));
                var status = account.RequiresLogin
                    ? (current ? "当前账户 · 需要重新登录" : "需要重新登录")
                    : current ? "当前使用" : managing ? "已保存" : "";
                var identity = Column(Text(Name(account.Session.Name), 17, true),
                    Text("学号 " + Number(account.Id), 12, color: Secondary));
                if (status.Length > 0)
                    identity.AddView(Text(status, 12, color: account.RequiresLogin ? error : current ? Green : Secondary));
                for (var i = 0; i < identity.ChildCount - 1; i++)
                    ((LinearLayout.LayoutParams)identity.GetChildAt(i)!.LayoutParameters!).BottomMargin = D(4);
                var row = Layout(Orientation.Horizontal, GravityFlags.CenterVertical);
                row.AddView(Icon(Resource.Drawable.ic_person_circle, 36, current ? Green : Secondary),
                    new LinearLayout.LayoutParams(D(36), D(36)) { MarginEnd = D(12) });
                row.AddView(identity, new LinearLayout.LayoutParams(0, -2, 1));
                var card = Card(row, 16, current ? Pale : Surface);
                card.Radius = D(20);
                if (current)
                {
                    card.StrokeWidth = D(1);
                    card.SetStrokeColor(ColorStateList.ValueOf(Green));
                }

                if (managing)
                {
                    var remove = Button("移除", () =>
                    {
                        DismissThen(dialog, () => { ConfirmRemove(account); return Task.CompletedTask; });
                        return Task.CompletedTask;
                    });
                    remove.ContentDescription = "移除账户 " + Name(account.Session.Name) + " " + Number(account.Id);
                    remove.SetTextColor(error);
                    remove.BackgroundTintList = ColorStateList.ValueOf(Color.Transparent);
                    row.AddView(remove, new LinearLayout.LayoutParams(-2, -2) { MarginStart = D(4) });
                }
                else
                {
                    row.AddView(Icon(current && !account.RequiresLogin ? Resource.Drawable.ic_check_circle : Resource.Drawable.ic_chevron_right,
                        22, current ? Green : Secondary), new LinearLayout.LayoutParams(D(22), D(22)) { MarginStart = D(12) });
                    Tap(card, () =>
                    {
                        if (Model.CanChangeAccount)
                            DismissThen(dialog, async () =>
                            {
                                if (account.RequiresLogin && current) Login(account);
                                else await Model.SwitchAsync(account.Id);
                            });
                        return Task.CompletedTask;
                    }, Name(account.Session.Name) + "，学号 " + Number(account.Id) + (status.Length > 0 ? "，" + status : ""));
                }
                Append(card, 10);
            }

            var add = Button("添加账户", () =>
            {
                DismissThen(dialog, () => { Login(); return Task.CompletedTask; });
                return Task.CompletedTask;
            }, true);
            footer.AddView(add, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(14) });
            footer.AddView(Text(managing ? "移除仅清除此账户在本机的数据，其他账户不受影响。"
                : "仅当前账户同步课程与提醒。账户信息安全保存在本机。", 12, color: Secondary),
                new LinearLayout.LayoutParams(-1, -2));
        }

        void Append(View view, int bottom) => content.AddView(view,
            new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(bottom) });

        Populate();
        Track(dialog);
        // Keep comfortable side margins on phones and a readable width on tablets.
        dialog.Window?.SetLayout(Math.Min(Resources!.DisplayMetrics!.WidthPixels, D(488)), -2);
    }
}
