# Shared Windows tooling discovery for the Android packaging scripts.
. (Join-Path $PSScriptRoot 'release-tools.ps1')
function Read-AndroidSigningPassword {
    $password = Read-Host 'Set UCAS signing password (at least 6 characters)' -AsSecureString
    $confirmation = Read-Host 'Confirm UCAS signing password' -AsSecureString
    if ($password.Length -lt 6) { throw 'The keystore password must contain at least six characters.' }
    $first = [PSCredential]::new('ucas-signin', $password)
    $second = [PSCredential]::new('ucas-signin', $confirmation)
    if ($first.GetNetworkCredential().Password -cne $second.GetNetworkCredential().Password) {
        throw 'Passwords do not match. No signing files have been changed.'
    }
    return $password
}

function Find-AndroidJavaHome {
    param([string]$JavaHome)
    if ($JavaHome) {
        if (-not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin/keytool.exe'))) {
            throw "JDK keytool was not found under: $JavaHome"
        }
        return (Resolve-Path -LiteralPath $JavaHome).Path
    }
    $candidates = @($env:JAVA_HOME)
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            $candidates += Get-ChildItem -LiteralPath (Join-Path $root 'Android/openjdk') -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | ForEach-Object FullName
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin/keytool.exe'))) {
            return $candidate
        }
    }
    throw 'JDK was not found. Set JAVA_HOME or pass -JavaHome.'
}

function Find-AndroidSdk {
    param([string]$AndroidSdkRoot)
    if ($AndroidSdkRoot) {
        return (Resolve-Path -LiteralPath $AndroidSdkRoot).Path
    }
    $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Android/android-sdk' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'build-tools'))) {
            return $candidate
        }
    }
    throw 'Android SDK was not found. Set ANDROID_SDK_ROOT or pass -AndroidSdkRoot.'
}

function Find-AndroidBuildTools {
    param([string]$SdkRoot)
    $tools = Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'build-tools') -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'zipalign.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'lib/apksigner.jar')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'aapt.exe'))
        } |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $tools) { throw 'Android build-tools with zipalign, apksigner and aapt were not found.' }
    return $tools.FullName
}
