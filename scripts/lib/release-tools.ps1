function Read-ReleaseVersion {
    param([string]$RepositoryRoot)
    $path = Join-Path $RepositoryRoot 'eng/version.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing release version file: $path" }
    $release = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($release.version -notmatch '^[1-9][0-9]*\.[0-9]+\.[0-9]+$' -or [int64]$release.build -lt 1) {
        throw 'eng/version.json contains an invalid version or build number.'
    }
    return $release
}

function Assert-VersionSynchronized {
    param([string]$RepositoryRoot)
    $tool = Join-Path $RepositoryRoot 'tools/Versioning/Versioning.csproj'
    & dotnet run --project $tool -- check
    if ($LASTEXITCODE -ne 0) { throw 'Generated version files are stale. Run the version sync command.' }
}
