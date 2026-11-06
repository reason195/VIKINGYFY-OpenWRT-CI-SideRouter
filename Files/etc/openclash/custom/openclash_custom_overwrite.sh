#!/bin/sh

CONFIG_FILE="$1"
[ -s "$CONFIG_FILE" ] || exit 0

. /usr/share/openclash/ruby.sh

# ruby_edit 的值按 Ruby 表达式执行，字符串必须自带引号。
ruby_edit "$CONFIG_FILE" "['global-client-fingerprint']" '"chrome"'
# Ruby 4 的 INTEGER 节点不在插件白名单内；to_i 保持缓存大小为整数。
ruby_edit "$CONFIG_FILE" "['dns']['cache-size']" '"4096".to_i'
ruby_edit "$CONFIG_FILE" "['dns']['listen']" '"127.0.0.1:7874"'

exit 0
