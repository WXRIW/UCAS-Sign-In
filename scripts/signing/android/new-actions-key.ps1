#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$JavaHome
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This script supports Windows Android SDK tooling.' }
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $repositoryRoot 'scripts/lib/android-tools.ps1')
$signingDirectory = Join-Path $repositoryRoot '.local/android-actions-signing'
$keyStore = Join-Path $signingDirectory 'ucas-signin-actions.keystore'
$certificatePath = Join-Path $signingDirectory 'ucas-signin-actions.cer'
$passwordPath = Join-Path $signingDirectory 'ucas-signin-actions.password.txt'
$keyAlias = 'ucas-signin-actions'

foreach ($path in @($keyStore, $certificatePath, $passwordPath)) {
    if (Test-Path -LiteralPath $path) { throw "Signing material already exists: $path. Reuse and back up the existing key." }
}
$jdk = Find-AndroidJavaHome $JavaHome
$keyTool = Join-Path $jdk 'bin/keytool.exe'
$passwordBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
$plainPassword = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$password = ConvertTo-SecureString $plainPassword -AsPlainText -Force
$credential = [PSCredential]::new($keyAlias, $password)
$oldPassword = $env:UCAS_ANDROID_SIGNING_PASSWORD
$created = $false
try {
    New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
    [IO.File]::WriteAllText($passwordPath, $plainPassword, [Text.UTF8Encoding]::new($false))
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $credential.GetNetworkCredential().Password
    & $keyTool -genkeypair -noprompt -keystore $keyStore -storetype PKCS12 -alias $keyAlias `
        -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 `
        -dname 'CN=UCAS Sign In Actions, OU=Android, O=UCAS Sign In, C=CN' `
        -storepass:env UCAS_ANDROID_SIGNING_PASSWORD -keypass:env UCAS_ANDROID_SIGNING_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Actions signing key generation failed.' }
    & $keyTool -exportcert -keystore $keyStore -storetype PKCS12 -alias $keyAlias `
        -storepass:env UCAS_ANDROID_SIGNING_PASSWORD -file $certificatePath
    if ($LASTEXITCODE -ne 0) { throw 'Actions signing certificate export failed.' }
    $created = $true
    $fingerprint = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Created Actions signing key: $keyStore"
    Write-Host "Generated password file: $passwordPath"
    Write-Host "Certificate SHA-256: $fingerprint"
    Write-Host 'Back up the keystore and password file before distributing APKs.'
} finally {
    $env:UCAS_ANDROID_SIGNING_PASSWORD = $oldPassword
    if (-not $created) {
        foreach ($path in @($keyStore, $certificatePath, $passwordPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}
