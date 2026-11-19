import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TARGET = Path(os.environ.get(
    "OVERWRITE_TARGET",
    ROOT / "Files/etc/openclash/custom/openclash_custom_overwrite.sh",
))


@unittest.skipUnless(shutil.which("sh"), "requires a POSIX shell")
class OverwriteHookTest(unittest.TestCase):
    def run_hook(self, content):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.yaml"
            helper = root / "ruby.sh"
            script = root / "hook.sh"
            helper.write_text('ruby_edit() { printf "%s\\0" ruby_edit "$@"; }\n',
                              encoding="utf-8")
            source = TARGET.read_text(encoding="utf-8")
            self.assertIn("/usr/share/openclash/ruby.sh", source)
            source = source.replace("/usr/share/openclash/ruby.sh",
                                    shlex.quote(helper.as_posix()))
            script.write_text(source, encoding="utf-8")
            if content is not None:
                config.write_text(content, encoding="utf-8")
            result = subprocess.run(
                [shutil.which("sh"), script.as_posix(), config.as_posix()],
                capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stderr, b"")
            if content is not None:
                self.assertEqual(config.read_text(encoding="utf-8"), content)
            fields = result.stdout.decode().split("\0")
            self.assertEqual(fields.pop(), "")
            return [fields[i:i + 4] for i in range(0, len(fields), 4)], config.as_posix()

    def assert_calls(self, content):
        calls, config = self.run_hook(content)
        self.assertEqual(calls, [
            ["ruby_edit", config, "['global-client-fingerprint']", '"chrome"'],
            ["ruby_edit", config, "['dns']['cache-size']", '"4096".to_i'],
            ["ruby_edit", config, "['dns']['listen']", '"127.0.0.1:7874"'],
        ])

    def test_missing_file(self):
        self.assertEqual(self.run_hook(None)[0], [])

    def test_empty_file(self):
        self.assertEqual(self.run_hook("")[0], [])

    def test_missing_keys_and_aliases(self):
        self.assert_calls("names: &names [DIRECT]\ndns:\n  enable: true\n"
                          "proxy-groups: [{name: test, type: select, proxies: *names}]\n")

    def test_existing_keys(self):
        self.assert_calls('global-client-fingerprint: firefox\ndns:\n'
                          '  cache-size: 1\n  listen: "0.0.0.0:7874"\n')

    def test_inline_dns_and_unrelated_keys(self):
        self.assert_calls('dns: {enable: true}\nother: {cache-size: 12, listen: localhost}\n')

    def test_no_default_selected_injection(self):
        """回归防护（26.11.19 实机事故）：不得再向任何组注入 default-selected。

        旧 US_FIRST 逻辑给所有含「美国策略」的 select 组写 default-selected，
        连「国内流量」也被改到美国节点，国内站点全部反向代理回源（TTFB 3~6s、
        淘宝整页 11s，DNS 因 respect-rules 一起变慢）。该逻辑已由 0ad3269 整段
        移除，本断言防止其被重新引入。
        """
        text = TARGET.read_text(encoding="utf-8")
        self.assertNotIn("default-selected", text)

    def test_domestic_group_not_hijacked(self):
        """功能验证：跑完 overwrite 后国内流量组不得被写上 default-selected。"""
        if not shutil.which("ruby"):
            self.skipTest("requires ruby")
        try:
            import yaml
        except ImportError:  # pragma: no cover
            self.skipTest("PyYAML not installed")
        config = (
            "proxy-groups:\n"
            "  - {name: 默认代理, type: select, proxies: [香港策略, 美国策略, 直接连接]}\n"
            "  - {name: 国内流量, type: select, proxies: [直接连接, 美国策略]}\n"
            "  - {name: 国外流量, type: select, proxies: [美国策略, 直接连接]}\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "config.yaml"
            config_path.write_text(config, encoding="utf-8")
            helper = root / "ruby.sh"
            helper.write_text("ruby_edit() { :; }\n", encoding="utf-8")
            script = root / "hook.sh"
            source = TARGET.read_text(encoding="utf-8")
            source = source.replace("/usr/share/openclash/ruby.sh",
                                    shlex.quote(helper.as_posix()))
            script.write_text(source, encoding="utf-8")
            result = subprocess.run(
                [shutil.which("sh"), script.as_posix(), config_path.as_posix()],
                capture_output=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            data = yaml.safe_load(config_path.read_text(encoding="utf-8"))
            groups = {g["name"]: g for g in data["proxy-groups"]}
            self.assertNotIn("default-selected", groups["国内流量"])
            self.assertNotIn("default-selected", groups["国外流量"])


if __name__ == "__main__":
    unittest.main()
