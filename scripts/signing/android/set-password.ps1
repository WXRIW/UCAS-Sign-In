#requires -Version 7.0
[CmdletBinding()]
param(
    [Security.SecureString]$CurrentPassword,
    [Security.SecureString]$Password,
    [string]$JavaHome
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This script supports Windows Android SDK tooling.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/android-tools.ps1')
$signingDirectory = Join-Path $repositoryRoot '.local/android-signing'
$keyStore = Join-Path $signingDirectory 'ucas-signin.keystore'
$certificatePath = Join-Path $signingDirectory 'ucas-signin.cer'
foreach ($path in @($keyStore, $certificatePath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing UCAS signing material: $path" }
}
$jdk = Find-AndroidJavaHome $JavaHome
$keyTool = Join-Path $jdk 'bin/keytool.exe'
if ($null -eq $CurrentPassword) { $CurrentPassword = Read-Host 'Current UCAS signing password' -AsSecureString }
if ($CurrentPassword.Length -eq 0) { throw 'The current signing password cannot be empty.' }
$credential = [PSCredential]::new('ucas-signin', $CurrentPassword)
if ($null -eq $Password) { $Password = Read-AndroidSigningPassword }
if ($Password.Length -lt 6) { throw 'The keystore password must contain at least six characters.' }
$newCredential = [PSCredential]::new('ucas-signin', $Password)
$oldPassword = $env:UCAS_ANDROID_SIGNING_PASSWORD
$oldNewPassword = $env:UCAS_ANDROID_NEW_SIGNING_PASSWORD
$temporaryDirectory = Join-Path $signingDirectory ([Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $temporaryKeyStore = Join-Path $temporaryDirectory 'ucas-signin.keystore'
    $temporaryCertificate = Join-Path $temporaryDirectory 'ucas-signin.cer'
    Copy-Item -LiteralPath $keyStore -Destination $temporaryKeyStore
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $credential.GetNetworkCredential().Password
    $env:UCAS_ANDROID_NEW_SIGNING_PASSWORD = $newCredential.GetNetworkCredential().Password
    & $keyTool -storepasswd -keystore $temporaryKeyStore -storetype PKCS12 `
        -storepass:env UCAS_ANDROID_SIGNING_PASSWORD -new:env UCAS_ANDROID_NEW_SIGNING_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Keystore password update failed. The original key was not changed.' }
    & $keyTool -exportcert -keystore $temporaryKeyStore -alias ucas-signin `
        -storepass:env UCAS_ANDROID_NEW_SIGNING_PASSWORD -file $temporaryCertificate
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the key with the new password. The original key was not changed.' }
    if ((Get-FileHash -LiteralPath $certificatePath).Hash -ne (Get-FileHash -LiteralPath $temporaryCertificate).Hash) {
        throw 'Certificate changed unexpectedly. The original key was not changed.'
    }
    [IO.File]::Replace($temporaryKeyStore, $keyStore, [NullString]::Value)
    Write-Host 'UCAS signing password updated. The signing certificate is unchanged.'
} finally {
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $oldPassword
    $env:UCAS_ANDROID_NEW_SIGNING_PASSWORD = $oldNewPassword
    foreach ($name in @('ucas-signin.keystore', 'ucas-signin.cer')) {
        $temporaryPath = Join-Path $temporaryDirectory $name
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    if (Test-Path -LiteralPath $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory }
}
