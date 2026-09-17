#!/bin/bash
set -euo pipefail

# Self-contained: uses Xcode and system tools, without invoking other scripts
# or reading a separate export-options plist.
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
apple_root="$repo_root/apps/apple"
. "$repo_root/scripts/lib/release-version.sh"
release_root="$repo_root/artifacts/publish/$release_version"
ios_artifacts_dir="$release_root"
macos_artifacts_dir="$release_root"
ios_logs_dir="$release_root/logs"
macos_logs_dir="$release_root/logs"
checksums_dir="$release_root/sha256"
ios_name="UCAS-SignIn-$release_version-ios-unsigned.ipa"
macos_name="UCAS-SignIn-$release_version-macos-universal.zip"
macos_pkg_name="UCAS-SignIn-$release_version-macos-universal.pkg"

if [[ "$#" -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
    printf '用法：%s\n独立生成未签名的 iOS IPA，以及包含临时签名 App 的 macOS 通用 ZIP 和 PKG。\n' "$0"
    printf '无需开发者证书；IPA 需要由签名或侧载工具签名后安装。\n'
    printf '所有产物保存在 %s。\n' "$release_root"
    printf '构建日志保存在 logs，校验文件保存在 sha256。\n'
    exit 0
fi
if [[ "$#" -ne 0 ]]; then
    printf '用法：%s [--help]\n' "$0" >&2
    exit 2
fi

mkdir -p "$ios_logs_dir" "$macos_logs_dir" "$checksums_dir"
package_dir=
ios_publish_dir=
macos_publish_dir=
cleanup() {
    if [[ -n "$package_dir" ]]; then rm -rf -- "$package_dir"; fi
    if [[ -n "$ios_publish_dir" ]]; then rm -rf -- "$ios_publish_dir"; fi
    if [[ -n "$macos_publish_dir" ]]; then rm -rf -- "$macos_publish_dir"; fi
}
trap cleanup EXIT
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/guoke-release.XXXXXX")"
ios_publish_dir="$(mktemp -d "$ios_artifacts_dir/.release.XXXXXX")"
macos_publish_dir="$(mktemp -d "$macos_artifacts_dir/.release.XXXXXX")"
failed=0

# Release archives contain runnable bundles, not local debugging information.
# Keep source references portable and do not serialize compiler command lines.
privacy_build_args=(
    DEBUG_INFORMATION_FORMAT=
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO
    SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO
    COMPILER_INDEX_STORE_ENABLE=NO
    'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map "$(SRCROOT)=/src/UCAS-Sign-In" -debug-prefix-map "$(SRCROOT)=/src/UCAS-Sign-In" -file-prefix-map "$(HOME)=/build-user" -debug-prefix-map "$(HOME)=/build-user" -file-compilation-dir /src/UCAS-Sign-In -Xfrontend -no-serialize-debugging-options'
    'OTHER_CFLAGS=$(inherited) -ffile-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -fdebug-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -ffile-prefix-map="$(HOME)=/build-user"'
    'OTHER_CPLUSPLUSFLAGS=$(inherited) -ffile-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -fdebug-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -ffile-prefix-map="$(HOME)=/build-user"'
)

# Usage: check_release_privacy APP_PATH [PRIVATE_PATH_PREFIX ...]
# Silent on success. Failures print only a risk type and an escaped app-relative path.
# Requires macOS Bash, find, grep, mktemp and tr. Does not follow app symlinks.
check_release_privacy() {
    local app_arg="${1-}" app_root inventory entry relative base lower risk
    local prefix status failed=0
    local -a patterns kinds
    if [ "$#" -eq 0 ]; then
        printf 'release-privacy: invalid-input %q\n' '.' >&2
        return 2
    fi
    shift
    for prefix in "$@"; do
        case "$prefix" in
            /*) ;;
            *) printf 'release-privacy: invalid-prefix %q\n' '.' >&2; return 2 ;;
        esac
        case "$prefix" in
            *$'\n'*|*$'\r'*) printf 'release-privacy: invalid-prefix %q\n' '.' >&2; return 2 ;;
        esac
    done
    while [ "$app_arg" != / ] && [[ "$app_arg" == */ ]]; do app_arg="${app_arg%/}"; done
    if [ -L "$app_arg" ]; then
        printf 'release-privacy: symlink %q\n' '.' >&2
        return 1
    fi
    if [ ! -d "$app_arg" ] || ! app_root=$(cd -P -- "$app_arg" 2>/dev/null && pwd -P); then
        printf 'release-privacy: invalid-app %q\n' '.' >&2
        return 2
    fi
    if ! inventory=$(mktemp "${TMPDIR:-/tmp}/ucas-release-privacy.XXXXXX" 2>/dev/null); then
        printf 'release-privacy: scan-error %q\n' '.' >&2
        return 2
    fi
    if ! find "$app_root" -print0 > "$inventory" 2>/dev/null; then
        rm -f -- "$inventory" >/dev/null 2>&1 || :
        printf 'release-privacy: scan-error %q\n' '.' >&2
        return 2
    fi
    patterns=('/(Users|home)/[^/[:cntrl:]]+/' '/(private/)?var/folders')
    kinds=('local-home-path' 'local-temp-path')
    while IFS= read -r -d '' entry; do
        relative="${entry#"$app_root"/}"
        [ "$entry" != "$app_root" ] || relative='.'
        if [ -L "$entry" ]; then
            printf 'release-privacy: symlink %q\n' "$relative" >&2
            failed=1
            continue
        fi
        [ ! -d "$entry" ] || continue
        if [ ! -f "$entry" ]; then
            printf 'release-privacy: unsupported-file %q\n' "$relative" >&2
            failed=1
            continue
        fi
        base="${entry##*/}"
        if ! lower=$(printf '%s' "$base" | LC_ALL=C tr '[:upper:]' '[:lower:]'); then
            printf 'release-privacy: scan-error %q\n' "$relative" >&2
            failed=1
            continue
        fi
        risk=''
        case "$lower" in
            *.mobileprovision|*.provisionprofile) risk='embedded-provisioning' ;;
            *.p12|*.p8|*.pfx|*.key|*.pem) risk='private-key-file' ;;
            signing.local.xcconfig) risk='local-signing-config' ;;
            .env|.env.*) risk='environment-file' ;;
            .ds_store|._*) risk='finder-metadata' ;;
            *.log|*.log.*|*.logs|*.trace|*.crash|*.dmp) risk='log-file' ;;
        esac
        if [ -n "$risk" ]; then
            printf 'release-privacy: %s %q\n' "$risk" "$relative" >&2
            failed=1
            continue
        fi
        # -a scans NUL-containing binaries; avoid -q so late read errors remain errors.
        for status in 0 1; do
            if LC_ALL=C grep -aE -- "${patterns[$status]}" "$entry" >/dev/null 2>&1; then
                printf 'release-privacy: %s %q\n' "${kinds[$status]}" "$relative" >&2
                failed=1
            else
                case "$?" in
                    1) ;;
                    *) printf 'release-privacy: scan-error %q\n' "$relative" >&2; failed=1 ;;
                esac
            fi
        done
        for prefix in "$@"; do
            if LC_ALL=C grep -aF -- "$prefix" "$entry" >/dev/null 2>&1; then
                printf 'release-privacy: private-path-prefix %q\n' "$relative" >&2
                failed=1
            else
                case "$?" in
                    1) ;;
                    *) printf 'release-privacy: scan-error %q\n' "$relative" >&2; failed=1 ;;
                esac
            fi
        done
    done < "$inventory"
    if ! rm -f -- "$inventory" 2>/dev/null; then
        printf 'release-privacy: scan-error %q\n' '.' >&2
        return 2
    fi
    return "$failed"
}

publish_artifact() {
    local source="$1"
    local name="$2"
    local artifacts_dir="$3"
    local publish_dir="$4"
    if [[ ! -s "$source" ]]; then
        printf '没有生成预期产物：%s\n' "$source" >&2
        return 1
    fi
    # Finish copying and hashing before replacing a previous output.
    cp "$source" "$publish_dir/$name"
    (
        cd "$publish_dir"
        /usr/bin/shasum -a 256 "$name" > "$name.sha256"
    )
    mv -f "$publish_dir/$name" "$artifacts_dir/$name"
    mv -f "$publish_dir/$name.sha256" "$checksums_dir/$name.sha256"
}

export_ios() {
    local derived_data="$package_dir/iOS-DerivedData"
    local payload_dir="$package_dir/Payload"
    local app_path="$payload_dir/UCASSignIn.app"
    local archive_path="$package_dir/$ios_name"
    local binary signature_info
    local binary_count=0

    # Build device products without using the project's signing configuration.
    xcodebuild -project "$apple_root/UCASSignIn.xcodeproj" \
        -scheme UCASSignIn -configuration Release -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$derived_data" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= \
        "${privacy_build_args[@]}" build

    mkdir -p "$payload_dir"
    /usr/bin/ditto --norsrc --noextattr --noqtn \
        "$derived_data/Build/Products/Release-iphoneos/UCASSignIn.app" "$app_path"
    check_apple_info_version "$app_path/Info.plist"
    check_apple_info_version "$app_path/PlugIns/UCASSignInWidget.appex/Info.plist"
    /usr/bin/find "$app_path" -type f \
        \( -name embedded.mobileprovision -o -name embedded.provisionprofile \) -delete
    /usr/bin/find "$app_path" -type d -name _CodeSignature -prune -exec rm -rf {} +

    # Remove even linker-generated ad-hoc signatures, including nested code.
    while IFS= read -r -d '' binary; do
        if /usr/bin/file -b "$binary" | grep -q 'Mach-O'; then
            binary_count=$((binary_count + 1))
            /usr/bin/lipo "$binary" -verify_arch arm64
            if /usr/bin/codesign --display "$binary" > /dev/null 2>&1; then
                /usr/bin/codesign --remove-signature "$binary"
            fi
            if signature_info="$(LC_ALL=C /usr/bin/codesign --display "$binary" 2>&1)"; then
                printf 'IPA 导出失败：仍包含签名：%s\n' "$binary" >&2
                return 1
            fi
            if ! printf '%s\n' "$signature_info" | grep -Fq 'code object is not signed at all'; then
                printf 'IPA 导出失败：无法确认无签名状态：%s\n' "$binary" >&2
                return 1
            fi
        fi
    done < <(/usr/bin/find "$app_path" -type f -print0)
    if [[ "$binary_count" -eq 0 ]]; then
        printf 'IPA 导出失败：未找到真机可执行文件。\n' >&2
        return 1
    fi

    check_release_privacy "$app_path" "$repo_root" "$package_dir"
    /usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$payload_dir" "$archive_path"
    publish_artifact "$archive_path" "$ios_name" \
        "$ios_artifacts_dir" "$ios_publish_dir"
}

export_macos() {
    local derived_data="$package_dir/macOS-DerivedData"
    local app_path="$package_dir/果壳签到.app"
    local archive_path="$package_dir/$macos_name"
    local installer_path="$package_dir/$macos_pkg_name"
    local library binary signature_info

    # Build both architectures in a fresh directory without certificate signing.
    xcodebuild -project "$apple_root/UCASSignIn.xcodeproj" \
        -scheme UCASSignInMac -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= \
        ENABLE_APP_SANDBOX=NO ENABLE_HARDENED_RUNTIME=NO \
        "${privacy_build_args[@]}" build

    /usr/bin/ditto --norsrc --noextattr --noqtn \
        "$derived_data/Build/Products/Release/UCASSignInMac.app" "$app_path"
    check_apple_info_version "$app_path/Contents/Info.plist"
    check_apple_info_version "$app_path/Contents/PlugIns/UCASSignInMacWidget.appex/Contents/Info.plist"
    # Sign nested code first, then the widget and its containing application.
    shopt -s nullglob
    for library in "$app_path"/Contents/MacOS/*.dylib \
        "$app_path"/Contents/PlugIns/*.appex/Contents/MacOS/*.dylib; do
        /usr/bin/codesign --force --timestamp=none --sign - "$library"
    done
    /usr/bin/codesign --force --timestamp=none --sign - \
        "$app_path/Contents/PlugIns/UCASSignInMacWidget.appex"
    /usr/bin/codesign --force --timestamp=none --sign - "$app_path"
    /usr/bin/codesign --verify --deep --strict "$app_path"

    while IFS= read -r -d '' binary; do
        if /usr/bin/file -b "$binary" | grep -q 'Mach-O'; then
            /usr/bin/lipo "$binary" -verify_arch arm64 x86_64
            signature_info="$(/usr/bin/codesign --display --verbose=4 "$binary" 2>&1)"
            if ! printf '%s\n' "$signature_info" | grep -Fxq 'Signature=adhoc'; then
                printf 'macOS 导出失败：预期临时签名：%s\n' "$binary" >&2
                return 1
            fi
        fi
    done < <(/usr/bin/find "$app_path" -type f -print0)

    check_release_privacy "$app_path" "$repo_root" "$package_dir"
    /usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$app_path" "$archive_path"
    /usr/bin/productbuild --component "$app_path" /Applications "$installer_path"
    publish_artifact "$archive_path" "$macos_name" \
        "$macos_artifacts_dir" "$macos_publish_dir"
    publish_artifact "$installer_path" "$macos_pkg_name" \
        "$macos_artifacts_dir" "$macos_publish_dir"
}

run_export() {
    local label="$1"
    local name="$2"
    local log="$3"
    local exporter="$4"
    local artifacts_dir="$5"
    local additional_name="${6-}"
    local status
    printf '\n%s\n构建日志：%s\n' "$label" "$log"
    # Keep the subshell outside an if/! condition, so errexit also applies
    # inside the export functions. A failed platform must not report success.
    set +e
    ( set -e; "$exporter" ) > "$log" 2>&1
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        printf '已生成：%s\n校验文件：%s/%s.sha256\n' \
            "$artifacts_dir/$name" "$checksums_dir" "$name"
        if [[ -n "$additional_name" ]]; then
            printf '已生成：%s\n校验文件：%s/%s.sha256\n' \
                "$artifacts_dir/$additional_name" "$checksums_dir" "$additional_name"
        fi
    else
        failed=1
        printf '生成失败，请查看日志：%s\n' "$log" >&2
        tail -n 20 "$log" >&2
    fi
}

run_export '[1/2] 生成 iOS IPA（未签名）' "$ios_name" \
    "$ios_logs_dir/release-ios.log" export_ios "$ios_artifacts_dir"
run_export '[2/2] 生成 macOS ZIP 和 PKG（Intel + Apple Silicon，App 临时签名）' "$macos_name" \
    "$macos_logs_dir/release-macos.log" export_macos "$macos_artifacts_dir" "$macos_pkg_name"

if [[ "$failed" -ne 0 ]]; then
    printf '\n部分产物生成失败，已成功的产物仍保存在版本目录。\n' >&2
    exit 1
fi
printf '\nApple 发布包已生成：%s\n' "$release_root"
printf 'IPA 需要由签名或侧载工具签名后安装。\n'
