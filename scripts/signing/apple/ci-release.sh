#!/bin/bash
# Only called from the manually dispatched, protected-environment release job.
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
set +x
if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_EVENT_NAME:-}" != workflow_dispatch || "${GITHUB_REF:-}" != refs/heads/main ]]; then
    printf 'Signed CI release requires a manual dispatch on main.\n' >&2
    exit 2
fi
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
for name in APPLE_CERTIFICATES_P12_BASE64 APPLE_CERTIFICATES_PASSWORD APPLE_PROFILES_ZIP_BASE64 APPLE_ARCHIVE_XCCONFIG_BASE64 APPLE_IOS_EXPORT_OPTIONS_BASE64 APPLE_MACOS_EXPORT_OPTIONS_BASE64 APPLE_NOTARY_KEY_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID UCAS_APPLE_TEAM_ID UCAS_MACOS_INSTALLER_IDENTITY RUNNER_TEMP; do
    [[ -n "${!name:-}" ]] || { printf 'Missing required signing secret: %s\n' "$name" >&2; exit 2; }
done
umask 077
signing_dir="$(mktemp -d "$RUNNER_TEMP/ucas-signing.XXXXXX")"
export UCAS_CI_SIGNING_DIR="$signing_dir"
keychain="$signing_dir/release.keychain-db"
# Restore the original search list rather than assuming a login keychain exists.
/usr/bin/security list-keychains -d user > "$signing_dir/original-keychains.txt"
cleanup() {
    python3 - <<'PY'
import os, pathlib, shlex, subprocess
root = pathlib.Path(os.environ['UCAS_CI_SIGNING_DIR'])
keychains = shlex.split((root / 'original-keychains.txt').read_text())
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *keychains], capture_output=True)
for path in (root / 'installed-profiles.txt').read_text().splitlines() if (root / 'installed-profiles.txt').exists() else []:
    pathlib.Path(path).unlink(missing_ok=True)
PY
    /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || :
    rm -rf -- "$signing_dir"
}
trap cleanup EXIT
prepare() {
    python3 - <<'PY'
import base64, os, pathlib, zipfile
root = pathlib.Path(os.environ['UCAS_CI_SIGNING_DIR'])
for name, filename in {
    'APPLE_CERTIFICATES_P12_BASE64': 'identities.p12',
    'APPLE_PROFILES_ZIP_BASE64': 'profiles.zip',
    'APPLE_ARCHIVE_XCCONFIG_BASE64': 'archive.xcconfig',
    'APPLE_IOS_EXPORT_OPTIONS_BASE64': 'ios-export.plist',
    'APPLE_MACOS_EXPORT_OPTIONS_BASE64': 'mac-export.plist',
    'APPLE_NOTARY_KEY_BASE64': 'notary.p8',
}.items():
    (root / filename).write_bytes(base64.b64decode(os.environ[name], validate=True))
profiles = root / 'profiles'
profiles.mkdir()
with zipfile.ZipFile(root / 'profiles.zip') as archive:
    for i, member in enumerate(archive.infolist()):
        if member.is_dir():
            continue
        extension = pathlib.Path(member.filename).suffix
        if extension not in ('.mobileprovision', '.provisionprofile') or member.file_size > 4_000_000:
            raise ValueError('Only provisioning profiles may be included in profile ZIP')
        # Flatten names to prevent ZIP traversal and collisions; no archive paths are trusted.
        (profiles / f'{i}{extension}').write_bytes(archive.read(member))
PY
    local password
    password="$(/usr/bin/openssl rand -hex 32)"
    /usr/bin/security create-keychain -p "$password" "$keychain"
    /usr/bin/security set-keychain-settings -lut 21600 "$keychain"
    /usr/bin/security unlock-keychain -p "$password" "$keychain"
    /usr/bin/security import "$signing_dir/identities.p12" -k "$keychain" \
        -P "$APPLE_CERTIFICATES_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild
    /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
    /usr/bin/security list-keychains -d user -s "$keychain"
    python3 - <<'PY'
import os, pathlib, plistlib, re, subprocess
root = pathlib.Path(os.environ['UCAS_CI_SIGNING_DIR'])
# Both locations are needed across the supported Xcode releases.
locations = [pathlib.Path.home() / 'Library/MobileDevice/Provisioning Profiles', pathlib.Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles']
with (root / 'installed-profiles.txt').open('w') as installed:
    for profile in (root / 'profiles').iterdir():
        decoded = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(profile)], check=True, capture_output=True).stdout
        uuid = plistlib.loads(decoded)['UUID']
        if not re.fullmatch(r'[A-Fa-f0-9-]{36}', uuid):
            raise ValueError('Invalid profile UUID')
        for location in locations:
            location.mkdir(parents=True, exist_ok=True)
            target = location / (uuid + profile.suffix)
            if target.exists():
                if target.read_bytes() != profile.read_bytes():
                    raise ValueError('Refusing to overwrite an existing profile')
            else:
                with target.open('xb') as destination:
                    destination.write(profile.read_bytes())
                installed.write(str(target) + '\n')
                installed.flush()
PY
    xcrun notarytool store-credentials ucas-ci-notary --key "$signing_dir/notary.p8" \
        --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --keychain "$keychain"
}
set +e
(set -e; prepare) > "$signing_dir/prepare.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
    printf 'Signing setup failed; check the configured certificates, profiles and notary credentials.\n' >&2
    exit "$status"
fi
export UCAS_APPLE_ARCHIVE_XCCONFIG="$signing_dir/archive.xcconfig"
export UCAS_IOS_EXPORT_OPTIONS="$signing_dir/ios-export.plist"
export UCAS_MACOS_EXPORT_OPTIONS="$signing_dir/mac-export.plist"
export UCAS_NOTARY_PROFILE=ucas-ci-notary
export UCAS_NOTARY_KEYCHAIN="$keychain"
# Avoid exposing certificate/notary material to build processes via inherited variables.
unset APPLE_CERTIFICATES_P12_BASE64 APPLE_CERTIFICATES_PASSWORD APPLE_PROFILES_ZIP_BASE64 \
    APPLE_ARCHIVE_XCCONFIG_BASE64 APPLE_IOS_EXPORT_OPTIONS_BASE64 APPLE_MACOS_EXPORT_OPTIONS_BASE64 \
    APPLE_NOTARY_KEY_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID
case "${UCAS_SIGNED_TOOLCHAIN:-stable}" in
    stable) bash "$repo_root/scripts/publish/all-on-macos.sh" --signed ;;
    latest) bash "$repo_root/scripts/publish/latest-apple-sdk.sh" --signed ;;
    *) printf 'Unsupported signing toolchain.\n' >&2; exit 2 ;;
esac
