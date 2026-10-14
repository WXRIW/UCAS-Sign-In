#!/bin/bash
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
# Explicit distribution entry point; never falls back to unsigned packaging.
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
apple_root="$repo_root/apps/apple"
. "$repo_root/scripts/lib/release-version.sh"
. "$repo_root/scripts/signing/apple/release-privacy.sh"
latest_suffix=''
if [[ "$#" -eq 1 && "$1" == --latest-sdk ]]; then
    latest_suffix=-latest-sdk
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: %s [--latest-sdk]\n' "$0" >&2
    exit 2
fi

require_variable() {
    if [[ -z "${!1:-}" ]]; then
        printf 'Signed Apple release requires %s; see scripts/publish/README.md.\n' "$1" >&2
        exit 2
    fi
}
for setting in UCAS_APPLE_TEAM_ID UCAS_IOS_EXPORT_OPTIONS UCAS_MACOS_EXPORT_OPTIONS UCAS_MACOS_INSTALLER_IDENTITY UCAS_NOTARY_PROFILE; do
    require_variable "$setting"
done
for options in "$UCAS_IOS_EXPORT_OPTIONS" "$UCAS_MACOS_EXPORT_OPTIONS"; do
    if [[ ! -f "$options" ]]; then
        printf 'Signed Apple release: missing export options file.\n' >&2
        exit 2
    fi
done
python3 "$repo_root/scripts/signing/apple/verify-distribution.py" options \
    "$UCAS_IOS_EXPORT_OPTIONS" "$UCAS_MACOS_EXPORT_OPTIONS" "$UCAS_APPLE_TEAM_ID"
case "$UCAS_MACOS_INSTALLER_IDENTITY" in
    'Developer ID Installer: '*) ;;
    *) printf 'A Developer ID Installer identity is required.\n' >&2; exit 2 ;;
esac
archive_config=()
if [[ -n "${UCAS_APPLE_ARCHIVE_XCCONFIG:-}" ]]; then
    [[ -f "$UCAS_APPLE_ARCHIVE_XCCONFIG" ]] || { printf 'Missing archive xcconfig.\n' >&2; exit 2; }
    archive_config=(-xcconfig "$UCAS_APPLE_ARCHIVE_XCCONFIG")
fi
language_args=()
if [[ -n "$latest_suffix" ]]; then
    if [[ ! "${UCAS_LATEST_SWIFT_LANGUAGE_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
        printf 'Latest SDK signing requires a valid detected Swift language version.\n' >&2
        exit 2
    fi
    language_args=("SWIFT_VERSION=$UCAS_LATEST_SWIFT_LANGUAGE_VERSION")
fi
notary_args=(--keychain-profile "$UCAS_NOTARY_PROFILE")
if [[ -n "${UCAS_NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$UCAS_NOTARY_KEYCHAIN")
fi
release_root="$repo_root/artifacts/publish/$release_version"
mkdir -p "$release_root/logs" "$release_root/sha256"
umask 077
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/ucas-signed-release.XXXXXX")"
trap 'rm -rf -- "$package_dir"' EXIT
# Build logs stay local and may contain signing identities. CI does not upload them.
log="$release_root/logs/release-apple${latest_suffix}-signed.log"
privacy_build_args=(
    DEBUG_INFORMATION_FORMAT=
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO
    SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO
    COMPILER_INDEX_STORE_ENABLE=NO
    'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map "$(SRCROOT)=/src/UCAS-Sign-In" -debug-prefix-map "$(SRCROOT)=/src/UCAS-Sign-In" -file-prefix-map "$(HOME)=/build-user" -debug-prefix-map "$(HOME)=/build-user" -file-compilation-dir /src/UCAS-Sign-In -Xfrontend -no-serialize-debugging-options'
    'OTHER_CFLAGS=$(inherited) -ffile-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -fdebug-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -ffile-prefix-map="$(HOME)=/build-user"'
    'OTHER_CPLUSPLUSFLAGS=$(inherited) -ffile-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -fdebug-prefix-map="$(SRCROOT)=/src/UCAS-Sign-In" -ffile-prefix-map="$(HOME)=/build-user"'
)

build_distribution() {
    xcodebuild -project "$apple_root/UCASSignIn.xcodeproj" -scheme UCASSignIn \
        -configuration Release -destination 'generic/platform=iOS' \
        -archivePath "$package_dir/iOS.xcarchive" -derivedDataPath "$package_dir/iOS-build" \
        ${archive_config[@]+"${archive_config[@]}"} \
        DEVELOPMENT_TEAM="$UCAS_APPLE_TEAM_ID" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES ICLOUD_CONTAINER_ENVIRONMENT=Production APS_ENVIRONMENT=production \
        ${language_args[@]+"${language_args[@]}"} "${privacy_build_args[@]}" archive
    xcodebuild -exportArchive -archivePath "$package_dir/iOS.xcarchive" \
        -exportPath "$package_dir/iOS-export" -exportOptionsPlist "$UCAS_IOS_EXPORT_OPTIONS"
    shopt -s nullglob
    local ipas=("$package_dir/iOS-export/"*.ipa)
    [[ "${#ipas[@]}" -eq 1 ]] || { printf 'Expected exactly one exported IPA.\n' >&2; return 1; }
    /usr/bin/ditto -x -k "${ipas[0]}" "$package_dir/iOS-inspect"
    local ios_app="$package_dir/iOS-inspect/Payload/UCASSignIn.app"
    check_apple_info_version "$ios_app/Info.plist"
    check_apple_info_version "$ios_app/PlugIns/UCASSignInWidget.appex/Info.plist"
    python3 "$repo_root/scripts/signing/apple/verify-distribution.py" app "$ios_app" ios "$UCAS_APPLE_TEAM_ID"
    check_signed_release_privacy "$ios_app" "$repo_root" "$package_dir"

    xcodebuild -project "$apple_root/UCASSignIn.xcodeproj" -scheme UCASSignInMac \
        -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$package_dir/macOS.xcarchive" -derivedDataPath "$package_dir/macOS-build" \
        ${archive_config[@]+"${archive_config[@]}"} \
        DEVELOPMENT_TEAM="$UCAS_APPLE_TEAM_ID" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
        'CODE_SIGN_IDENTITY=Developer ID Application' ENABLE_HARDENED_RUNTIME=YES \
        ICLOUD_CONTAINER_ENVIRONMENT=Production APS_ENVIRONMENT=production \
        ${language_args[@]+"${language_args[@]}"} "${privacy_build_args[@]}" archive
    xcodebuild -exportArchive -archivePath "$package_dir/macOS.xcarchive" \
        -exportPath "$package_dir/macOS-export" -exportOptionsPlist "$UCAS_MACOS_EXPORT_OPTIONS"
    local apps=("$package_dir/macOS-export/"*.app)
    [[ "${#apps[@]}" -eq 1 ]] || { printf 'Expected exactly one exported Mac app.\n' >&2; return 1; }
    local mac_app="${apps[0]}"
    check_apple_info_version "$mac_app/Contents/Info.plist"
    check_apple_info_version "$mac_app/Contents/PlugIns/UCASSignInMacWidget.appex/Contents/Info.plist"
    python3 "$repo_root/scripts/signing/apple/verify-distribution.py" app "$mac_app" macos "$UCAS_APPLE_TEAM_ID"
    python3 "$repo_root/scripts/signing/apple/verify-distribution.py" pair "$ios_app" "$mac_app"
    check_signed_release_privacy "$mac_app" "$repo_root" "$package_dir"

    # Notarize and staple the app before making the final ZIP and installer.
    /usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$mac_app" "$package_dir/notarize.zip"
    xcrun notarytool submit "$package_dir/notarize.zip" "${notary_args[@]}" --wait --output-format json > "$package_dir/notary-app.json"
    python3 "$repo_root/scripts/signing/apple/verify-distribution.py" notary "$package_dir/notary-app.json"
    xcrun stapler staple "$mac_app"
    xcrun stapler validate "$mac_app"
    /usr/sbin/spctl --assess --type execute "$mac_app"
    local ios_name="UCAS-SignIn-$release_version-ios${latest_suffix}-signed.ipa"
    local mac_name="UCAS-SignIn-$release_version-macos${latest_suffix}-universal-signed.zip"
    local pkg_name="UCAS-SignIn-$release_version-macos${latest_suffix}-universal-signed.pkg"
    /usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$mac_app" "$package_dir/$mac_name"
    /usr/bin/productbuild --sign "$UCAS_MACOS_INSTALLER_IDENTITY" --timestamp \
        --component "$mac_app" /Applications "$package_dir/$pkg_name"
    /usr/sbin/pkgutil --check-signature "$package_dir/$pkg_name"
    xcrun notarytool submit "$package_dir/$pkg_name" "${notary_args[@]}" --wait --output-format json > "$package_dir/notary-pkg.json"
    python3 "$repo_root/scripts/signing/apple/verify-distribution.py" notary "$package_dir/notary-pkg.json"
    xcrun stapler staple "$package_dir/$pkg_name"
    xcrun stapler validate "$package_dir/$pkg_name"
    /usr/sbin/spctl --assess --type install "$package_dir/$pkg_name"
    # No output is promoted until both platforms and notarization have passed.
    cp "${ipas[0]}" "$package_dir/$ios_name"
    local name
    for name in "$ios_name" "$mac_name" "$pkg_name"; do
        (cd "$package_dir"; /usr/bin/shasum -a 256 "$name" > "$name.sha256")
        mv -f "$package_dir/$name" "$release_root/$name"
        mv -f "$package_dir/$name.sha256" "$release_root/sha256/$name.sha256"
    done
}
printf 'Building signed Apple packages; private local log: %s\n' "$log"
set +e
(set -e; build_distribution) > "$log" 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
    printf 'Signed release failed; inspect the local log. No unsigned fallback was attempted.\n' >&2
    exit "$status"
fi
printf 'Signed and notarized packages saved in %s\n' "$release_root"
