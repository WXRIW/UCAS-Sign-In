using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media.Animation;
using QRCoder;
using UCASSignIn.Core;
using UCASSignIn.Windows.Services;
using Windows.Storage.Streams;
using Windows.System;
namespace UCASSignIn.Windows;

public sealed partial class MainWindow
{
    CancellationTokenSource? qrCancellation;
    Image? qrImage;
    TextBlock? qrCaption;
    bool updateCheckRunning;
    readonly WindowsStoreUpdater storeUpdater = new();
    async Task<ContentDialogResult> Show(ContentDialog dialog)
    {
        if (dialogOpen)
            return ContentDialogResult.None;
        qrCancellation?.Cancel();
        dialogOpen = true;
        activeDialog = dialog;
        dialog.XamlRoot = Root.XamlRoot;
        dialog.RequestedTheme = Root.RequestedTheme;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            dialogOpen = false;
            activeDialog = null;
            if (!closed && route == "detail") Render();
            DispatcherQueue.TryEnqueue(ShowPendingSignInError);
        }
    }
    async void ShowPendingSignInError()
    {
        if (closed || dialogOpen || Root.XamlRoot is null || !Model.IsForeground || Model.SignInError is not { } error) return;
        var source = Model;
        var dialog = new ContentDialog
        {
            Title = "温馨提示", Content = new TextBlock { Text = error.Message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "知道了", DefaultButton = ContentDialogButton.Close
        };
        dialog.Closed += (_, _) => { if (!closed) source.AcknowledgeSignInError(error.Id); };
        await Show(dialog);
    }
    async Task RequestManualSignAsync(Course requested)
    {
        var epoch = Model.Generation;
        var current = Model.Courses.FirstOrDefault(x => x.Id == requested.Id && x.Day == requested.Day);
        if (current is null || !Model.CanSign(current)) return;
        if (Model.EffectiveConfirmation(Model.PreferenceId(current)))
        {
            var result = await Show(new ContentDialog
            {
                Title = "确认手动签到",
                Content = new TextBlock { Text = $"{current.Name}\n{CourseTime.Date(current.Day):yyyy 年 M 月 d 日} · {current.TimeRange}", TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "确认签到", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
            });
            if (result != ContentDialogResult.Primary) return;
        }
        current = Model.Courses.FirstOrDefault(x => x.Id == requested.Id && x.Day == requested.Day);
        if (epoch == Model.Generation && current is not null && Model.CanSign(current))
            await Model.SignAsync(current, epoch);
    }
    async Task CheckForUpdates(bool manual)
    {
        if (updateCheckRunning || closed || (!manual && dialogOpen))
            return;
        var storePackage = WindowsDistribution.IsStorePackage;
        if (!storePackage && !manual && !vm.AutoCheckUpdates)
            return;
        var state = ReadUpdateState();
        if (!storePackage && !manual && state.CheckedVersion == Information.DisplayVersion
            && DateTimeOffset.TryParse(state.CheckedAt, out var lastCheck))
        {
            var elapsed = DateTimeOffset.UtcNow - lastCheck;
            if (elapsed >= TimeSpan.Zero && elapsed < TimeSpan.FromHours(24))
                return;
        }
        updateCheckRunning = true;
        try
        {
            if (storePackage)
            {
                await CheckMicrosoftStoreUpdates();
                return;
            }
            state = state with
            {
                CheckedAt = DateTimeOffset.UtcNow.ToString("O"),
                CheckedVersion = Information.DisplayVersion
            };
            SaveUpdateState(state);
            var release = await new GitHubReleaseChecker().CheckAsync(Information.DisplayVersion);
            if (closed)
                return;
            if (release is null)
            {
                if (manual)
                    await Show(new ContentDialog
                    {
                        Title = "已是最新版本",
                        Content = $"当前版本 {Information.DisplayVersion} 已是最新的正式版本。",
                        CloseButtonText = "知道了"
                    });
                return;
            }
            var releaseIdentity = $"{Information.DisplayVersion}|{release.Tag}";
            if (!manual && state.PromptedRelease == releaseIdentity)
                return;
            if (!manual && dialogOpen)
                return;
            state = state with { PromptedRelease = releaseIdentity };
            SaveUpdateState(state);
            var result = await Show(new ContentDialog
            {
                Title = "检测到新版本",
                Content = $"果壳签到 {release.Version} 已发布，当前版本为 {Information.DisplayVersion}。",
                PrimaryButtonText = "前往下载",
                CloseButtonText = "稍后",
                DefaultButton = ContentDialogButton.Primary
            });
            if (result == ContentDialogResult.Primary)
                await Launcher.LaunchUriAsync(release.Url);
        }
        catch (Exception)
        {
            if (manual)
                await Show(new ContentDialog
                {
                    Title = "暂时无法检查更新",
                    Content = "请检查网络连接后重试，或直接前往 GitHub Releases 查看。",
                    CloseButtonText = "知道了"
                });
        }
        finally { updateCheckRunning = false; }
    }
    async Task CheckMicrosoftStoreUpdates()
    {
        var update = await storeUpdater.CheckAsync();
        if (closed || !update.HasUpdate)
            return;

        switch (vm.StoreUpdates)
        {
            case StoreUpdateOption.Ask:
                WindowsStoreUpdater.ShowUpdateNotification(() => DispatcherQueue.TryEnqueue(() =>
                {
                    _ = update.TryDownloadAndInstallAsync();
                }));
                break;
            case StoreUpdateOption.Download:
                _ = update.TryDownloadAsync();
                break;
            case StoreUpdateOption.DownloadAndInstall:
                _ = update.TryDownloadAndInstallAsync();
                break;
        }
    }
    UpdateState ReadUpdateState()
    {
        try { return AtomicFile.ReadJson<UpdateState>(Path.Combine(vm.Root, "updates.json")) ?? new(); }
        catch { return new(); }
    }
    void SaveUpdateState(UpdateState state) => AtomicFile.WriteJson(Path.Combine(vm.Root, "updates.json"), state);
    sealed record UpdateState(string? CheckedAt = null, string? CheckedVersion = null, string? PromptedRelease = null);
    async Task Login(StoredAccount? account = null)
    {
        var user = new TextBox { Header = "账户", PlaceholderText = "学号或 SEP 邮箱", Text = account?.LoginUsername ?? "" };
        var password = new PasswordBox { Header = "密码", Password = account?.Credentials?.Password ?? "" };
        var remember = new ToggleSwitch { Header = "在此设备记住密码", IsOn = account?.Credentials is not null || account is null };
        var error = Text("", 12);
        error.Foreground = Brush("B14738");
        var body = Column(Text(account is null ? "使用 SEP 邮箱或轻新课堂学号登录。添加成功后将切换到这个账户。" : "验证此账户的登录信息，继续同步课程与签到状态。", 14, color: Secondary), user, password, remember, error, Text("登录信息仅发送至学校 HTTPS 服务。会话与可选密码由 Windows DPAPI 加密保存在本机。", 12, color: Secondary));
        body.Spacing = 16;
        body.Width = Math.Min(400, Math.Max(240, Root.ActualWidth - 96));
        var dialog = new ContentDialog { Title = account is null ? "连接学校账户" : "重新登录", Content = new ScrollViewer { Content = body, MaxHeight = 500, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, PrimaryButtonText = "登录并同步课程", CloseButtonText = "取消", SecondaryButtonText = account is null ? "先体验演示模式" : "", IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(user.Text) && password.Password.Length > 0 };
        user.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(user.Text) && password.Password.Length > 0;
        password.PasswordChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(user.Text) && password.Password.Length > 0;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var defer = e.GetDeferral();
            e.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            dialog.CloseButtonText = "";
            error.Text = "正在连接学校并同步课程…";
            try
            {
                await Model.LoginAsync(user.Text, password.Password, remember.IsOn, account?.Id);
                password.Password = "";
                e.Cancel = false;
            }
            catch (Exception ex) { error.Text = ex.Message; }
            finally { dialog.IsPrimaryButtonEnabled = true; dialog.IsSecondaryButtonEnabled = true; dialog.CloseButtonText = "取消"; defer.Complete(); }
        };
        if (await Show(dialog) == ContentDialogResult.Secondary)
            await Model.EnterDemoAsync();
    }
    async Task ConfirmExitDemo()
    {
        if (await Show(new()
        {
            Title = "退出演示模式？",
            Content = "退出后仍可选择本机保存的学校账户。",
            PrimaryButtonText = "退出",
            CloseButtonText = "取消"
        }) == ContentDialogResult.Primary)
            await Model.ExitDemoAsync();
    }
    async Task Remove(StoredAccount account)
    {
        if (await Show(new()
        {
            Title = "移除此账户？",
            Content = "仅清除此账户在本机的登录信息、课程缓存、签到记录和课堂偏好，其他账户会保留。",
            PrimaryButtonText = "移除",
            CloseButtonText = "取消"
        }) == ContentDialogResult.Primary)
            await Model.RemoveAsync(account.Id);
    }
    async Task ManageAccounts()
    {
        StoredAccount? selected = null;
        StoredAccount? removed = null;
        bool add = false;
        var body = Column(Text("在这台设备保存多个学校账户，点击账户即可切换。仅当前账户同步课程、签到和安排提醒。", 13, color: Secondary));
        body.Width = Math.Min(460, Math.Max(240, Root.ActualWidth - 96));
        body.Spacing = 12;
        var dialog = new ContentDialog { Title = "切换与管理账户", Content = new ScrollViewer { Content = body, MaxHeight = 500, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, CloseButtonText = "完成" };
        var hide = Button(vm.HideIdentity ? "显示账户信息" : "隐藏账户信息", () => { vm.HideIdentity = !vm.HideIdentity; vm.SaveAppearance(); dialog.Hide(); return Task.CompletedTask; });
        bool reopen = false;
        hide.Click += (_, _) => reopen = true;
        body.Children.Add(hide);
        if (Model.Accounts.Count == 0)
            body.Children.Add(Card(Column(Text("还没有保存账户", 20, true), Text("添加学校账户后，可在这里快捷切换。", 13, color: Secondary))));
        foreach (var a in Model.Accounts.OrderByDescending(a => a.Id == Model.ActiveAccount?.Id && !Model.IsDemo))
        {
            body.Children.Add(AccountCard(a, a.Id == Model.ActiveAccount?.Id && !Model.IsDemo,
                () => { selected = a; dialog.Hide(); return Task.CompletedTask; },
                () => { removed = a; dialog.Hide(); return Task.CompletedTask; }));
        }
        body.Children.Add(Button("添加账户", () => { add = true; dialog.Hide(); return Task.CompletedTask; }, true));
        body.Children.Add(Text("会话与可选密码由 Windows DPAPI 保护。移除账户只清除该账户在此设备的数据。", 11, color: Secondary));
        await Show(dialog);
        if (reopen)
        {
            await ManageAccounts();
            return;
        }
        if (add)
        {
            await Login();
            return;
        }
        if (removed is not null)
        {
            await Remove(removed);
            await ManageAccounts();
            return;
        }
        if (selected is not null)
        {
            if (selected.RequiresLogin)
                await Login(selected);
            else
                await Model.SwitchAsync(selected.Id);
        }
    }
    Border AccountCard(StoredAccount account, bool current, Func<Task> select, Func<Task> remove)
    {
        var status = account.RequiresLogin ? (current ? "当前账户 · 需要重新登录" : "需要重新登录")
            : current ? "当前账户" : "";
        var identity = Column(Text(Name(account.Session.Name), 16, true),
            Text("学号 " + Number(account.Id), 12, color: Secondary));
        if (status.Length > 0)
            identity.Children.Add(Text(status, 11, color: account.RequiresLogin ? Brush(dark ? "F0BE7B" : "986019") : Green));
        identity.Spacing = 5;
        var avatar = new PersonPicture { DisplayName = Name(account.Session.Name), Width = 40, Height = 40 };
        var indicator = new FontIcon { Glyph = current && !account.RequiresLogin ? "\uE73E" : "\uE76C", FontSize = 12, Foreground = current ? Green : Secondary };
        var choose = Plain(Across(Leading(avatar, identity), indicator), select);
        choose.Padding = new(16);
        choose.MinHeight = 88;
        choose.CornerRadius = new(7, 0, 0, 7);
        var transparent = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ButtonColors(choose, transparent, Ink, current ? Pale : Hover, current ? Brush(dark ? "3B5543" : "D5E5CF") : Pressed);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(choose, $"{Name(account.Session.Name)}，学号 {Number(account.Id)}" + (status.Length > 0 ? "，" + status : ""));

        // Keep the two actions as siblings: removing an account never invokes switching.
        var removeButton = Button("移除", remove);
        removeButton.Padding = new(10, 8, 10, 8);
        removeButton.FontSize = 12;
        ButtonColors(removeButton, transparent, Secondary, Brush(dark ? "39272B" : "FCEDEC"), Brush(dark ? "492D33" : "F8DDDB"));
        removeButton.Resources["ButtonForegroundPointerOver"] = Brush(dark ? "FF99A4" : "C42B1C");
        removeButton.Resources["ButtonForegroundPressed"] = removeButton.Resources["ButtonForegroundPointerOver"];
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(removeButton, "移除" + Name(account.Session.Name) + "的账户");
        var outline = current ? Green : Stroke;
        var removeArea = new Border { Child = removeButton, Padding = new(8, 0, 8, 0), BorderThickness = new(1, 0, 0, 0), BorderBrush = Stroke, VerticalAlignment = VerticalAlignment.Center };
        var row = Across(choose, removeArea);
        row.ColumnSpacing = 0;
        return new Border { Child = row, CornerRadius = new(8), Background = current ? Pale : Surface, BorderBrush = outline, BorderThickness = new(1) };
    }
    void QuickAccounts(object sender, object e)
    {
        var flyout = (MenuFlyout)sender;
        flyout.Items.Clear();
        foreach (var a in Model.Accounts)
        {
            var item = new MenuFlyoutItem { Text = Name(a.Session.Name) + " · " + Number(a.Id) + (a.RequiresLogin ? " · 需要重新登录" : a.Id == Model.ActiveAccount?.Id && !Model.IsDemo ? " · 当前" : "") };
            item.Click += async (_, _) => await Run(() => a.RequiresLogin ? Login(a) : Model.SwitchAsync(a.Id));
            flyout.Items.Add(item);
        }
        if (flyout.Items.Count > 0)
            flyout.Items.Add(new MenuFlyoutSeparator());
        var add = new MenuFlyoutItem { Text = "添加账户" };
        add.Click += async (_, _) => await Login();
        flyout.Items.Add(add);
        var manage = new MenuFlyoutItem { Text = "切换与管理账户" };
        manage.Click += async (_, _) => await ManageAccounts();
        flyout.Items.Add(manage);
    }
    void RenderDetail(Course course)
    {
        var title = Column(Text(course.Name, 25, true), Text($"{CourseTime.Date(course.Day):M 月 d 日} · {course.TimeRange}", 13, color: Secondary), Text(Metadata(course, true), 12, color: Secondary), Text(Model.AttendanceLabel(course), 12, color: Green));
        foreach (FrameworkElement item in title.Children)
            item.HorizontalAlignment = HorizontalAlignment.Center;
        Page.Children.Add(title);
        if (!Model.IsDemo && !Model.IsFresh(course))
            Banner(CourseTime.Date(course.Day));
        var image = new Image { Width = 224, Height = 224, HorizontalAlignment = HorizontalAlignment.Center };
        qrImage = image;
        var caption = Text("正在同步学校时间…", 12, color: Secondary);
        caption.TextAlignment = TextAlignment.Center;
        qrCaption = caption;
        var progress = QrProgress();
        var canvas = new Border { Child = image, Width = 250, Height = 250, Padding = new(13), Background = Brush("FFFFFF"), CornerRadius = new(12), HorizontalAlignment = HorizontalAlignment.Center };
        Page.Children.Add(Card(Column(canvas, progress, caption), 26));
        var removed = !Model.Courses.Any(c => c.Id == course.Id && c.Day == course.Day) && Model.IsFresh(course);
        var signText = Model.IsSignInDisabled(Model.PreferenceId(course)) ? "本课程已禁用签到" : removed ? "课程已不在最新课表中" : course.Signed ? "已完成签到" : "为本节课程签到";
        var sign = Button(signText, () => RequestManualSignAsync(course), true);
        if (!removed)
        {
            var content = Row(new FontIcon { Glyph = "\uE73E", FontSize = 16 },
                new TextBlock { Text = signText, VerticalAlignment = VerticalAlignment.Center });
            content.Spacing = 8;
            content.HorizontalAlignment = HorizontalAlignment.Center;
            sign.Content = content;
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(sign, signText);
        sign.IsEnabled = Model.CanSign(course);
        sign.HorizontalAlignment = HorizontalAlignment.Stretch;
        Page.Children.Add(sign);
        var retry = Button("重新同步二维码", () => { Render(); return Task.CompletedTask; });
        retry.Visibility = Visibility.Collapsed;
        Page.Children.Add(retry);
        Page.Children.Add(Text(Model.IsDemo ? "这里是完整的交互演示，所有操作均不会提交给学校。" : "二维码随学校时间自动刷新。签到是否成功，以学校返回结果为准。", 12, color: Secondary));
        qrCancellation = new();
        _ = RefreshQr(course, image, caption, progress, retry, Model.Generation, qrCancellation.Token);
    }
    ProgressBar QrProgress()
    {
        var progress = new ProgressBar { Minimum = 0, Maximum = 5, Value = 5, Width = 220, Height = 4,
            HorizontalAlignment = HorizontalAlignment.Center, Foreground = Green,
            Style = (Style)Application.Current.Resources["QrCountdownProgressStyle"] };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(progress, "二维码刷新倒计时");
        return progress;
    }
    Storyboard? StartQrCountdown(ProgressBar progress, double seconds)
    {
        progress.Value = Math.Clamp(seconds, progress.Minimum, progress.Maximum);
        if (seconds <= 0 || !motionSettings.AnimationsEnabled) return null;
        var animation = new DoubleAnimation
        {
            From = progress.Value, To = 0, Duration = TimeSpan.FromSeconds(seconds),
            EnableDependentAnimation = true
        };
        Storyboard.SetTarget(animation, progress);
        Storyboard.SetTargetProperty(animation, "Value");
        var countdown = new Storyboard();
        countdown.Children.Add(animation);
        countdown.Begin();
        return countdown;
    }
    async Task RefreshQr(Course course, Image image, TextBlock caption, ProgressBar progress, Button retry, Guid epoch, CancellationToken ct)
    {
        Storyboard? countdown = null;
        try
        {
            while (!ct.IsCancellationRequested && epoch == Model.Generation)
            {
                image.Source = null;
                if (!Model.IsForeground || dialogOpen)
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
                    using var stream = new InMemoryRandomAccessStream();
                    using (var writer = new DataWriter(stream))
                    {
                        writer.WriteBytes(bytes);
                        await writer.StoreAsync();
                        writer.DetachStream();
                    }
                    stream.Seek(0);
                    var bitmap = new BitmapImage();
                    await bitmap.SetSourceAsync(stream);
                    if (ct.IsCancellationRequested)
                        return;
                    image.Source = bitmap;
                    countdown = Model.IsDemo ? null : StartQrCountdown(progress, Math.Max(0, (qr.ExpiresAt - DateTimeOffset.UtcNow).TotalSeconds));
                    while (DateTimeOffset.UtcNow < qr.ExpiresAt && Model.IsForeground && !dialogOpen)
                    {
                        var seconds = Math.Max(0, (qr.ExpiresAt - DateTimeOffset.UtcNow).TotalSeconds);
                        var remainingText = Model.IsDemo ? "演示二维码 · 无签到效力" : $"{Math.Ceiling(seconds)} 秒后刷新";
                        if (caption.Text != remainingText) caption.Text = remainingText;
                        progress.Visibility = Model.IsDemo ? Visibility.Collapsed : Visibility.Visible;
                        if (countdown is null) progress.Value = seconds;
                        await Task.Delay(200, ct);
                    }
                    countdown?.Stop();
                    countdown = null;
                    progress.Value = 0;
                }
                catch (OperationCanceledException) { break; }
                catch (Exception e) { image.Source = null; caption.Text = e.Message; retry.Visibility = Visibility.Visible; break; }
            }
        }
        catch (OperationCanceledException) { }
        finally { countdown?.Stop(); image.Source = null; }
    }
    void RenderInformation()
    {
        if (route == "records")
        {
            if (Model.Records.Count == 0)
                Page.Children.Add(Card(Column(Text("还没有签到记录", 22, true), Text("在此设备完成签到后，结果会显示在这里。", 13, color: Secondary))));
            foreach (var r in Model.Records)
                Page.Children.Add(Card(Column(Across(Text(r.CourseName, 16, true), Text(r.Succeeded ? "✓" : "!", 18, color: Green)), Text(r.Message, 13, color: Secondary), Text(r.Date.ToOffset(CourseTime.ShanghaiOffset).ToString("M月d日 HH:mm:ss"), 11, color: Secondary))));
            return;
        }
        if (route == "about")
        {
            var mark = new Image
            {
                Width = 96,
                Height = 96,
                Source = new BitmapImage(new Uri("ms-appx:///Assets/BrandIcon.png")),
                HorizontalAlignment = HorizontalAlignment.Center
            };
            var name = Text("果壳签到", 28, true);
            name.HorizontalAlignment = HorizontalAlignment.Center;
            var slogan = Text("为国科大轻新课堂打造的多平台原生客户端", 14, color: Secondary);
            slogan.HorizontalAlignment = HorizontalAlignment.Center;
            slogan.TextAlignment = TextAlignment.Center;
            var version = Text("版本 " + Information.DisplayVersion, 12, true, Green);
            version.HorizontalAlignment = HorizontalAlignment.Center;
            var hero = Column(mark, name, slogan, version);
            hero.Spacing = 12;
            Page.Children.Add(hero);
            var informationCards = new StackPanel { Spacing = 12 };
            informationCards.Children.Add(Card(Column(
                Leading(new FontIcon { Glyph = "\uE9D5", FontSize = 20, Foreground = Green }, Text("功能概览", 17, true)),
                Text("支持课表查询、课程签到、动态二维码、课程提醒与多账户切换。", 14, color: Secondary))));
            informationCards.Children.Add(Card(Column(
                Leading(new FontIcon { Glyph = "\uE72E", FontSize = 20, Foreground = Green }, Text("数据与隐私", 17, true)),
                Text("• 登录请求直接发送至学校 HTTPS 服务，不经过自建服务器", 14, color: Secondary),
                Text("• 各账户的会话和密码由 Windows DPAPI 加密保存在本机", 14, color: Secondary),
                Text("• 课程缓存、签到记录与课堂偏好按账户隔离", 14, color: Secondary),
                Text("• 移除账户时仅清除该账户的数据", 14, color: Secondary),
                Text("• App 不申请定位权限", 14, color: Secondary))));
            informationCards.Children.Add(SettingsLink("项目源码与致谢", "\uE943", () => Navigate("source"),
                "源代码、开源许可与贡献者"));
            Page.Children.Add(informationCards);
            var license = Text("开源许可 · AGPL-3.0", 12, color: Secondary);
            license.HorizontalAlignment = HorizontalAlignment.Center;
            Page.Children.Add(license);
            return;
        }
        if (route == "source")
        {
            Page.Children.Add(Text("项目源码", Information.SectionTitleSize, true));
            Project("UCAS-Sign-In", "WXRIW");
            Page.Children.Add(Text("致谢", Information.SectionTitleSize, true));
            Page.Children.Add(Text("轻新课堂接口实现参考了以下项目，感谢原作者及贡献者的开源分享。", 14, color: Secondary));
            Project("UCAS-Course-Sign-in", "lccipher");
            Project("UCAS-Sign-in", "zhan-nine");
            Page.Children.Add(Text("两个参考项目均采用 GNU Affero General Public License v3.0（AGPL-3.0）。原作者及贡献者保留其相应版权。果壳签到沿用 AGPL-3.0 开源许可。", 12, color: Secondary));
            Page.Children.Add(Text("第三方组件", Information.SectionTitleSize, true));
            foreach (var component in Information.WindowsComponents)
                ComponentCard(component);
            return;
        }
        Page.Children.Add(Text("ⓘ 使用前请了解", 23, true, Green));
        foreach (var (title, text) in Information.Statements)
            Page.Children.Add(Column(Text(title, 16, true), Text(text, 13, color: Secondary)));
        Page.Children.Add(Text("更新日期：2026 年 9 月 16 日", 11, color: Secondary));
        void Project(string name, string author)
        {
            var url = "https://github.com/" + author + "/" + name;
            ComponentCard(new(name, author, url, "AGPL-3.0", url + "/blob/main/LICENSE"));
        }
        void ComponentCard(Information.Component component)
        {
            var heading = Across(Column(Text(component.Name, 17, true), Text(component.Author, 12, color: Secondary)), Text("↗", 20, color: Green));
            var badge = new Border { Child = Text(component.License, 12, true, Green), HorizontalAlignment = HorizontalAlignment.Left, Padding = new(8, 4, 8, 4), CornerRadius = new(4), Background = Pale };
            var licenseLink = Plain(Text("查看协议", 12, true, Green), async () => { await Launcher.LaunchUriAsync(new(component.LicenseUrl)); });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(licenseLink, "查看 " + component.Name + " 的 " + component.License + " 协议");
            var content = Column(
                Plain(heading, async () => { await Launcher.LaunchUriAsync(new(component.Repository)); }),
                Rule(),
                Across(badge, licenseLink));
            content.Spacing = 16;
            Page.Children.Add(Card(content));
        }
    }
}
