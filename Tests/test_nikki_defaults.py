"""nikki 出厂配置回归防护（26.11.20 实机事故）。

事故：nikki 出厂 enabled='1'，mixin 端口（9090/7890/7891/7892）与 OpenClash 完全
重叠。刷机后 nikki 先起占住端口，OpenClash 核心初始化超时自停，全网流量落到 nikki
订阅的 MATCH,PROXY 上——国内也走美国节点，TTFB 从 0.07s 劣化到 1s+。

本测试锁住三件事：
  1. nikki 出厂必须关闭（主代理栈是 OpenClash，两者不能同开）
  2. mixin 文件必须启用，且 fake-ip 白名单含国内域名
  3. mixin 规则必须含国内直连，且排在订阅的 MATCH,PROXY 之前（前置语义）
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UCI = ROOT / "Files/etc/config/nikki"
MIXIN = ROOT / "Files/etc/nikki/mixin.yaml"


class NikkiDefaultsTest(unittest.TestCase):
    def setUp(self):
        self.uci = UCI.read_text(encoding="utf-8")
        self.mixin = MIXIN.read_text(encoding="utf-8")

    def test_disabled_by_default(self):
        """端口与 OpenClash 重叠，出厂必须关闭，否则刷机后抢占代理栈。"""
        section = re.search(r"config config 'config'(.*?)\nconfig ", self.uci, re.S)
        self.assertIsNotNone(section, "未找到 config config 段")
        self.assertRegex(section.group(1), r"option enabled '0'")

    def test_mixin_enabled(self):
        self.assertRegex(self.uci, r"option mixin_file_content '1'")

    def test_fake_ip_filter_covers_cn(self):
        self.assertRegex(self.uci, r"option fake_ip_filter '1'")
        self.assertRegex(self.uci, r"list fake_ip_filters 'geosite:cn'")

    def test_mixin_has_direct_rules(self):
        for rule in ("GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve"):
            with self.subTest(rule=rule):
                self.assertIn(rule, self.mixin)

    def test_mixin_rules_prepend_key(self):
        """必须用 nikki-rules（前置语义），普通 rules 会被订阅覆盖。"""
        self.assertRegex(self.mixin, r"(?m)^nikki-rules:")


if __name__ == "__main__":
    unittest.main()
