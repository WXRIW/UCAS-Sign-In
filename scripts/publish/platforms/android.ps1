#requires -Version 7.0
[CmdletBinding()]
param(
    [Security.SecureString]$Password,
    [string]$JavaHome,
    [string]$AndroidSdkRoot,
    [switch]$ActionsBuild
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Android release packaging is performed on Windows.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/android-tools.ps1')
$project = Join-Path $repositoryRoot 'apps/android/UCASSignIn.Android/UCASSignIn.Android.csproj'
$release = Read-ReleaseVersion $repositoryRoot
$version = [string]$release.version
$build = [int64]$release.build
$signingName = if ($ActionsBuild) { 'ucas-signin-actions' } else { 'ucas-signin' }
$signingDirectoryName = if ($ActionsBuild) { 'android-actions-signing' } else { 'android-signing' }
$expectedApplicationId = if ($ActionsBuild) { 'cn.ucas.signin.githubactions' } else { 'cn.ucas.signin' }
$expectedApplicationLabel = '果壳签到'
$artifactQualifier = if ($ActionsBuild) { '-githubactions' } else { '' }
$signingDirectory = Join-Path $repositoryRoot ".local/$signingDirectoryName"
$keyStore = Join-Path $signingDirectory "$signingName.keystore"
$certificatePath = Join-Path $signingDirectory "$signingName.cer"
foreach ($path in @($keyStore, $certificatePath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $guidance = if ($ActionsBuild) {
            'Restore the Actions keystore and certificate before packaging.'
        } else {
            'Run scripts/signing/android/new-key.ps1 once, or restore the existing key and certificate.'
        }
        throw "Missing UCAS signing material: $path. $guidance"
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
$outputDirectory = Join-Path $repositoryRoot "artifacts/publish/$version"
$checksumDirectory = Join-Path $outputDirectory 'sha256'
$outputApk = Join-Path $outputDirectory "UCAS-SignIn-$version-android$artifactQualifier.apk"
$outputChecksum = Join-Path $checksumDirectory "$([IO.Path]::GetFileName($outputApk)).sha256"
$oldPassword = $env:UCAS_ANDROID_SIGNING_PASSWORD
if ($null -eq $Password) { $Password = Read-Host 'UCAS signing password' -AsSecureString }
if ($Password.Length -eq 0) { throw 'The signing password cannot be empty.' }
$credential = [PSCredential]::new($signingName, $Password)

Push-Location $repositoryRoot
try {
    Assert-VersionSynchronized $repositoryRoot
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $credential.GetNetworkCredential().Password
    & $keyTool -list -keystore $keyStore -alias $signingName -storepass:env UCAS_ANDROID_SIGNING_PASSWORD 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot open the UCAS signing key. Check the password and keystore.' }
    New-Item -ItemType Directory -Path $stagingDirectory, $outputDirectory, $checksumDirectory -Force | Out-Null
    $arguments = @(
        'publish', $project, '-c', 'Release', '-o', $stagingDirectory,
        '-p:RestoreLockedMode=true', '-p:AndroidPackageFormats=apk', '-p:AndroidKeyStore=true',
        "-p:JavaSdkDirectory=$jdk", "-p:AndroidSdkDirectory=$sdk",
        "-p:AndroidSigningKeyStore=$keyStore", "-p:AndroidSigningKeyAlias=$signingName",
        '-p:AndroidSigningStorePass=env:UCAS_ANDROID_SIGNING_PASSWORD',
        '-p:AndroidSigningKeyPass=env:UCAS_ANDROID_SIGNING_PASSWORD'
    )
    if ($ActionsBuild) { $arguments += '-p:ActionsBuild=true' }
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
    $labelLine = [string]($badging | Where-Object { $_ -match '^application-label:' } | Select-Object -First 1)
    $actualApplicationLabel = [regex]::Match($labelLine, "^application-label:'([^']*)'").Groups[1].Value
    if ($packageName -ne $expectedApplicationId -or $actualVersion -ne $version -or $actualBuild -ne [string]$build) {
        throw "APK metadata mismatch: package=$packageName version=$actualVersion build=$actualBuild."
    }
    if ($actualApplicationLabel -ne $expectedApplicationLabel) {
        throw "APK application label mismatch: expected=$expectedApplicationLabel actual=$actualApplicationLabel."
    }
    if ($badging -match '^application-debuggable') { throw 'Release APK must not be debuggable.' }

    Copy-Item -LiteralPath $signedApk -Destination $outputApk -Force
    $hash = (Get-FileHash -LiteralPath $outputApk -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($outputApk))" | Set-Content -LiteralPath $outputChecksum -Encoding utf8
    Write-Host "Signed APK: $outputApk"
    Write-Host "Checksum: $outputChecksum"
    Write-Host "Certificate SHA-256: $expectedFingerprint"
    Write-Host "APK SHA-256: $hash"
} finally {
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $oldPassword
    Pop-Location
    if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
}
