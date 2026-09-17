# 完整发布流程

三端共用 `eng/version.json` 作为唯一版本源。正式产物直接写入 `artifacts/<版本>/`，不再增加平台子目录；临时构建文件放在 `artifacts/.staging/` 或系统临时目录。

## 1. 设置版本

在任意平台的仓库根目录执行：

```powershell
dotnet run --project tools/Versioning -- set 1.0.0 --build 1
dotnet run --project tools/Versioning -- check
```

- `version` 是用户可见版本，例如 `1.0.0`。
- `build` 是递增的内部构建号。
- `set` 会同步生成 .NET、Android、Apple 和 Windows MSIX 所需的版本配置。
- Windows MSIX 使用四段版本，例如公开版本 `1.0.0`、build `1` 对应 `1.0.0.1`。
- 也可使用 `bump patch`、`bump minor`、`bump major` 或 `bump build`。

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
- macOS arm64 + x86_64 通用临时签名 ZIP。

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
UCAS-SignIn-<版本>-<平台>-<架构>-<类型>.<扩展名>
```

以 `1.0.0` 为例：

```text
artifacts/1.0.0/
  UCAS-SignIn-1.0.0-android-arm-arm64-release.apk
  UCAS-SignIn-1.0.0-android-arm-arm64-release.apk.sha256
  UCAS-SignIn-1.0.0-ios-arm64-unsigned.ipa
  UCAS-SignIn-1.0.0-ios-arm64-unsigned.ipa.sha256
  UCAS-SignIn-1.0.0-macos-universal-adhoc.zip
  UCAS-SignIn-1.0.0-macos-universal-adhoc.zip.sha256
  UCAS-SignIn-1.0.0-windows-x64.zip
  UCAS-SignIn-1.0.0-windows-x64.zip.sha256
  UCAS-SignIn-1.0.0-windows-arm64.zip
  UCAS-SignIn-1.0.0-windows-arm64.zip.sha256
  UCAS-SignIn-1.0.0-windows-x64-arm64-sideload.zip
  UCAS-SignIn-1.0.0-windows-x64-arm64-sideload.zip.sha256
  UCAS-SignIn-1.0.0-windows-x64-arm64-store.msixupload
  UCAS-SignIn-1.0.0-windows-x64-arm64-store.msixupload.sha256
  logs/
```

旁加载 ZIP 内含一个双架构 `.msixbundle` 和公开 `.cer` 证书。`.msixupload` 是唯一上传 Partner Center 的文件，其余 Windows 包用于直接分发。

## 5. 发布前检查

1. 确认 `dotnet run --project tools/Versioning -- check` 通过。
2. 确认 `artifacts/<版本>/` 中所需产物及对应 `.sha256` 都存在。
3. Android 应继续使用历史发布密钥；不要重新生成密钥。
4. Windows 商店只上传 `*-store.msixupload`。
5. PFX、keystore、密码、`Signing.local.props` 和本地 Apple 签名配置不得提交或随包分发。

## Apple 本地旧辅助脚本

原有 macOS/iOS 辅助脚本已集中放入被 Git 忽略的 `scripts/local/apple/`，不作为统一发布入口：

```text
scripts/local/apple/build-macos.sh
scripts/local/apple/export-release.sh
scripts/local/apple/export-macos.sh
scripts/local/apple/export-ipa.sh
scripts/local/apple/update-macos-icons.sh
```

需要单独调试构建、开发签名 IPA 或更新 macOS 图标时仍可直接使用这些脚本。正式版本优先使用 `scripts/publish/all-on-macos.sh`。
