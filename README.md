<p align="center">
  <img src="UCASSignInMac/Resources/MacAssets.xcassets/MacAppIcon.appiconset/icon_512x512@2x.png" width="128" height="128" alt="果壳签到应用图标">
</p>

<h1 align="center">果壳签到</h1>

<p align="center">面向国科大轻新课堂的 iOS、iPadOS 与 macOS 客户端，支持课表查询、课程签到、动态二维码、课程提醒与桌面小组件。</p>

## 功能概览

- **账号登录**：支持 SEP 邮箱或轻新课堂学号，可选择记住密码。
- **多账户切换**：在本机保存多个学校账户，从今日页、Mac 侧栏或账户管理页快速切换。
- **课程查询**：查看今日安排，按日期和周次浏览课表，展示学校提供的上课教室，支持本地缓存。
- **课程签到**：手动签到、前台自动签到，以及与学校时间同步的动态二维码。
- **课程提醒**：为已同步课程设置开课前 10 分钟的本地通知。
- **桌面小组件**：小号、中号课程卡片，展示今日课程与签到状态。
- **账户隐私**：一键将姓名脱敏、隐藏学号，隐藏状态在本机保存。
- **演示模式**：无需账号即可体验课表和模拟签到，支持浅色、深色外观。

## 运行截图

截图使用演示账号与示例课程。

### iOS

<table>
  <tr>
    <th>今日课程</th>
    <th>日期课表</th>
    <th>账户信息</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ios/today.png" width="250" alt="iPhone 今日课程"></td>
    <td><img src="docs/screenshots/ios/schedule.png" width="250" alt="iPhone 日期课表"></td>
    <td><img src="docs/screenshots/ios/profile.png" width="250" alt="iPhone 账户与隐私开关"></td>
  </tr>
</table>

<details>
<summary>更多 iOS 界面</summary>

<table>
  <tr>
    <th>深色外观</th>
    <th>登录</th>
    <th>课程二维码</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ios/today-dark.png" width="250" alt="iOS 深色今日课程"></td>
    <td><img src="docs/screenshots/ios/login.png" width="250" alt="iOS 登录页面"></td>
    <td><img src="docs/screenshots/ios/qrcode.png" width="250" alt="iOS 演示课程二维码"></td>
  </tr>
  <tr>
    <th>本机签到记录</th>
    <th>开源声明</th>
    <th>免责声明</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ios/records.png" width="250" alt="iOS 演示签到记录"></td>
    <td><img src="docs/screenshots/ios/open-source.png" width="250" alt="iOS 开源项目与协议"></td>
    <td><img src="docs/screenshots/ios/disclaimer.png" width="250" alt="iOS 免责声明"></td>
  </tr>
</table>

</details>

### iPadOS

<table>
  <tr>
    <th>今日课程</th>
    <th>日期课表</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ipados/today.png" width="400" alt="iPad 横屏今日课程"></td>
    <td><img src="docs/screenshots/ipados/schedule.png" width="400" alt="iPad 横屏日期课表"></td>
  </tr>
</table>

<details>
<summary>更多 iPadOS 界面</summary>

<table>
  <tr>
    <th>账户信息</th>
    <th>课程二维码</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ipados/profile.png" width="400" alt="iPadOS 账户与隐私开关"></td>
    <td><img src="docs/screenshots/ipados/qrcode.png" width="400" alt="iPadOS 演示课程二维码"></td>
  </tr>
  <tr>
    <th colspan="2">深色外观</th>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/screenshots/ipados/today-dark.png" width="820" alt="iPadOS 深色今日课程"></td>
  </tr>
</table>

</details>

### macOS

<img src="docs/screenshots/macos/today.png" width="820" alt="Mac 原生侧边栏与今日课程">

<details>
<summary>更多 macOS 界面</summary>

<table>
  <tr>
    <th>日期课表</th>
    <th>账户信息</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/macos/schedule.png" width="400" alt="Mac 日期课表"></td>
    <td><img src="docs/screenshots/macos/profile.png" width="400" alt="Mac 账户与课堂偏好"></td>
  </tr>
</table>

</details>

## 使用说明

支持 **iOS 16+、iPadOS 16+ 和 macOS 14+**。

### 登录与课程签到

1. 打开 App，点击「连接学校账号」，输入 **SEP 邮箱与 SEP 密码**，或 **轻新课堂学号与对应密码**，点击「登录并同步课程」。
2. 在「今日」查看当天安排，或进入「课表」选择日期、查看课程。
3. 在首页点击「一键签到」，或打开课程详情查看动态二维码、点击「为本节课程签到」。签到结果以学校返回状态为准。
4. 在「账户 → 本机签到记录」查看当前账号在本机的操作结果。

欢迎页点击「先体验一下」可进入演示模式。演示模式不向学校提交签到，二维码无签到效力。

教室信息来自学校课表；未提供时，课程详情显示「教室暂未提供」。

iPhone / iPad 下拉刷新课程；Mac 点击刷新按钮或按 `⌘R`。课表页刷新所选日期，切换页面不会重置日期。

缓存课表需同步成功后才能签到。网络恢复后可点击「重新同步」，App 回到前台或保持前台时也会自动重试。

在「账户」页点击姓名右侧的眼睛图标，可隐藏或显示姓名、学号。

### 添加、切换与移除账户

在「账户 → 切换与管理账户」点击「添加账户」并登录，成功后会切换到新账户。也可使用今日页的账户按钮或 Mac 侧栏底部的账户菜单，直接选择已保存的账户。使用邮箱或学号再次登录同一个学校账户，会更新已有账户。

每个账户分别保存登录会话、课程缓存、签到记录和课堂偏好。切换时先显示目标账户的本机缓存，再同步课程；课程详情和二维码会关闭，课表日期回到今天。重新打开 App 会恢复上次选中的账户。登录、恢复会话或提交签到期间，暂时不能切换或移除账户。

不勾选「在此设备记住密码」也会保存登录会话，因此会话有效时可直接切换。会话失效后，已记住密码的账户会尝试自动恢复；未记住密码或恢复失败时，会提示重新验证该账户。自动恢复只重试课程查询，不会重复提交签到。

账户管理页可单独移除账户；「账户」页的「退出并移除此账户」仅清除当前账户。其他账户继续保留。移除当前账户后需自行选择另一个账户，不会自动代选。

升级后，原有单账户登录、课程缓存、签到记录和课堂偏好会自动保留。演示模式使用示例数据，不添加或覆盖真实账户。

### 自动签到与课程提醒

在「账户 → 课堂偏好」开启「前台自动签到」或「课程提醒」。课程提醒需要允许通知权限，针对已同步课程在开课前 10 分钟发送。

两个开关按账户保存，新添加账户默认关闭。**只有当前账户运行自动签到和课程提醒**；切换会清除原账户的待发送提醒，并按目标账户的偏好和已同步课程重新安排。

**自动签到仅在 App 前台活跃时运行。** 切换到其他 App、关闭 Mac 窗口或设备睡眠后会暂停。课程提醒不会触发签到。

### 桌面小组件

登录并同步今日课程后，从系统的小组件列表添加「果壳签到 · 今日课程」，选择小号或中号卡片。

小组件始终展示当前账户的今日课程，切换账户时同步更新，不会独立联网或执行签到。数据未更新时，打开主 App 刷新课程；演示模式不提供小组件数据。

### Mac 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘1` / `⌘2` / `⌘3` | 切换今日 / 课表 / 账户 |
| `⌘R` | 刷新课表所选日期；其他页面刷新今日课程 |
| `⌘,` | 打开账户与偏好设置 |
| `⌘⇧L` | 添加学校账户 |

## 本地构建

### 环境要求

- macOS、Xcode 16 或更新版本。
- 核心逻辑可通过 Swift Package 单独测试，需要 Swift 5.9+、macOS 13+。

### iPhone / iPad 模拟器

1. 下载或克隆源码，使用 Xcode 打开 `UCASSignIn.xcodeproj`。
2. 选择 `UCASSignIn` scheme 和一个 iPhone 或 iPad 模拟器，点击运行。

在 **Product → Scheme → Edit Scheme → Run → Arguments Passed On Launch** 中添加 `--demo`，可在启动时直接进入演示模式。

### macOS 原生版

在 Xcode 中打开 `UCASSignIn.xcodeproj`，按下文完成签名配置，选择 `UCASSignInMac` scheme 和 **My Mac**，点击运行。可在 scheme 的启动参数中添加 `--demo`，直接进入演示模式。

macOS 会在启动时恢复上次选中的账户，在重新验证该账户时填充其已记住的密码。添加新账户时不会填入其他账户的密码。若系统提示钥匙串授权，输入“登录”钥匙串密码，通常与 Mac 登录密码相同；应用签名变化后可能需要重新授权。

### 设备与开发者签名

iPhone / iPad 真机运行和 Mac 开发者签名构建共用本机配置。首次使用时，在项目根目录复制示例：

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

编辑 `Config/Signing.local.xcconfig`，使用自己开发者账号对应的值：

| 配置项 | 用途 |
| --- | --- |
| `DEVELOPMENT_TEAM` | Apple 开发者 Team ID |
| `APP_BUNDLE_IDENTIFIER` | 主 App 的基础 Bundle Identifier |
| `APP_GROUP_IDENTIFIER` | iOS / iPadOS App 与 Widget 共用的 App Group |
| `MAC_APP_GROUP_SUFFIX` | Mac App Group 后缀，完整值为 `$(TeamIdentifierPrefix)$(MAC_APP_GROUP_SUFFIX)` |

各 target 的 Bundle Identifier 后缀由工程自动添加。Mac App Group 示例：`ABCDE12345.com.example.guokesignin`。

在开发者账号中配置相应标识与签名，再到 Xcode 的 **Signing & Capabilities** 检查 App 和 Widget 的 Team、Bundle Identifier 与 App Group。同一平台的 App 和 Widget 使用相同 App Group。

### 构建与测试

在项目根目录验证无签名模拟器构建，并运行核心逻辑测试：

```sh
xcodebuild -project UCASSignIn.xcodeproj \
  -scheme UCASSignIn \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ucas-ios-build \
  CODE_SIGNING_ALLOWED=NO build

swift test
```

网络测试使用模拟响应，账户存储测试使用内存存储，无需学校账号或访问真实钥匙串。

在 Xcode 中选择 `UCASSignIn` scheme 和 iPhone / iPad 模拟器，或选择 `UCASSignInMac` scheme 和 **My Mac**，按 `⌘U` 运行测试。UI 测试使用演示模式或独立的本地多账户样例，不登录真实学校账户。Mac scheme 还包含 AppModel 单元测试，验证账户切换、会话恢复以及通知和小组件隔离。

## 目录结构

```text
UCASSignIn/
├── Core/                    课程与账户模型、学校接口、时间处理与 Keychain
├── UI/                      SwiftUI 页面与应用状态
└── Resources/               图标、Info.plist、entitlement 与隐私声明
UCASSignInMac/Resources/     macOS 配置、沙盒权限与原生 AppIcon
UCASSignInWidget/            iOS / macOS 共享的 WidgetKit 扩展
Shared/                     App 与 Widget 共享的课程快照
Tests/UCASCoreTests/         核心逻辑单元测试
UCASSignInMacTests/          AppModel 与账户切换单元测试
UCASSignInUITests/           iOS / iPadOS 演示与多账户 UI 测试
UCASSignInMacUITests/        macOS 演示与多账户 UI 测试
UCASSignIn.xcodeproj/        Xcode 工程与共享 scheme
Package.swift               核心库的 Swift Package 定义
Config/                     共享签名配置与本机配置示例
docs/screenshots/           README 界面截图
LICENSE                     AGPL-3.0 协议全文
```

## 数据与隐私

- 登录请求直接发送至学校 HTTPS 服务，不经过本项目自建服务器。
- 账户列表、各账户的会话和可选密码保存在本机 Keychain；只有选择记住密码时才持久保存密码。本功能不提供跨设备账户同步。
- 课程缓存按账号和日期隔离，签到记录与课堂偏好也按账户保存。本机保留各账号最近 100 条签到结果，不代表学校完整考勤记录。
- 姓名与学号的隐藏开关同时作用于账户页、账户列表和快捷切换菜单。
- 小组件只共享当前账户的课程摘要和签到状态，不共享账户列表、密码或会话令牌。
- App 不申请定位、通讯录或相机权限，未集成广告或统计 SDK。
- 移除账户会清除该账户在本机的凭据、课程缓存、签到记录与课堂偏好；移除当前账户时还会清空待发送提醒及小组件数据。其他账户的数据不受影响。

## 致谢

本项目的轻新课堂接口实现参考了以下项目，感谢原作者及贡献者的开源分享：

- [lccipher/UCAS-Course-Sign-in](https://github.com/lccipher/UCAS-Course-Sign-in)
- [zhan-nine/UCAS-Sign-in](https://github.com/zhan-nine/UCAS-Sign-in)

## 开源许可

本项目及上述参考项目均采用 [AGPL-3.0](LICENSE) 许可证，上游代码的相应版权归原作者及贡献者所有。

## 免责声明

果壳签到是非官方客户端，与中国科学院大学及轻新课堂服务运营方无隶属、合作或官方授权关系，不代表上述机构或运营方。使用本软件产生的一切风险由用户自行承担。
