#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# health_check.sh - 路由器全面体检（非 OpenClash 项，旁路由形态）
# 检查：出口连通性(IPv4 经主路由) / DNS 解析 /
#       dnsmasq 备用上游 / 防火墙转发链路(lan forward + ip_forward + rp_filter) / 硬件流量卸载。
# 用法：手动 /usr/share/buffy/health_check.sh，或每日 cron（见 /etc/crontabs/root）。
# 任一 FAIL：退出码非 0 并推 ntfy/Telegram 告警；日志：/tmp/health_check.log

LOG="/tmp/health_check.log"

PASS=0
FAIL=0
REPORT=""

# 公共函数（log/notify/resolve/cert_expires_within 等）
. /usr/share/buffy/lib-buffy.sh

ok()  { PASS=$((PASS + 1)); REPORT="${REPORT}[OK]   $1\n"; log "[OK]   $1"; echo "[OK]   $1"; }
bad() { FAIL=$((FAIL + 1)); REPORT="${REPORT}[FAIL] $1\n"; log "[FAIL] $1"; echo "[FAIL] $1"; }
warn(){ REPORT="${REPORT}[WARN] $1\n"; log "[WARN] $1"; echo "[WARN] $1"; }

log "=== health_check: start ==="

# ---- 1. 出口连通性（旁路由：本机不拨号，一切经主路由） ----
if ip -4 route show default 2>/dev/null | grep -q 'default'; then
	ok "IPv4 默认路由存在"
	GW=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')
	if [ -n "$GW" ] && ping -4 -c 1 -W 2 "$GW" >/dev/null 2>&1; then
		ok "IPv4 网关可达 ($GW)"
	else
		bad "IPv4 网关不可达"
	fi
else
	bad "IPv4 默认路由缺失"
fi

if ping -4 -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
	ok "公网 IPv4 可达 (223.5.5.5)"
else
	bad "公网 IPv4 不可达"
fi

# 旁路由无 wan/wan6，也不发 RA；且内核在 forwarding=1 时不再采纳 RA，本机通常拿不到全局
# IPv6 地址与 v6 默认路由。客户端 IPv6 由主路由直接下发、不经本机，故只观测、不判失败。
if ip -6 route show default 2>/dev/null | grep -q default; then
	ok "本机存在 IPv6 默认路由"
else
	warn "本机无 IPv6 默认路由（旁路由预期：客户端 IPv6 走主路由，不经本机）"
fi

if resolve www.baidu.com 223.5.5.5; then
	ok "DNS 解析正常 (经 223.5.5.5)"
else
	bad "DNS 解析失败 (223.5.5.5)"
fi

# ---- 2. dnsmasq 备用上游 ----
# rc.local 写到生成的 dnsmasq conf 里的 conf-dir（本机为 /tmp/dnsmasq.<cfgid>.d，非 /tmp/dnsmasq.d），
# 用 glob 兜底定位真实路径，避免按固定目录查漏报。
FALLBACK=""
for f in /tmp/dnsmasq.*.d/60-fallback.conf /tmp/dnsmasq.d/60-fallback.conf /tmp/etc/dnsmasq.d/60-fallback.conf; do
	[ -s "$f" ] && FALLBACK="$f" && break
done
if [ -n "$FALLBACK" ]; then
	if grep -q '223.5.5.5' "$FALLBACK"; then
		ok "dnsmasq 备用上游已部署 ($FALLBACK)"
	else
		bad "dnsmasq 备用上游内容异常"
	fi
else
	bad "dnsmasq 备用上游缺失 (conf-dir/60-fallback.conf)"
fi

if [ -n "$(pidof dnsmasq 2>/dev/null)" ]; then
	ok "dnsmasq 进程运行中"
else
	bad "dnsmasq 未运行"
fi

if resolve www.baidu.com 127.0.0.1; then
	ok "本地 DNS 解析正常 (127.0.0.1)"
else
	bad "本地 DNS 解析失败 (127.0.0.1)"
fi

# ---- 3. 防火墙转发链路（旁路由） ----
# 旁路由形态下没有 wan/wan6 接口，但防火墙包默认生成的 wan 区域仍写着 network 'wan wan6'。
# 这种悬空引用会让 fw4 拒绝加载整张表——连 lan 转发一起失效，客户端全断且无明显报错。
# 92-buffy-firewall.sh 负责清除，这里验证清除结果与转发是否真的就位。
if nft list table inet fw4 >/dev/null 2>&1; then
	ok "fw4 nft 表已加载"
else
	bad "fw4 nft 表缺失（防火墙未运行 / 配置加载失败）"
fi

LAN_FWD=""
WAN_LEFT=""
i=0
while [ -n "$(uci -q get firewall.@zone[$i].name 2>/dev/null)" ]; do
	ZNAME=$(uci -q get firewall.@zone[$i].name)
	[ "$ZNAME" = "wan" ] && WAN_LEFT=1
	[ "$ZNAME" = "lan" ] && LAN_FWD=$(uci -q get firewall.@zone[$i].forward)
	i=$((i + 1))
done
if [ -n "$WAN_LEFT" ]; then
	bad "firewall 残留 wan 区域（引用已删除的 wan/wan6 接口）"
else
	ok "firewall 无 wan 区域残留"
fi
if [ "$LAN_FWD" = "ACCEPT" ]; then
	ok "lan 区域 forward=ACCEPT（客户端转发放行）"
else
	bad "lan 区域 forward 非 ACCEPT（当前: ${LAN_FWD:-未设置}，旁路由无法转发）"
fi

if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
	ok "IPv4 转发已开启"
else
	bad "IPv4 转发未开启（旁路由无法给客户端转发流量）"
fi

# 客户端流量从 br-lan 进、又从同一个 br-lan 出，严格反向路径过滤会把这类非对称包直接丢弃。
if [ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)" = "0" ]; then
	ok "IPv4 rp_filter 已关闭"
else
	bad "IPv4 rp_filter 未关闭（旁路由同口转发会丢包）"
fi

if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = "1" ]; then
	ok "IPv6 转发已开启"
else
	bad "IPv6 转发未开启"
fi

# ---- 4. 硬件流量卸载 ----
SW=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
HW=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
if [ "$SW" = "1" ] && [ "$HW" = "1" ]; then
	ok "流量卸载开关已开启（软件+硬件）"
elif [ "$HW" = "1" ]; then
	warn "仅开硬件卸载、缺软件开关（fw4 不会生成 flowtable）"
else
	bad "流量卸载未开启（软件:${SW:-0} 硬件:${HW:-0}）"
fi

if nft list flowtables 2>/dev/null | grep -q 'flowtable'; then
	if nft list flowtable inet fw4 ft 2>/dev/null | grep -q 'flags offload'; then
		ok "nft flowtable 已创建（hardware offload）"
	else
		warn "nft flowtable 已创建（软件卸载，无 offload 标志）"
	fi
else
	warn "nft flowtable 未创建"
fi

# ---- 汇总 ----
log "=== health_check: done (PASS=$PASS FAIL=$FAIL) ==="
if [ "$FAIL" -gt 0 ]; then
	notify "路由器体检异常" "$(printf '%b' "$REPORT" | head -c 2000)"
	exit 1
fi
exit 0
