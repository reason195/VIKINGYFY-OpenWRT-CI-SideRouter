#!/bin/sh
# 美国线路兜底切换（26.11.15 实机：优质服务商 4 个美国节点全掉线后，
# 「美国自动」仍停在已死的 [优]United States 02，[备] 节点健康却不被选中）。
# 每 2 分钟检查两个组：
#   1) 美国自动（url-test）：当前节点不在组延迟测试结果里 → 切到存活的 [备] 节点，
#      没有 [备] 就切到组内任一存活节点；
#   2) 美国策略（select）：若被手动钉在某个单节点且该节点已死 → 切回「美国自动」。
# 只动这两个组的选中项，不改订阅、不改规则；核心未运行时直接退出。
# 日志：/tmp/us_failover.log

API='http://127.0.0.1:9090'
LOG='/tmp/us_failover.log'
TEST_URL='https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204'

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# 防重入：上一轮延迟测试未结束时跳过本轮
LOCK='/tmp/us_failover.lock'
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

pidof clash >/dev/null 2>&1 || exit 0
P="$(uci -q get openclash.config.dashboard_password 2>/dev/null)"
[ -n "$P" ] || P="$(uci -q get openclash.@openclash[0].dashboard_password 2>/dev/null)"
[ -n "$P" ] || exit 0
A="Authorization: Bearer $P"

# $1=组名 $2=URL 编码组名 $3=兜底目标（可空）
check_group() {
	_now="$(curl -s -m4 -H "$A" "$API/proxies/$2" | sed -n 's/.*"now":"\([^"]*\)".*/\1/p')"
	[ -n "$_now" ] || return 0
	# 只在「当前选中项是具体节点」时检查；选中的是子组（如 美国自动）则交给子组自己处理
	case "$_now" in
		*US-Oracle*|*'[优]'*|*'[备]'*) ;;
		*) return 0 ;;
	esac

	_map="$(curl -s -m25 -H "$A" "$API/group/$2/delay?url=$TEST_URL&timeout=4000&expected=204" 2>/dev/null)"
	case "$_map" in
		''|*'"message":'*) log "$1: delay test empty/error, keep $_now"; return 0 ;;
	esac

	case "$_map" in
		*"\"$_now\":"*) return 0 ;;
	esac

	_target="$3"
	if [ -z "$_target" ]; then
		_target="$(printf '%s' "$_map" | tr ',' '\n' | grep -o '"[^"]*US-Oracle[^"]*":[0-9]' | head -n1 | sed 's/":[0-9]$//; s/^"//')"
	fi
	[ -n "$_target" ] || _target="$(printf '%s' "$_map" | tr ',' '\n' | grep -o '"[^"]*":[0-9]' | head -n1 | sed 's/":[0-9]$//; s/^"//')"
	[ -n "$_target" ] || { log "$1: no alive member, keep $_now"; return 0; }
	[ "$_target" = "$_now" ] && return 0

	if curl -s -m5 -o /dev/null -w '%{http_code}' -X PUT -H "$A" -H 'Content-Type: application/json' \
		--data "{\"name\":\"$_target\"}" "$API/proxies/$2" | grep -q '^204$'; then
		log "$1: switch $_now -> $_target"
	else
		log "$1: switch failed $_now -> $_target"
	fi
}

check_group '美国自动' '%E7%BE%8E%E5%9B%BD%E8%87%AA%E5%8A%A8' ''
check_group '美国策略' '%E7%BE%8E%E5%9B%BD%E7%AD%96%E7%95%A5' '美国自动'
exit 0
