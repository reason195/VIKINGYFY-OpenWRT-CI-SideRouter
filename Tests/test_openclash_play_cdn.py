import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CUSTOM = ROOT / "Files/etc/openclash/custom"
RULES = CUSTOM / "openclash_custom_rules.list"
FAKE = CUSTOM / "openclash_custom_fake_filter.list"
UCI = ROOT / "Files/etc/uci-defaults/93-buffy-openclash.sh"
RC = ROOT / "Files/etc/rc.local"


class PlayCdnFixTest(unittest.TestCase):
    """Google Play 下载 CDN 修复的出厂文件静态断言（无需路由器）。"""

    def test_rules_file_has_direct_and_proxy_rules(self):
        text = RULES.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("rules:"), "自定义规则文件必须以 rules: 开头")
        for line in (
            "DOMAIN-SUFFIX,gvt1-cn.com,直接连接",
            "DOMAIN-SUFFIX,gvt2-cn.com,直接连接",
            "DOMAIN-SUFFIX,xn--ngstr-lra8j.com,直接连接",
            "DOMAIN-SUFFIX,gvt1.com,谷歌服务",
            "DOMAIN-SUFFIX,googleapis.com,谷歌服务",
            "DOMAIN,play.googleapis.com,谷歌服务",
        ):
            self.assertIn("- " + line, text)

    def test_direct_rules_precede_proxy_rules(self):
        lines = [l.strip() for l in RULES.read_text(encoding="utf-8").splitlines()
                 if l.strip().startswith("- ")]
        self.assertLess(lines.index("- DOMAIN-SUFFIX,gvt1-cn.com,直接连接"),
                        lines.index("- DOMAIN-SUFFIX,gvt1.com,谷歌服务"))

    def test_fake_filter_has_cdn_domains(self):
        text = FAKE.read_text(encoding="utf-8")
        for domain in ("+.gvt1-cn.com", "+.gvt2-cn.com", "+.xn--ngstr-lra8j.com"):
            self.assertIn(domain, text)

    def test_fake_filter_keeps_subscription_domains(self):
        text = FAKE.read_text(encoding="utf-8")
        for domain in ("+.tohno-0.top", "+.de5.net", "+.github.com", "+.jsdelivr.net"):
            self.assertIn(domain, text)

    def test_uci_defaults_enables_custom_rules(self):
        self.assertIn("uci set openclash.config.enable_custom_clash_rules='1'",
                      UCI.read_text(encoding="utf-8"))

    def test_rc_local_self_heals_rules(self):
        text = RC.read_text(encoding="utf-8")
        self.assertIn("openclash_custom_rules.list", text)
        self.assertIn("enable_custom_clash_rules", text)


if __name__ == "__main__":
    unittest.main()
