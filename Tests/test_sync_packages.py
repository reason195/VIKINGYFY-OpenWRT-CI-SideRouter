import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/Sync-Packages.sh"
PATCH = """diff --git a/package/utils/ucode/Makefile b/package/utils/ucode/Makefile
--- a/package/utils/ucode/Makefile
+++ b/package/utils/ucode/Makefile
@@ -1,3 +1,3 @@
 PKG_NAME:=ucode
-PKG_VERSION:=old
+PKG_VERSION:=new
 PKG_RELEASE:=1
diff --git a/package/system/procd/Makefile b/package/system/procd/Makefile
--- a/package/system/procd/Makefile
+++ b/package/system/procd/Makefile
@@ -1,3 +1,3 @@
 PKG_NAME:=procd
-PKG_VERSION:=old
+PKG_VERSION:=new
 PKG_RELEASE:=1
"""


@unittest.skipUnless(shutil.which("bash") and shutil.which("git"), "requires bash and git")
class SyncPackagesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="package sync ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source tree"
        self.source.mkdir()
        result = subprocess.run(["git", "init", "-q", str(self.source)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.script = self.root / "Scripts/Sync-Packages.sh"
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        self.patch = self.script.parent / "patches/immortalwrt-base-packages.patch"
        self.patch.parent.mkdir()
        self.patch.write_text(PATCH, encoding="utf-8", newline="\n")
        self.recipes = ("package/utils/ucode/Makefile", "package/system/procd/Makefile")
        for path, name in zip(self.recipes, ("ucode", "procd")):
            target = self.source / path
            target.parent.mkdir(parents=True)
            target.write_text(f"PKG_NAME:={name}\nPKG_VERSION:=old\nPKG_RELEASE:=1\n",
                              encoding="utf-8", newline="\n")
        for path in ("target/linux/qualcommax/config-default",
                     "package/kernel/qca-nss-drv/Makefile", "files/etc/config/network"):
            target = self.source / path
            target.parent.mkdir(parents=True)
            target.write_text("device customization\n", encoding="utf-8", newline="\n")

    def snapshot(self):
        return {p.relative_to(self.source).as_posix(): p.read_bytes()
                for p in self.source.rglob("*")
                if p.is_file() and ".git" not in p.relative_to(self.source).parts}

    def run_sync(self, *args):
        return subprocess.run(
            [shutil.which("bash"), self.script.as_posix(), *args],
            capture_output=True, timeout=15,
            env={**os.environ, "GIT_CONFIG_COUNT": "1",
                 "GIT_CONFIG_KEY_0": "core.autocrlf", "GIT_CONFIG_VALUE_0": "false"},
        )

    def test_applies_all_recipes_without_touching_device_files(self):
        before = self.snapshot()
        result = self.run_sync(self.source.as_posix())
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        after = self.snapshot()
        for path, content in before.items():
            expected = content.replace(b":=old\n", b":=new\n") if path in self.recipes else content
            self.assertEqual(after[path], expected, path)
        self.assertEqual(after.keys(), before.keys())

    def test_repeat_is_idempotent(self):
        self.assertEqual(self.run_sync(self.source.as_posix()).returncode, 0)
        first = self.snapshot()
        self.assertEqual(self.run_sync(self.source.as_posix()).returncode, 0)
        self.assertEqual(self.snapshot(), first)

    def test_conflict_stops_without_partial_application(self):
        target = self.source / self.recipes[-1]
        target.write_text("different upstream version\n", encoding="utf-8", newline="\n")
        before = self.snapshot()
        result = self.run_sync(self.source.as_posix())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_partially_updated_tree_is_not_silently_accepted(self):
        target = self.source / self.recipes[0]
        target.write_bytes(target.read_bytes().replace(b":=old\n", b":=new\n"))
        before = self.snapshot()
        self.assertNotEqual(self.run_sync(self.source.as_posix()).returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_missing_patch_fails_without_changes(self):
        self.patch.unlink()
        before = self.snapshot()
        self.assertNotEqual(self.run_sync(self.source.as_posix()).returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_source_argument_is_required(self):
        before = self.snapshot()
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_package_pipeline_propagates_sync_failure(self):
        lines = (ROOT / "Scripts/Packages.sh").read_text(encoding="utf-8").splitlines()
        entry = 'bash "$GITHUB_WORKSPACE/Scripts/Sync-Packages.sh" "$GITHUB_WORKSPACE/wrt" || exit 1'
        self.assertIn(entry, lines)
        self.assertLess(lines.index(entry), next(i for i, line in enumerate(lines)
                                                if line.startswith("UPDATE_PACKAGE ")))


class BundledPatchTest(unittest.TestCase):
    def test_changes_only_reviewed_package_trees(self):
        text = (ROOT / "Scripts/patches/immortalwrt-base-packages.patch").read_text(encoding="utf-8")
        paths = re.findall(r"^diff --git a/(\S+) b/(\S+)$", text, re.MULTILINE)
        self.assertTrue(paths)
        recipes = (
            "libs/openssl", "libs/libjson-c", "utils/ucode", "system/procd",
            "libs/libnetfilter-conntrack", "libs/jansson", "libs/libnftnl",
            "network/utils/nftables", "network/services/dnsmasq",
            "network/config/wifi-scripts", "libs/libbpf", "network/services/uhttpd",
            "boot/uboot-tools", "libs/libffi",
        )
        changed = set()
        for before, after in paths:
            self.assertEqual(before, after)
            matches = [recipe for recipe in recipes if after.startswith(f"package/{recipe}/")]
            self.assertEqual(len(matches), 1, after)
            changed.add(matches[0])
            self.assertFalse(after.startswith("package/boot/uboot-tools/uboot-envtools/files/"))
        self.assertEqual(changed, set(recipes))

    def test_preserves_existing_executable_modes(self):
        text = (ROOT / "Scripts/patches/immortalwrt-base-packages.patch").read_text(encoding="utf-8")
        blocks = re.split(r"(?=^diff --git )", text, flags=re.MULTILINE)[1:]
        executable_paths = {
            "package/network/services/dnsmasq/files/dnsmasq.init",
            "package/network/config/wifi-scripts/files/lib/netifd/wireless/mac80211.sh",
            "package/network/config/wifi-scripts/files-ucode/lib/netifd/wireless/mac80211.sh",
            *(f"package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/{name}.uc"
              for name in ("ap", "hostapd", "iface", "supplicant", "validate")),
        }
        checked = set()
        for block in blocks:
            path = block.splitlines()[0].split()[2][2:]
            self.assertNotRegex(block, r"(?m)^(old|new) mode ")
            if path in executable_paths:
                self.assertRegex(block, r"(?m)^index [0-9a-f]+\.\.[0-9a-f]+ 100755$")
                checked.add(path)
        self.assertEqual(checked, executable_paths)

    def test_snapshot_provenance_is_pinned(self):
        text = (ROOT / "Scripts/patches/immortalwrt-base-packages.patch").read_text(encoding="utf-8")
        self.assertIn("Source: https://github.com/immortalwrt/immortalwrt/commit/"
                      "4765b657625ec5bbda74b44400465fe043802b30\n", text)
        self.assertIn("Base: https://github.com/VIKINGYFY/immortalwrt/commit/"
                      "f9b0ce7650fdcc7f4793256a3ae43c1132e2bc49\n", text)


if __name__ == "__main__":
    unittest.main()
