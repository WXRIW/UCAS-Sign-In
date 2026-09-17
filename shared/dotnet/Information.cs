namespace UCASSignIn;
// Product copy mirrored from the current Apple DisclaimerView.
internal static class Information
{
    internal const float SectionTitleSize = 22;

    internal sealed record Component(string Name, string Author, string Repository, string License, string LicenseUrl);

    // Group related runtime packages from each platform's lock file. Build/test tools are excluded.
    // Binding packages declare MIT AND Apache-2.0 in their bundled NuGet metadata.
    const string BindingLicenseUrl = "https://licenses.nuget.org/MIT%20AND%20Apache-2.0";
    static readonly Component DotNet = new(".NET", ".NET Foundation", "https://github.com/dotnet/runtime", "MIT", "https://github.com/dotnet/runtime/blob/main/LICENSE.TXT");
    static readonly Component QrCoder = new("QRCoder", "codebude", "https://github.com/codebude/QRCoder", "MIT", "https://licenses.nuget.org/MIT");

    internal static readonly Component[] AndroidComponents =
    [
        DotNet,
        new(".NET for Android", ".NET Foundation", "https://github.com/dotnet/android", "MIT", "https://github.com/dotnet/android/blob/main/LICENSE.TXT"),
        new("Material Components for Android", "Google / Microsoft", "https://github.com/material-components/material-components-android", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Material Symbols", "Google", "https://github.com/google/material-design-icons", "Apache-2.0", "https://github.com/google/material-design-icons/blob/master/LICENSE"),
        new("AndroidX", "Android Open Source Project / Microsoft", "https://android.googlesource.com/platform/frameworks/support", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Kotlin Standard Library", "JetBrains / Microsoft", "https://github.com/JetBrains/kotlin", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Kotlin Coroutines", "JetBrains / Microsoft", "https://github.com/Kotlin/kotlinx.coroutines", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Kotlin Serialization", "JetBrains / Microsoft", "https://github.com/Kotlin/kotlinx.serialization", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Guava ListenableFuture", "Google / Microsoft", "https://github.com/google/guava", "MIT · Apache-2.0", BindingLicenseUrl),
        new("Error Prone Annotations", "Google / Microsoft", "https://github.com/google/error-prone", "MIT · Apache-2.0", BindingLicenseUrl),
        new("JetBrains Annotations", "JetBrains / Microsoft", "https://github.com/JetBrains/java-annotations", "MIT · Apache-2.0", BindingLicenseUrl),
        new("JSpecify", "JSpecify / Microsoft", "https://github.com/jspecify/jspecify", "MIT · Apache-2.0", BindingLicenseUrl),
        QrCoder,
    ];

    internal static readonly Component[] WindowsComponents =
    [
        DotNet,
        new("Windows App SDK / WinUI", "Microsoft", "https://github.com/microsoft/WindowsAppSDK", "Microsoft 软件许可", "https://www.nuget.org/packages/Microsoft.WindowsAppSDK/1.8.260317003/License"),
        new("Windows Community Toolkit Notifications", "Microsoft / Community Toolkit", "https://github.com/CommunityToolkit/WindowsCommunityToolkit", "MIT", "https://licenses.nuget.org/MIT"),
        QrCoder,
    ];

    internal static readonly (string Title, string Body)[] Statements =
    [
        ("非官方软件", "果壳签到是独立开发的开源客户端，与中国科学院、中国科学院大学及轻新课堂服务运营方不存在隶属、合作或官方授权关系。"),
        ("遵守考勤规定", "本软件用于学习交流和个人课程管理。请遵守学校、课程及服务平台的相关规定，仅在实际到课且满足签到要求时使用。请勿代签、虚假签到、规避考勤或用于其他违法违规活动。"),
        ("以学校系统为准", "课程信息和签到结果以学校系统记录为准。网络状况、接口变化、系统限制等可能导致数据延迟、功能不可用或签到失败；本软件不保证每次请求成功。请及时核对结果，出现异常时使用学校提供的正式渠道处理。"),
        ("保护账号与数据", "请仅使用本人有权使用的账号，并妥善保管设备和登录凭据。登录信息会提交给学校服务进行验证；在他人设备上使用后，请及时退出登录并清除本机账号数据。"),
        ("无担保声明", "在适用法律允许的范围内，本软件按“现状”提供，不作适销性、特定用途适用性或持续可用性的担保。本声明不排除或限制依法不得免除的责任，具体开源许可条款请见“项目源码与致谢”。"),
    ];
}
