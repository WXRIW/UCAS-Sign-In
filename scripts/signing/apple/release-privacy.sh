#!/bin/bash
# Signed-only scanner. Call verify-distribution.py first to authenticate profiles.
# The unsigned packagers retain their original, stricter profile prohibition.
# Usage: check_signed_release_privacy APP_PATH [PRIVATE_PATH_PREFIX ...]
# Silent on success. Failures print only a risk type and an escaped app-relative path.
# Requires macOS Bash, find, grep, mktemp and tr. Does not follow app symlinks.
check_signed_release_privacy() {
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
            *.mobileprovision|*.provisionprofile)
                # Only verified Xcode bundle locations may contain distribution profiles.
                case "$relative" in
                    embedded.mobileprovision|PlugIns/UCASSignInWidget.appex/embedded.mobileprovision|Contents/embedded.provisionprofile|Contents/PlugIns/UCASSignInMacWidget.appex/Contents/embedded.provisionprofile) ;;
                    *) risk='unexpected-provisioning' ;;
                esac
                ;;
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
