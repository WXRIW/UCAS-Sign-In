#!/bin/bash

# Select Xcode for this process and its children, including xcrun and xcodebuild.
select_apple_toolchain() {
    local candidate reported
    case "${UCAS_APPLE_SDK:-stable}" in
        stable)
            DEVELOPER_DIR="$(python3 "$(dirname "${BASH_SOURCE[0]}")/apple_xcode.py" installed \
                "${DEVELOPER_DIR:-}" "$(env -u DEVELOPER_DIR xcode-select --print-path 2>/dev/null || :)" \
                /Applications/*.app "$HOME"/Applications/*.app)" || return 1
            apple_sdk_suffix=''
            ;;
        lagacy-sdk)
            apple_sdk_suffix=-lagacy-sdk
            if [[ -z "${DEVELOPER_DIR:-}" ]]; then
                candidate=/Applications/Xcode_16.4.app/Contents/Developer
                if [[ -d "$candidate" ]]; then
                    DEVELOPER_DIR="$candidate"
                else
                    DEVELOPER_DIR="$(xcode-select --print-path)" || return 1
                fi
            fi
            ;;
        *)
            printf '未知的 Apple 打包选项：%s\n' "$UCAS_APPLE_SDK" >&2
            return 2
            ;;
    esac

    export DEVELOPER_DIR
    reported="$(xcodebuild -version)" || return 1
    if [[ -n "$apple_sdk_suffix" && "${reported%%$'\n'*}" != 'Xcode 16.4' ]]; then
        printf 'lagacy-sdk 需要 Xcode 16.4，当前为 %s。请用 DEVELOPER_DIR 指定对应的 Xcode。\n' \
            "${reported%%$'\n'*}" >&2
        return 1
    fi
    printf '%s\n' "$reported"
}
