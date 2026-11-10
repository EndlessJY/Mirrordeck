import ipaddress
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import adb_lan
from adb_lan import (
    AdbLan, endpoint_parts, explain_failure, parse_devices, parse_interfaces,
    parse_listeners, parse_mdns,
)


class AdbTestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name, value in (
            ("APP_DIR", root),
            ("KNOWN_FILE", root / "known_endpoints.json"),
            ("TCPIP_FILE", root / "tcpip_attempts.json"),
            ("USB_WIRELESS_FILE", root / "usb_wireless_endpoints.json"),
            ("find_adb", lambda: "/test/adb"),
        ):
            replacement = patch.object(adb_lan, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        # Never reach a real iPhone through this Mac's usbmuxd in tests.
        apple = patch.object(adb_lan.ios_devices, "scan", return_value=([], []))
        apple.start()
        self.addCleanup(apple.stop)


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
            "utun0: flags=1\n\tinet 100.64.0.2 netmask 0xffffffff\n",
            for_scan=True,
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


class RecoveryTests(AdbTestCase):
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


class ForgetTests(AdbTestCase):
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


class TcpipTests(AdbTestCase):
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


class NetworkScopeTests(AdbTestCase):
    host_interfaces = (
        "en0: flags=1\n\tinet 100.74.61.101 netmask 0xfffff000\n"
        "utun0: flags=1\n\tinet 10.22.0.1 netmask 0xffffff00\n"
    )

    def test_interfaces_keep_real_lan_masks(self):
        for host, mask, expected in (
            ("100.74.61.101", "0xfffff000", "100.74.48.0/20"),
            ("192.168.61.101", "0xffff0000", "192.168.0.0/16"),
            ("10.0.0.3", "0xffffff00", "10.0.0.0/24"),
        ):
            with self.subTest(host=host):
                networks, notes = parse_interfaces(f"en0: flags=1\n\tinet {host} netmask {mask}\n")
                self.assertEqual(networks, [ipaddress.IPv4Network(expected)])
                self.assertEqual(notes, [])

    def test_interfaces_accept_shared_range_and_exclude_non_lan(self):
        interfaces = "".join(
            f"{name}: flags=1\n\tinet {address} netmask 0xffffff00\n"
            for name, address in (
                ("en0", "100.63.255.1"), ("en1", "100.64.0.1"),
                ("en2", "100.127.255.1"), ("en3", "100.128.0.1"),
                ("utun0", "100.74.61.1"), ("bridge0", "192.168.1.1"),
                ("lo0", "127.0.0.1"), ("en4", "169.254.1.1"),
                ("en5", "8.8.8.8"),
            )
        )
        self.assertEqual(parse_interfaces(interfaces)[0], [
            ipaddress.IPv4Network("100.64.0.0/24"),
            ipaddress.IPv4Network("100.127.255.0/24"),
        ])

    def test_subnet_probe_stays_in_local_24_and_excludes_host(self):
        manager = AdbLan()
        manager.networks = [ipaddress.IPv4Network("100.74.48.0/20")]
        probed = []

        def probe(endpoint, *_args):
            probed.append(endpoint)
            return False

        with (
            patch.object(adb_lan, "run_command", return_value=(0, self.host_interfaces)),
            patch.object(adb_lan, "port_open", side_effect=probe),
        ):
            self.assertEqual(manager._discover_lan_ports(), [])
        expected = {
            f"100.74.61.{last}:{port}"
            for last in range(1, 255) if last != 101
            for port in adb_lan.SCAN_PORTS
        }
        self.assertEqual(set(probed), expected)
        self.assertEqual(len(probed), len(expected))
        self.assertEqual(manager.networks, [ipaddress.IPv4Network("100.74.48.0/20")])

    def scan_usb(self, host, phone, opened):
        manager = AdbLan()
        manager.save_known({})
        manager.save_tcpip_attempts({})
        manager.save_usb_wireless({})
        serial = "usb-network-test"
        endpoint = f"{phone}:5555"
        connected = False
        calls = []

        def command(*args, **_kwargs):
            nonlocal opened, connected
            calls.append(args)
            if args == ("devices", "-l"):
                devices = f"{serial} device usb:1-1 model:TEST\n"
                if connected:
                    devices += f"{endpoint} device model:TEST\n"
                return 0, devices
            if args[:1] == ("connect",):
                connected = True
                return 0, f"connected to {endpoint}"
            if args == ("-s", serial, "tcpip", "5555"):
                opened = True
                return 0, "restarting in TCP mode port: 5555"
            if args[2:] == ("shell", "getprop", "ro.serialno"):
                return 0, serial
            if args[2:] == ("shell", "getprop"):
                return 0, f"[ro.serialno]: [{serial}]\n[ro.product.model]: [TEST]\n"
            if args[2:] == ("shell", "ip", "-o", "-4", "addr", "show"):
                return 0, f"16: wlan0 inet {phone}/20 scope global wlan0\n"
            return 0, ""

        interfaces = self.host_interfaces.replace("100.74.61.101", host)
        with (
            patch.object(manager, "command", side_effect=command),
            patch.object(adb_lan, "run_command", side_effect=lambda args, **_kw:
                         (0, interfaces if args == ["/sbin/ifconfig"] else "")),
            patch.object(adb_lan, "port_open", side_effect=lambda *_a, **_kw: opened),
            patch.object(adb_lan.time, "sleep"),
        ):
            report = manager.scan(include_subnet_scan=False, usb_check=True)
        return report, calls, manager

    def check_usb_connection(self, opened):
        for host, phone in (
            ("100.74.61.101", "100.74.61.207"),
            ("100.74.61.101", "100.74.60.207"),
            ("192.168.61.101", "192.168.60.207"),
        ):
            with self.subTest(host=host, phone=phone, opened=opened):
                report, calls, manager = self.scan_usb(host, phone, opened)
                self.assertEqual(report["usb_issues"], [])
                self.assertEqual(report["failed"], [])
                self.assertEqual(report["networks"], [str(ipaddress.IPv4Network(f"{host}/20", strict=False))])
                self.assertEqual(report["notes"], [])
                self.assertTrue(report["devices"][0]["wireless"])
                self.assertEqual(report["candidate_count"], 1)
                self.assertEqual([c for c in calls if c[0] == "connect"], [("connect", f"{phone}:5555")])
                tcpip = ("-s", "usb-network-test", "tcpip", "5555")
                self.assertEqual(calls.count(tcpip), 0 if opened else 1)
                if not opened:
                    self.assertLess(calls.index(tcpip), calls.index(("connect", f"{phone}:5555")))
                self.assertEqual(manager.load_known()[f"{phone}:5555"], "usb-network-test")

    def test_usb_connects_existing_wireless_port(self):
        self.check_usb_connection(opened=True)

    def test_usb_enables_closed_wireless_port_before_connecting(self):
        self.check_usb_connection(opened=False)

    def test_usb_does_not_configure_public_or_link_local_addresses(self):
        for phone in ("8.8.8.8", "169.254.1.2"):
            with self.subTest(phone=phone):
                report, calls, _manager = self.scan_usb("100.74.61.101", phone, opened=False)
                self.assertEqual(report["usb_issues"][0]["state"], "no_lan_ip")
                self.assertFalse(any("tcpip" in call or call[0] == "connect" for call in calls))

    def test_manual_connect_and_pair_use_real_lan_membership(self):
        endpoint = "100.74.60.207:5555"
        manager = AdbLan()
        with (
            patch.object(adb_lan, "run_command", return_value=(0, self.host_interfaces)),
            patch.object(adb_lan, "port_open", return_value=True),
            patch.object(manager, "command", return_value=(0, "connected to " + endpoint)) as command,
            patch.object(manager, "devices", return_value={endpoint: {"state": "device"}}),
        ):
            self.assertTrue(manager.connect_manual(endpoint)["ok"])
            command.assert_any_call("connect", endpoint, timeout=3)
            command.return_value = (0, "Successfully paired 123456")
            self.assertTrue(manager.pair(endpoint, "123456")["ok"])
            command.assert_called_with("pair", endpoint, "123456", timeout=10)

    def test_manual_connect_and_pair_reject_non_lan_addresses(self):
        manager = AdbLan()
        with (
            patch.object(adb_lan, "run_command", return_value=(0, self.host_interfaces)),
            patch.object(adb_lan, "port_open") as port,
            patch.object(manager, "command") as command,
        ):
            for endpoint in ("100.74.64.207:5555", "10.22.0.2:5555", "8.8.8.8:5555"):
                with self.subTest(endpoint=endpoint):
                    with self.assertRaisesRegex(ValueError, "局域网"):
                        manager.connect_manual(endpoint)
                    with self.assertRaisesRegex(ValueError, "局域网"):
                        manager.pair(endpoint, "123456")
            port.assert_not_called()
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
