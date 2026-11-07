import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/openclash_sub_domains.py"
FAKE = ROOT / "Files/etc/openclash/custom/openclash_custom_fake_filter.list"
POLICY = ROOT / "Files/etc/openclash/custom/openclash_custom_domain_dns_policy.list"

CONFIG = """\
mixed-port: 7890
proxy-providers:
  优质服务商:
    type: http
    url: https://m1.tohno-0.top/api/v1/client/subscribe?token=abc
    interval: 3600
  备用服务商:
    type: http
    url: "https://sub.reason195.de5.net/sub/starter2026/mihomo.yaml"
  relay:
    type: http
    url: http://192.0.2.10/sub
  local:
    type: file
    path: ./proxy_provider/local.yaml
rules:
  - IP-CIDR,198.18.0.0/16,DIRECT
rule-providers:
  rule:
    type: http
    behavior: domain
    url: https://rules.example.net/rule.mrs
"""


class SubscriptionDomainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="oc-subdom-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.yaml = self.tmp / "MihomoPro.yaml"
        self.yaml.write_text(CONFIG, encoding="utf-8")
        self.fake = self.tmp / "fake.list"
        self.policy = self.tmp / "policy.list"
        self.fake.write_text(FAKE.read_text(encoding="utf-8"), encoding="utf-8")
        self.policy.write_text(POLICY.read_text(encoding="utf-8"), encoding="utf-8")

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.yaml), str(self.fake), str(self.policy)],
            capture_output=True, text=True, timeout=20,
        )

    def test_static_lists_cover_current_airport(self):
        """静态兜底必须含本次事故的机场域名，防止有人改回只有 aisaka。"""
        for path in (FAKE, POLICY):
            text = path.read_text(encoding="utf-8")
            self.assertIn("+.tohno-0.top", text, path)
            self.assertIn("+.de5.net", text, path)

    def test_extracts_only_proxy_provider_hosts(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        fake = self.fake.read_text(encoding="utf-8")
        policy = self.policy.read_text(encoding="utf-8")
        # 静态列表已覆盖 tohno-0.top / de5.net，不应重复追加
        self.assertEqual(fake.count("+.tohno-0.top"), 1)
        self.assertEqual(fake.count("+.de5.net"), 1)
        self.assertEqual(policy.count("+.tohno-0.top"), 1)
        self.assertEqual(policy.count("+.de5.net"), 1)
        # rule-providers / rules 段的域名不是订阅源，不得混入
        self.assertNotIn("rules.example.net", fake)
        self.assertNotIn("rules.example.net", policy)
        # IP 与 file provider 不产生条目
        self.assertNotIn("192.0.2.10", fake)
        self.assertNotIn("192.0.2.10", policy)

    def test_appends_new_airport_and_is_idempotent(self):
        self.fake.write_text("+.github.com\n", encoding="utf-8")
        self.policy.write_text('"geosite:cn":\n  - https://doh.pub/dns-query\n', encoding="utf-8")

        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        fake = self.fake.read_text(encoding="utf-8")
        policy = self.policy.read_text(encoding="utf-8")
        self.assertIn("+.m1.tohno-0.top", fake)
        self.assertIn("+.sub.reason195.de5.net", fake)
        self.assertIn("+.m1.tohno-0.top", policy)
        self.assertIn("+.sub.reason195.de5.net", policy)

        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.fake.read_text(encoding="utf-8"), fake)
        self.assertEqual(self.policy.read_text(encoding="utf-8"), policy)
        self.assertIn("无需追加", second.stdout)

    def test_parent_domain_covers_child(self):
        self.fake.write_text("+.tohno-0.top\n+.de5.net\n", encoding="utf-8")
        self.policy.write_text('"+.tohno-0.top,+.de5.net":\n  - https://doh.pub/dns-query\n', encoding="utf-8")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fake.read_text(encoding="utf-8"), "+.tohno-0.top\n+.de5.net\n")
        self.assertEqual(
            self.policy.read_text(encoding="utf-8"),
            '"+.tohno-0.top,+.de5.net":\n  - https://doh.pub/dns-query\n',
        )

    def test_no_proxy_providers_is_non_fatal(self):
        self.yaml.write_text("mixed-port: 7890\n", encoding="utf-8")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stdout + result.stderr)

    def test_missing_config_is_non_fatal(self):
        self.yaml.unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stderr)


if __name__ == "__main__":
    unittest.main()
