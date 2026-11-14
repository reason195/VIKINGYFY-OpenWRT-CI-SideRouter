"""校验随镜像发布的 OpenClash 覆写模块与首启登记脚本。

模块是纯文本 INI 三段格式（16-overwrite-module-format.md §16.2），这里只做结构校验，
避免把 YAML 解析器带进构建依赖；YAML 段用 PyYAML 解析（缺失则跳过）。
"""
import re
import shutil
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "Files/etc/openclash/overwrite/OC_SelfHeal_AntiLeak"
DEFAULTS = ROOT / "Files/etc/uci-defaults/93-buffy-openclash.sh"


class OverwriteModuleTest(unittest.TestCase):
    def setUp(self):
        self.text = MODULE.read_text(encoding="utf-8")

    def test_meta_header(self):
        self.assertTrue(self.text.startswith("#!NAME = OC_SelfHeal_AntiLeak"))
        self.assertIn("#!DESC = ", self.text)
        self.assertIn("#!CONFIG = all", self.text)

    def test_required_sections(self):
        for header in ("[General]", "[YAML]"):
            self.assertRegex(self.text, r"(?m)^" + re.escape(header) + r"\s*$")

    def test_general_keys(self):
        match = re.search(r"(?ms)^\[General\]\s*$", self.text)
        self.assertIsNotNone(match)
        general = re.split(r"(?m)^\[", self.text[match.end():])[0]
        for key in ("ENABLE_RESPECT_RULES", "APPEND_WAN_DNS", "IPV6_ENABLE",
                    "IPV6_DNS"):
            self.assertRegex(general, r"(?m)^" + key + r"\s*=")

    def test_yaml_block(self):
        try:
            import yaml
        except ImportError:  # pragma: no cover - 构建机无 PyYAML 时跳过
            self.skipTest("PyYAML not installed")
        match = re.search(r"(?ms)^\[YAML\]\s*$", self.text)
        self.assertIsNotNone(match)
        data = yaml.safe_load(self.text[match.end():])
        self.assertIs(data["dns"]["ipv6"], False)
        provider = data["proxy-providers*"]["set"]
        self.assertEqual(provider["interval"], 3600)
        self.assertEqual(provider["health-check"]["interval"], 60)
        self.assertEqual(provider["health-check"]["lazy"], False)
        self.assertEqual(provider["health-check"]["expected-status"], 204)
        group = data["<proxy-groups>*"]
        self.assertEqual(group["where"]["type"], "/^(url-test|fallback|load-balance)$/")
        self.assertEqual(group["set"]["interval"], 60)
        self.assertEqual(group["set"]["lazy"], False)
        self.assertEqual(group["set"]["expected-status"], 204)
        self.assertEqual(group["set"]["empty-fallback"], "DIRECT")

    def test_registered_by_uci_defaults(self):
        script = DEFAULTS.read_text(encoding="utf-8")
        self.assertIn("OC_SelfHeal_AntiLeak", script)
        self.assertIn("enable=1", script)
        self.assertIn("config_overwrite", script)

    def test_shell_syntax(self):
        sh = shutil.which("sh")
        if not sh:  # pragma: no cover
            self.skipTest("requires a POSIX shell")
        import subprocess
        result = subprocess.run([sh, "-n", str(DEFAULTS)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
