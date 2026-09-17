# Apple 客户端开发说明

本目录包含 iOS、iPadOS 和 macOS 的 Swift + SwiftUI 工程。返回[仓库首页](../../README.md)。

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
Shared/                     App 与 Widget 共享的课程快照
Tests/UCASCoreTests/         核心逻辑单元测试
UCASSignInMacTests/          AppModel 与账户切换单元测试
UCASSignInUITests/           iOS / iPadOS 演示与多账户 UI 测试
UCASSignInMacUITests/        macOS 演示与多账户 UI 测试
UCASSignIn.xcodeproj/        Xcode 工程与共享 scheme
Package.swift               核心库的 Swift Package 定义
Config/                     共享签名配置与本机配置示例
```
