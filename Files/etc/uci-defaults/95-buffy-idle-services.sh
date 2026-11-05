#!/bin/sh
# 停用对本机无用的「空转服务」。
# uci-defaults 每次升级都会重新投放并执行，所以 /etc/rc.d 软链即使被软件包重建，也会再被关掉。
#   wpad   —— WiFi 认证（hostapd/wpa_supplicant）；ipq60xx 本机无射频，无对象
#   relayd —— 网络中继/桥接守护进程；旁路由不使用
#   radius —— RADIUS(802.1X) 认证服务器；家用旁路由不使用
#   odhcpd —— IPv6 的 DHCPv6/RA 服务器；本固件 IPv6 全关（ra/dhcpv6/ndp=disabled）
# 注：若日后要启用 IPv6，需先把 odhcpd 重新 enable。
exec 2>/dev/null
for _s in wpad relayd radius odhcpd; do
	[ -x "/etc/init.d/$_s" ] || continue
	/etc/init.d/$_s disable >/dev/null 2>&1
	/etc/init.d/$_s stop >/dev/null 2>&1
done
unset _s
exit 0
