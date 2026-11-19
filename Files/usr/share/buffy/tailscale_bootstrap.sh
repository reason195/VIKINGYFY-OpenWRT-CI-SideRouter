#!/bin/sh
# SPDX-License-Identifier: MIT
# tailscale_bootstrap.sh - 补齐 Tailscale 静态二进制、拉起服务、按需登录
#
# 为什么需要：本仓库默认 sysupgrade -n（不保留配置刷机），/overlay 每次清空；
# 而 Tailscale 静态包解压后约 40MB，烧进 squashfs 会显著增大镜像。折中方案是
# 二进制放 /overlay，由本脚本幂等补齐：
#   1. 二进制缺失 → 下载官方静态包解压到 /overlay/tailscale
#   2. 服务未运行 → /etc/init.d/tailscaled start
#   3. 未登录且注入了 TAILSCALE_AUTHKEY → tailscale up（子网路由 + 不接管 DNS）
#
# 幂等：二进制在、服务在跑、已登录 → 立即退出（cron 每 10 分钟一次，开销可忽略）。
# 日志：/tmp/tailscale_bootstrap.log
#
# --accept-dns=false 必加：否则 Tailscale 会把系统 DNS 改成 100.100.100.100，
# 摧毁 dnsmasq → OpenClash(127.0.0.1#7874) 的分流链路（旁路由的 DNS 架构是硬约束）。
# --advertise-routes 让手机/电脑在外网可直接访问 192.168.1.0/24（SSH、管理页、服务）。

LOG=/tmp/tailscale_bootstrap.log
TS_DIR=/overlay/tailscale
TS_SOCK=/var/run/tailscale/tailscaled.sock
# 固定版本而非 latest：latest 会随上游滚动，出问题难回滚；升级时改这里并刷机验证。
# 包名里的 arm64 对应 jdcloud_re-cs-07（IPQ60xx / aarch64），换设备需同步改。
TS_VERSION="${TS_VERSION:-1.104.7}"
TS_ROUTES="${TS_ROUTES:-192.168.1.0/24}"
TS_AUTHKEY="@@TAILSCALE_AUTHKEY@@"

. /usr/share/buffy/lib-buffy.sh

ts() { "$TS_DIR/tailscale" --socket="$TS_SOCK" "$@"; }

fetch() { # $1=URL $2=输出文件；curl 优先，busybox wget 兜底
	if command -v curl >/dev/null 2>&1; then
		curl -fSL -m 300 -o "$2" "$1" 2>>"$LOG"
	else
		wget -q -T 300 -O "$2" "$1" 2>>"$LOG"
	fi
}

install_binaries() {
	log "下载 Tailscale $TS_VERSION 静态包（pkgs.tailscale.com 走代理，失败由 cron 重试）"
	_tmp="/tmp/tailscale.$$"
	mkdir -p "$_tmp" || return 1
	_ok=''
	# 最多等 10 分钟（30 × 20s）：刚开机时 OpenClash 可能还没就绪
	_n=0
	while [ "$_n" -lt 30 ]; do
		_n=$((_n + 1))
		if fetch "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_arm64.tgz" "$_tmp/ts.tgz" \
			&& tar xzf "$_tmp/ts.tgz" -C "$_tmp" 2>>"$LOG"; then
			_ok=1
			break
		fi
		log "第 $_n 次下载失败，20 秒后重试"
		sleep 20
	done
	if [ -z "$_ok" ]; then
		log "下载失败 30 次，放弃本轮（cron 10 分钟后重试）"
		rm -rf "$_tmp"
		return 1
	fi
	mkdir -p "$TS_DIR"
	cp "$_tmp"/tailscale_*/tailscale "$_tmp"/tailscale_*/tailscaled "$TS_DIR/" || {
		log "解压后未找到二进制，清理"
		rm -rf "$_tmp"
		return 1
	}
	chmod +x "$TS_DIR/tailscale" "$TS_DIR/tailscaled"
	rm -rf "$_tmp"
	log "安装完成：$("$TS_DIR/tailscaled" --version 2>/dev/null | head -1)"
}

# ---- 1. 二进制 ----
[ -x "$TS_DIR/tailscaled" ] && [ -x "$TS_DIR/tailscale" ] || install_binaries || exit 1

# ---- 2. 服务 ----
if ! pidof tailscaled >/dev/null 2>&1; then
	log "tailscaled 未运行，启动"
	/etc/init.d/tailscaled start
	sleep 3
	pidof tailscaled >/dev/null 2>&1 || {
		log "tailscaled 启动失败，退出（下一轮重试）"
		exit 1
	}
fi

# ---- 3. 登录（仅当注入了预认证密钥）----
if ts status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
	exit 0
fi
if [ -z "$TS_AUTHKEY" ]; then
	# 未配置密钥：只装不登录，管理员自行 `tailscale up` 走网页授权（一次性）
	log "未配置 TAILSCALE_AUTHKEY，跳过自动登录"
	exit 0
fi
log "未登录，使用预认证密钥上线（路由 $TS_ROUTES）"
_host=$(uci -q get system.@system[0].hostname)
if ts up --authkey="$TS_AUTHKEY" --advertise-routes="$TS_ROUTES" \
	--accept-dns=false --hostname="${_host:-openwrt}" --timeout=60s 2>>"$LOG"; then
	log "登录成功：$(ts ip -4 2>/dev/null | head -1)"
else
	log "登录失败（密钥过期/已被吊销？），本轮放弃"
fi

exit 0
