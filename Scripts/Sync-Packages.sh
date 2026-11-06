#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:?请指定 OpenWrt 源码目录}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/immortalwrt-base-packages.patch"

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
	printf '%s\n' '基础软件包更新已应用'
	exit 0
fi

git -C "$SOURCE_DIR" apply --check "$PATCH_FILE"
git -C "$SOURCE_DIR" apply "$PATCH_FILE"
printf '%s\n' '基础软件包更新已应用；内核与设备配置保持不变'
