#!/bin/sh
# 自定义项：移除 dropbear 的接口绑定，改为监听本机全部地址。
# 旁路由只有 br-lan，解绑后 SSH 仍只在本机可达；不再依赖「绑定 lan」这一主路由形态的假设。
# 其余选项全部使用 dropbear 软件包默认值，随包更新自动继承。
exec 2>/dev/null
uci -q delete dropbear.@dropbear[0].Interface
uci -q delete dropbear.@dropbear[0].DirectInterface
uci commit dropbear
exit 0
