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
| `APP_BUNDLE_IDENTIFIER` | 稳定的基础标识，用于派生 Mac Bundle Identifier、默认 CloudKit 容器及共享钥匙串组 |
| `IOS_APP_BUNDLE_IDENTIFIER` | iOS 主 App 的 Bundle Identifier，默认继承基础标识；Widget 和 UI 测试在此值后添加后缀 |
| `APP_GROUP_IDENTIFIER` | iOS / iPadOS App 与 Widget 共用的 App Group |
| `MAC_APP_GROUP_SUFFIX` | Mac App Group 后缀，完整值为 `$(TeamIdentifierPrefix)$(MAC_APP_GROUP_SUFFIX)` |
| `ICLOUD_CONTAINER_IDENTIFIER` | 两个主 App 共用的 CloudKit 容器，默认 `iCloud.$(APP_BUNDLE_IDENTIFIER)` |
| `ICLOUD_KEYCHAIN_ACCESS_GROUP` | 两个主 App 共用的同步钥匙串组，默认 `$(AppIdentifierPrefix)$(APP_BUNDLE_IDENTIFIER).icloud-credentials` |
| `ICLOUD_CONTAINER_ENVIRONMENT` | 本机开发默认 `Development`；正式打包使用 `Production` |

iOS Widget 和 UI 测试分别使用 `$(IOS_APP_BUNDLE_IDENTIFIER).widget` 和 `$(IOS_APP_BUNDLE_IDENTIFIER).uitests`。Mac 仍由 `APP_BUNDLE_IDENTIFIER` 派生 `.mac` 等后缀。Mac App Group 示例：`ABCDE12345.com.example.guokesignin`。所有 target 的 Team 统一继承本机配置，避免在单个 target 中覆盖。

在开发者账号中配置相应标识与签名，再到 Xcode 的 **Signing & Capabilities** 检查 App 和 Widget 的 Team、Bundle Identifier 与 App Group。同一平台的 App 和 Widget 使用相同 App Group。

## iOS 签名归档

完成本机签名配置，并在 Xcode 的 **Settings → Accounts** 登录对应开发者账号后，在本目录执行：

内部测试保持 `cn.ucas.signin`，其 Widget 为 `cn.ucas.signin.widget`；这套标识需要自己的 App Group 和描述文件。

```sh
xcodebuild -project UCASSignIn.xcodeproj \
  -scheme UCASSignIn \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ../../build/ios/UCASSignIn.xcarchive \
  -allowProvisioningUpdates archive
```

上传 TestFlight 使用 App Store Connect 已登记的 `cn.ucas.signin.ios`，在上述命令中增加 `-xcconfig Config/Signing.TestFlight.xcconfig`，并将归档路径改为 `../../build/ios/UCASSignIn-TestFlight.xcarchive`。该覆盖配置将 iOS App / Widget 切换为 `cn.ucas.signin.ios` / `cn.ucas.signin.ios.widget`，App Group 切换为 `group.cn.ucas.signin.ios`，并使用 CloudKit Production 环境；Mac Bundle Identifier、共享 CloudKit 容器和钥匙串组名称保持原值。本机默认配置仍用于内部测试，两套 iOS App ID 分别配置能力和描述文件。

`-allowProvisioningUpdates` 允许 Xcode 为自动签名的 target 创建或更新描述文件。修改 Team、Bundle Identifier 或 App Group 后，App 和 Widget 都需要匹配新配置的描述文件；Widget 的 Bundle Identifier 为 `$(IOS_APP_BUNDLE_IDENTIFIER).widget`。

若报错 `iOS Team Provisioning Profile: *` 不支持 App Groups，说明选中了缺少共享容器权限的通配符描述文件。检查 App 和 Widget 都启用了自动签名、选择了同一 Team 并勾选了同一 App Group，然后使用上面的命令更新描述文件。若账号无权自动配置，在 Apple Developer 的 **Certificates, Identifiers & Profiles** 中为两个明确的 App ID 启用 App Groups、关联共享组并重新生成描述文件；参见 [Apple 的配置说明](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)。

App Groups 用于 App 与 Widget 共享课程快照，需要保留。构建日志中的 `Disabling previews` 是 Release 优化设置的提示，不是归档失败原因。

## iCloud 同步与隐私

iPhone、iPad 和 Mac 默认启用 iCloud 同步；设置页可以关闭本机同步或立即同步。关闭的选择会保留。无有效签名权限、未登录 iCloud、等待网络或登录信息尚未到达时，本地功能仍可使用，设置页显示相应状态。演示和测试不连接真实 iCloud。

同步资料使用当前 Apple 账户的 CloudKit **私有数据库**，个人内容放入加密 `payload` 字段；学校会话和已选择记住的密码分别存放于 iCloud 钥匙串，使用 `WhenUnlocked` 和同步属性，Mac 使用 Data Protection Keychain。主 App 保留原默认钥匙串访问组在首位，以继续读取本机旧账户仓库。共享凭据组只授予两个主 App，Widget 继续只读取 App Group 中的课程快照。

| 同步 | 仅留在本机 |
| --- | --- |
| 学校账户、登录状态、已记住的密码 | 当前账户选择、通知系统授权、小组件快照 |
| 外观、信息隐藏、课表显示、自动检查更新和记录保留偏好 | 自动签到开关、规则、暂停、课次覆盖、重试、校时及执行账本 |
| 提醒和提醒时间、签到确认、课程禁用 | 学校课表、课程目录、考勤和可重新获取的缓存 |
| 签到操作记录、自动签到只读历史及来源设备，默认不限数量与时间 | 远端历史不会触发本机签到或重试 |

可在“设置 → 记录保留”分别调整操作记录和自动签到历史的数量上限、保留天数，支持自定义正整数，关闭对应限制即不限，保留限制按账户分别计算。只有点击“保存”后才生效并清理超额或过期记录；保留设置会通过 iCloud 在 Apple 设备间同步。历史清理不影响正在执行的任务和防重复签到的本机运行状态。此前已清理的记录无法恢复。

修改先保存本机，再排队同步，连续修改合并后约 2 秒提交。应用启动时主动同步，前台每 30 秒检查一次，距上次尝试至少 60 秒才进行周期同步。私有 `UCASSync` zone 安装静默 CloudKit 订阅，收到云端变更通知后直接增量拉取，不等待下一轮轮询；同步过程中收到的通知合并为后续拉取。推送仍遵守服务端重试时间和永久错误限制，订阅配置失败不会阻止普通同步，前台轮询继续兜底。

静默推送不弹出通知，也不会申请提醒通知权限。后台能否收到推送由系统调度决定，推送可能合并、延迟或遗漏，后台和退出后不承诺实时传输。CloudKit 和钥匙串独立到达，等待凭据期间不会删除现有可用会话。系统通知授权不随偏好同步，也不会因远端设置自动弹窗申请。

冲突由字段级因果版本自动合并，不要求用户选择。独立字段都保留，同字段并发使用固定逻辑版本次序，设备时钟不决定输赢。历史按稳定标识去重；显式重置、取消记住密码及账户删除均保存标记，防止离线旧设备重新带回。账户可以“仅从本机移除”并记住本机排除状态，或“从 iCloud 与所有设备移除”；后者联网后传播删除，只有主动重新登录才能重新添加。切换 Apple 账户会隔离旧同步队列和归属。

关闭本机同步会保留本地数据与云端副本，并停止 App 的同步读写；已经写入 iCloud 钥匙串的项目仍由系统管理，关闭 App 开关不等于暂停系统钥匙串传输。

### 开发者容器与 production schema

1. 在 Apple Developer 为实际使用的明确主 App ID（`IOS_APP_BUNDLE_IDENTIFIER` 和 `$(APP_BUNDLE_IDENTIFIER).mac`）启用 iCloud / CloudKit 和 Push Notifications，并关联**同一个** `ICLOUD_CONTAINER_IDENTIFIER`；授权同一个共享钥匙串组。内部测试和 TestFlight 使用不同 iOS App ID 时，两者均需分别配置。两个平台各自的 App 与 Widget 仍需匹配 App Group。只有两个主 App 需要推送权限，Widget 不参与云端同步。
2. 为所有四个 target 更新描述文件。Mac 使用 Developer ID 分发时也需包含 CloudKit 和 App Group 的 Developer ID 描述文件；只有临时签名或重新侧载签名不代表获得原开发者的 iCloud 权限。[Apple Developer ID 能力说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
3. 使用开发签名构建与测试 Apple 账户在 CloudKit Console 的 Development 环境初始化 schema。实现使用私有自定义 zone **`UCASSync`**，record type **`SyncEntry`**；唯一业务字段 **`payload`** 是加密 Bytes（`CKRecord.encryptedValues` 中的 `Data`）。recordName 为不透明 SHA-256 标识；按 zone changes 增量读取，不需要查询索引，也不要把数据放到 Public database。
4. 发布前在 CloudKit Console 将 schema 部署到 Production，再用 Production 签名设备验收。用户数据不会随 schema 部署从 Development 复制到 Production。不要把此步骤视作打包脚本已完成；脚本只能验证导出包权限与容器一致性。
5. 保持既有容器和 keychain group 稳定；换组或 App ID 会改变云端/凭据访问范围。跨 iOS/macOS 的 AppIdentifierPrefix 必须一致，历史 App ID 的 prefix 不一定等于 Team ID，正式脚本会检查两包解析后的共享组完全相同。

签名发行命令、ExportOptions 与手动 CI 配置见[发布说明](../../scripts/publish/README.md)。尚未配置证书、描述文件、公证和真实测试设备时，只能验证本地构建、模拟传输与合并行为；不能声称真实双设备同步或生产 schema 已验收。

### Xcode 直装真机的同步排查

Xcode 直装使用哪个 CloudKit 环境，以安装包实际签名中的 `com.apple.developer.icloud-container-environment` 为准。本项目本机配置默认是 `Development`；该环境首次成功写入新的加密字段时会更新开发 schema，**不需要先部署 Production schema**。Production 部署用于连接 Production 的发行构建，不会修复 Development 请求。参见 [Apple 的加密字段与 schema 说明](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)。

1. 先保留“设置 → iCloud 同步”的完整状态和发生时间，再点“立即同步”复现。旧构建曾把多种 CloudKit 请求错误统一显示成“服务暂时繁忙”；请确认手机已安装当前构建，再根据新状态定位。仅凭旧提示无法判断是服务故障还是容器或字段配置问题。
2. 检查**对应安装构建**的签名，不能只查看源码中的 entitlements、Xcode 能力勾选或描述文件。对构建生成的 `.app` 执行 `codesign -d --entitlements - --xml /path/to/UCASSignIn.app`，确认容器包含 `ICLOUD_CONTAINER_IDENTIFIER`、服务包含 `CloudKit`，环境符合预期。`keychain-access-groups` 还须包含 Info.plist 中 `CloudKeychainAccessGroup` 的完整值，`CloudContainerIdentifier` 须与已签容器一致。描述文件也须授权这些能力；检查其他时间或其他 Bundle Identifier 的归档不能证明手机上当前构建的配置。
3. 在 [CloudKit Console](https://icloud.developer.apple.com/) 选择签名所属 Team、实际容器和对应环境。在 Schema 中检查 `SyncEntry` 的 `payload` 是 **Encrypted Bytes**，不是普通 Bytes、String 或 Asset。数据操作使用 Private database 的 `UCASSync` zone；不要在 Public database 手动创建业务记录。加密字段不支持索引，本实现也不需要查询索引。若还没有 schema，成功写入会初始化它；若已有同名普通字段，不能直接转为加密字段，应保留现有数据后安排字段迁移，避免通过 Reset Environment 或删除 zone 来试错。[Apple 对加密字段的限制](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)
4. 按状态处理后，在设备解锁、系统已登录 iCloud 且网络可用时重试。CloudKit 加密字段依赖 iCloud 钥匙串的密钥；同步登录信息也需要系统 iCloud 钥匙串可用。跨设备验证时，两端需使用同一 Apple 账户、容器和 CloudKit 环境，Development 与 Production 的数据彼此独立。

若提示 iCloud 同步区域已被移除，需要关闭后重新开启应用内同步，才会重建区域并重新上传本机仍保留的同步资料。恢复授权仅适用于发生错误的 Apple 账户；账户删除与登录撤销记录继续保留，普通轮询和“立即同步”不会自行恢复已删除的区域。

| 状态或错误码 | 排查方向 |
| --- | --- |
| “此构建未配置 iCloud 同步权限” | 检查实际签名、容器授权、Info.plist 和共享钥匙串组；修改能力后更新匹配的描述文件并重新构建安装 |
| `CKError.invalidArguments (12)`、`serverRejectedRequest (15)`、`constraintViolation (19)` | 核对实际环境中 `SyncEntry.payload` 的字段类型、加密属性及请求内容；这些代码不直接证明是哪项 schema 配置有误 |
| `CKError.partialFailure (2)`、`batchRequestFailed (22)` | 批量请求未提供可用的具体失败原因时会显示；检查同一请求中的底层错误，不能据此认定为临时服务故障 |
| `CKError.limitExceeded (27)` | 检查请求大小与批量记录数量，调整请求后再试 |
| “iCloud 服务暂时繁忙” | 当前构建仅将服务不可用、请求限流或 zone 繁忙映射为此状态，并按服务端建议延迟重试 |
| 网络、未登录、系统限制、空间不足或钥匙串锁定 | 按显示的具体状态处理；这些问题不靠部署 schema 解决 |

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
Shared/                     App 与 Widget 共享的课程快照
Tests/UCASCoreTests/         核心逻辑单元测试
UCASSignInMacTests/          AppModel 与账户切换单元测试
UCASSignInUITests/           iOS / iPadOS 演示与多账户 UI 测试
UCASSignInMacUITests/        macOS 演示与多账户 UI 测试
UCASSignIn.xcodeproj/        Xcode 工程与共享 scheme
Package.swift               核心库的 Swift Package 定义
Config/                     共享签名配置与本机配置示例
```
