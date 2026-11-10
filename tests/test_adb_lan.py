import ipaddress
import unittest
from unittest.mock import patch

import adb_lan
from adb_lan import (
    AdbLan, endpoint_parts, explain_failure, parse_devices, parse_interfaces,
    parse_listeners, parse_mdns,
)


class ParserTests(unittest.TestCase):
    def test_devices_distinguish_usb_network_and_emulator_states(self):
        text = """List of devices attached
0123abcd device usb:2-1.2 model:24053PY09C
10.0.0.5:5555 device model:PJZ110
emulator-5554 offline
"""
        found = parse_devices(text)
        self.assertEqual(found["0123abcd"]["model_hint"], "24053PY09C")
        self.assertEqual(found["10.0.0.5:5555"]["state"], "device")
        self.assertEqual(found["emulator-5554"]["state"], "offline")

    def test_transient_mdns_service_is_not_a_disconnected_device(self):
        found = parse_devices(
            "List of devices attached\n"
            "adb-2a77f61a-vWy7Uy._adb-tls-connect._tcp offline\n"
            "10.0.0.5:33849 device model:PJZ110\n"
        )
        self.assertEqual(list(found), ["10.0.0.5:33849"])

    def test_mdns_and_emulator_listener_parsing(self):
        services = parse_mdns(
            "adb-serial _adb-tls-connect._tcp 10.0.0.5:40853\n"
            "adb-other _adb-tls-pairing._tcp 10.0.0.7:45201\n"
        )
        self.assertEqual(services[0]["endpoint"], "10.0.0.5:40853")
        self.assertEqual(services[1]["service"], "_adb-tls-pairing._tcp")
        listeners = parse_listeners(
            "MuMuEmula 123 user 42u IPv4 1 0t0 TCP *:16416 (LISTEN)\n"
            "MuMuEmula 123 user 43u IPv4 1 0t0 TCP *:18464 (LISTEN)\n"
            "Chrome 124 user 4u IPv4 1 0t0 TCP *:5555 (LISTEN)"
        )
        self.assertEqual(listeners, ["127.0.0.1:16416"])

    def test_network_scope_caps_large_network_and_skips_vpn(self):
        networks, notes = parse_interfaces(
            "en1: flags=1\n\tinet 10.0.0.3 netmask 0xffffff00 broadcast 10.0.0.255\n"
            "en2: flags=1\n\tinet 192.168.2.4 netmask 0xffff0000 broadcast 192.168.255.255\n"
            "utun0: flags=1\n\tinet 100.64.0.2 netmask 0xffffffff\n"
        )
        self.assertEqual(networks, [
            ipaddress.IPv4Network("10.0.0.0/24"),
            ipaddress.IPv4Network("192.168.2.0/24"),
        ])
        self.assertEqual(len(notes), 1)

    def test_endpoint_validation_and_failure_reason(self):
        self.assertIsNone(endpoint_parts("10.0.0.2:99999"))
        self.assertIsNone(endpoint_parts("host.example:5555"))
        self.assertEqual(endpoint_parts("10.0.0.5:5555"), ("10.0.0.5", 5555))
        self.assertIn("重启", explain_failure("No route to host"))
        self.assertIn("授权", explain_failure("unauthorized"))
        host_down = "failed to connect to '10.0.0.250:5555': Host is down"
        self.assertIn("没有响应", explain_failure(host_down))
        self.assertNotIn("端口开放", explain_failure("failed", port_reachable=False))
        self.assertIn("端口开放", explain_failure("failed", port_reachable=True))


class RecoveryTests(unittest.TestCase):
    def test_active_projection_prevents_server_restart(self):
        with patch.object(adb_lan, "run_command", return_value=(0,
            "/Library/Application Support/Mirrors/a.app/Contents/MacOS/scrcpy --serial=usb\n"
        )):
            self.assertTrue(adb_lan.active_mirror_process())
        with patch.object(adb_lan, "run_command", return_value=(0,
            "/Library/Application Support/Mirrors/a.app/Contents/MacOS/scrcpy --serial=usb --no-window\n"
        )):
            self.assertFalse(adb_lan.active_mirror_process())

    def test_event_scan_skips_subnet_probe(self):
        manager = AdbLan()
        with (
            patch.object(manager, "command", return_value=(0, "")),
            patch.object(manager, "devices", return_value={}),
            patch.object(manager, "load_known", return_value={}),
            patch.object(manager, "save_known"),
            patch.object(manager, "_discover_emulators", return_value=[]),
            patch.object(manager, "_discover_lan_ports", side_effect=AssertionError("subnet scan")),
            patch.object(adb_lan, "run_command", return_value=(0, "")),
        ):
            report = manager.scan(include_subnet_scan=False)
        self.assertEqual(report["devices"], [])

    def run_known_scan(self, port_is_open):
        endpoint = "10.0.0.9:5555"
        manager = AdbLan()
        with (
            patch.object(manager, "command", return_value=(0, "failed to connect: timed out")),
            patch.object(manager, "devices", return_value={}),
            patch.object(manager, "load_known", return_value={endpoint: "tv-serial"}),
            patch.object(manager, "save_known"),
            patch.object(manager, "_discover_emulators", return_value=[]),
            patch.object(adb_lan, "port_open", return_value=port_is_open),
            patch.object(adb_lan, "run_command", return_value=(
                0, "en1: flags=1\n\tinet 10.0.0.3 netmask 0xffffff00\n"
            )),
            patch.object(adb_lan.time, "sleep"),
        ):
            return manager.scan(include_subnet_scan=False)

    def test_offline_remembered_device_is_not_reported(self):
        # A TV on standby: only its old address is known and nothing answers.
        report = self.run_known_scan(port_is_open=False)
        self.assertEqual(report["failed"], [])

    def test_reachable_remembered_device_that_fails_is_reported(self):
        report = self.run_known_scan(port_is_open=True)
        self.assertEqual([item["endpoint"] for item in report["failed"]], ["10.0.0.9:5555"])

    def test_two_mumu_ports_share_one_emulator_identity(self):
        manager = AdbLan()
        manager.emulator_pids = {
            "127.0.0.1:16416": 1234, "127.0.0.1:5555": 1234,
        }
        with patch.object(manager, "command", return_value=(0, "23052a7f75e15cb4")):
            first = manager._identity("127.0.0.1:16416")
            second = manager._identity("127.0.0.1:5555")
        self.assertEqual(first, second)
        self.assertEqual(first, "emulator-process:1234")
        self.assertEqual(manager._identity("emulator-5554"), first)

    def test_restarts_only_local_adb_when_port_open_but_adb_says_no_route(self):
        endpoint = "10.0.0.5:5555"
        manager = AdbLan()
        command_calls = []
        connected = {"serial": endpoint, "state": "device", "model_hint": "PJZ110"}
        device_states = iter([{}, {}, {endpoint: connected}, {endpoint: connected}])

        def fake_command(*args, **_kwargs):
            command_calls.append(args)
            if args[:1] == ("connect",):
                count = sum(call[:1] == ("connect",) for call in command_calls)
                return (0, "No route to host" if count <= 2 else "connected to " + endpoint)
            return 0, ""

        with (
            patch.object(manager, "command", side_effect=fake_command),
            patch.object(manager, "devices", side_effect=lambda: next(device_states)),
            patch.object(manager, "load_known", return_value={}),
            patch.object(manager, "save_known"),
            patch.object(manager, "_discover_lan_ports", return_value=[endpoint]),
            patch.object(manager, "_discover_emulators", return_value=[]),
            patch.object(manager, "_details", return_value={
                "identity": "oneplus-serial", "manufacturer": "OnePlus",
                "model": "PJZ110", "emulator": False,
            }),
            patch.object(adb_lan, "port_open", return_value=True),
            patch.object(adb_lan, "run_command", return_value=(
                0, "en1: flags=1\n\tinet 10.0.0.3 netmask 0xffffff00\n"
            )),
            patch.object(adb_lan.time, "sleep"),
        ):
            report = manager.scan()

        self.assertIn(("kill-server",), command_calls)
        self.assertTrue(report["devices"][0]["wireless"])
        self.assertFalse(report["failed"])

    def test_manual_connect_keeps_adb_server_while_projecting(self):
        endpoint = "10.0.0.5:5555"
        manager = AdbLan()
        manager.networks = [ipaddress.IPv4Network("10.0.0.0/24")]
        command_calls = []

        def fake_command(*args, **_kwargs):
            command_calls.append(args)
            return (0, "No route to host") if args[:1] == ("connect",) else (0, "")

        with (
            patch.object(manager, "command", side_effect=fake_command),
            patch.object(manager, "devices", return_value={}),
            patch.object(adb_lan, "port_open", return_value=True),
            patch.object(adb_lan, "active_mirror_process", return_value=True),
            patch.object(adb_lan.time, "sleep"),
        ):
            result = manager.connect_manual(endpoint)

        self.assertNotIn(("kill-server",), command_calls)
        self.assertFalse(result["ok"])
        self.assertIn("投屏", result["reason"])


class DeviceInfoTests(unittest.TestCase):
    def test_parses_sections_from_one_shell_output(self):
        sep = adb_lan.INFO_SEPARATOR
        parts = [
            "[ro.product.marketname]: [Xiaomi Civi 4 Pro]\n[ro.product.brand]: [Xiaomi]\n"
            "[ro.product.model]: [24053PY09C]\n[ro.build.version.release]: [16]\n"
            "[ro.build.version.sdk]: [36]\n[ro.mi.os.version.name]: [OS3.0]\n"
            "[ro.soc.manufacturer]: [QTI]\n[ro.soc.model]: [SM8635]\n"
            "[ro.board.platform]: [pineapple]",
            "Physical size: 1236x2750\nPhysical density: 480",
            "MemTotal:       11542320 kB\nMemAvailable:    7130000 kB",
            "Filesystem 1K-blocks Used Available Use% Mounted on\n"
            "/dev/block/dm-54 487987180 80211968 407644140  17% /data",
            "Current Battery Service state:\n  AC powered: true\n  USB powered: false\n"
            "  status: 2\n  health: 2\n  level: 79\n  voltage: 4100\n  temperature: 235",
            "Xiaomi Civi 4 Pro",
            "6.1.138",
            "7030.5 1000.0",
            "0-7",
            "3014400\n2112000",
            "24: wlan0    inet 10.0.0.6/24 brd 10.0.0.255 scope global wlan0\n"
            "32: vgate0    inet 172.30.250.24/32 scope global vgate0",
            "renderFrameRate 60.000004\nfps=120.00001\nfps=60.000004",
            "45.62.126.7",
        ]
        keys = ["getprop", "screen", "meminfo", "df", "battery", "device_name", "kernel",
                "uptime", "cpu_possible", "cpu_freq", "ip_addr", "display", "public_ip"]
        sections = {
            section["title"]: dict(section["items"])
            for section in adb_lan.parse_device_info(dict(zip(keys, parts)))
        }
        self.assertEqual(sections["概览"]["名称"], "Xiaomi Civi 4 Pro")
        self.assertNotIn("制造商", sections["概览"])  # same as the brand
        self.assertNotIn("机型", sections["概览"])  # same as the retail name
        self.assertEqual(sections["系统"]["Android"], "16（API 36）")
        self.assertEqual(sections["系统"]["系统界面"], "Xiaomi HyperOS 3.0")
        self.assertEqual(sections["系统"]["已运行"], "1 小时 57 分钟")
        self.assertEqual(sections["硬件"]["处理器"], "QTI SM8635")
        self.assertEqual(sections["硬件"]["CPU"], "8 核 · 最高 3.01 GHz")
        self.assertEqual(sections["硬件"]["内存"], "11.0 GB（可用 6.8 GB）")
        self.assertEqual(sections["屏幕"]["刷新率"], "当前 60 Hz · 最高 120 Hz")
        self.assertEqual(sections["电池"]["供电"], "电源适配器")
        self.assertEqual(sections["电池"]["状态"], "正在充电")
        self.assertEqual(sections["电池"]["温度"], "23.5 °C")
        self.assertEqual(sections["网络"]["内网 IP"], "10.0.0.6")
        self.assertEqual(sections["网络"]["外网 IP"], "45.62.126.7")
        self.assertEqual(sections["网络"]["VPN"], "172.30.250.24")

    def test_dynamic_scope_only_has_changing_values(self):
        parts = {"battery": "  level: 50\n  status: 3", "uptime": "120.0 10.0"}
        sections = {s["title"]: dict(s["items"]) for s in adb_lan.parse_device_info(parts)}
        self.assertEqual(sections["电池"]["电量"], "50%")
        self.assertNotIn("概览", sections)

    def test_market_name_falls_back_across_vendors(self):
        self.assertEqual(adb_lan.market_name({"ro.vendor.oplus.market.name": "一加 13"}), "一加 13")
        self.assertEqual(adb_lan.market_name({"ro.product.vendor.marketname": ""}), "")


class ForgetTests(unittest.TestCase):
    def test_forget_removes_cached_endpoint(self):
        manager = AdbLan()
        saved = []
        with (
            patch.object(manager, "load_known", return_value={
                "10.0.0.250:5555": "gone", "10.0.0.5:5555": "664b491b"}),
            patch.object(manager, "save_known", side_effect=saved.append),
            patch.object(manager, "devices", return_value={}),
            patch.object(manager, "command", return_value=(0, "")),
        ):
            result = manager.forget("10.0.0.250:5555")
        self.assertTrue(result["ok"])
        self.assertEqual(saved[-1], {"10.0.0.5:5555": "664b491b"})


class TcpipTests(unittest.TestCase):
    serial = "0123abcd"
    endpoint = "10.0.0.8:5555"

    def run_scan(self, attempts, mirror_serials=(), known=None, usb_check=False, opens=False):
        manager = AdbLan()
        command_calls = []
        usb = {self.serial: {"serial": self.serial, "state": "device", "model_hint": ""}}

        def fake_command(*args, **_kwargs):
            command_calls.append(args)
            return 0, ""

        saved = []
        with (
            patch.object(manager, "command", side_effect=fake_command),
            patch.object(manager, "devices", return_value=usb),
            patch.object(manager, "load_known", return_value=dict(known or {})),
            patch.object(manager, "save_known"),
            patch.object(manager, "load_tcpip_attempts", return_value=attempts),
            patch.object(manager, "save_tcpip_attempts", side_effect=saved.append),
            patch.object(manager, "_discover_emulators", return_value=[]),
            patch.object(manager, "_identity", return_value=self.serial),
            patch.object(manager, "_wifi_ips", return_value=["10.0.0.8"]),
            patch.object(manager, "_details", return_value={
                "identity": self.serial, "manufacturer": "Xiaomi",
                "model": "24053PY09C", "emulator": False,
            }),
            patch.object(adb_lan, "port_open",
                         side_effect=lambda *_a, **_k: opens and bool(
                             [c for c in command_calls if "tcpip" in c])),
            patch.object(adb_lan, "mirror_uses_serial",
                         side_effect=lambda serial: serial in mirror_serials),
            patch.object(adb_lan, "run_command", return_value=(
                0, "en1: flags=1\n\tinet 10.0.0.3 netmask 0xffffff00\n"
            )),
            patch.object(adb_lan.time, "sleep"),
        ):
            report = manager.scan(include_subnet_scan=False, usb_check=usb_check)
        tcpip_calls = [call for call in command_calls if "tcpip" in call]
        return report, tcpip_calls, saved

    def attempt(self, seconds_ago, ok=False):
        return {self.serial: {"at": adb_lan.time.time() - seconds_ago, "ok": ok}}

    def test_first_attempt_runs_tcpip_and_records_result(self):
        _report, tcpip_calls, saved = self.run_scan({}, opens=True)
        self.assertEqual(len(tcpip_calls), 1)
        self.assertTrue(saved[-1][self.serial]["ok"])

    def test_failed_attempt_is_recorded_as_failed(self):
        report, _tcpip_calls, saved = self.run_scan({})
        self.assertFalse(saved[-1][self.serial]["ok"])
        states = {issue["serial"]: issue["state"] for issue in report["usb_issues"]}
        self.assertIn(self.serial, states)

    def test_periodic_scan_backs_off_after_failure(self):
        report, tcpip_calls, _saved = self.run_scan(self.attempt(10 * 60))
        self.assertEqual(tcpip_calls, [])
        states = {issue["serial"]: issue["state"] for issue in report["usb_issues"]}
        self.assertEqual(states.get(self.serial), "tcpip_unreachable")

    def test_periodic_scan_retries_after_backoff(self):
        old = adb_lan.TCPIP_RETRY_SECONDS + 1
        _report, tcpip_calls, _saved = self.run_scan(self.attempt(old))
        self.assertEqual(len(tcpip_calls), 1)

    def test_device_connection_retries_despite_earlier_failure(self):
        _report, tcpip_calls, _saved = self.run_scan(self.attempt(10 * 60), usb_check=True)
        self.assertEqual(len(tcpip_calls), 1)

    def test_periodic_scan_retries_when_wireless_was_lost_after_success(self):
        # e.g. the phone rebooted, which turns wireless ADB off again.
        _report, tcpip_calls, _saved = self.run_scan(self.attempt(10 * 60, ok=True))
        self.assertEqual(len(tcpip_calls), 1)

    def test_reconnect_caused_by_tcpip_does_not_loop(self):
        _report, tcpip_calls, _saved = self.run_scan(self.attempt(20), usb_check=True)
        self.assertEqual(tcpip_calls, [])

    def test_old_attempt_file_format_is_read(self):
        manager = AdbLan()
        with patch.object(adb_lan.TCPIP_FILE.__class__, "read_text",
                          return_value='{"%s": 1700000000.0}' % self.serial):
            attempts = manager.load_tcpip_attempts()
        self.assertEqual(attempts[self.serial], {"at": 1700000000.0, "ok": False})

    def test_usb_projection_blocks_tcpip(self):
        _report, tcpip_calls, _saved = self.run_scan({}, mirror_serials={self.serial},
                                                     usb_check=True)
        self.assertEqual(tcpip_calls, [])

    def test_known_endpoint_with_closed_port_still_enables_tcpip(self):
        # adbd falls back to USB-only mode after a phone reboot.
        report, tcpip_calls, _saved = self.run_scan({}, known={self.endpoint: self.serial})
        self.assertEqual(len(tcpip_calls), 1)

    def test_closed_cached_port_is_not_reported_while_usb_projecting(self):
        report, tcpip_calls, _saved = self.run_scan(
            {}, mirror_serials={self.serial}, known={self.endpoint: self.serial})
        self.assertEqual(tcpip_calls, [])
        self.assertEqual([item["endpoint"] for item in report["failed"]], [])

    def test_mirror_serial_match_is_exact(self):
        ps = "/x.app/Contents/MacOS/scrcpy --serial=0123abcd --window-title=A\n"
        with patch.object(adb_lan, "run_command", return_value=(0, ps)):
            self.assertTrue(adb_lan.mirror_uses_serial("0123abcd"))
            self.assertFalse(adb_lan.mirror_uses_serial("d537"))


if __name__ == "__main__":
    unittest.main()
