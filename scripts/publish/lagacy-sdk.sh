#!/bin/bash
set -euo pipefail

if [[ "$#" -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
    printf '用法：%s [--signed]\n' "$0"
    printf '使用 Xcode 16.4 生成带 lagacy-sdk 标记的 iOS 和 macOS 安装包。\n'
    printf '可用 DEVELOPER_DIR 指定 Xcode 安装位置，使用 --signed 执行正式签名和公证。\n'
    exit 0
fi

publish_dir="$(cd "$(dirname "$0")" && pwd)"
export UCAS_APPLE_SDK=lagacy-sdk
exec "$publish_dir/platforms/apple.sh" "$@"
