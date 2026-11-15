"""us_failover.sh 结构与配置校验（不做网络请求）。"""
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Files/usr/share/buffy/us_failover.sh"
CRON = ROOT / "Files/etc/crontabs/root"


class UsFailoverTest(unittest.TestCase):
    def test_shell_syntax(self):
        sh = shutil.which("sh")
        if not sh:
            self.skipTest("requires a POSIX shell")
        result = subprocess.run([sh, "-n", str(SCRIPT)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_targets_both_groups(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("check_group '美国自动'", text)
        self.assertIn("check_group '美国策略'", text)
        self.assertIn("US-Oracle", text)
        self.assertIn("mkdir \"$LOCK\"", text)

    def test_cron_registered(self):
        self.assertIn("/usr/share/buffy/us_failover.sh", CRON.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
