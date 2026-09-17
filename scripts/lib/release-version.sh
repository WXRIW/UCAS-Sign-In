#!/bin/bash

version_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_repo_root="$(cd "$version_script_dir/../.." && pwd)"
version_file="$version_repo_root/eng/version.json"
version_xcconfig="$version_repo_root/eng/generated/Version.xcconfig"

if [[ ! -f "$version_file" || ! -f "$version_xcconfig" ]]; then
    printf 'Version configuration is missing. Run the version sync command.\n' >&2
    return 1 2>/dev/null || exit 1
fi
release_version="$(/usr/bin/sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)"[,]\{0,1\}[[:space:]]*$/\1/p' "$version_file")"
release_build="$(/usr/bin/sed -n 's/^[[:space:]]*"build":[[:space:]]*\([0-9][0-9]*\)[,]\{0,1\}[[:space:]]*$/\1/p' "$version_file")"
if [[ ! "$release_version" =~ ^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+$ || ! "$release_build" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid version data in %s\n' "$version_file" >&2
    return 1 2>/dev/null || exit 1
fi
if ! /usr/bin/grep -Fxq "MARKETING_VERSION = $release_version" "$version_xcconfig" ||
   ! /usr/bin/grep -Fxq "CURRENT_PROJECT_VERSION = $release_build" "$version_xcconfig"; then
    printf 'Generated Apple version configuration is stale. Run the version sync command.\n' >&2
    return 1 2>/dev/null || exit 1
fi

check_apple_info_version() {
    local info_plist="$1" actual_version actual_build
    if [[ ! -f "$info_plist" ]]; then
        printf 'Missing bundle Info.plist: %s\n' "$info_plist" >&2
        return 1
    fi
    actual_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info_plist")"
    actual_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$info_plist")"
    if [[ "$actual_version" != "$release_version" || "$actual_build" != "$release_build" ]]; then
        printf 'Bundle version mismatch in %s: %s (%s), expected %s (%s)\n' \
            "$info_plist" "$actual_version" "$actual_build" "$release_version" "$release_build" >&2
        return 1
    fi
}
