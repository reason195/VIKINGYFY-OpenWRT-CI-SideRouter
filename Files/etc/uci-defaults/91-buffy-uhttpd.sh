#!/bin/sh
# 自定义项：关掉 uhttpd 的 HTTP→HTTPS 强制跳转，局域网用 http://192.168.1.2 直接进 LuCI。
# 必须关：本机不再有任何可信证书（DDNS 与 acme/Let's Encrypt 已随旁路由改造移除），
# 跳过去只会得到 ERR_CERT_AUTHORITY_INVALID，且没有可免告警的路子。
# 443 监听不再干预——原先显式 add_list 是为 Let's Encrypt 证书准备的，现在沿用软件包默认值。
# 其余选项全部使用 uhttpd 软件包默认值，随包更新自动继承。
exec 2>/dev/null
uci -q delete uhttpd.main.redirect_https
uci commit uhttpd
exit 0
