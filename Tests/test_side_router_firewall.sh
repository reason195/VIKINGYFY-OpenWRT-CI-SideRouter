#!/bin/sh
# SPDX-License-Identifier: MIT
# test_side_router_firewall.sh - 92-buffy-firewall.sh（旁路由形态）的沙箱回归测试
#
# 做法：PATH 前置 mock uci（状态存 $UCI_STATE，每行 key=value，支持 get/set/delete/commit
# 与 @section[N] 删除后的前移），直接运行真实的 Files/etc/uci-defaults/92-buffy-firewall.sh。
#
# 背景：旁路由形态的 /etc/config/network 已无 wan/wan6 接口，但防火墙包默认生成的 wan 区域
# 仍写着 network 'wan wan6'。这种悬空引用会让 fw4 拒绝加载整张表——连 lan 转发一起失效，
# 表现为刷机后客户端全断且日志无显式报错。脚本负责清除，本测试锁住清除逻辑本身。
#
# 覆盖：
#   1 包默认形态（zone[lan,wan] + rule[lan,wan,wan]）→ 只删 wan 引用，lan 前移且内容完整
#   2 wan 区域位于 [0] → 删除后 lan 落到 [0]，不被漏扫
#   3 dest='wan' 的端口转发类规则同样被清
#   4 已干净的状态 → 不误删任何段，选项照常写入
#   5 幂等：连续执行两次结果一致
#   6 10 条 src='wan' 规则（多于早期实现的 8 轮上限）全部清除
#   7 fullcone6（旧镜像 --keep-config 带过来）与 fullcone（ImmortalWrt 出厂自带）→ 都删除
#
# 用法：sh Tests/test_side_router_firewall.sh
# 退出码：0 = 全部通过；1 = 有失败

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_DIR/Files/etc/uci-defaults/92-buffy-firewall.sh"

[ -f "$TARGET" ] || { echo "找不到 $TARGET"; exit 1; }

PASS=0
FAIL=0

SBX=$(mktemp -d /tmp/side-router-fw.XXXXXX 2>/dev/null || true)
[ -n "${SBX:-}" ] || SBX=$(mktemp -d)
case "$SBX" in
*\\*)
	echo "沙箱路径含反斜杠（$SBX），请设置 POSIX 风格的 TMPDIR 后重试"
	exit 1
	;;
esac

mkdir -p "$SBX/bin"
UCI_STATE="$SBX/uci.state"
export UCI_STATE

# mock uci：只实现本脚本用到的子集。@section[N] 的 get 返回合成段名并在删除时前移高位下标。
cat > "$SBX/bin/uci" <<'MOCK'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"
[ $# -gt 0 ] && shift
st="${UCI_STATE:?}"
[ -f "$st" ] || : > "$st"

get_val() { # $1=key → 打印值，未命中 rc=1
	awk -v k="$1" 'BEGIN{FS="="}
		{ if (substr($0, 1, length(k) + 1) == k "=") { print substr($0, length(k) + 2); f=1; exit } }
		END { exit(f ? 0 : 1) }' "$st"
}

case "$cmd" in
get)
	key="${1:-}"; [ -n "$key" ] || exit 1
	case "$key" in
	*'@'*'['*']')
		base="${key%%\[*}"; idx="${key#*\[}"; idx="${idx%%\]*}"
		if awk -v p="$base[$idx]." 'substr($0, 1, length(p)) == p { f=1; exit } END { exit(f ? 0 : 1) }' "$st"; then
			printf 'cfg%s\n' "$idx"; exit 0
		fi
		exit 1
		;;
	esac
	get_val "$key"
	;;
set)
	kv="${1:-}"
	case "$kv" in
	*=*) k="${kv%%=*}"; v="${kv#*=}" ;;
	*) k="$kv"; v="" ;;
	esac
	[ -n "$k" ] || exit 1
	awk -v k="$k" -v v="$v" 'BEGIN{FS="="}
		substr($0, 1, length(k) + 1) != k "="' "$st" > "$st.new" && printf '%s=%s\n' "$k" "$v" >> "$st.new" && mv "$st.new" "$st"
	;;
delete)
	key="${1:-}"; [ -n "$key" ] || exit 1
	case "$key" in
	*'@'*'['*']')
		base="${key%%\[*}"; idx="${key#*\[}"; idx="${idx%%\]*}"
		awk -v base="$base" -v idx="$idx" '
			{
				pfx = base "["
				if (substr($0, 1, length(pfx)) == pfx) {
					rest = substr($0, length(pfx) + 1)   # "0].name=wan"
					n = rest; sub(/\].*$/, "", n)
					if (n ~ /^[0-9]+$/) {
						if (n + 0 == idx + 0) next
						if (n + 0 > idx + 0) { print base "[" (n - 1) "]" substr(rest, length(n) + 2); next }
					}
				}
				print
			}' "$st" > "$st.new" && mv "$st.new" "$st"
		;;
	*)
		awk -v k="$key" 'substr($0, 1, length(k) + 1) != k "="' "$st" > "$st.new" && mv "$st.new" "$st"
		;;
	esac
	;;
commit) exit 0 ;;
*) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$SBX/bin/uci"
PATH="$SBX/bin:$PATH"
export PATH

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check_eq() { # $1=描述 $2=期望 $3=实得
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2] 实得 [$3]）"; fi
}
val() { # key 里的 [0] 在 sed BRE 中是字符类，统一用 awk 前缀精确匹配
	awk -v k="$1" 'BEGIN{FS="="}
		substr($0, 1, length(k) + 1) == k "=" { print substr($0, length(k) + 2); exit }' "$UCI_STATE"
}
count_pref() { grep -c "^$1" "$UCI_STATE" 2>/dev/null || true; }
zone_names() {
	awk -F= '/^firewall\.@zone\[[0-9]+\]\.name=/{printf "%s ", $2}' "$UCI_STATE"
}
rule_names() {
	awk -F= '/^firewall\.@rule\[[0-9]+\]\.name=/{printf "%s ", $2}' "$UCI_STATE"
}
wan_refs() { # 残留的 wan 引用：区域 name=wan、规则 src/dest=wan
	printf '%s\n' "$(count_pref 'firewall.@zone\[.*\].name=wan')" \
		"$(count_pref 'firewall.@rule\[.*\].src=wan')" \
		"$(count_pref 'firewall.@rule\[.*\].dest=wan')" |
	awk '{ s += $1 } END { print s }'
}
run_target() { sh "$TARGET"; }

# ---- 用例 1：包默认形态（wan 区域在 lan 之后） ----
echo "[1] 包默认形态：清 wan 引用、保留 lan"
cat > "$UCI_STATE" <<'EOF'
firewall.@defaults[0].input=ACCEPT
firewall.@defaults[0].output=ACCEPT
firewall.@defaults[0].syn_flood=1
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
firewall.@zone[0].output=ACCEPT
firewall.@zone[0].forward=ACCEPT
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@zone[1].input=REJECT
firewall.@zone[1].forward=REJECT
firewall.@zone[1].masq=1
firewall.@rule[0].name=Allow-LAN-DHCP
firewall.@rule[0].src=lan
firewall.@rule[0].proto=udp
firewall.@rule[0].dest_port=67
firewall.@rule[1].name=Allow-WAN-SSH-v6
firewall.@rule[1].src=wan
firewall.@rule[1].family=ipv6
firewall.@rule[2].name=Allow-WAN-LuCI-v6
firewall.@rule[2].src=wan
firewall.@rule[2].family=ipv6
EOF
run_target
check_eq "退出码 0" "0" "$?"
check_eq "无 wan 引用残留" "0" "$(wan_refs)"
check_eq "区域仅剩 lan" "lan " "$(zone_names)"
check_eq "lan 前移到 [0] 且 forward 保留" "ACCEPT" "$(val 'firewall.@zone[0].forward')"
check_eq "lan 的 network 未被牵连" "lan" "$(val 'firewall.@zone[0].network')"
check_eq "无关规则保留" "Allow-LAN-DHCP " "$(rule_names)"
check_eq "无关规则 src 保留" "lan" "$(val 'firewall.@rule[0].src')"
check_eq "syn_flood 等默认项未被牵连" "1" "$(val 'firewall.@defaults[0].syn_flood')"
check_eq "flow_offloading=1" "1" "$(val 'firewall.@defaults[0].flow_offloading')"
check_eq "flow_offloading_hw=1" "1" "$(val 'firewall.@defaults[0].flow_offloading_hw')"
check_eq "fullcone6 未被写入" "" "$(val 'firewall.@defaults[0].fullcone6')"

# ---- 用例 2：wan 区域在 [0]，删除后需重扫到 lan ----
echo "[2] wan 区域在前：lan 落到 [0]"
cat > "$UCI_STATE" <<'EOF'
firewall.@defaults[0].input=ACCEPT
firewall.@zone[0].name=wan
firewall.@zone[0].network=wan wan6
firewall.@zone[0].forward=REJECT
firewall.@zone[1].name=lan
firewall.@zone[1].network=lan
firewall.@zone[1].forward=ACCEPT
EOF
run_target
check_eq "无 wan 引用残留" "0" "$(wan_refs)"
check_eq "区域仅剩 lan" "lan " "$(zone_names)"
check_eq "lan 索引前移到 [0]" "lan" "$(val 'firewall.@zone[0].name')"
check_eq "lan forward 保留" "ACCEPT" "$(val 'firewall.@zone[0].forward')"

# ---- 用例 3：dest='wan' 的端口转发类规则 ----
echo "[3] dest=wan 规则同样清除"
cat > "$UCI_STATE" <<'EOF'
firewall.@defaults[0].input=ACCEPT
firewall.@zone[0].name=lan
firewall.@zone[0].forward=ACCEPT
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@rule[0].name=PortFwd-ToNAS
firewall.@rule[0].dest=wan
firewall.@rule[0].proto=tcp
firewall.@rule[1].name=Allow-LAN-DHCP
firewall.@rule[1].src=lan
EOF
run_target
check_eq "无 wan 引用残留" "0" "$(wan_refs)"
check_eq "区域仅剩 lan" "lan " "$(zone_names)"
check_eq "dest=wan 规则已删、lan 规则前移" "Allow-LAN-DHCP " "$(rule_names)"
check_eq "保留的规则内容完整" "lan" "$(val 'firewall.@rule[0].src')"

# ---- 用例 4：已经是干净状态 → 不误删 ----
echo "[4] 已干净：不误删任何段"
cat > "$UCI_STATE" <<'EOF'
firewall.@defaults[0].input=ACCEPT
firewall.@defaults[0].syn_flood=1
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].forward=ACCEPT
firewall.@rule[0].name=Allow-LAN-DHCP
firewall.@rule[0].src=lan
firewall.@rule[1].name=My-Custom-Keep
firewall.@rule[1].src=lan
firewall.@rule[1].dest=lan
EOF
run_target
check_eq "lan 区域保留" "lan " "$(zone_names)"
check_eq "两条 lan 规则保留" "2" "$(count_pref 'firewall.@rule\[.*\].name=')"
check_eq "自定义规则未被动到" "lan" "$(val 'firewall.@rule[1].dest')"
check_eq "默认项仍写入" "1" "$(val 'firewall.@defaults[0].flow_offloading_hw')"

# ---- 用例 5：幂等 ----
echo "[5] 连跑两次结果一致"
before=$(sort "$UCI_STATE")
run_target
after=$(sort "$UCI_STATE")
check_eq "第二次执行不改变状态" "$before" "$after"

# ---- 用例 6：大量 wan 规则（超过早期实现的 8 轮上限） ----
echo "[6] 10 条 src=wan 规则全部清除"
: > "$UCI_STATE"
printf '%s\n' 'firewall.@defaults[0].input=ACCEPT' 'firewall.@zone[0].name=lan' 'firewall.@zone[0].forward=ACCEPT' >> "$UCI_STATE"
i=0
while [ "$i" -lt 10 ]; do
	printf 'firewall.@rule[%s].name=Wan-Rule-%s\nfirewall.@rule[%s].src=wan\n' "$i" "$i" "$i" >> "$UCI_STATE"
	i=$((i + 1))
done
printf 'firewall.@rule[10].name=Keep-Me\nfirewall.@rule[10].src=lan\n' >> "$UCI_STATE"
run_target
check_eq "无 wan 引用残留" "0" "$(wan_refs)"
check_eq "10 条 wan 规则清空、仅剩 lan 规则" "1" "$(count_pref 'firewall.@rule\[.*\].name=')"
check_eq "lan 规则内容完整" "Keep-Me" "$(val 'firewall.@rule[0].name')"

# ---- 用例 7：fullcone / fullcone6 两个残留键都被清除（扩展已移出固件） ----
echo "[7] fullcone 残留清除"
cat > "$UCI_STATE" <<'EOF'
firewall.@defaults[0].input=ACCEPT
firewall.@defaults[0].fullcone6=1
firewall.@defaults[0].fullcone=1
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].forward=ACCEPT
EOF
run_target
check_eq "fullcone6 已删除" "" "$(val 'firewall.@defaults[0].fullcone6')"
# fullcone 不是我们写的，是 ImmortalWrt 出厂 /etc/config/firewall 的 @defaults 自带的
check_eq "fullcone 已删除" "" "$(val 'firewall.@defaults[0].fullcone')"
check_eq "无关默认项保留" "ACCEPT" "$(val 'firewall.@defaults[0].input')"
check_eq "卸载开关仍写入" "1" "$(val 'firewall.@defaults[0].flow_offloading')"
check_eq "lan 区域未受影响" "lan" "$(val 'firewall.@zone[0].name')"
run_target
check_eq "重复执行后依然为空" "" "$(val 'firewall.@defaults[0].fullcone6')"

echo
echo "==== 结果：$PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
