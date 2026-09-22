# Windows 客户端

C# / .NET 10 / WinUI 3。默认以 unpackaged、自包含程序运行；独立 Windows Application Packaging Project 提供 MSIX。最低 Windows 10 1809，支持 x64、ARM64。本文以 x64 为主要开发平台，ARM64 的对应配置见补充说明。

## 工程

- `UCASSignIn.Windows.slnx`：Windows 解决方案，包含应用、可选打包项目、共享核心与核心测试。
- `UCASSignIn.Windows/`：应用入口、ViewModels、原生界面及 DPAPI/通知服务。
- `UCASSignIn.Windows.Package/`：独立 `.wapproj`，默认不随解决方案构建，需单独选择。

不依赖 Android 工作负载。安装 .NET SDK 10.0.100 或更新的 .NET 10 SDK、Visual Studio WinUI 开发工具和 Windows SDK 10.0.26100。

## 构建与运行

在 Visual Studio 2026 中打开 `UCASSignIn.Windows.slnx`，选择 `Debug` 和 `x64` 平台，再选择 `UCASSignIn.Windows` 按 F5。ARM64 设备可将平台切换为 `ARM64`。应用使用 `Properties/launchSettings.json` 中的 `Project` 配置直接启动，无需部署 MSIX。

以下命令从仓库根目录执行，以 x64 为例。

```powershell
dotnet restore apps/windows/UCASSignIn.Windows/UCASSignIn.Windows.csproj -p:Platform=x64
dotnet build apps/windows/UCASSignIn.Windows/UCASSignIn.Windows.csproj --no-restore -p:Platform=x64
```

构建 ARM64 版本时，将上述 restore、build 命令中的 `-p:Platform=x64` 改为 `-p:Platform=ARM64`。

运行输出目录的 `UCASSignIn.Windows.exe`。`--demo` 可直接进入无网络演示模式。

## 平台行为

- 启动窗口默认在所在屏幕的工作区居中，按显示缩放调整尺寸，并避开任务栏。“今日 / 课表 / 课程 / 账户”支持窄窗口与侧栏导航；`Ctrl+1/2/3/4` 切页，`Ctrl+R` 刷新。
- 课程页展示学校当前学期的完整官方目录，支持按课程名、编号和教师搜索；课程详情可设置提醒、二次确认、自动签到及禁用签到，并将学校考勤与本机操作记录分开显示。
- 右上角按钮与 `Ctrl+R` 刷新当前内容：今日／日课表刷新对应日期，周课表刷新所查看学期，课程列表刷新目录，课程详情刷新学校考勤。
- 课表支持日／周切换并记忆所选模式，提供历史学期、周次跳转和可选的非本周课程预览。
- 课程详情提供「排课信息」完整摘要，点击卡片可查看按周排列的实际课次、教室与教师；自动复用或补齐所属学期缓存，子页面只读，手动同步仍在课表页完成。
- 页面内容通过原生 `Frame` 切换：主入口使用 WinUI 进入动画，子页面前进 / 返回使用方向相反的水平滑动。页面内的数据刷新和主题更新不重播切页动画；关闭 Windows 动画效果时自动停用过渡。
- 鼠标侧面返回键（XButton1）松开时返回上一层，兼容驱动映射的 Browser Back 键，沿用原生返回动画。弹窗 / 菜单打开期间不穿透返回，主页面没有上一层时不拦截事件。
- 二维码倒计时使用连续线性动画，进度条左端固定、右端平滑收缩；剩余秒数变化时才更新文字。离开页面或取消刷新时停止动画，关闭系统动画效果时使用静态进度更新。
- 页面采用 WinUI 原生按钮、主题卡片与紧凑排版；今日课程集中展示时间、状态与签到操作，设置使用左侧说明、右侧控件的卡片行。菜单和课程卡片提供随主题变化的轻量悬停反馈。全局快捷键不生成整页 tooltip，刷新、二维码和信息显隐按钮保留说明；窄窗口标题为导航按钮留出空间。
- 账户页按“账户与数据”和“关于”分组；底部退出 / 移除账户按钮铺满正文宽度，按钮文字居中，窄窗口保持相同布局。
- 账户管理用独立描边卡片展示每个账户，当前账户置顶并使用绿色底色与勾选标记；失效账户显示“需要重新登录”，移除按钮与切换区域分开。
- 在“账户 → 设置”统一调整系统 / 浅色 / 深色主题、提醒时间、手动签到二次确认、自动签到及打开系统通知设置；主题按设备保存，课堂偏好按账户及官方课程 ID 保存。姓名与学号隐藏设置作用于账户列表和课程页。
- 账户保存在 `%LOCALAPPDATA%/UCASSignIn/accounts.dat`，以当前 Windows 用户 DPAPI 加密。缓存与记录按账户隔离。
- 自动签到在窗口失去激活或最小化后继续运行；退出应用或设备休眠时暂停。计划通知由 Windows 发送，关闭应用不取消有效提醒。
- 便携版首次使用通知时由 Toolkit 注册当前程序路径；建议将程序放在固定目录。MSIX 使用清单中的 COM 激活注册。
- 通知点击只打开当前账户的对应课程；失效账户通知不自动切换或签到。
