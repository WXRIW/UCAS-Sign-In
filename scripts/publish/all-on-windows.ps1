#requires -Version 7.0
[CmdletBinding()]
param(
    [Security.SecureString]$AndroidSigningPassword,
    [string]$JavaHome,
    [string]$AndroidSdkRoot,
    [string]$MSBuildPath
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The Android and Windows release must run on Windows.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/release-tools.ps1')
$release = Read-ReleaseVersion $repositoryRoot
Write-Host "UCAS Sign-In $($release.version) (build $($release.build)) Android + Windows release"

$androidArguments = @{}
if ($null -ne $AndroidSigningPassword) { $androidArguments.Password = $AndroidSigningPassword }
if ($JavaHome) { $androidArguments.JavaHome = $JavaHome }
if ($AndroidSdkRoot) { $androidArguments.AndroidSdkRoot = $AndroidSdkRoot }
& (Join-Path $PSScriptRoot 'platforms/android.ps1') @androidArguments

$windowsArguments = @{}
if ($MSBuildPath) { $windowsArguments.MSBuildPath = $MSBuildPath }
& (Join-Path $PSScriptRoot 'platforms/windows.ps1') @windowsArguments

$releaseDirectory = Join-Path $repositoryRoot "artifacts/$($release.version)"
Write-Host "Release directory: $releaseDirectory"
