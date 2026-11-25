#!/bin/sh

CONFIG_FILE="$1"
[ -s "$CONFIG_FILE" ] || exit 0

. /usr/share/openclash/ruby.sh

# ruby_edit 的值按 Ruby 表达式执行，字符串必须自带引号。
# 注：Mihomo 新版核心已移除 global-client-fingerprint，改为下方为各 proxy-provider 注入 override.client-fingerprint。
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
  data.delete("global-client-fingerprint")
  if data["proxy-providers"].is_a?(Hash)
    data["proxy-providers"].each_value do |p|
      next unless p.is_a?(Hash)
      p["override"] ||= {}
      p["override"]["client-fingerprint"] ||= "chrome" if p["override"].is_a?(Hash)
    end
  end
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
    us_first["interval"] = 60
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

  # 备用策略：单独聚合「备用服务商」（独享节点），含自动测速「备用自动」与手动选节点，
  # 并注入所有含「全球手动」的 select 策略组，方便将 GitHub/微软等服务一键切到独享节点。
  if data["proxy-providers"].is_a?(Hash) && data["proxy-providers"].key?("备用服务商")
    backup_auto = groups.find { |g| g.is_a?(Hash) && g["name"] == "备用自动" }
    unless backup_auto
      backup_auto = {
        "name" => "备用自动",
        "icon" => "https://github.com/Koolson/Qure/raw/master/IconSet/Color/Auto.png"
      }
      groups.push(backup_auto)
    end
    backup_auto["type"] = "url-test"
    backup_auto["use"] = ["备用服务商"]
    backup_auto["url"] = "https://www.google.com/generate_204"
    backup_auto["interval"] = 180
    backup_auto["tolerance"] = 50
    backup_auto["timeout"] = 5000
    backup_auto["lazy"] = false
    backup_auto["hidden"] = true
    backup_auto.delete("proxies")
    backup_auto.delete("include-all")
    backup_auto.delete("filter")

    backup_select = groups.find { |g| g.is_a?(Hash) && g["name"] == "备用策略" }
    unless backup_select
      backup_select = {
        "name" => "备用策略",
        "icon" => "https://github.com/Koolson/Qure/raw/master/IconSet/Color/Server.png"
      }
      gm_idx = groups.index { |g| g.is_a?(Hash) && g["name"] == "全球手动" }
      gm_idx ? groups.insert(gm_idx, backup_select) : groups.push(backup_select)
    end
    backup_select["type"] = "select"
    backup_select["proxies"] = ["备用自动"]
    backup_select["use"] = ["备用服务商"]
    backup_select.delete("include-all")
    backup_select.delete("filter")

    groups.each do |g|
      next unless g.is_a?(Hash) && g["type"] == "select" && g["proxies"].is_a?(Array)
      next if g["name"] == "备用策略" || g["proxies"].include?("备用策略")
      idx = g["proxies"].index("全球手动")
      next unless idx
      g["proxies"] = g["proxies"].dup
      g["proxies"].insert(idx, "备用策略")
    end
  end

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
