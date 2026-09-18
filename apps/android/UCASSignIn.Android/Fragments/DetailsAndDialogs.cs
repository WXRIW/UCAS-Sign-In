using Android.Content;
using Android.OS;
using Android.Views;
using Android.Widget;
using Android.Graphics;
using Google.Android.Material.Dialog;
using Google.Android.Material.TextField;
using Google.Android.Material.MaterialSwitch;
using UCASSignIn.Core;
using QRCoder;
using OperationCanceledException = System.OperationCanceledException;
namespace UCASSignIn.Android.Fragments;

public sealed partial class MainPageFragment
{
    const string UpdatePreferences = "updates";
    bool updateCheckRunning;
    void Track(global::AndroidX.AppCompat.App.AlertDialog dialog, Func<bool>? canCancel = null)
    {
        qrCancellation?.Cancel();
        Host.ActiveDialog = dialog;
        dialog.DismissEvent += (_, _) =>
        {
            if (!IsAdded || Host.IsChangingConfigurations || Host.IsFinishing || Host.IsDestroyed) return;
            // Dismiss notifications are queued; a new dialog may already be visible.
            if (Host.ActiveDialog != dialog) return;
            Host.ActiveDialog = null;
            if (Route == "detail") Render();
            // A failure can arrive while another native dialog is open.
            Host.Window?.DecorView?.Post(ShowPendingSignInError);
        };
        dialog.Show();
        if (OperatingSystem.IsAndroidVersionAtLeast(34))
            PredictiveDialogBack.Attach(dialog, canCancel ?? (() => true));
    }
    public void ShowPendingSignInError()
    {
        if (!IsAdded || Host.DialogOpen || Host.IsFinishing || Host.IsDestroyed || !Model.IsForeground
            || Model.SignInError is not { } error) return;
        var source = Model;
        var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle("温馨提示")!
            .SetMessage(error.Message)!
            .SetPositiveButton("知道了", (_, _) => source.AcknowledgeSignInError(error.Id))!
            .SetCancelable(false)!.Create()!;
        Track(dialog, () => false);
    }
    public async Task CheckForUpdates(bool manual)
    {
        if (updateCheckRunning || !IsAdded || Host.IsFinishing || Host.IsDestroyed || (!manual && Host.DialogOpen))
            return;
        if (!manual && !Host.Vm.AutoCheckUpdates)
            return;
        var preferences = Ui.GetSharedPreferences(UpdatePreferences, FileCreationMode.Private)!;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var elapsed = now - preferences.GetLong("checkedAt", 0);
        if (!manual && preferences.GetString("checkedVersion", "") == Information.DisplayVersion
            && elapsed >= 0 && elapsed < TimeSpan.FromHours(24).TotalMilliseconds)
            return;
        updateCheckRunning = true;
        preferences.Edit()!
            .PutLong("checkedAt", now)!
            .PutString("checkedVersion", Information.DisplayVersion)!
            .Apply();
        try
        {
            var release = await new GitHubReleaseChecker().CheckAsync(Information.DisplayVersion);
            if (!IsAdded || Host.IsFinishing || Host.IsDestroyed)
                return;
            if (release is null)
            {
                if (manual)
                    Track(new MaterialAlertDialogBuilder(Ui).SetTitle("已是最新版本")!
                        .SetMessage($"当前版本 {Information.DisplayVersion} 已是最新的正式版本。")!
                        .SetPositiveButton("知道了", (_, _) => { })!.Create()!);
                return;
            }
            var releaseIdentity = $"{Information.DisplayVersion}|{release.Tag}";
            if (!manual && preferences.GetString("promptedRelease", "") == releaseIdentity)
                return;
            if (!manual && Host.DialogOpen)
                return;
            preferences.Edit()!.PutString("promptedRelease", releaseIdentity)!.Apply();
            var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle("检测到新版本")!
                .SetMessage($"果壳签到 {release.Version} 已发布，当前版本为 {Information.DisplayVersion}。")!
                .SetNegativeButton("稍后", (_, _) => { })!
                .SetPositiveButton("前往下载", (_, _) => Open(release.Url.ToString()))!
                .Create()!;
            Track(dialog);
        }
        catch (Exception)
        {
            if (manual && IsAdded && !Host.IsFinishing && !Host.IsDestroyed)
                Track(new MaterialAlertDialogBuilder(Ui).SetTitle("暂时无法检查更新")!
                    .SetMessage("请检查网络连接后重试，或直接前往 GitHub Releases 查看。")!
                    .SetPositiveButton("知道了", (_, _) => { })!.Create()!);
        }
        finally { updateCheckRunning = false; }
    }
    void DismissThen(global::AndroidX.AppCompat.App.AlertDialog dialog, Func<Task> next)
    {
        var epoch = Model.Generation;
        dialog.DismissEvent += (_, _) =>
        {
            if (!IsAdded) return;
            var activity = Host;
            activity.Window?.DecorView?.Post(async () =>
            {
                if (IsAdded && epoch == Model.Generation)
                    await activity.Run(next);
            });
        };
        dialog.Dismiss();
    }
    void Appearance()
    {
        var selected = Host.Vm.Theme == "light" ? 1 : Host.Vm.Theme == "dark" ? 2 : 0;
        var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle("外观")!.SetSingleChoiceItems(new[] { "跟随系统", "浅色", "深色" }, selected, (_, e) =>
        {
            if (Host.ActiveDialog is { } current)
                DismissThen(current, () => { Host.SetAppearance(new[] { "system", "light", "dark" }[e.Which]); return Task.CompletedTask; });
        })!.SetNegativeButton("取消", (_, _) => { })!.Create()!;
        Track(dialog);
    }
    void Login(StoredAccount? account = null)
    {
        if (Host.DialogOpen)
            return;
        var logo = Icon(Resource.Drawable.ic_leaf_filled, 34);
        var userBox = new TextInputLayout(Ui) { Hint = "账户", HelperText = "SEP 邮箱或轻新课堂学号" };
        var username = new TextInputEditText(Ui) { Text = account?.LoginUsername ?? "", InputType = global::Android.Text.InputTypes.ClassText | global::Android.Text.InputTypes.TextVariationEmailAddress };
        userBox.AddView(username);
        var passwordBox = new TextInputLayout(Ui) { Hint = "密码", EndIconMode = TextInputLayout.EndIconPasswordToggle };
        var password = new TextInputEditText(Ui) { Text = account?.Credentials?.Password ?? "", InputType = global::Android.Text.InputTypes.ClassText | global::Android.Text.InputTypes.TextVariationPassword };
        passwordBox.AddView(password);
        var remember = new MaterialSwitch(Ui) { Text = "在此设备记住密码", Checked = account is null || account.Credentials is not null };
        var error = Text("", 12, color: C("B14738"));
        var logoFrame = new FrameLayout(Ui);
        logoFrame.AddView(logo, new FrameLayout.LayoutParams(D(34), D(34), GravityFlags.Center));
        var logoTile = Card(logoFrame, 20, Pale);
        logoTile.Radius = D(23);
        var logoRow = Layout(global::Android.Widget.Orientation.Horizontal, GravityFlags.Left);
        logoRow.AddView(logoTile, new LinearLayout.LayoutParams(D(74), D(74)) { BottomMargin = D(16) });
        var content = Column(logoRow, Text(account is null ? "连接你的课堂。" : "重新连接课堂。", 30, true), Text(account is null ? "使用 SEP 邮箱或轻新课堂学号登录，\n添加成功后将切换到这个账户。" : "验证此账户的登录信息，\n继续同步课程与签到状态。", 14, color: Secondary), userBox, passwordBox, remember, error);
        content.SetPadding(D(24), D(16), D(24), D(24));
        var scroller = new ScrollView(Ui);
        scroller.AddView(content);
        var dialog = new MaterialAlertDialogBuilder(Ui).SetView(scroller)!.SetNegativeButton("取消", (_, _) => { })!.Create()!;
        Google.Android.Material.Button.MaterialButton? login = null;
        bool submitting = false;
        login = Button("登录并同步课程", async () =>
        {
            if (submitting)
                return;
            submitting = true;
            login!.Enabled = false;
            dialog.SetCancelable(false);
            dialog.GetButton((int)DialogButtonType.Negative)!.Enabled = false;
            username.Enabled = false;
            password.Enabled = false;
            remember.Enabled = false;
            error.Text = "正在连接学校并同步课程…";
            try
            {
                await Model.LoginAsync(username.Text ?? "", password.Text ?? "", remember.Checked, account?.Id);
                password.Text = "";
                dialog.Dismiss();
            }
            catch (Exception ex) { error.Text = ex.Message; }
            finally { submitting = false; login!.Enabled = true; dialog.SetCancelable(true); dialog.GetButton((int)DialogButtonType.Negative)!.Enabled = true; username.Enabled = true; password.Enabled = true; remember.Enabled = true; }
        }, true);
        content.AddView(login, new LinearLayout.LayoutParams(-1, -2) { BottomMargin = D(18) });
        content.AddView(Text("登录信息仅发送至学校 HTTPS 服务。会话与可选密码由 Android Keystore 保护并保存在本机。", 11, color: Secondary));
        if (account is null)
            content.AddView(Button("先体验演示模式", async () => { if (submitting) return; dialog.Dismiss(); await Model.EnterDemoAsync(); }));
        void Validate() => login.Enabled = !string.IsNullOrWhiteSpace(username.Text) && !string.IsNullOrEmpty(password.Text) && !Model.IsBusy;
        username.TextChanged += (_, _) => Validate();
        password.TextChanged += (_, _) => Validate();
        Validate();
        Track(dialog, () => !submitting);
    }
    void ConfirmRemove(StoredAccount? account)
    {
        var demo = account is null;
        var dialog = new MaterialAlertDialogBuilder(Ui).SetTitle(demo ? "退出演示模式？" : "移除此账户？")!.SetMessage(demo ? "退出后仍可选择本机保存的学校账户。" : "仅清除此账户在本机的登录信息、课程缓存、签到记录和课堂偏好，其他账户会保留。")!.SetNegativeButton("取消", (_, _) => { })!.SetPositiveButton(demo ? "退出" : "移除", async (_, _) => await Host.Run(() => demo ? Model.ExitDemoAsync() : Model.RemoveAsync(account!.Id)))!.Create()!;
        Track(dialog);
    }
    public void QuickAccounts()
    {
        var accounts = Model.Accounts.ToArray();
        var labels = accounts.Select(a => Name(a.Session.Name) + " · " + Number(a.Id) + (a.RequiresLogin ? " · 需要重新登录" : a.Id == Model.ActiveAccount?.Id && !Model.IsDemo ? " · 当前" : "")).Concat(new[] { "添加账户", "切换与管理账户" }).ToArray();
        var menu = new global::AndroidX.AppCompat.Widget.PopupMenu(Ui, Host.AccountMenuAnchor, (int)GravityFlags.End);
        for (var index = 0; index < labels.Length; index++) menu.Menu.Add(0, index, index, labels[index]);
        menu.MenuItemClick += async (_, e) =>
        {
            var index = e.Item!.ItemId;
            if (index == accounts.Length) Login();
            else if (index == accounts.Length + 1) ManageAccounts();
            else
            {
                var account = accounts[index];
                if (account.RequiresLogin && account.Id == Model.ActiveAccount?.Id && !Model.IsDemo) Login(account);
                else await Host.Run(() => Model.SwitchAsync(account.Id));
            }
        };
        menu.Show();
    }
    void RenderDetail(Course course)
    {
        var header = Column(Text(course.Name, 25, true), Text($"{CourseTime.Date(course.Day):M 月 d 日} · {course.TimeRange}", 13, color: Secondary), Text(Metadata(course, true), 12, color: Secondary), Text(course.Signed ? "✓ 已签到" : "未签到", 12, color: Green));
        for (int i = 0; i < header.ChildCount; i++)
            ((TextView)header.GetChildAt(i)!).Gravity = GravityFlags.Center;
        Add(header);
        if (!Model.IsDemo && !Model.IsFresh(course))
            Banner(CourseTime.Date(course.Day));
        var image = new ImageView(Ui) { ContentDescription = "课程签到二维码" };
        image.SetBackgroundColor(Color.White);
        image.SetPadding(D(13), D(13), D(13), D(13));
        image.SetScaleType(ImageView.ScaleType.FitCenter);
        var canvas = Layout(Orientation.Vertical, GravityFlags.CenterHorizontal);
        var qrSize = TwoColumns ? 180 : 250;
        canvas.AddView(image, new LinearLayout.LayoutParams(D(qrSize), D(qrSize)));
        var progress = new Google.Android.Material.ProgressIndicator.LinearProgressIndicator(Ui)
        {
            Max = 5000, Progress = 5000, Indeterminate = false,
            TrackStopIndicatorSize = 0, IndicatorTrackGapSize = D(4),
            TrackThickness = D(4), TrackCornerRadius = D(2), TrackColor = Pale
        };
        progress.SetIndicatorColor(Green);
        canvas.AddView(progress, new LinearLayout.LayoutParams(D(qrSize - 30), D(4)) { TopMargin = D(TwoColumns ? 12 : 18), BottomMargin = D(12) });
        var caption = Text("正在同步学校时间…", 12, color: Secondary);
        caption.Gravity = GravityFlags.Center;
        canvas.AddView(caption);
        var qrCard = Card(canvas, TwoColumns ? 16 : 24);
        if (!TwoColumns) Add(qrCard);
        var removed = !Model.Courses.Any(c => c.Id == course.Id && c.Day == course.Day) && Model.IsFresh(course);
        var sign = Button(removed ? "课程已不在最新课表中" : course.Signed ? "✓ 已完成签到" : "✓ 为本节课程签到", () => Model.SignAsync(course, Model.Generation), true);
        sign.Enabled = Model.CanSign(course);
        var disabledInk = Color.Argb(97, Ink.R, Ink.G, Ink.B);
        sign.BackgroundTintList = EnabledColors(C("285C45"), Color.Argb(31, Ink.R, Ink.G, Ink.B));
        sign.SetTextColor(EnabledColors(Color.White, disabledInk));
        Add(sign, 12);
        CourseNotice(CourseTime.Date(course.Day));
        var retry = Button("重新同步二维码", () => { Render(); return Task.CompletedTask; });
        retry.Visibility = ViewStates.Gone;
        Add(retry, 16);
        Add(Text(Model.IsDemo ? "这里是完整的交互演示，所有操作均不会提交给学校。" : "二维码随学校时间自动刷新。签到是否成功，以学校返回结果为准。", 12, color: Secondary));
        if (TwoColumns)
        {
            var qrIndex = body!.ChildCount;
            Add(qrCard, 0);
            ArrangeColumns(i => i < qrIndex, .5f);
        }
        qrCancellation = new();
        _ = RefreshQr(course, image, caption, progress, retry, Model.Generation, qrCancellation.Token);
    }
    async Task RefreshQr(Course course, ImageView image, TextView caption, Google.Android.Material.ProgressIndicator.LinearProgressIndicator progress, Google.Android.Material.Button.MaterialButton retry, Guid epoch, CancellationToken ct)
    {
        Bitmap? bitmap = null;
        try
        {
            while (!ct.IsCancellationRequested && epoch == Model.Generation)
            {
                image.SetImageDrawable(null);
                progress.Visibility = ViewStates.Invisible;
                progress.Progress = 0;
                bitmap?.Dispose();
                bitmap = null;
                if (!Model.IsForeground || Host.DialogOpen)
                {
                    await Task.Delay(200, ct);
                    continue;
                }
                try
                {
                    var qr = await Model.QrAsync(course, ct);
                    if (ct.IsCancellationRequested || epoch != Model.Generation)
                        return;
                    using var generator = new QRCodeGenerator();
                    using var data = generator.CreateQrCode(qr.Url, QRCodeGenerator.ECCLevel.M);
                    using var code = new PngByteQRCode(data);
                    var bytes = code.GetGraphic(8);
                    bitmap = BitmapFactory.DecodeByteArray(bytes, 0, bytes.Length);
                    image.SetImageBitmap(bitmap);
                    progress.Max = Math.Max(1, (int)qr.ValidityDuration.TotalMilliseconds);
                    var demo = Model.IsDemo;
                    progress.Visibility = demo ? ViewStates.Invisible : ViewStates.Visible;
                    if (demo) caption.Text = "演示二维码 · 无签到效力";
                    using var animation = new QrCountdownAnimation(progress, qr.ExpiresAt,
                        () => !ct.IsCancellationRequested && epoch == Model.Generation && Model.IsForeground && !Host.DialogOpen,
                        seconds => caption.Text = $"学校时间已同步 · {seconds} 秒后刷新");
                    if (!demo) animation.Start();
                    while (DateTimeOffset.UtcNow < qr.ExpiresAt && Model.IsForeground && !Host.DialogOpen)
                    {
                        var ms = Math.Max(0, (qr.ExpiresAt - DateTimeOffset.UtcNow).TotalMilliseconds);
                        await Task.Delay(TimeSpan.FromMilliseconds(Math.Max(1, Math.Min(200, ms))), ct);
                    }
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex) { image.SetImageDrawable(null); caption.Text = ex.Message; retry.Visibility = ViewStates.Visible; break; }
            }
        }
        catch (OperationCanceledException) { }
        finally { progress.Visibility = ViewStates.Invisible; image.SetImageDrawable(null); bitmap?.Dispose(); }
    }
    void InformationPage()
    {
        if (Route == "records")
        {
            if (Model.Records.Count == 0)
                Add(Card(Column(Text("还没有签到记录", 22, true), Text("在此设备完成签到后，结果会显示在这里。", 13, color: Secondary))));
            foreach (var r in Model.Records)
                Add(Card(Column(Across(Text(r.CourseName, 16, true), Text(r.Succeeded ? "✓" : "!", 18, color: Green)), Text(r.Message, 13, color: Secondary), Text(r.Date.ToOffset(CourseTime.ShanghaiOffset).ToString("M月d日 HH:mm:ss"), 11, color: Secondary))));
            return;
        }
        if (Route == "about")
        {
            var mark = new ImageView(Ui);
            mark.SetImageResource(Resource.Drawable.app_icon);
            mark.SetScaleType(ImageView.ScaleType.CenterInside);
            mark.LayoutParameters = new LinearLayout.LayoutParams(D(104), D(104));
            var appName = Text("果壳签到", 28, true);
            appName.Gravity = GravityFlags.Center;
            var positioning = Text("为国科大轻新课堂打造的多平台原生客户端", 14, color: Secondary);
            positioning.Gravity = GravityFlags.Center;
            var version = LicenseBadge("版本 " + Information.DisplayVersion);
            var versionRow = new FrameLayout(Ui);
            versionRow.AddView(version, new FrameLayout.LayoutParams(-2, -2, GravityFlags.Center));
            var hero = Column(mark, appName, positioning, versionRow);
            hero.SetGravity(GravityFlags.CenterHorizontal);
            Add(hero, 28);
            Add(Card(Column(
                IconLabel(Resource.Drawable.ic_check_circle, "功能概览", 17),
                Text("支持课表查询、课程签到、动态二维码、课程提醒与多账户切换。", 14, color: Secondary))), 20);
            Add(Card(Column(
                IconLabel(Resource.Drawable.ic_document, "数据与隐私", 17),
                Text("• 登录请求直接发送至学校 HTTPS 服务，不经过自建服务器", 14, color: Secondary),
                Text("• 各账户的会话和密码由 Android Keystore 保护", 14, color: Secondary),
                Text("• 课程缓存、签到记录与课堂偏好按账户保存在本机", 14, color: Secondary),
                Text("• 移除账户时仅清除该账户的数据", 14, color: Secondary),
                Text("• App 不申请定位权限", 14, color: Secondary))), 20);
            var source = Tap(Across(
                SettingLabel(Resource.Drawable.ic_code, "项目源码与致谢", "源代码、开源许可与贡献者"),
                Icon(Resource.Drawable.ic_chevron_right, 11, Secondary)),
                () => Navigate("source"), "项目源码与致谢");
            source.SetPadding(0, D(8), 0, D(8));
            Add(Card(source), 20);
            var license = Text("开源许可 · AGPL-3.0", 11, color: Secondary);
            license.Gravity = GravityFlags.Center;
            Add(license, 0);
            return;
        }
        if (Route == "source")
        {
            Add(Text("项目源码", Information.SectionTitleSize, true));
            Project("UCAS-Sign-In", "WXRIW");
            Add(Text("致谢", Information.SectionTitleSize, true));
            Add(Text("轻新课堂接口实现参考了以下项目，感谢原作者及贡献者的开源分享。", 14, color: Secondary));
            Project("UCAS-Course-Sign-in", "lccipher");
            Project("UCAS-Sign-in", "zhan-nine");
            Add(Text("两个参考项目均采用 GNU Affero General Public License v3.0（AGPL-3.0）。原作者及贡献者保留其相应版权。果壳签到沿用 AGPL-3.0 开源许可。", 12, color: Secondary));
            Add(Text("第三方组件", Information.SectionTitleSize, true));
            foreach (var component in Information.AndroidComponents)
                ComponentCard(component);
            return;
        }
        Add(Text("ⓘ 使用前请了解", 23, true, color: Green));
        foreach (var (title, text) in Information.Statements)
            Add(Column(Text(title, 16, true), Text(text, 13, color: Secondary)));
        Add(Text("更新日期：2026 年 9 月 16 日", 11, color: Secondary));
        void Project(string name, string author)
        {
            var url = "https://github.com/" + author + "/" + name;
            ComponentCard(new(name, author, url, "AGPL-3.0", url + "/blob/main/LICENSE"));
        }
        void ComponentCard(Information.Component component)
        {
            var license = new FrameLayout(Ui);
            license.AddView(LicenseBadge(component.License), new FrameLayout.LayoutParams(-2, -2) { Gravity = GravityFlags.Start });
            var content = Column(
                Tap(Across(Column(Text(component.Name, 17, true), Text(component.Author, 12, color: Secondary)), Icon(Resource.Drawable.ic_arrow_up_right, 18, Green)), () => Open(component.Repository), "打开 " + component.Name),
                Rule(),
                Across(license, Tap(Text("查看协议", 12, true, Green), () => Open(component.LicenseUrl), "查看 " + component.Name + " 的 " + component.License + " 协议")));
            Add(Card(content, 20), 20);
        }
    }
    Task Open(string url)
    {
        Host.StartActivity(new Intent(Intent.ActionView, global::Android.Net.Uri.Parse(url)));
        return Task.CompletedTask;
    }
}
