import importlib.util
import io
from pathlib import Path
import shlex
import sys
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "Scripts" / "verify_flash.py"
spec = importlib.util.spec_from_file_location("verify_flash_under_test", SCRIPT)
vf = importlib.util.module_from_spec(spec)
with mock.patch.dict(sys.modules, {"paramiko": mock.Mock()}), \
        mock.patch("sys.stdout", new=io.StringIO()):
    spec.loader.exec_module(vf)

DNS_OPTIONS = ("enabled", "type", "ip", "group")
DNS_SERVERS = (
    ("1", "udp", "119.29.29.29", "default"),
    ("1", "udp", "223.5.5.5", "default"),
    ("1", "https", "dns.cloudflare.com/dns-query", "nameserver"),
    ("1", "https", "dns.google/dns-query", "nameserver"),
)
SUBSCRIPTION_PATH = "/etc/openclash/config/MihomoPro.yaml"
RUNTIME_PATH = "/etc/openclash/MihomoPro.yaml"
PASS_LINES = (
    "PASS global-client-fingerprint",
    "PASS dns.cache-size",
    "PASS dns.listen",
    "PASS dns.respect-rules",
    "PASS dns.nameserver",
    "PASS dns.default-nameserver",
    "PASS dns.fake-ip-filter",
    "PASS dns.nameserver-policy",
)
PASS_OUTPUT = "\n".join((*PASS_LINES, "CHECK_COMPLETE"))
IDLE_COMMAND = (
    'for s in wpad relayd radius odhcpd; do '
    '[ -x "/etc/init.d/$s" ] || continue; '
    'if /etc/init.d/$s enabled; then echo "enabled=$s"; fi; '
    'done; '
    'pidof wpad hostapd wpa_supplicant relayd radius radiusd odhcpd; '
    'echo CHECK_COMPLETE'
)


def dns_config(indices=(0, 1, 2, 3)):
    result = {"openclash.config.config_path": SUBSCRIPTION_PATH}
    for index, values in zip(indices, DNS_SERVERS):
        section = f"openclash.@dns_servers[{index}]"
        result[section] = "dns_servers"
        result.update((f"{section}.{key}", value)
                      for key, value in zip(DNS_OPTIONS, values))
    return result


def cmdline(path=RUNTIME_PATH):
    return "\0".join(("/etc/openclash/core/clash", "-d", "/etc/openclash",
                      "-f", path, "")).encode("utf-8")


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        for name in ("ssh_cli", "ssh_sftp"):
            patcher = mock.patch.object(vf, name, side_effect=AssertionError("SSH forbidden"))
            blocked = patcher.start()
            self.addCleanup(patcher.stop)
            self.addCleanup(blocked.assert_not_called)


class DnsServersTest(OfflineTestCase):
    def assert_rejected(self, data):
        errors = vf.check_dns_servers(data)
        self.assertEqual(len(errors), 1)
        self.assertIn("dns_servers", errors[0])

    def test_correct_dns(self):
        self.assertEqual(vf.check_dns_servers(dns_config()), [])

    def test_sections_are_sorted_numerically_not_by_insertion(self):
        data = dict(reversed(list(dns_config((0, 1, 2, 10)).items())))
        self.assertEqual(vf.check_dns_servers(data), [])

    def test_four_empty_sections(self):
        self.assert_rejected({f"openclash.@dns_servers[{i}]": "dns_servers"
                              for i in range(4)})

    def test_no_sections(self):
        self.assert_rejected({})

    def test_missing_section(self):
        for i in range(4):
            with self.subTest(section=i):
                prefix = f"openclash.@dns_servers[{i}]"
                self.assert_rejected({k: v for k, v in dns_config().items()
                                      if k != prefix and not k.startswith(prefix + ".")})

    def test_missing_options(self):
        for i in range(4):
            for option in DNS_OPTIONS:
                with self.subTest(section=i, option=option):
                    data = dns_config()
                    del data[f"openclash.@dns_servers[{i}].{option}"]
                    self.assert_rejected(data)

    def test_disabled_sections(self):
        for i in range(4):
            with self.subTest(section=i):
                data = dns_config()
                data[f"openclash.@dns_servers[{i}].enabled"] = "0"
                self.assert_rejected(data)

    def test_wrong_type_ip_or_group(self):
        for i in range(4):
            for option, value in (("type", "tls"), ("ip", "8.8.8.8"),
                                  ("group", "fallback")):
                with self.subTest(section=i, option=option):
                    data = dns_config()
                    data[f"openclash.@dns_servers[{i}].{option}"] = value
                    self.assert_rejected(data)

    def test_wrong_section_type(self):
        for i in range(4):
            with self.subTest(section=i):
                data = dns_config()
                data[f"openclash.@dns_servers[{i}]"] = "authentication"
                self.assert_rejected(data)

    def test_extra_empty_or_populated_section(self):
        for populated in (False, True):
            with self.subTest(populated=populated):
                data = dns_config()
                section = "openclash.@dns_servers[4]"
                data[section] = "dns_servers"
                if populated:
                    data.update((f"{section}.{key}", value)
                                for key, value in zip(DNS_OPTIONS, DNS_SERVERS[0]))
                self.assert_rejected(data)

    def test_literal_quotes(self):
        for key, value in dns_config().items():
            if not key.startswith("openclash.@dns_servers["):
                continue
            for quote in ("'", '"'):
                with self.subTest(key=key, quote=quote):
                    data = dns_config()
                    data[key] = quote + value + quote
                    self.assert_rejected(data)


class OpenClashRuntimeTest(OfflineTestCase):
    def check_runtime(self, *, pid=("2468", ""), args=cmdline(),
                      ruby=(PASS_OUTPUT, "")):
        with mock.patch.object(vf, "run", side_effect=[pid, ruby]) as run, \
                mock.patch.object(vf, "router_bytes", return_value=args) as read, \
                mock.patch.object(vf, "uci_dump", return_value={
                    "openclash.config.config_path": SUBSCRIPTION_PATH}) as uci:
            self.run_mock, self.read_mock = run, read
            self.calls = mock.Mock()
            self.calls.attach_mock(run, "run")
            self.calls.attach_mock(read, "read")
            result = vf.check_openclash_runtime()
            uci.assert_not_called()
        return result

    def assert_pid_rejected(self, pid):
        ok, detail = self.check_runtime(pid=pid)
        self.assertIs(ok, False)
        self.assertIn("无法确定唯一 Clash 进程", detail)
        self.run_mock.assert_called_once_with("pidof clash")
        self.read_mock.assert_not_called()

    def test_runtime_passes_in_expected_call_order(self):
        ok, detail = self.check_runtime()
        self.assertIs(ok, True)
        self.assertIn(f"配置={RUNTIME_PATH}", detail)
        self.assertIn("CHECK_COMPLETE", detail)
        self.assertEqual(self.calls.mock_calls, [
            mock.call.run("pidof clash"),
            mock.call.read("/proc/2468/cmdline"),
            mock.call.run(mock.ANY, timeout=30),
        ])

    def test_no_process(self):
        self.assert_pid_rejected(("", ""))

    def test_multiple_processes(self):
        for pids in ("2468 1357", "2468\n1357"):
            with self.subTest(pids=pids):
                self.assert_pid_rejected((pids, ""))

    def test_invalid_pid(self):
        for pid in ("clash", "2468; id", "-1"):
            with self.subTest(pid=pid):
                self.assert_pid_rejected((pid, ""))

    def test_pid_ssh_error(self):
        for pid in ("", "2468"):
            with self.subTest(pid=pid):
                self.assert_pid_rejected((pid, "EXEC-ERR: SSH disconnected"))

    def test_unreadable_cmdline(self):
        for args in (None, b""):
            with self.subTest(args=args):
                ok, detail = self.check_runtime(args=args)
                self.assertIs(ok, False)
                self.assertIn("无法读取", detail)
                self.read_mock.assert_called_once_with("/proc/2468/cmdline")
                self.run_mock.assert_called_once_with("pidof clash")

    def test_missing_f_option(self):
        for args in (b"clash\0-d\0/etc/openclash\0",
                     b"clash\0-f=/etc/openclash/runtime.yaml\0"):
            with self.subTest(args=args):
                ok, detail = self.check_runtime(args=args)
                self.assertIs(ok, False)
                self.assertIn("缺少 -f 配置路径", detail)
                self.run_mock.assert_called_once_with("pidof clash")

    def test_missing_f_path(self):
        for args in (b"clash\0-f", b"clash\0-f\0", b"clash\0-f\0\0"):
            with self.subTest(args=args):
                ok, detail = self.check_runtime(args=args)
                self.assertIs(ok, False)
                self.assertIn("缺少 -f 配置路径", detail)
                self.run_mock.assert_called_once_with("pidof clash")

    def test_ruby_command_uses_runtime_not_subscription(self):
        self.check_runtime()
        command = self.run_mock.call_args.args[0]
        argv = shlex.split(command)
        self.assertEqual(argv[-1], RUNTIME_PATH)
        self.assertIn("YAML.load_file(ARGV[0])", argv[-2])
        self.assertNotIn("/etc/openclash/config/", command)
        self.assertNotIn(SUBSCRIPTION_PATH, command)

    def test_runtime_path_is_shell_quoted_without_injection(self):
        paths = (
            "/etc/openclash/runtime config.yaml",
            "/etc/openclash/user's config.yaml",
            "/etc/openclash/user's config; $(id) `id` & injected.yaml",
        )
        for path in paths:
            with self.subTest(path=path):
                ok, detail = self.check_runtime(args=cmdline(path))
                self.assertIs(ok, True)
                command = self.run_mock.call_args.args[0]
                argv = shlex.split(command)
                self.assertEqual(len(argv), 10)
                self.assertEqual(argv[:-2], ["ruby", "-ryaml", "-rYAML", "-I",
                                            "/usr/share/openclash", "-E", "UTF-8", "-e"])
                self.assertEqual(argv[-1], path)
                self.assertTrue(command.endswith(" " + shlex.quote(path)))
                self.assertIn(f"配置={path};", detail)

    def test_ruby_exception_or_ssh_error(self):
        for error in ("Psych::SyntaxError: invalid YAML", "EXEC-ERR: SSH disconnected"):
            for output in ("", PASS_OUTPUT):
                with self.subTest(error=error, output=output):
                    ok, detail = self.check_runtime(ruby=(output, error))
                    self.assertIs(ok, False)
                    self.assertIn(error, detail)

    def test_ruby_empty_output(self):
        ok, _ = self.check_runtime(ruby=("", ""))
        self.assertIs(ok, False)

    def test_ruby_incomplete_output(self):
        for output in ("CHECK_COMPLETE", "\n".join(PASS_LINES),
                       "\n".join((*PASS_LINES[:5], "CHECK_COMPLETE"))):
            with self.subTest(output=output):
                ok, _ = self.check_runtime(ruby=(output, ""))
                self.assertIs(ok, False)

    def test_ruby_fail_output(self):
        for i in range(6):
            with self.subTest(check=i):
                lines = list(PASS_LINES)
                lines[i] = lines[i].replace("PASS ", "FAIL ", 1)
                output = "\n".join((*lines, "CHECK_COMPLETE"))
                ok, detail = self.check_runtime(ruby=(output, ""))
                self.assertIs(ok, False)
                self.assertIn(lines[i], detail)

    def test_ruby_extra_or_malformed_output(self):
        outputs = (
            PASS_OUTPUT + "\nPASS extra",
            "PASS extra\n" + PASS_OUTPUT,
            "CHECK_COMPLETE\n" + "\n".join(PASS_LINES),
            PASS_OUTPUT.replace("PASS dns.listen", "PASSdns.listen"),
        )
        for output in outputs:
            with self.subTest(output=output):
                ok, _ = self.check_runtime(ruby=(output, ""))
                self.assertIs(ok, False)


class IdleServicesTest(OfflineTestCase):
    def check_idle(self, output, error=""):
        def run(command, timeout=15):
            return (output, error) if command == IDLE_COMMAND else ("", "")

        with mock.patch.object(vf, "uci_dump", return_value={}), \
                mock.patch.object(vf, "run", side_effect=run) as run_mock:
            results = [result for result in vf.check_uci_defaults()
                       if result[0] == "95-buffy-idle-services.sh"]
            run_mock.assert_any_call(IDLE_COMMAND, timeout=20)
        self.assertEqual(len(results), 1)
        return results[0][1:]

    def test_disabled_and_not_running(self):
        ok, _ = self.check_idle("CHECK_COMPLETE")
        self.assertIs(ok, True)

    def test_enabled_service_fails(self):
        for service in ("wpad", "relayd", "radius", "odhcpd"):
            with self.subTest(service=service):
                ok, detail = self.check_idle(f"enabled={service}\nCHECK_COMPLETE")
                self.assertIs(ok, False)
                self.assertIn(f"enabled={service}", detail)

    def test_running_pid_fails(self):
        for pids in ("2468", "2468 1357"):
            with self.subTest(pids=pids):
                ok, detail = self.check_idle(f"{pids}\nCHECK_COMPLETE")
                self.assertIs(ok, False)
                self.assertIn(pids, detail)

    def test_ssh_error_fails_even_with_completion(self):
        for output in ("", "CHECK_COMPLETE"):
            with self.subTest(output=output):
                ok, detail = self.check_idle(output, "EXEC-ERR: SSH disconnected")
                self.assertIs(ok, False)
                self.assertIn("EXEC-ERR", detail)

    def test_missing_completion_fails(self):
        for output in ("", "enabled=wpad", "2468"):
            with self.subTest(output=output):
                ok, _ = self.check_idle(output)
                self.assertIs(ok, False)


class MainExitCodeTest(OfflineTestCase):
    def run_main(self, ruby_output):
        with mock.patch.object(sys, "argv", [str(SCRIPT)]), \
                mock.patch.object(vf, "_SSH", {}), \
                mock.patch.object(vf, "ssh_cli") as ssh, \
                mock.patch.object(vf.os.path, "isdir", return_value=True), \
                mock.patch.object(vf.os, "walk", return_value=[]), \
                mock.patch.object(vf, "RUNTIME_CHECKS", []), \
                mock.patch.object(vf, "check_uci_defaults", return_value=[
                    ("95-buffy-idle-services.sh", True, "disabled")]), \
                mock.patch.object(vf, "router_bytes", return_value=cmdline()) as read, \
                mock.patch.object(vf, "run", side_effect=[
                    ("2468", ""), (ruby_output, "")]) as run, \
                mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            code = vf.main()
            ssh.assert_called_once_with(force=True)
            read.assert_called_once_with("/proc/2468/cmdline")
            self.assertEqual(run.call_count, 2)
        return code, output.getvalue()

    def test_success_returns_zero(self):
        code, output = self.run_main(PASS_OUTPUT)
        self.assertEqual(code, 0)
        self.assertIn("[PASS] 固件校验", output)

    def test_runtime_failure_alone_returns_one(self):
        code, output = self.run_main(PASS_OUTPUT.replace("PASS dns.listen", "FAIL dns.listen"))
        self.assertEqual(code, 1)
        self.assertIn("[FAIL] 固件校验：1 项不一致", output)


if __name__ == "__main__":
    unittest.main()
