#!/bin/sh

CONFIG_FILE="$1"
[ -s "$CONFIG_FILE" ] || exit 0

. /usr/share/openclash/ruby.sh

# ruby_edit 的值按 Ruby 表达式执行，字符串必须自带引号。
ruby_edit "$CONFIG_FILE" "['global-client-fingerprint']" '"chrome"'
# Ruby 4 的 INTEGER 节点不在插件白名单内；to_i 保持缓存大小为整数。
ruby_edit "$CONFIG_FILE" "['dns']['cache-size']" '"4096".to_i'
ruby_edit "$CONFIG_FILE" "['dns']['listen']" '"127.0.0.1:7874"'

# 默认代理原本是 select，首项固定为香港策略：香港节点全挂时 select 不会换组，
# 而 MATCH → 兜底流量 → 默认代理 整条链路都停在不健康的香港策略上，表现为
# 刷机后代理完全不通，必须手动切到其他地区。
# 这里注入跨地区 url-test 组「自动选择」（include-all 所有订阅节点，按延迟取
# 最低的存活节点），并把默认代理的首项换成它：香港不可用时自动落到其他地区
# 节点；用户仍可手动选择具体地区，profile.store-selected 会记住手动选择。
# 注意不要把「自动选择」做成 fallback + 地区策略组：mihomo 的 fallback 只判断
# 成员的 Alive()，而 select 组恒为 alive，等于永远停在香港策略（26.11.08 实测）。
ruby -ryaml -rYAML -I /usr/share/openclash -E UTF-8 -e '
  path = ARGV[0]
  data = YAML.load_file(path)
  groups = data["proxy-groups"]
  exit 0 unless groups.is_a?(Array)

  default = groups.find { |g| g.is_a?(Hash) && g["name"] == "默认代理" }
  exit 0 unless default && default["proxies"].is_a?(Array)

  members = default["proxies"].reject { |name| ["自动选择", "直接连接"].include?(name) }
  exit 0 if members.empty?

  filter = "^(?!.*(DIRECT|REJECT|直接连接|群|邀请|返利|循环|官网|客服|网站|网址|获取|订阅|流量|到期|机场|下次|版本|官址|备用|过期|已用|联系|邮箱|工单|贩卖|通知|倒卖|防止|国内|地址|频道|无法|说明|使用|提示|特别|访问|支持|教程|关注|更新|作者|加入|USE|USED|TOTAL|EXPIRE|EMAIL|Panel|Channel|Author))"
  auto = groups.find { |g| g.is_a?(Hash) && g["name"] == "自动选择" }
  unless auto
    auto = {
      "name" => "自动选择",
      "icon" => "https://github.com/Koolson/Qure/raw/master/IconSet/Color/Auto.png"
    }
    groups.unshift(auto)
  end
  auto["type"] = "url-test"
  auto["url"] = "https://www.google.com/generate_204"
  auto["interval"] = 200
  auto["tolerance"] = 50
  auto["include-all"] = true
  auto["filter"] = filter
  auto.delete("proxies")

  tail = default["proxies"].include?("直接连接") ? ["直接连接"] : []
  default["proxies"] = ["自动选择"] + members + tail
  YAML.dump(data, path)
' "$CONFIG_FILE" 2>/dev/null || true

exit 0
