#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows signing certificates must be created on Windows.' }

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$packageProjectDirectory = Join-Path $repositoryRoot 'apps/windows/UCASSignIn.Windows.Package'
$signingDirectory = Join-Path $repositoryRoot '.local/windows-signing'
$pfxPath = Join-Path $signingDirectory 'ucas-signin-sideload.pfx'
$cerPath = Join-Path $signingDirectory 'ucas-signin-sideload.cer'
$propsPath = Join-Path $packageProjectDirectory 'Signing.local.props'
$publisher = 'CN=FD2EEB64-9B3F-4B12-B833-80497D4F956C'

foreach ($path in @($pfxPath, $cerPath, $propsPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing signing configuration: $path"
    }
}

$password = Read-Host 'Password for the PFX backup (store this password safely)' -AsSecureString
New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null

$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $publisher `
    -FriendlyName 'UCAS Sign-In sideload signing' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(5)

try {
    Export-PfxCertificate -Cert $certificate -FilePath $pfxPath -Password $password | Out-Null
    Export-Certificate -Cert $certificate -FilePath $cerPath -Type CERT | Out-Null

    $props = @"
<?xml version="1.0" encoding="utf-8"?>
<Project>
  <PropertyGroup>
    <AppxPackageSigningEnabled>true</AppxPackageSigningEnabled>
    <PackageCertificateThumbprint>$($certificate.Thumbprint)</PackageCertificateThumbprint>
  </PropertyGroup>
</Project>
"@
    [IO.File]::WriteAllText($propsPath, $props, [Text.UTF8Encoding]::new($false))
} catch {
    foreach ($path in @($pfxPath, $cerPath, $propsPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    throw
}

Write-Host "Signing certificate created: $cerPath"
Write-Host "Encrypted private-key backup: $pfxPath"
Write-Host "Local MSBuild configuration: $propsPath"
Write-Host 'Keep the PFX and its password in a secure backup. None of these files are committed to Git.'
