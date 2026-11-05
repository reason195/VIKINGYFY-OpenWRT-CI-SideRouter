#!/bin/sh
# OpenClash 配置覆盖钩子 —— 由 /etc/init.d/openclash 在每次生成配置后调用（$1 = 临时配置路径）。
# 因为它在「订阅下载 + 配置生成」之后执行，所以订阅刷新/重启后依然生效。
# 通过 ruby.sh 的 ruby_edit 记录编辑指令，由 YAML.overwrite_run_custom 做锚点安全的精确修改
# （不会破坏 proxies: *N 这类锚点引用）。
#
# 覆盖两项 OpenClash 没有 UCI 选项的 mihomo 配置：
#   1) global-client-fingerprint: chrome —— 抗 TLS 指纹识别（降低流媒体/风控触发验证码）
#   2) dns.cache-size: 4096 —— DNS 缓存（openclash 的 cachesize_dns 只是布尔开关，非缓存条数）

CONFIG_FILE="$1"
[ -s "$CONFIG_FILE" ] || exit 0

[ -f /usr/share/openclash/ruby.sh ] && . /usr/share/openclash/ruby.sh 2>/dev/null

ruby_edit "$CONFIG_FILE" "['global-client-fingerprint']" "chrome"
ruby_edit "$CONFIG_FILE" "['dns']['cache-size']" "4096"
# DNS 收口：dnsmasq 用 127.0.0.1#7874 转发，LAN 侧无需直连 7874 → 只绑本机
# 注意：ruby_edit 的值是按 Ruby 代码原样拼接（Value[path] = 值），含冒号等非字面量必须自带引号
ruby_edit "$CONFIG_FILE" "['dns']['listen']" "\"127.0.0.1:7874\""

exit 0
