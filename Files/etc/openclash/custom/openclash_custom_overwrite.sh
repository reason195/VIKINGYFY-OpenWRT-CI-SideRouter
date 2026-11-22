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

  members = default["proxies"].reject { |name| ["自动选择", "直接连接", "美国优先"].include?(name) }
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

  # 美国优先：fallback(美国自动 → 自动选择)。
  # 默认代理首项指向它，效果是「优先走美国、美国全挂自动回退全球最快」。
  # 不能直接把「美国策略」放进 fallback：它是 select 组，Alive() 恒为 true，
  # fallback 永远认为它可用，节点挂了也不会切（26.11.08 实测过同类陷阱）。
  us_auto = groups.find { |g| g.is_a?(Hash) && g["name"] == "美国自动" }
  if us_auto
    us_first = groups.find { |g| g.is_a?(Hash) && g["name"] == "美国优先" }
    unless us_first
      us_first = {
        "name" => "美国优先",
        "icon" => "https://github.com/Koolson/Qure/raw/master/IconSet/Color/United_States.png"
      }
      groups.unshift(us_first)
    end
    us_first["type"] = "fallback"
    us_first["proxies"] = ["美国自动", "自动选择"]
    us_first["url"] = "https://www.google.com/generate_204"
    us_first["interval"] = 300
    us_first["tolerance"] = 50
    us_first["timeout"] = 5000
    us_first.delete("include-all")
    us_first.delete("filter")
    first = "美国优先"
  else
    first = "自动选择"
  end

  tail = default["proxies"].include?("直接连接") ? ["直接连接"] : []
  default["proxies"] = [first] + members + ["自动选择"] + tail

  YAML.dump(data, path)
' "$CONFIG_FILE" 2>/dev/null || true

# Tailscale 控制面/中继域名必须拿到真实 IP 且直连：
# fake-ip 模式会把 controlplane/log/derp*.tailscale.com 解析成 198.18.x，
# tailscaled 连的是 fake-ip 地址，表现为 "dial ... i/o timeout" 后卡在
# doLogin，节点显示 NoState 或在线但接口无地址。缺这条时刷机后 tailscale
# 必然起不来（26.11.22 实测：log.tailscale.com → 198.18.0.53，30s 超时）。
ruby -ryaml -rYAML -I /usr/share/openclash -E UTF-8 -e '
  path = ARGV[0]
  data = YAML.load_file(path)
  dns = data["dns"]
  if dns.is_a?(Hash)
    filter = (dns["fake-ip-filter"] ||= [])
    %w[+.tailscale.com +.tailscale.io +.tailscale.net].each do |d|
      filter << d unless filter.include?(d)
    end
  end
  rules = data["rules"]
  if rules.is_a?(Array)
    %w[DOMAIN-SUFFIX,tailscale.com DOMAIN-SUFFIX,tailscale.io DOMAIN-SUFFIX,tailscale.net].reverse_each do |r|
      rules.unshift("#{r},DIRECT") unless rules.any? { |x| x.to_s.start_with?(r) }
    end
  end
  YAML.dump(data, path)
' "$CONFIG_FILE" 2>/dev/null || true

exit 0
