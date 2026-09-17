# 完整发布流程

三端共用 `eng/version.json` 作为唯一版本源。正式产物直接写入 `artifacts/publish/<版本>/`，不再增加平台子目录；临时构建文件放在 `artifacts/.staging/` 或系统临时目录。

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

## 3. 正式构建

### 在 macOS 生成 Apple 产物

```sh
scripts/publish/all-on-macos.sh
```

该入口生成：

- iOS arm64 未签名 IPA。
- macOS arm64 + x86_64 通用 ZIP，以及安装到 `/Applications` 的 PKG；包内 App 使用临时签名。

也可只执行 `scripts/publish/platforms/apple.sh`，结果相同。

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
