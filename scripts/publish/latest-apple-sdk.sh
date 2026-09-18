#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

usage() {
    printf '用法：%s [--xcode /Applications/Xcode.app]\n' "$0"
    printf '使用本机最高版本 Xcode/Apple SDK，同时保留工程配置的最低系统版本。\n'
}

xcode_app="${UCAS_XCODE_APP:-}"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --xcode)
            if [[ "$#" -lt 2 ]]; then usage >&2; exit 2; fi
            xcode_app="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'latest Apple SDK 构建只能在 macOS 上运行。\n' >&2
    exit 1
fi

version_key() {
    printf '%s\n' "$1" | awk -F. '{ printf "%06d%06d%06d\n", $1, $2, $3 }'
}

if [[ -z "$xcode_app" ]]; then
    best_key=''
    for candidate in /Applications/Xcode*.app; do
        developer_dir="$candidate/Contents/Developer"
        [[ -x "$developer_dir/usr/bin/xcodebuild" ]] || continue
        candidate_version="$(DEVELOPER_DIR="$developer_dir" \
            "$developer_dir/usr/bin/xcodebuild" -version | awk '/^Xcode / { print $2 }')"
        [[ "$candidate_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || continue
        candidate_key="$(version_key "$candidate_version")"
        if [[ -z "$best_key" || "$candidate_key" > "$best_key" ]]; then
            best_key="$candidate_key"
            xcode_app="$candidate"
        fi
    done
fi

if [[ -z "$xcode_app" || ! -x "$xcode_app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    printf '没有找到可用的 Xcode；可通过 --xcode 指定 Xcode.app。\n' >&2
    exit 1
fi

export DEVELOPER_DIR="$xcode_app/Contents/Developer"
xcode_output="$(xcodebuild -version)"
xcode_version="$(printf '%s\n' "$xcode_output" | awk '/^Xcode / { print $2 }')"
xcode_build="$(printf '%s\n' "$xcode_output" | awk '/^Build version / { print $3 }')"
ios_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift_output="$(xcrun swiftc --version)"
swift_compiler_version="$(printf '%s\n' "$swift_output" | \
    sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)+).*/\1/p')"

for detected_version in "$xcode_version" "$ios_sdk_version" "$macos_sdk_version" "$swift_compiler_version"; do
    if [[ ! "$detected_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
        printf '无法解析 Apple 工具链版本：%s\n' "$detected_version" >&2
        exit 1
    fi
done

swift_major="${swift_compiler_version%%.*}"
swift_language_version="$swift_major.0"

printf 'Latest Apple SDK build\n'
printf 'Xcode %s (%s)\n' "$xcode_version" "$xcode_build"
printf 'iOS SDK: %s (deployment target: project default)\n' "$ios_sdk_version"
printf 'macOS SDK: %s (deployment target: project default)\n' "$macos_sdk_version"
printf 'Swift compiler %s / language mode %s\n' "$swift_compiler_version" "$swift_language_version"

UCAS_LATEST_SWIFT_LANGUAGE_VERSION="$swift_language_version" \
    bash "$script_dir/platforms/apple-latest-sdk.sh"

. "$repo_root/scripts/lib/release-version.sh"
release_root="$repo_root/artifacts/publish/$release_version"
metadata_name="UCAS-SignIn-$release_version-apple-latest-sdk-build-info.txt"
metadata_path="$release_root/$metadata_name"
metadata_temp="$(mktemp "$release_root/.latest-sdk-info.XXXXXX")"
cleanup() {
    rm -f -- "$metadata_temp"
}
trap cleanup EXIT
{
    printf 'mode=latest-sdk\n'
    printf 'xcode_version=%s\n' "$xcode_version"
    printf 'xcode_build=%s\n' "$xcode_build"
    printf 'swift_compiler_version=%s\n' "$swift_compiler_version"
    printf 'swift_language_mode=%s\n' "$swift_language_version"
    printf 'ios_sdk=%s\n' "$ios_sdk_version"
    printf 'ios_deployment_target=project-default\n'
    printf 'macos_sdk=%s\n' "$macos_sdk_version"
    printf 'macos_deployment_target=project-default\n'
    printf 'runner_architecture=%s\n' "$(uname -m)"
    if [[ -n "${UCAS_RUNNER_LABEL:-}" ]]; then
        printf 'runner_label=%s\n' "$UCAS_RUNNER_LABEL"
    fi
} > "$metadata_temp"
mv -f -- "$metadata_temp" "$metadata_path"
(
    cd "$release_root"
    /usr/bin/shasum -a 256 "$metadata_name" > "sha256/$metadata_name.sha256"
)
trap - EXIT
printf '构建环境清单：%s\n' "$metadata_path"
