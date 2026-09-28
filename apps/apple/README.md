# Apple 客户端开发说明

本目录包含 iOS、iPadOS、watchOS 和 macOS 的 Swift + SwiftUI 工程。返回[仓库首页](../../README.md)。

下列命令均在本目录执行；从仓库根目录进入：

```sh
cd apps/apple
```

## 环境要求

- macOS、Xcode 16 或更新版本。
- 核心逻辑可通过 Swift Package 单独测试，需要 Swift 5.9+、macOS 13+。

## iPhone / iPad 模拟器

1. 下载或克隆源码，使用 Xcode 打开 `UCASSignIn.xcodeproj`。
2. 选择 `UCASSignIn` scheme 和一个 iPhone 或 iPad 模拟器，点击运行。

在 **Product → Scheme → Edit Scheme → Run → Arguments Passed On Launch** 中添加 `--demo`，可在启动时直接进入演示模式。

## Apple Watch 配套版

`UCASSignIn` iPhone App 内嵌 `UCASSignInWatch` target。需要 watchOS 10 或更新版本，以及配对的 iPhone。先在 iPhone 上安装、打开并登录果壳签到，再通过 iPhone 的 Watch App 安装手表 App；开发时也可在 Xcode 中选择配对的 iPhone 与 Apple Watch 作为运行设备。真机上 iPhone 和 Apple Watch 都需要开发者模式及相应签名。

手表可查看今日概览与下一节课、本周课表、课程时间地点和教师、最近 20 条签到记录及账户同步状态。手表每次进入前台时向 iPhone 请求一次课程摘要；后台不接收课程推送，打开某一天也不会自动刷新，可按需点“刷新这一天”。今日可签到课程提供快捷入口，提交前仍需二次确认。账户、会话和学校网络请求始终留在 iPhone；手表只保存最近一次课程与记录摘要。手表和 iPhone 暂时无法通信时，会显示上次同步内容，但不能提交签到。课程状态过期、账户切换或学校未明确返回“未签到”时，iPhone 会拒绝提交。手表暂不提供动态二维码和自动签到。

使用免费 Apple 账号在真机自签安装时，配置描述文件通常 7 天到期，届时需要重新构建安装。长期在固定设备测试可使用付费开发者账号的设备注册与 Ad Hoc 签名；watchOS App 跟随已签名的 iPhone App 一起打包。

自签 IPA 和配置描述文件含有签名及设备信息，仅供本机安装使用；仓库的 `.gitignore` 已排除 `artifacts/`、`*.ipa` 和配置描述文件，不要把它们加入源码提交。

如果 iPhone 的 Watch App 在“可用 App”中反复提示无法安装，可双击仓库中的 `scripts/apple/安装手表.command`，或在仓库根目录运行 `scripts/apple/install-watch.sh`，直接把当前 `artifacts/ios` 中的手表包安装到已连接的 Apple Watch。先用同一 IPA 更新配对 iPhone；手表需解锁并开启开发者模式，Mac 与手表需要能建立设备连接。脚本也接受 IPA 路径作为第一个参数，以及 Apple Watch 设备 ID 作为第二个参数，并会在安装后核对版本。

构建手表 target 前，Xcode 还需安装与 SDK 对应的 watchOS 运行时；若提示缺少 watchOS 运行时，请在 Xcode 的平台组件设置中安装。此工程的 iPhone App 和小组件使用 App Group，真机签名也需正确配置该能力。

## macOS 原生版

在 Xcode 中打开 `UCASSignIn.xcodeproj`，按下文完成签名配置，选择 `UCASSignInMac` scheme 和 **My Mac**，点击运行。可在 scheme 的启动参数中添加 `--demo`，直接进入演示模式。

macOS 会在启动时恢复上次选中的账户，在重新验证该账户时填充其已记住的密码。添加新账户时不会填入其他账户的密码。若系统提示钥匙串授权，输入“登录”钥匙串密码，通常与 Mac 登录密码相同；应用签名变化后可能需要重新授权。

## 设备与开发者签名

iPhone / iPad 真机运行和 Mac 开发者签名构建共用本机配置。首次使用时，在 Apple 项目目录（`apps/apple/`）复制示例：

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

## 构建与测试

Apple 各应用与 Widget 的版本来自仓库根目录 `eng/version.json`，生成配置位于 `eng/generated/Version.xcconfig`。修改版本时使用根目录 `tools/Versioning`，不要直接编辑 Xcode target 的版本字段。

在 Apple 项目目录（`apps/apple/`）验证无签名模拟器构建，并运行核心逻辑测试：

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
UCASSignInWatch/             配对 iPhone 的 watchOS App
Shared/                     App 与 Widget 共享的课程快照
Tests/UCASCoreTests/         核心逻辑单元测试
UCASSignInMacTests/          AppModel 与账户切换单元测试
UCASSignInUITests/           iOS / iPadOS 演示与多账户 UI 测试
UCASSignInMacUITests/        macOS 演示与多账户 UI 测试
UCASSignIn.xcodeproj/        Xcode 工程与共享 scheme
Package.swift               核心库的 Swift Package 定义
Config/                     共享签名配置与本机配置示例
```
