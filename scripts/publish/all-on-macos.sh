#!/bin/bash
set -euo pipefail

publish_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$publish_dir/../.." && pwd)"
. "$repo_root/scripts/lib/release-version.sh"

printf 'UCAS Sign-In %s (build %s) Apple release\n' "$release_version" "$release_build"
"$publish_dir/platforms/apple.sh"
printf '\nRelease directory: %s\n' "$repo_root/artifacts/$release_version"
