#requires -Version 7.0
[CmdletBinding()]
param(
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
$keyAlias = 'ucas-signin'

foreach ($path in @($keyStore, $certificatePath)) {
    if (Test-Path -LiteralPath $path) { throw "Signing material already exists: $path. Reuse and back up the existing key." }
}
$jdk = Find-AndroidJavaHome $JavaHome
$keyTool = Join-Path $jdk 'bin/keytool.exe'
if ($null -eq $Password) { $Password = Read-AndroidSigningPassword }
if ($Password.Length -lt 6) { throw 'The keystore password must contain at least six characters.' }
$credential = [PSCredential]::new($keyAlias, $Password)
$oldPassword = $env:UCAS_ANDROID_SIGNING_PASSWORD
try {
    New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $credential.GetNetworkCredential().Password
    & $keyTool -genkeypair -noprompt -keystore $keyStore -storetype PKCS12 -alias $keyAlias `
        -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 `
        -dname 'CN=UCAS Sign In, OU=Android, O=UCAS Sign In, C=CN' `
        -storepass:env UCAS_ANDROID_SIGNING_PASSWORD -keypass:env UCAS_ANDROID_SIGNING_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'UCAS signing key generation failed.' }
    & $keyTool -exportcert -keystore $keyStore -alias $keyAlias -storepass:env UCAS_ANDROID_SIGNING_PASSWORD -file $certificatePath
    if ($LASTEXITCODE -ne 0) { throw 'Signing certificate export failed.' }
    $fingerprint = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Created UCAS signing key: $keyStore"
    Write-Host "Certificate SHA-256: $fingerprint"
    Write-Host 'The password has not been saved. Back up the keystore and password before distributing APKs.'
} finally {
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $oldPassword
}
