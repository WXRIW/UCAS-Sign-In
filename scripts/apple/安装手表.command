#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/install-watch.sh" "$@"
result=$?
printf '\n按回车键关闭窗口…'
read -r _
exit "$result"
