#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$MSBuildPath,
    [switch]$PortableOnly
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows packaging must run on Windows.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/release-tools.ps1')
$applicationProject = Join-Path $repositoryRoot 'apps/windows/UCASSignIn.Windows/UCASSignIn.Windows.csproj'
$packageProjectDirectory = Join-Path $repositoryRoot 'apps/windows/UCASSignIn.Windows.Package'
$packageProject = Join-Path $packageProjectDirectory 'UCASSignIn.Windows.Package.wapproj'
$signingPropsPath = Join-Path $packageProjectDirectory 'Signing.local.props'
$certificatePath = Join-Path $repositoryRoot '.local/windows-signing/ucas-signin-sideload.cer'
$release = Read-ReleaseVersion $repositoryRoot
$version = [string]$release.version
$stagingDirectory = Join-Path $repositoryRoot "artifacts/.staging/windows/$([Guid]::NewGuid().ToString('N'))"
$outputDirectory = Join-Path $repositoryRoot "artifacts/publish/$version"
$checksumDirectory = Join-Path $outputDirectory 'sha256'

$outputs = [ordered]@{
    PortableX64 = Join-Path $outputDirectory "UCAS-SignIn-$version-windows-x64.zip"
    PortableArm64 = Join-Path $outputDirectory "UCAS-SignIn-$version-windows-arm64.zip"
    Sideload = Join-Path $outputDirectory "UCAS-SignIn-$version-windows-x64-arm64-sideload.zip"
    StoreUpload = Join-Path $outputDirectory "UCAS-SignIn-$version-windows-x64-arm64-store.msixupload"
}

function Find-MSBuild {
    param([string]$RequestedPath)
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) { throw "MSBuild was not found: $RequestedPath" }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $command = Get-Command MSBuild.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $installerRoot = ${env:ProgramFiles(x86)}
    if ($installerRoot) {
        $vswhere = Join-Path $installerRoot 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $candidate = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
                Select-Object -First 1
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    throw 'MSBuild.exe was not found. Install the Visual Studio Windows application packaging tools or pass -MSBuildPath.'
}

function Publish-PortableArchive {
    param(
        [string]$Platform,
        [string]$RuntimeIdentifier,
        [string]$ArchivePath
    )

    $publishDirectory = Join-Path $stagingDirectory "portable/$RuntimeIdentifier"
    & dotnet publish $applicationProject -c Release -p:Platform=$Platform -r $RuntimeIdentifier --self-contained true `
        -p:RestoreLockedMode=true -o $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw "Windows $Platform portable build failed." }

    Compress-Archive -Path (Join-Path $publishDirectory '*') -DestinationPath $ArchivePath -CompressionLevel Optimal
}

function Invoke-VSPackageBuild {
    param(
        [string]$BuildMode,
        [string]$PackageDirectory,
        [bool]$SigningEnabled
    )

    $arguments = @(
        $packageProject,
        '/restore',
        '/target:Publish',
        '/verbosity:minimal',
        '/p:RestoreLockedMode=true',
        '/p:Configuration=Release',
        '/p:Platform=x64',
        '/p:UCASAppxBundle=Always',
        '/p:UCASAppxBundlePlatforms=x64|arm64',
        "/p:UCASUapAppxPackageBuildMode=$BuildMode",
        "/p:UCASAppxPackageSigningEnabled=$($SigningEnabled.ToString().ToLowerInvariant())",
        "/p:UCASAppxPackageDir=$PackageDirectory\"
    )
    & $script:msbuild @arguments
    if ($LASTEXITCODE -ne 0) { throw "Visual Studio $BuildMode package build failed." }
}

Push-Location $repositoryRoot
try {
    Assert-VersionSynchronized $repositoryRoot
    if (-not $PortableOnly) {
        if (-not (Test-Path -LiteralPath $signingPropsPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
            throw 'Sideload signing is not configured. Run pwsh scripts/signing/windows/new-certificate.ps1 once.'
        }
        $script:msbuild = Find-MSBuild $MSBuildPath
    }
    New-Item -ItemType Directory -Path $stagingDirectory, $outputDirectory, $checksumDirectory -Force | Out-Null

    $portableX64Archive = Join-Path $stagingDirectory ([IO.Path]::GetFileName($outputs.PortableX64))
    $portableArm64Archive = Join-Path $stagingDirectory ([IO.Path]::GetFileName($outputs.PortableArm64))
    Publish-PortableArchive -Platform x64 -RuntimeIdentifier win-x64 -ArchivePath $portableX64Archive
    Publish-PortableArchive -Platform ARM64 -RuntimeIdentifier win-arm64 -ArchivePath $portableArm64Archive

    $stagedOutputs = @(
        [pscustomobject]@{ Source = $portableX64Archive; Destination = $outputs.PortableX64 }
        [pscustomobject]@{ Source = $portableArm64Archive; Destination = $outputs.PortableArm64 }
    )
    if (-not $PortableOnly) {
        $sideloadPackageDirectory = Join-Path $stagingDirectory 'sideload-packages'
        Invoke-VSPackageBuild -BuildMode SideloadOnly -PackageDirectory $sideloadPackageDirectory -SigningEnabled $true
        $sideloadBundles = @(Get-ChildItem -LiteralPath $sideloadPackageDirectory -Filter '*.msixbundle' -File -Recurse)
        if ($sideloadBundles.Count -ne 1) { throw "Expected one sideload .msixbundle, found $($sideloadBundles.Count)." }

        $sideloadContents = Join-Path $stagingDirectory 'sideload'
        New-Item -ItemType Directory -Path $sideloadContents -Force | Out-Null
        Copy-Item -LiteralPath $sideloadBundles[0].FullName `
            -Destination (Join-Path $sideloadContents "UCAS-SignIn-$version-windows-x64-arm64.msixbundle")
        Copy-Item -LiteralPath $certificatePath `
            -Destination (Join-Path $sideloadContents 'UCAS-SignIn-Sideload.cer')
        $sideloadArchive = Join-Path $stagingDirectory ([IO.Path]::GetFileName($outputs.Sideload))
        Compress-Archive -Path (Join-Path $sideloadContents '*') -DestinationPath $sideloadArchive -CompressionLevel Optimal

        $storePackageDirectory = Join-Path $stagingDirectory 'store-packages'
        Invoke-VSPackageBuild -BuildMode StoreUpload -PackageDirectory $storePackageDirectory -SigningEnabled $false
        $uploads = @(Get-ChildItem -LiteralPath $storePackageDirectory -Filter '*.msixupload' -File -Recurse)
        if ($uploads.Count -ne 1) { throw "Expected one x64+ARM64 .msixupload file, found $($uploads.Count)." }

        $stagedOutputs += @(
            [pscustomobject]@{ Source = $sideloadArchive; Destination = $outputs.Sideload }
            [pscustomobject]@{ Source = $uploads[0].FullName; Destination = $outputs.StoreUpload }
        )
    }
    foreach ($item in $stagedOutputs) {
        Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
    }

    foreach ($path in $stagedOutputs.Destination) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $checksumPath = Join-Path $checksumDirectory "$([IO.Path]::GetFileName($path)).sha256"
        "$hash  $([IO.Path]::GetFileName($path))" |
            Set-Content -LiteralPath $checksumPath -Encoding utf8
    }

    Write-Host "Windows release files: $outputDirectory"
    foreach ($path in $stagedOutputs.Destination) {
        Write-Host "  $([IO.Path]::GetFileName($path))"
        Write-Host "  sha256/$([IO.Path]::GetFileName($path)).sha256"
    }
    if (-not $PortableOnly) {
        Write-Host 'Upload only the single .msixupload file to Partner Center; it contains both x64 and ARM64.'
    }
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
}
