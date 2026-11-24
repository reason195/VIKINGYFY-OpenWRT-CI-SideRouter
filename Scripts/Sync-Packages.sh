#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:?请指定 OpenWrt 源码目录}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/immortalwrt-base-packages.patch"

if [ ! -f "$PATCH_FILE" ]; then
	printf 'ERROR: 找不到补丁文件 %s\n' "$PATCH_FILE" >&2
	exit 1
fi

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
	printf '%s\n' '基础软件包更新已应用'
	exit 0
fi

# 上游分支可能已自带这些更新：owrt 分支的 base packages 版本领先 main，
# 补丁想改的文件要么已存在（already exists）、要么上下文已演进（does not apply）。
# 此时补丁无法应用属正常情况，跳过而不是让整个构建失败；main 分支仍按原逻辑应用。
if ! git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
	printf '%s\n' '基础软件包更新补丁不适用（源码已包含或已演进），跳过'
	exit 0
fi

git -C "$SOURCE_DIR" apply "$PATCH_FILE"
printf '%s\n' '基础软件包更新已应用；内核与设备配置保持不变'
