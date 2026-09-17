#requires -Version 7.0
[CmdletBinding()]
param(
    [Security.SecureString]$Password,
    [string]$JavaHome,
    [string]$AndroidSdkRoot
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Android release packaging is performed on Windows.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/android-tools.ps1')
$project = Join-Path $repositoryRoot 'apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj'
$release = Read-ReleaseVersion $repositoryRoot
$version = [string]$release.version
$build = [int64]$release.build
$signingDirectory = Join-Path $repositoryRoot '.local/android-signing'
$keyStore = Join-Path $signingDirectory 'ucas-signin.keystore'
$certificatePath = Join-Path $signingDirectory 'ucas-signin.cer'
foreach ($path in @($keyStore, $certificatePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing UCAS signing material: $path. Run scripts/signing/android/new-key.ps1 once, or restore the existing key and certificate."
    }
}

$jdk = Find-AndroidJavaHome $JavaHome
$sdk = Find-AndroidSdk $AndroidSdkRoot
$buildTools = Find-AndroidBuildTools $sdk
$java = Join-Path $jdk 'bin/java.exe'
$keyTool = Join-Path $jdk 'bin/keytool.exe'
$apkSigner = Join-Path $buildTools 'lib/apksigner.jar'
$zipAlign = Join-Path $buildTools 'zipalign.exe'
$aapt = Join-Path $buildTools 'aapt.exe'
$stagingDirectory = Join-Path $repositoryRoot "artifacts/.staging/android/$([Guid]::NewGuid().ToString('N'))"
$outputDirectory = Join-Path $repositoryRoot "artifacts/$version"
$outputApk = Join-Path $outputDirectory "UCAS-SignIn-$version-android-arm-arm64-release.apk"
$oldPassword = $env:UCAS_ANDROID_SIGNING_PASSWORD
if ($null -eq $Password) { $Password = Read-Host 'UCAS signing password' -AsSecureString }
if ($Password.Length -eq 0) { throw 'The signing password cannot be empty.' }
$credential = [PSCredential]::new('ucas-signin', $Password)

Push-Location $repositoryRoot
try {
    Assert-VersionSynchronized $repositoryRoot
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $credential.GetNetworkCredential().Password
    & $keyTool -list -keystore $keyStore -alias ucas-signin -storepass:env UCAS_ANDROID_SIGNING_PASSWORD 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot open the UCAS signing key. Check the password and keystore.' }
    New-Item -ItemType Directory -Path $stagingDirectory, $outputDirectory -Force | Out-Null
    $arguments = @(
        'publish', $project, '-c', 'Release', '-o', $stagingDirectory,
        '-p:RestoreLockedMode=true', '-p:AndroidPackageFormats=apk', '-p:AndroidKeyStore=true',
        "-p:JavaSdkDirectory=$jdk", "-p:AndroidSdkDirectory=$sdk",
        "-p:AndroidSigningKeyStore=$keyStore", '-p:AndroidSigningKeyAlias=ucas-signin',
        '-p:AndroidSigningStorePass=env:UCAS_ANDROID_SIGNING_PASSWORD',
        '-p:AndroidSigningKeyPass=env:UCAS_ANDROID_SIGNING_PASSWORD'
    )
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Android publish failed.' }
    $signedPackages = @(Get-ChildItem -LiteralPath $stagingDirectory -Filter '*-Signed.apk' -File -Recurse)
    if ($signedPackages.Count -ne 1) { throw "Expected one signed APK, found $($signedPackages.Count)." }
    $signedApk = $signedPackages[0].FullName

    $verification = & $java -jar $apkSigner verify --verbose --print-certs $signedApk 2>&1
    if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed: $verification" }
    $expectedFingerprint = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not ($verification -match "(?m)^Signer #1 certificate SHA-256 digest: $expectedFingerprint$")) {
        throw 'APK signer does not match the UCAS signing certificate.'
    }
    & $zipAlign -c -P 16 4 $signedApk
    if ($LASTEXITCODE -ne 0) { throw 'APK alignment verification failed.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($signedApk)
    try {
        $resources = $archive.GetEntry('resources.arsc')
        if ($null -eq $resources -or $resources.Length -ne $resources.CompressedLength) {
            throw 'APK resources.arsc must exist and be uncompressed.'
        }
    } finally { $archive.Dispose() }

    $badging = & $aapt dump badging $signedApk
    if ($LASTEXITCODE -ne 0 -or $badging.Count -eq 0) { throw 'Cannot read APK package metadata.' }
    $packageLine = [string]$badging[0]
    $packageName = [regex]::Match($packageLine, "name='([^']+)'").Groups[1].Value
    $actualBuild = [regex]::Match($packageLine, "versionCode='([^']+)'").Groups[1].Value
    $actualVersion = [regex]::Match($packageLine, "versionName='([^']+)'").Groups[1].Value
    if ($packageName -ne 'cn.ucas.signin' -or $actualVersion -ne $version -or $actualBuild -ne [string]$build) {
        throw "APK metadata mismatch: package=$packageName version=$actualVersion build=$actualBuild."
    }
    if ($badging -match '^application-debuggable') { throw 'Release APK must not be debuggable.' }

    Copy-Item -LiteralPath $signedApk -Destination $outputApk -Force
    $hash = (Get-FileHash -LiteralPath $outputApk -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($outputApk))" | Set-Content -LiteralPath "$outputApk.sha256" -Encoding utf8
    Write-Host "Signed APK: $outputApk"
    Write-Host "Certificate SHA-256: $expectedFingerprint"
    Write-Host "APK SHA-256: $hash"
} finally {
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $oldPassword
    Pop-Location
    if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
}
