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


if __name__ == "__main__":
    unittest.main()
