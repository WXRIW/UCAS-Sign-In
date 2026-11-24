# 完整发布流程

三端共用 `eng/version.json` 作为唯一版本源。正式产物直接写入 `artifacts/publish/<版本>/`，不再增加平台子目录；临时构建文件放在 `artifacts/.staging/` 或系统临时目录。

Windows 与 Android 构建使用根目录 `global.json` 固定的 .NET SDK；GitHub Actions 从该文件安装 SDK，并将 SDK 安装到 runner 临时目录，以隔离预装的 Visual Studio 工作负载。Android 任务显式执行 `dotnet workload install android --version 10.0.303.1`；工作负载集不写入根目录 `global.json`，Windows 和版本工具无需安装它。升级工具链时应同步更新依赖锁文件并验证锁定还原，避免 SDK 隐式引用的 `Microsoft.NET.ILLink.Tasks` 版本变化导致 `NU1004`。

## 1. 设置版本

在任意平台的仓库根目录执行：

```powershell
dotnet run --project tools/Versioning -- set 1.0.0 --build 1
dotnet run --project tools/Versioning -- check
```

- `version` 是用户可见版本，例如 `1.0.0`。
- `build` 是递增的内部构建号。
- `set` 会同步生成 .NET、Android、Apple 和 Windows MSIX 所需的版本配置。
- Windows MSIX 在公开版本后补一位 `0`，例如公开版本 `1.1.0` 对应 `1.1.0.0`。第四段必须为 `0`，由 Microsoft Store 保留使用；内部 build 不写入 MSIX 版本。

常规升级优先使用 `bump`，它会同时递增内部构建号并同步三端配置：

```powershell
# 1.0.0 → 1.0.1，同时 build + 1
dotnet run --project tools/Versioning -- bump patch

# 1.0.0 → 1.1.0，同时 build + 1
dotnet run --project tools/Versioning -- bump minor

# 1.0.0 → 2.0.0，同时 build + 1
dotnet run --project tools/Versioning -- bump major

# 公开版本号不变，仅 build + 1；用于 Android、Apple 等同版本重新构建
dotnet run --project tools/Versioning -- bump build
```

`set VERSION` 默认保留当前 build；需要指定确切构建号时使用 `set VERSION --build NUMBER`。每次对外发布或向 Android、Apple 商店上传新包，都应确保 build 比上一次更大。由于 MSIX 不包含内部 build，只执行 `bump build` 不会改变 Windows 包版本；同一公开版本的 Windows 包不能作为更高版本重新上传，需要至少执行 `bump patch`。

不要直接编辑 `eng/generated/` 或生成后的 `Package.appxmanifest`；Windows 清单的非版本内容在 `Package.appxmanifest.in` 中维护。

## 2. 首次配置签名

### Android（Windows）

```powershell
pwsh scripts/signing/android/new-key.ps1
```

密钥保存在 `.local/android-signing/`。必须安全备份 keystore、公开证书和密码；后续版本必须继续使用同一密钥。

### Windows 旁加载包（Windows）

先在 Visual Studio 中将打包项目关联到 Partner Center，再执行：

```powershell
pwsh scripts/signing/windows/new-certificate.ps1
```

脚本将加密的 PFX 和公开 CER 放在 `.local/windows-signing/`，并生成被 Git 忽略的 `Signing.local.props`。PFX 与密码必须安全备份；旁加载 ZIP 只包含公开 CER，不包含私钥。

### Apple（macOS）

统一发布默认生成未签名 iOS IPA，以及临时签名的 macOS 通用包，不要求开发者证书。若需要真机开发签名，可配置被 Git 忽略的 `apps/apple/Config/Signing.local.xcconfig`。

未签名 iOS 包使用发布 App Group `group.cn.ucas.signin`，本机内部测试可以在本地配置中使用其他组。正式签名打包使用其指定的签名配置。

## 3. 正式构建

### 在 macOS 生成 Apple 产物

常规包和默认签名包每次都使用本机已安装的最新正式版 Xcode 和随附的 SDK。脚本检查 `/Applications`、`~/Applications`、`DEVELOPER_DIR` 和 `xcode-select` 指向的安装位置，跳过 Beta 和 RC。构建开头会打印选中的 Xcode 版本和构建号。

GitHub Actions 每次打包都会读取官方镜像清单，选择提供最新正式版 Xcode 的标准 Apple Silicon runner。新主版本或小版本进入镜像后，下一次构建会自动使用。[GitHub runner 镜像清单](https://github.com/actions/runner-images#available-images)

```sh
scripts/publish/all-on-macos.sh
```

该入口生成：

- iOS arm64 未签名 IPA。
- macOS arm64 + x86_64 通用 ZIP，以及安装到 `/Applications` 的 PKG；包内 App 使用临时签名。

也可只执行 `scripts/publish/platforms/apple.sh`，结果相同。

### 用 Xcode 16.4 生成 lagacy-sdk 兼容包

```sh
scripts/publish/lagacy-sdk.sh
```

该入口使用 Xcode 16.4 自带的 iOS 18.5 和 macOS 15.5 SDK。Apple 支持在 macOS 15.3 至 26.1.x 上运行这版 Xcode。[Apple 的 Xcode 系统要求](https://developer.apple.com/xcode/system-requirements/)

脚本优先使用 `DEVELOPER_DIR`，其次查找 `/Applications/Xcode_16.4.app`，最后检查 `xcode-select` 当前选中的版本。Xcode 安装在其他位置时，可按下面的示例指定路径。

```sh
DEVELOPER_DIR="/Applications/Xcode 16.4.app/Contents/Developer" scripts/publish/lagacy-sdk.sh
```

兼容包与常规包共用打包、签名和校验步骤。IPA、通用 ZIP、PKG、日志以及 SHA-256 文件的名称都包含 `lagacy-sdk`，可与常规包一起保存在同一版本目录。GitHub Actions 的 **Package Apple with lagacy-sdk** 使用 `macos-15` runner，在相关主分支推送、Pull Request 或手动触发时运行。

### Apple 正式签名、iCloud 与公证

在 `scripts/publish/all-on-macos.sh` 或 `scripts/publish/lagacy-sdk.sh` 后增加 `--signed` 即可使用对应工具链执行归档、导出和公证。签名配置不完整或签名、公证失败时，脚本会停止发布。

在开发者门户创建同一 Team 下的 iOS App/Widget、Mac App/Widget 标识和匹配的发行描述文件；两主 App 共享 CloudKit 容器及 iCloud 钥匙串访问组，Widget 保留 App Groups。生产 schema 的配置与部署见 [Apple 开发说明](../../apps/apple/README.md#开发者容器与-production-schema)。Mac 需 Developer ID Application 与 Developer ID Installer 两个证书及私钥；iOS 需 Apple Distribution 证书及私钥。

把 `scripts/signing/apple/` 的 `Archive.xcconfig.example`、`IOSExportOptions.plist.example`、`MacExportOptions.plist.example` 复制到 `.local/apple-signing/` 并修改：四个 profile 名称、已注册 Bundle IDs、App Groups、Team ID。示例 iOS 使用 `release-testing`，仅安装到 profile 已登记设备；App Store 发行改用 `app-store-connect` 并换相应 profiles。两个 ExportOptions 都必须指定 `iCloudContainerEnvironment=Production`、`destination=export` 及相同 `teamID`；Mac method 必须为 `developer-id`。

先把证书/私钥与四份 profiles 导入本机，并通过 `xcrun notarytool store-credentials` 配置钥匙串中的公证凭据。随后在仓库根目录运行（替换示例值）：

```sh
export UCAS_APPLE_TEAM_ID=YOURTEAMID
export UCAS_APPLE_ARCHIVE_XCCONFIG="$PWD/.local/apple-signing/Archive.xcconfig"
export UCAS_IOS_EXPORT_OPTIONS="$PWD/.local/apple-signing/IOSExportOptions.plist"
export UCAS_MACOS_EXPORT_OPTIONS="$PWD/.local/apple-signing/MacExportOptions.plist"
export UCAS_MACOS_INSTALLER_IDENTITY='Developer ID Installer: Your Organization (YOURTEAMID)'
export UCAS_NOTARY_PROFILE=your-notary-profile
scripts/publish/all-on-macos.sh --signed
```

`UCAS_NOTARY_KEYCHAIN` 可指定保存公证凭据的钥匙串路径。脚本不会自动更新开发者门户、上传 App Store 或创建 GitHub Release。它依次 archive/export 两个平台、检查代码签名与嵌入 profiles、核对两个主 App 的 Production 容器和共享钥匙串组、对 Mac App 公证和 staple，再制作与公证签名 PKG。`Archive.xcconfig` 示例按 target 选择 profile，不要把单个 `PROVISIONING_PROFILE_SPECIFIER` 强制套给 App 和 Widget。

输出文件为 `*-ios-signed.ipa`、`*-macos-universal-signed.zip`、`*-macos-universal-signed.pkg` 及对应的 SHA-256 校验文件。两平台验证和公证全部成功后才将产物放入发布目录。签名日志仅保存在本地 `logs/*-signed.log`，可能包含签名身份，不应公开上传。签名包允许经过验证的 App/Widget 固定位置包含 provisioning profile，其他私钥、本机配置和私人路径仍被隐私扫描拒绝。

正式验收必须使用有效签名设备与同一 Apple 账户检查双向资料/凭据恢复、离线冲突自动合并、密码清除及删除传播；无签名构建通过不代表 iCloud 权限或 Production schema 可用。

#### 受保护的手动 Apple 签名 CI

手动运行时，`toolchain` 默认为 `stable`，自动选择 runner 上可用的最新正式版 Xcode。选择 `lagacy-sdk` 可在 `macos-15` runner 上生成 Xcode 16.4 签名包。

`.github/workflows/package-apple-signed.yml` 仅响应 `main` 分支的 `workflow_dispatch`，不处理 PR、push 或计划任务，也不创建 Release。仓库管理员需先创建 **`apple-release` Environment**，设置 required reviewers 与只允许 `main` 的 deployment branch 规则；这些远端规则不是工作流文件自动创建的。

在该 Environment 中配置以下 Secrets（不要放入源码）：

| Secret | 内容 |
| --- | --- |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_INSTALLER_IDENTITY` | 完整 Developer ID Installer 证书名称 |
| `APPLE_CERTIFICATES_P12_BASE64` | 含 Apple Distribution、Developer ID Application、Developer ID Installer 证书及私钥的加密 P12 的单行 Base64 |
| `APPLE_CERTIFICATES_PASSWORD` | P12 导出密码 |
| `APPLE_PROFILES_ZIP_BASE64` | 四个 target 发行 profiles 的 ZIP，单行 Base64；仅包含 `.mobileprovision` / `.provisionprofile` |
| `APPLE_ARCHIVE_XCCONFIG_BASE64` | 填好的 `Archive.xcconfig` 的单行 Base64 |
| `APPLE_IOS_EXPORT_OPTIONS_BASE64` / `APPLE_MACOS_EXPORT_OPTIONS_BASE64` | 两个已配置 ExportOptions 的单行 Base64 |
| `APPLE_NOTARY_KEY_BASE64` | App Store Connect team API 私钥 `.p8` 的单行 Base64 |
| `APPLE_NOTARY_KEY_ID` / `APPLE_NOTARY_ISSUER_ID` | 对应 API key ID 和 issuer ID |

CI 建立临时钥匙串并安装 profiles，结束后恢复钥匙串搜索列表、删除本次安装的 profiles 和敏感文件；不会输出证书、密码或私钥内容。Artifacts 仅包含验证过的安装包和校验文件，不上传签名日志。现有 PR 工作流仍运行无签名构建。尚未配置 Secrets、环境保护或 Production schema 时，手动签名运行不会被视为已完成验收。

### 在 Windows 生成 Android 与 Windows 产物

```powershell
pwsh scripts/publish/all-on-windows.ps1
```

该入口先生成 Android 正式签名 APK，再生成 Windows 便携包、旁加载包和商店上传包。也可分别执行：

```powershell
pwsh scripts/publish/platforms/android.ps1
pwsh scripts/publish/platforms/windows.ps1
```

Windows 旁加载包和商店上传包均由 Visual Studio/MSBuild 的 Windows 打包目标生成。Partner Center 只上传一个 `.msixupload`；该文件内部同时包含 x64 与 ARM64。

### GitHub Actions 自动打包

`.github/workflows/package.yml` 在每次推送到 `main` 以及 Pull Request 时，使用相互独立的 Apple、Windows、Android 三个 job 并行打包；Windows 与 Android 分别使用各自的 Windows runner。它不创建 GitHub Release，产物从对应工作流页面的 **Artifacts** 下载，保留 7 天。与 Ink-Canvas 的工作流相同，每类成品单独调用一次 `upload-artifact`：

- `UCAS-SignIn-Android`：Actions 专用签名 Android APK。
- `UCAS-SignIn-Windows`：Windows x64、ARM64 便携 ZIP。
- `UCAS-SignIn-iOS`：未签名 iOS IPA。
- `UCAS-SignIn-macOS`：macOS Universal ZIP 和 PKG。

每个 Artifact 同时包含相应的 SHA-256 文件。GitHub 下载 Artifact 时仍会强制套一层 ZIP，这与 Ink-Canvas 示例一致，但不再把所有平台合并成两个大型压缩包。

Windows Actions 任务只生成 unpackaged 便携 ZIP，不生成 MSIX、旁加载包或商店上传包。iOS IPA 仍为未签名真机包，需要使用独立签名或侧载工具后才能安装。

#### 配置 Actions 专用 Android 签名

Actions APK 使用包名 `cn.ucas.signin.githubactions` 和独立密钥，启动器名称与正式版一致，均为“果壳签到”。它可与正式版并存，并在后续 Actions 构建之间覆盖升级，但不能更新正式版。

在 Windows PowerShell 中从仓库根目录一次性生成密钥：

```powershell
pwsh scripts/signing/android/new-actions-key.ps1
```

脚本会自动查找 Android 使用的 JDK，不要求 `keytool` 已加入 `PATH`。它会生成一个加密安全的随机密码，然后在 `.local/android-actions-signing/` 中生成 keystore、公开证书和 `ucas-signin-actions.password.txt`；如果文件已存在则拒绝覆盖。

密码文件是明文敏感信息，但整个 `.local/` 目录已被 Git 忽略。请将 keystore 与密码文件一同安全备份；同一包名的后续 APK 必须继续使用这把密钥，更换密钥后已安装的 Actions 版无法直接升级。

在仓库 **Settings → Secrets and variables → Actions** 中创建：

| Secret | 内容 |
| --- | --- |
| `ANDROID_ACTIONS_KEYSTORE_BASE64` | `ucas-signin-actions.keystore` 的 Base64 内容 |
| `ANDROID_ACTIONS_SIGNING_PASSWORD` | 生成 keystore 时使用的密码 |

可使用 GitHub CLI 从标准输入写入 Secrets，避免将值放到命令行参数中：

```powershell
$keyStore = Join-Path (Get-Location) '.local/android-actions-signing/ucas-signin-actions.keystore'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keyStore)) |
    gh secret set ANDROID_ACTIONS_KEYSTORE_BASE64
$passwordFile = Join-Path (Get-Location) '.local/android-actions-signing/ucas-signin-actions.password.txt'
[IO.File]::ReadAllText($passwordFile).Trim() |
    gh secret set ANDROID_ACTIONS_SIGNING_PASSWORD
```

工作流在能读取这两个 Secrets 时使用固定密钥；Fork PR、Dependabot 等无法读取 Secrets 的运行会自动生成仅用于该次构建的临时密钥，因此仍可正常打包，但临时签名 APK 不能覆盖升级其他运行生成的版本。本地验证 Actions APK 可执行：

```powershell
$passwordFile = Join-Path (Get-Location) '.local/android-actions-signing/ucas-signin-actions.password.txt'
$password = ConvertTo-SecureString ([IO.File]::ReadAllText($passwordFile).Trim()) -AsPlainText -Force
& scripts/publish/platforms/android.ps1 -Password $password -ActionsBuild
```

只生成 Windows 便携 ZIP 可执行：

```powershell
pwsh scripts/publish/platforms/windows.ps1 -PortableOnly
```

## 4. 产物布局与命名

统一文件名格式：

```text
UCAS-SignIn-<版本>-<平台>[-<架构>][-<用途或状态>].<扩展名>
```

以 `1.0.0` 为例：

```text
artifacts/publish/1.0.0/
  UCAS-SignIn-1.0.0-android.apk
  UCAS-SignIn-1.0.0-ios-unsigned.ipa
  UCAS-SignIn-1.0.0-macos-universal.zip
  UCAS-SignIn-1.0.0-macos-universal.pkg
  UCAS-SignIn-1.0.0-windows-x64.zip
  UCAS-SignIn-1.0.0-windows-arm64.zip
  UCAS-SignIn-1.0.0-windows-x64-arm64-sideload.zip
  UCAS-SignIn-1.0.0-windows-x64-arm64-store.msixupload
  logs/
  sha256/
    UCAS-SignIn-1.0.0-android.apk.sha256
    UCAS-SignIn-1.0.0-ios-unsigned.ipa.sha256
    UCAS-SignIn-1.0.0-macos-universal.zip.sha256
    UCAS-SignIn-1.0.0-macos-universal.pkg.sha256
    UCAS-SignIn-1.0.0-windows-x64.zip.sha256
    UCAS-SignIn-1.0.0-windows-arm64.zip.sha256
    UCAS-SignIn-1.0.0-windows-x64-arm64-sideload.zip.sha256
    UCAS-SignIn-1.0.0-windows-x64-arm64-store.msixupload.sha256
```

macOS 的 PKG 将应用安装到 `/Applications`。其中 App 使用临时签名，PKG 本身未使用 Apple Developer Installer 证书签名。

旁加载 ZIP 内含一个双架构 `.msixbundle` 和公开 `.cer` 证书。`.msixupload` 是唯一上传 Partner Center 的文件，其余 Windows 包用于直接分发。

## 5. 创建 GitHub Release

应用从 GitHub 的 latest release 接口检测更新。完成构建后，在 `WXRIW/UCAS-Sign-In` 创建公开的正式 Release：

- 标签必须为 `v<version>`，例如版本 `1.1.0` 使用 `v1.1.0`。
- 不要把正式更新保留为 Draft，也不要勾选 Pre-release；这两类版本不会触发应用内更新提示。
- 发布时将该版本设为 Latest release。
- 将需要公开分发的安装包和对应的 SHA-256 文件上传为 Release assets。
- Release 的版本必须与 `eng/version.json` 及产物文件名一致。

## 6. 发布前检查

1. 确认 `dotnet run --project tools/Versioning -- check` 通过。
2. 确认 `artifacts/publish/<版本>/` 中所需产物及 `sha256/` 下对应的校验文件都存在。
3. Android 应继续使用历史发布密钥；不要重新生成密钥。
4. Windows 商店只上传 `*-store.msixupload`。
5. PFX、keystore、密码、`Signing.local.props` 和本地 Apple 签名配置不得提交或随包分发。
6. GitHub Release 标签为 `v<version>`，并已作为非草稿、非预发布的正式版本发布。
