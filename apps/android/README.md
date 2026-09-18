# Android 客户端

C# / .NET 10 for Android，原生 Material 3，无 MAUI、无 WebView。最低 Android 6.0（API 23），目标 API 36。

## 工程与环境

- `UCASSignIn.Android.slnx`：包含 Android 应用、共享核心与核心测试。
- `UCASSignIn.Android/`：MainActivity、Fragment、ViewModel、Android 系统服务及资源。
- 安装仓库 `global.json` 固定的 .NET SDK（当前为 10.0.400）、`android` 工作负载、Android SDK 36 和兼容 JDK；无需 Windows App SDK。

## 构建

### Visual Studio 安装与调试

打开 `UCASSignIn.Android.slnx`，将 `UCASSignIn.Android` 设为启动项目，选择 `Debug | Any CPU` 和已连接的 Android 真机或模拟器，然后按 F5。解决方案已启用应用项目的“部署”，VS 会构建、安装应用并附加托管调试器；共享核心与测试项目不参与部署。真机需开启 USB 调试并授权当前电脑。

Debug 配置关闭代码优化，使 Android SDK 启用调试运行时并将调试符号打包到 APK；仅设置清单中的 `android:debuggable=true` 不能替代这两项。APK 仍嵌入全部程序集，可单独安装。若 VS 已打开旧配置，重新加载解决方案后再启动调试，并在“配置管理器”确认 Android 应用的“生成”和“部署”均已勾选。

### 命令行

从仓库根目录运行：

```powershell
dotnet workload restore apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj
dotnet build apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj -c Debug
dotnet build apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj -c Release
```

Debug 输出包含 ARM64 与 x86_64 的开发密钥签名 APK，既可安装到真机，也可用于模拟器。Debug 与 Release 分别维护依赖锁文件，可在还原命令中加入 `--locked-mode -p:Configuration=Debug` 或 `Release` 验证。普通构建输出位于应用的 `bin/<配置>/net10.0-android/`。

## 界面与系统能力

- Material 3 原生按钮、卡片、输入框、日期选择器、开关和对话框；以 `#285C45` 为品牌种子，使用与 Apple 对齐的固定浅色 / 深色角色色板，旧系统使用同一套打包资源，不读取壁纸颜色。
- “账户 → 设置”统一提供外观、课堂偏好与系统通知设置。主题默认跟随系统，也可选择浅色/深色；主题按设备保存，课堂偏好按账户保存。宽度达到 600dp 时底部导航切换为 NavigationRail。
- 页面处理系统栏、显示切口、键盘、字体放大和旋转生命周期。
- Android 14 及以上为账户管理、主题选择、登录、确认弹窗和日期选择接入预测性返回：随手势缩放与位移，中途取消恢复原状；键盘优先收起，不可取消状态保持打开。关闭后的动画和回调不影响新打开的弹窗，日期选择器重建后重新绑定返回与确认事件。旧系统保留原生返回行为。
- Android Keystore 保存 AES-GCM 密钥，加密账户文件存放在应用私有目录；禁用应用备份，仅在“记住密码”开启时保存密码。
- Android 13+ 开启提醒时按需请求通知权限。使用普通 `AlarmManager`，不申请精确闹钟权限，省电模式可能延迟提醒。
- 重启或应用更新后恢复当前账户仍有效的提醒；点击提醒只打开课程，前台自动签到不在后台运行。
- 不申请定位、相机、通讯录权限。演示模式不访问学校接口。

## 真机验证

安装 Debug APK 后从欢迎页进入“先体验一下”。验证今日、日期切换、二维码、模拟签到、记录及外观。开发启动可附加 `--ez demo true`；该参数只切换至无学校网络请求的演示模式。

页面结构与 Apple 客户端保持一致：课程详情、签到记录、源码与致谢、免责声明为独立子页面；登录与账户管理为原生模态界面。支持下拉刷新和各主入口独立保留返回路径。
