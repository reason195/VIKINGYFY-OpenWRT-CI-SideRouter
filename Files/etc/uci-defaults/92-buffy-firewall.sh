#!/bin/sh
# 自定义项（旁路由）：硬件流卸载；清除引用已删除 wan/wan6 接口的区域与规则，并清掉旧版残留的 fullcone6。
# 区域/默认规则及各软件包 include（qcanssecm/nikki/openclash/homeproxy）均由软件包自行管理，
# 不在此烘焙，随包更新自动继承。
exec 2>/dev/null
# --- defaults: 硬件流卸载 ---
# 关键：fw4 的 resolve_offload_devices() 先判断 flow_offloading（软件开关），
# 未开启则直接返回空、根本不会生成 flowtable —— 只设 flow_offloading_hw 是无效的。
# 必须两个都开：软件开关负责生成 flowtable + flow offload 规则，硬件开关在其上加 flags offload。
# 内核不支持硬件卸载时 fw4 会自动回退为软件卸载，不会报错断网。
# 旁路由下这条尤其重要：客户端流量全部走 br-lan 进、br-lan 出的同口转发，
# 没有卸载时每一包都过完整 ruleset，吞吐上限直接掉一个数量级。
uci -q delete firewall.@defaults[0].flow_offloading
uci set firewall.@defaults[0].flow_offloading='1'
uci -q delete firewall.@defaults[0].flow_offloading_hw
uci set firewall.@defaults[0].flow_offloading_hw='1'
# fullcone / fullcone6 只删不写：旁路由不做 NAT，fullcone 没有作用对象，nft fullcone 扩展
# （fullconenat-sonic）也已移出固件。两个键都要清：
#   - fullcone6：旧版镜像写入过，--keep-config 升级会带过来；
#   - fullcone：ImmortalWrt 出厂 /etc/config/firewall 的 @defaults 里就写着 '1'（wan 区域里
#     那一个随下方 wan 区域一起删除），不是我们写的，但既然固件里已无 fullcone 扩展，留着
#     只是一个指向不存在表达式的开关。
# 26.11.06 实机：清掉扩展后 fw4 表内 fullcone 引用为 0，本项属确定性清理而非救火。
uci -q delete firewall.@defaults[0].fullcone6
uci -q delete firewall.@defaults[0].fullcone

# --- 清除 wan 区域与引用 wan 的放行规则 ---
# /etc/config/network 里已无 wan/wan6（旁路由不拨号），但防火墙包默认生成的 wan 区域仍写着
# network 'wan wan6'，原「wan forward=DROP」「Allow-WAN-*-v6」也都是为主路由形态准备的。
# 留着这些引用，fw4 会因未知接口拒绝加载整张表 —— 连 lan 的转发一起失效，
# 表现为刷机后客户端全断且日志无显式报错。删除后出口方向只剩 lan 区域，
# 其 forward=ACCEPT（包默认值）负责放行客户端 → 主路由的转发。
# 删一段后其余匿名段会前移填补下标，故每删一段就从头重扫；上限 32 轮只是防 uci 异常时空转，
# 正常配置（1 个 wan 区域 + 2 条包自带规则）远碰不到。
_drop_wan_ref() { # $1=段类型(zone/rule) $2=匹配选项名 $3=匹配值
	_round=0
	while [ "$_round" -lt 32 ]; do
		_round=$((_round + 1))
		_hit=''
		_i=0
		while [ -n "$(uci -q get "firewall.@$1[$_i]")" ]; do
			if [ "$(uci -q get "firewall.@$1[$_i].$2")" = "$3" ]; then
				uci -q delete "firewall.@$1[$_i]"
				_hit=1
				break
			fi
			_i=$((_i + 1))
		done
		[ -n "$_hit" ] || break
	done
}
_drop_wan_ref zone name wan
# 规则两个方向都要清：src='wan'（包自带的 Allow-WAN-*-v6）与 dest='wan'（端口转发类）
# 都是对不存在接口的引用，留着任一个都会让 fw4 整表加载失败。
_drop_wan_ref rule src wan
_drop_wan_ref rule dest wan
unset _round _hit _i

uci commit firewall
exit 0
