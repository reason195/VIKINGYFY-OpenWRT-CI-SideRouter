# VIKINGYFY-OpenWRT-CI-SideRouter（京东云 jdcloud_re-cs-07 · 旁路由专用）

从 [reason195/VIKINGYFY-OpenWRT-CI](https://github.com/reason195/VIKINGYFY-OpenWRT-CI)（主路由形态）拆出的独立仓库，构建逻辑同源。拆库原因：两种角色的 release 落在同一个命名空间会互相挤占 `Auto-Clean` 的「保留 5 条」配额，而 GitHub 的 schedule 只在默认分支运行——分库后 release、清理配额、定时构建各自独立。

基于 [VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI) 的 ImmortalWRT 固件自动构建项目，本仓库只维护单设备固件：

- 设备：京东云 jdcloud_re-cs-07（Qualcomm IPQ60xx 平台，无 WiFi）
- 目标：`qualcommax/ipq60xx`，aarch64
- 角色：**旁路由**（不拨号、不发 DHCP），挂在主路由下做 LAN 内的转发网关 + DNS + OpenClash 代理节点
- 登录地址：`192.168.1.2`，root 密码由 GitHub Secret `ROUTER_ROOT_PASSWORD` 注入；主路由为 `192.168.1.1`
- 构建：每日凌晨 4:00（北京时间）检查上游 [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)（main 分支），有更新才自动编译并发布 release；旧 release 自动清理只留 5 个（本仓库独立计数）

> ⚠️ 新仓库首次构建前必须重配 Secrets，缺失会直接终止构建：
> `ROUTER_ROOT_PASSWORD`、`HP_ADDRESS`、`HP_UUID`、`MAIN_AIRPORT_SUB`、`BACKUP_AIRPORT_SUB`。
> 可选：`TELEGRAM_BOT_TOKEN`、`TELEGRAM_CHAT_ID`、`SINGBOX_SS_PASSWORD`；`PPPOE_USERNAME`/`PPPOE_PASSWORD` 旁路由已不拨号，降为可选、可不配置。
> GitHub API 读不到 secret 的**值**，跨仓库无法自动搬运，只能手动重设一遍。

## 旁路由形态说明

| 项 | 本固件的行为 |
|---|---|
| 出口 | `lan` 静态 `192.168.1.2/24` + `gateway 192.168.1.1`，无 wan/wan6/modem 接口，不再 PPPoE 拨号 |
| LAN 口 | 原 `wan` 物理口并入 `br-lan`，4 个口全部当交换口用 |
| DHCP/RA | 全部关闭（`dhcpv4/ra/dhcpv6/ndp = disabled`，不是 `ignore`——`ignore` 会连 dnsmasq 的 DNS 一起摘掉），地址与网关由主路由下发 |
| DNS | 本机 dnsmasq 继续在 br-lan 上服务，上游指向 OpenClash（`127.0.0.1#7874`），`authoritative` 已关 |
| 接管方式 | 固件本身两种都支持，**当前部署是「全局接管」**：主路由（Cudy WR3600H）的 DHCP 把 `default_gateway` 与 `dns1` 都下发成 `192.168.1.2`，所以全网 IPv4 默认经过本机，不需要逐台手动设置。代价是本机成了 IPv4 的单点——自动刷机/重启那一两分钟内全家断网，客户端要续租或重试才恢复（`dns2=223.5.5.5` 只兜底解析，兜底时 fake-ip 静默失效）。想退回「手动 opt-in」：把主路由 `services/dhcp` 的 `default_gateway`/`dns1` 改回 `192.168.1.1` 即可，本固件无需改动 |
| IPv6 | 本机不发 RA，且内核在 `forwarding=1` 时不采纳 RA → 本机一般无全局 IPv6；客户端 IPv6 由主路由 RA/RDNSS 直接下发，**不经本机、不走代理**（当前部署接受这一条：有 AAAA 的站点优先走 v6 直连，出境 v6 到 Google/GitHub 受阻时表现为 TLS 握手被断，而不是代理故障） |
| DDNS + 证书 | **整体移除**：`/etc/config/ddns`、`/etc/config/acme`、`Files/usr/lib/acme/`（vendored dns_duckdns 插件）、`cert_check.sh` 与相关包全删。旁路由不是边缘设备，既取不到公网地址，也没有对外服务的域名 |
| 防火墙 | 清除引用已删除接口的 `wan` 区域与 `Allow-WAN-*-v6` 规则（残留会让 fw4 整表加载失败）；保留硬件流卸载；`rp_filter=0` 放行同口非对称转发。FullCone 已随 NAT 角色一起移除 |

外部访问：本固件不再有 DDNS 与 Let's Encrypt 证书链，管理入口就是 `http://192.168.1.2`（`redirect_https` 已强制关闭——没有可信证书时跳转只会 `ERR_CERT_AUTHORITY_INVALID`）。若仍要从外网进管理页，得自己补齐三件事：① 由主路由或别处把域名解析到你的入口地址；② 在主路由做端口转发到 `192.168.1.2:80`——**只有 80 可用**，26.11.06 实机测过 `uhttpd.main` 仅有 `listen_http='0.0.0.0:80' '[::]:80'`，443 并没有监听（`listen_https` 沿用软件包默认即为空；`/etc/uhttpd.crt` 虽在但没被使用），要 443 得自己 `uci add_list uhttpd.main.listen_https=...` 并承担自签告警；③ 想要可信证书需另找方案（反向代理或内网穿透自带 TLS）。

### 旁路由下已移除的软件包

| 包 | 移除原因 |
|---|---|
| `ddns-scripts` / `ddns-scripts-duckdns` / `luci-app-ddns` / `luci-i18n-ddns-zh-cn` | 旁路由没有公网接口可取地址，DDNS 永远失败 |
| `acme` / `luci-app-acme` / `luci-i18n-acme-zh-cn` + `Files/usr/lib/acme/` | Let's Encrypt 证书服务于「域名 + 外网访问」，DDNS 移除后域名不再指向本机，证书失去用途；连带删掉 `cert_check.sh`、cron 里的三行证书任务、`lib-buffy.sh` 的 `DOMAIN`/`LEAF`/`cert_expires_within`，以及 OpenClash 的「第二 DNS 服务器」域名列表（其两个条目都是 DDNS 域名） |
| `luci-app-upnp`（连带 `etc/config/upnpd`） | 本机不是 NAT 边缘设备，映射对入向流量无效，还会与主路由抢答 SSDP |
| `luci-app-fullconenat-sonic` / `luci-i18n-fullconenat-sonic-zh-cn` / `fullconenat-sonic` | 旁路由不做 NAT，FullCone 没有作用对象；`--keep-config` 升级带过来的旧 `fullcone6='1'` 由 `92-buffy-firewall.sh` 删除。**注意**：上游该包写了 `LUCI_DEFAULT:=y if PACKAGE_luci-app-firewall`，只要镜像里有 LuCI 就会被 `make defconfig` 自动选中，光从 `GENERAL.txt` 删掉 `=y` 行删不掉——必须显式 `=n`（26.11.05 首次构建实测到） |

`luci-app-homeproxy` / `luci-app-nikki` / `sing-box` 与 filebrowser、diskmanager、partexp、ksmbd、ttyd、vnstat2 等属个人功能，不随本次改造移除。装多套代理栈时注意不要同时开启，它们会互相抢转发和 DNS。

## 目录结构

| 目录 | 说明 |
|---|---|
| `.github/workflows/` | CI：QCA-ALL（触发）、WRT-CORE（编译核心）、Auto-Clean（清理 release） |
| `Scripts/` | 构建脚本与工具（Packages.sh / Handles.sh / Settings.sh / verify_flash.py），仅在 CI 构建机运行，**不会编译进固件** |
| `Config/` | 编译配置：GENERAL.txt（通用包）+ IPQ60XX-WIFI-NO.txt（设备） |
| `Files/` | 路由器根文件系统覆盖层，**仅此目录内容会拷入固件 rootfs** |

## 构建与 Secrets 注入

构建时 `Scripts/Settings.sh` 把 `Files/` 拷入 rootfs，并用 GitHub Secrets 替换 `@@XXX@@` 占位符：

| Secret | 注入位置 |
|---|---|
| `PPPOE_USERNAME` / `PPPOE_PASSWORD` | 旁路由不再拨号，`/etc/config/network` 里已无对应占位符；Secret 已降为**可选**，可在仓库里删除 |
| `HP_ADDRESS` / `HP_UUID` | `/etc/config/homeproxy` |
| `MAIN_AIRPORT_SUB` / `BACKUP_AIRPORT_SUB` | `/etc/openclash/config/MihomoPro.yaml`（机场订阅） |
| `ROUTER_ROOT_PASSWORD` | `/etc/shadow`（SHA-256 crypt 哈希） |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | `/etc/buffy-notify.conf`（告警，可选） |
| `SINGBOX_SS_PASSWORD` | `/etc/sing-box/config.json`（Shadowsocks 入站，可选） |

必需 secret 缺失会终止构建；可选 secret 缺失只置空占位符、不阻断构建。

## 固件内置功能

- **OpenClash**：核心 / 规则集 / GEO / 大陆白名单 / 面板均在构建期预置，刷机首启即用（首启规则集空缓存死锁已修复）；旁路网关兼容 `bypass_gateway_compatible=1` 随镜像固化，保留 `br-lan` 四口桥接；默认出口**美国优先**（`默认代理` 首项 `美国策略` → `美国自动` url-test，美国节点内自动切；所有含美国策略的选择组写 `default-selected`），需要跨地区兜底时在 `openclash_custom_overwrite.sh` 里设 `US_FIRST=0` 即恢复 `自动选择` 优先（26.11.14）；内置覆写模块 `OC_SelfHeal_AntiLeak` 把 url-test/fallback/load-balance 组统一为 60s 健康检查、`expected-status: 204`、`empty-fallback: DIRECT`（全挂不断网、代价是直连），并把 `proxy-providers` 刷新降到 1h、健康检查 60s（26.11.14）；控制台登录密钥与 SOCKS5/HTTP(S) 认证由 `luci-app-openclash` 首启随机生成（旧版自造值在升级首启自动迁移），快照见 `/etc/openclash-credentials.txt`
- **订阅域名自愈**：`sysupgrade -n` 会清空 `proxy_provider` 缓存，首启必须重拉订阅。构建期 `Scripts/openclash_sub_domains.py` 从 `MihomoPro.yaml` 的 `proxy-providers` 提取订阅域名，自动补进 `fake-ip-filter`（返回真实 IP）与 `nameserver-policy`（国内 DoH 直连），避免「拉不到订阅 → 代理起不来 → 无法解析 → 更拉不到」死锁（26.11.07 实机事故）；换机场不必手改列表
- **Google Play 下载 CDN 分流**（2026-11-12）：`fake-ip` 旁路由下，Play 的 APK 分片会被 `redirector.gvt1.com` 302 到国内 CDN 域名（`*.gvt1-cn.com` 及 punycode 等价域 `*.xn--ngstr-lra8j.com`），走境外代理节点会 0 字节挂死、商店一直「等待中…」。构建期固化 `Files/etc/openclash/custom/openclash_custom_rules.list`（国内 CDN 直连、国际 CDN/API 钉在代理）与 `openclash_custom_fake_filter.list` 白名单（返回真实 IP），并由 `93-buffy-openclash.sh` / `rc.local` 启用与自愈 `enable_custom_clash_rules=1`；`verify_flash.py` 带运行时断言，详见 CHANGELOG 首节
- **DNS**：dnsmasq 备用上游（223.5.5.5 / 119.29.29.29 / 2400:3200::1）+ fake-ip 分流；国外域名经代理用境外 DoH 解析、国内走国内 DoH（`custom_name_policy`），避免 DNS 泄漏。旁路由**只走 IPv4**：`ipv6_enable=0`、`ipv6_dns=0`、`filter_aaaa_dns=1` 与 dnsmasq `filter_aaaa=1` 固化在镜像里，内核不返回 AAAA、dnsmasq 直接丢弃 AAAA，客户端不会拿到真实 IPv6 绕过分流（26.11.14 实测泄漏路径）
- **防火墙**：旁路由转发链路就位（无悬空 `wan` 区域、`lan` forward=ACCEPT、`ip_forward=1`、`rp_filter=0`）、硬件流量卸载
- **监控告警**：ntfy + Telegram 双通道（见下方脚本）

### 监控脚本（`Files/usr/share/buffy/`）

| 脚本 | 作用 |
|---|---|
| `lib-buffy.sh` | 公共函数库（log/notify/resolve/代理探测） |
| `boot_selfcheck.sh` | 开机自检：确认 OpenClash 核心 + 代理 204 就绪 |
| `health_check.sh` | 每日体检：出口连通性/DNS/备用上游/防火墙转发链路/流量卸载 |
| `proxy_watch.sh` | 每小时代理 204 探测，失败告警（运行中守护） |
| `first_boot_download.sh` | 首启引导：更新 GEO/白名单/面板，幂等仅执行一次 |
| `auto_upgrade.sh` | 每日 10:07 检查 GitHub 新 release，自动下载校验并 sysupgrade（见「路由器端自动升级」） |

## 路由器端自动升级

`Files/usr/share/buffy/auto_upgrade.sh` 由 cron 每日 10:07 触发，发现新的 release 后自动下载、校验 sha256 并 sysupgrade 刷入：

- 开关：`/etc/config/auto_upgrade` 的 `enabled`（**默认 1**）；`keep_config=0`（**默认**）→ `sysupgrade -n` **不保留配置刷机**，改为 `1` 才保留
- 基线：`last_tag` 记录当前运行的 release tag；为空时读固件内 `/etc/buffy-version`（构建期由 `Settings.sh` 写入）作为运行版本，据此判断是否需要升级
- **分支隔离**：release tag 格式为 `$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_REF-$WRT_DATE`，其中 `WRT_BRANCH` 是上游 immortalwrt 源码分支、`WRT_REF` 才是**本仓库分支**（`/`→`-`）。设备用 `/etc/buffy-version` 剥掉尾部日期得到本机前缀，只接受同前缀的 release——否则旁路由机器会自动刷成 `main` 产出的主路由镜像，登录地址/DHCP/wan 口归属被整体换掉
- 标识缺失或格式不符时**跳过刷机**并按 boot 告警一次，绝不退化成"挑最新的刷"；本分支还没有任何 release 时只记日志、不告警（新分支首日属正常）
- 校验：读 release 附带的 `SHA256SUMS.txt`（免 GitHub API 限流），sha256 不符即中止；刷机前校验 `board_name`
- 日志：`/tmp/auto_upgrade.log`；失败与"未启用"都会推 ntfy/Telegram 告警（后者每周一提醒一次）
- 调试：`AUTO_UPGRADE_DRYRUN=1 /usr/share/buffy/auto_upgrade.sh` 走完整流程但不刷写

> 关于分支隔离：tag 里的 `$WRT_REF`（本仓库分支）与设备端按前缀筛选，是为「同一仓库并存两种角色」设计的。本固件已拆到独立仓库，release 命名空间天然隔离，这套逻辑退化为双保险——如果以后在本仓库再开角色分支，它仍然生效。
> 独立仓库同时也解掉了原来两个坑：schedule 跑在本仓库的默认分支上，`Auto-Clean` 的「保留 5 条」只统计本仓库的 release。

```bash
uci show auto_upgrade                                # 查看开关与基线
uci set auto_upgrade.@auto_upgrade[0].enabled='1'    # 启用
uci commit auto_upgrade
/usr/share/buffy/auto_upgrade.sh                     # 立即执行一次
```

> 为什么默认不保留配置：本仓库的 `Files/` 与 uci-defaults 已把网络、DNS、OpenClash、密钥占位符等构建期配置全部烤进固件，`sysupgrade -n` 不生成/传递配置备份，改由新镜像里的出厂文件和首启脚本重建，是最干净、可复现的刷法。
> 反过来，`SAVE_CONFIG=1` 时 sysupgrade 才会按 `/etc/sysupgrade.conf` 和 `/lib/upgrade/keep.d/*` 打包旧文件：`/etc/rc.local` 在 `base-files-essential` 清单里，`luci-app-openclash` 还保留整个 `/etc/openclash/`。保留升级会把旧开机钩子、旧 OpenClash 配置/缓存/面板选择带回，可能覆盖新镜像逻辑，没必要用。
> `-n` 会清空 `/etc` 覆盖层（本开关也在里面），刷机后由镜像内置的 `Files/etc/config/auto_upgrade` 恢复
> 默认值（`enabled=1`、`keep_config=0`），`last_tag` 缺失时脚本再按 `/etc/buffy-version` 自愈基线。
> 只有确需保留运行期手工改动（安装软件、临时 UCI/面板改动、缓存、凭据）时才设 `keep_config=1` 或用 `--keep-config`，并自行处理新旧配置兼容。
> 排查看 `/tmp/auto_upgrade.log`（每次运行都记录「刷机模式」）与 `uci show auto_upgrade`；
> 改回保留配置：`uci set auto_upgrade.@auto_upgrade[0].keep_config='1' && uci commit auto_upgrade`。

## 一键升级

`Scripts/upgrade_firmware.py` 从 GitHub latest release 下载本设备的 sysupgrade 固件、校验 sha256 并刷入：

```bash
pip install paramiko
python3 Scripts/upgrade_firmware.py                            # 默认 192.168.1.2 root/root（旁路由），不保留配置刷机（sysupgrade -n）
python3 Scripts/upgrade_firmware.py --dry-run                  # 只下载+校验，不刷机
python3 Scripts/upgrade_firmware.py --yes                      # 跳过刷机确认（默认已是不保留配置）
python3 Scripts/upgrade_firmware.py --keep-config              # 改回保留配置升级（不清空 /etc 覆盖层）
python3 Scripts/upgrade_firmware.py --no-verify                # 刷机后不等待重启、不自动复验
```

- sha256 以 GitHub 资产 `digest` 为准，本地 + 路由器侧双重校验，不一致即中止
- 刷机前校验路由器 `board_name` 与固件设备段一致，防止刷错设备
- 连上路由器后读 `/etc/buffy-version`，把选版范围**收紧到本机所在的 CI 分支**；跨分支（例如主路由转旁路由那一次）必须显式 `--tag`，脚本会打印跨分支警告
- 默认不保留配置（`-n` 清空 `/etc` 覆盖层，改用镜像内置配置，含构建期注入的 secret）：刷机前先在路由器上 `sysupgrade -b /tmp/backup.tar.gz` 备份，需要时 `sysupgrade -r` 还原
- 刷机后自动等待重启（按 uptime 判断确已重启）、等 OpenClash 开机自检完成后再运行 `verify_flash.py` 复验；`--no-verify` 跳过
- 建议已安装并登录 `gh`（避免 GitHub 匿名 API 限流）

## 刷机校验

刷机后可用 `Scripts/verify_flash.py` 校验路由器与本仓库 `Files/` 的一致性（含 secret 脱敏比对与 uci-defaults 运行时效果）：

```bash
pip install paramiko
python3 Scripts/verify_flash.py                              # 默认 192.168.1.2 root/root（旁路由）
python3 Scripts/verify_flash.py --host 10.0.0.1 --user admin --password xxxx
ROUTER_HOST=192.168.1.2 ROUTER_PASSWORD=root python3 Scripts/verify_flash.py
```

## 上游参考

- 自用源码：[VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)
- 自用插件：[VIKINGYFY/packages](https://github.com/VIKINGYFY/packages)
- 本地编译器：[VIKINGYFY/OWRT-Tools](https://github.com/VIKINGYFY/OWRT-Tools)
- 上游项目：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)
- U-BOOT（高通）：[chenxin527/uboot-qsdk12.5-build](https://github.com/chenxin527/uboot-qsdk12.5-build) / [1980490718/u-boot-2016](https://github.com/1980490718/u-boot-2016)

#
[![Stargazers over time](https://starchart.cc/VIKINGYFY/OpenWRT-CI.svg?variant=adaptive)](https://starchart.cc/VIKINGYFY/OpenWRT-CI)
