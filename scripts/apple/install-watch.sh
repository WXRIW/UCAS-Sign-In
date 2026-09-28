#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
    cat <<'EOF'
用法：scripts/apple/install-watch.sh [IPA 路径] [Apple Watch 设备 ID]

先将同一 IPA 安装到配对 iPhone。保持手表解锁、开发者模式开启，
并让 Mac 和手表处于同一网络。脚本会从 IPA 提取手表 App，
通过 Xcode 的 devicectl 直接安装并核对版本。

不传 IPA 路径时，使用 artifacts/ios 下与 eng/version.json 对应的手表 IPA。
同时连接多只手表时，请传第二个参数指定设备 ID。
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

for command in xcrun python3 unzip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "缺少命令：$command" >&2
        exit 1
    fi
done

if [[ $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

if [[ $# -ge 1 ]]; then
    ipa_path="$1"
else
    version_tag="$(python3 - "$repo_root/eng/version.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as file:
    release = json.load(file)
print(f"{release['version']}-{release['build']}")
PY
)"
    ipa_path="$repo_root/artifacts/ios/GuokeSignIn-Watch-$version_tag.ipa"
fi

if [[ ! -f "$ipa_path" ]]; then
    echo "找不到 IPA：$ipa_path" >&2
    echo "可把 IPA 路径作为第一个参数传给脚本。" >&2
    exit 1
fi

work_dir="$(mktemp -d /tmp/ucas-install-watch.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

unzip -q "$ipa_path" -d "$work_dir"
watch_app="$(python3 - "$work_dir/Payload" <<'PY'
from pathlib import Path
import sys
apps = list(Path(sys.argv[1]).glob('*.app/Watch/*.app'))
if len(apps) != 1:
    raise SystemExit(f'IPA 中应有一个内嵌手表 App，实际找到 {len(apps)} 个')
print(apps[0])
PY
)"

watch_info="$watch_app/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$watch_info")"
expected_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$watch_info")"
expected_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$watch_info")"

xcrun devicectl list devices --json-output "$work_dir/devices.json" >/dev/null
watch_id="$(python3 - "$work_dir/devices.json" "${2:-}" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as file:
    devices = json.load(file)['result']['devices']
requested = sys.argv[2]
watches = [device for device in devices
           if device.get('hardwareProperties', {}).get('deviceType') == 'appleWatch'
           and device.get('connectionProperties', {}).get('tunnelState') == 'connected']
if requested:
    watches = [device for device in watches
               if requested in (device.get('identifier'),
                                device.get('hardwareProperties', {}).get('udid'),
                                device.get('deviceProperties', {}).get('name'))]
if len(watches) != 1:
    raise SystemExit(f'需要一只已连接的 Apple Watch；当前匹配 {len(watches)} 只。'
                     '请解锁手表、确认开发者模式和网络连接，再重试。')
print(watches[0]['identifier'])
PY
)"

echo "安装 $bundle_id $expected_version ($expected_build) 到 Apple Watch…"
xcrun devicectl device install app --device "$watch_id" --timeout 90 "$watch_app"
xcrun devicectl device info apps --device "$watch_id" --bundle-id "$bundle_id" \
    --json-output "$work_dir/installed.json" >/dev/null
python3 - "$work_dir/installed.json" "$expected_version" "$expected_build" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as file:
    apps = json.load(file)['result']['apps']
if len(apps) != 1:
    raise SystemExit('安装命令已返回，但未能在手表应用列表中确认该 App。')
app = apps[0]
if (app.get('version'), app.get('bundleVersion')) != (sys.argv[2], sys.argv[3]):
    raise SystemExit(f"版本不一致：手表上为 {app.get('version')} ({app.get('bundleVersion')})")
print(f"安装成功：{app['name']} {app['version']} ({app['bundleVersion']})")
PY
