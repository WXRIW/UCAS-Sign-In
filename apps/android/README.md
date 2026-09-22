# Android 客户端

C# / .NET 10 for Android，原生 Material 3，无 MAUI、无 WebView。最低 Android 6.0（API 23），目标 API 36。

## 工程与环境

- `UCASSignIn.Android.slnx`：包含 Android 应用、共享核心与核心测试。
- `UCASSignIn.Android/`：MainActivity、Fragment、ViewModel、Android 系统服务及资源。
- 安装 .NET SDK 10.0.100 或更新的 .NET 10 SDK、`android` 工作负载、Android SDK 36 和兼容 JDK；无需 Windows App SDK。

## 构建

### Visual Studio 安装与调试

打开 `UCASSignIn.Android.slnx`，将 `UCASSignIn.Android` 设为启动项目，选择 `Debug | Any CPU` 和已连接的 Android 真机或模拟器，然后按 F5。解决方案已启用应用项目的“部署”，VS 会构建、安装应用并附加托管调试器；共享核心与测试项目不参与部署。真机需开启 USB 调试并授权当前电脑。

Debug 配置关闭代码优化并启用程序集快速部署：首次 F5 会安装 APK，之后仅改动 C# 时，VS 可将变化的程序集直接部署到手机，避免每次重新打包、安装整个 APK。首次构建、资源或清单改动仍可能需要完整打包。Debug 仍保留托管调试运行时和调试符号；仅设置清单中的 `android:debuggable=true` 不能替代这些配置。若 VS 已打开旧配置，重新加载解决方案后再启动调试，并在“配置管理器”确认 Android 应用的“生成”和“部署”均已勾选。

快速部署要求设备允许 `run-as`；本项目最低 API 23 已满足系统版本要求。个别设备若报 XA0129、XA0133 等快速部署错误，可在 VS 的 Android 项目属性中关闭“快速部署”，或临时传入 `-p:EmbedAssembliesIntoApk=true` 构建。快速部署的 Debug APK 依赖 VS 部署的程序集，不能作为独立安装包分发；需要单独安装调试包时也使用此覆盖参数。

### 命令行

从仓库根目录运行：

```powershell
dotnet workload restore apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj
dotnet build apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj -c Debug
dotnet build apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj -c Release
```

Debug 默认支持 ARM64 真机与 x86_64 模拟器；命令行只针对 ARM64 真机构建时可加 `-r android-arm64`，减少另一架构的构建工作。Debug 与 Release 分别维护依赖锁文件，可在还原命令中加入 `--locked-mode -p:Configuration=Debug` 或 `Release` 验证。普通构建输出位于应用的 `bin/<配置>/net10.0-android/`。

## 界面与系统能力

- Material 3 原生按钮、卡片、输入框、日期选择器、开关和对话框；以 `#285C45` 为品牌种子，使用与 Apple 对齐的固定浅色 / 深色角色色板，旧系统使用同一套打包资源，不读取壁纸颜色。
- 课表支持日／周切换并记忆所选模式，提供历史学期、周次跳转和可选的非本周课程预览。
- 课程详情提供「排课信息」完整摘要，点击卡片可查看按周排列的实际课次、教室与教师；自动复用或补齐所属学期缓存，子页面只读，手动同步仍在课表页完成。
- 主导航为“今日 / 课表 / 课程 / 账户”。课程页使用原生搜索与下拉刷新，展示学校当前学期完整目录；详情页提供课程级提醒、二次确认、自动签到、禁用签到及学校考勤，本机操作记录单独分区。宽度达到 600dp 时底部导航切换为 NavigationRail。
- “账户 → 设置”统一提供外观、提醒时间、手动签到二次确认、自动签到与系统通知设置。主题默认跟随系统，也可选择浅色/深色；主题按设备保存，课堂偏好按账户及官方课程 ID 保存。
- 页面处理系统栏、显示切口、键盘、字体放大和旋转生命周期。
- Android 14 及以上为账户管理、主题选择、登录、确认弹窗和日期选择接入预测性返回：随手势缩放与位移，中途取消恢复原状；键盘优先收起，不可取消状态保持打开。关闭后的动画和回调不影响新打开的弹窗，日期选择器重建后重新绑定返回与确认事件。旧系统保留原生返回行为。
- Android Keystore 保存 AES-GCM 密钥，加密账户文件存放在应用私有目录；禁用应用备份，仅在“记住密码”开启时保存密码。
- Android 13+ 开启提醒或后台自动签到时按需请求通知权限；拒绝权限不会丢弃已保存偏好，但会提示相关通知或后台能力暂不可用。课程提醒使用普通 `AlarmManager`，不申请精确闹钟权限，省电模式可能延迟提醒。
- 后台自动签到使用带常驻状态通知的 `specialUse` 前台服务；不必保持界面在前台，完成或失败时会发送结果通知。系统省电、自启动限制、厂商后台策略或强行停止 App 仍可能使任务延迟或中断。
- 重启或应用更新后恢复当前账户仍有效的提醒，并按当前账户偏好恢复后台自动签到；点击课程提醒只打开课程，不会直接触发签到。
- 不申请定位、相机、通讯录权限。演示模式不访问学校接口。

## 真机验证

安装 Debug APK 后从欢迎页进入“先体验一下”。验证今日、日期切换、课程目录搜索、课程偏好、学校考勤演示、二维码、模拟签到、记录及外观。开发启动可附加 `--ez demo true`；该参数只切换至无学校网络请求的演示模式。

页面结构与 Apple 客户端保持一致：课程详情、签到记录、源码与致谢、免责声明为独立子页面；登录与账户管理为原生模态界面。支持下拉刷新和各主入口独立保留返回路径。
