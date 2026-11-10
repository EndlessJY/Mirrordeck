import ipaddress
import json
from contextlib import contextmanager
from unittest.mock import patch

import adb_lan
from adb_lan import AdbLan
from test_adb_lan import AdbTestCase


class USBWirelessTests(AdbTestCase):
    serial = "usb-oneplus"
    endpoint = "100.74.13.243:5555"
    interfaces = "en0: flags=1\n\tinet 100.74.61.101 netmask 0xfffff000\n"

    def setUp(self):
        super().setUp()
        self.trusted_file = adb_lan.APP_DIR / "usb_wireless_endpoints.json"
        replacement = patch.object(adb_lan, "USB_WIRELESS_FILE", self.trusted_file, create=True)
        replacement.start()
        self.addCleanup(replacement.stop)

    def trusted(self):
        return json.loads(self.trusted_file.read_text()) if self.trusted_file.exists() else {}

    @contextmanager
    def device(self, **overrides):
        state = dict(usb=True, usb_tag=True, usb_state="device", connected=False,
                     port=True, opens=True, wireless_identity=self.serial,
                     addresses="28: wlan0 inet 100.74.13.243/20 scope global wlan0\n",
                     connect_error="", first_route_error=False)
        state.update(overrides)
        calls = []

        def command(*args, **_kwargs):
            calls.append(args)
            if args == ("devices", "-l"):
                lines = []
                if state["usb"]:
                    tag = "usb:1-1" if state["usb_tag"] else ""
                    lines.append(f"{self.serial} {state['usb_state']} {tag} model:PJZ110")
                if state["connected"]:
                    lines.append(f"{self.endpoint} device model:PJZ110")
                return 0, "\n".join(lines)
            if args[0] == "connect":
                if state["first_route_error"]:
                    state["first_route_error"] = False
                    return 1, "No route to host"
                if state["connect_error"]:
                    return 1, state["connect_error"]
                state["connected"] = True
                return 0, "connected to " + self.endpoint
            if args[0] == "disconnect":
                state["connected"] = False
                return 0, "disconnected"
            if args == ("kill-server",):
                state["connected"] = False
                return 0, ""
            if "tcpip" in args:
                state["port"] = state["opens"]
                return 0, "restarting in TCP mode port: 5555"
            if args[0] == "-s":
                identity = self.serial if args[1] == self.serial else state["wireless_identity"]
                if args[2:] == ("shell", "getprop", "ro.serialno"):
                    return (0, identity) if identity else (1, "")
                if args[2:] == ("shell", "getprop"):
                    return 0, f"[ro.serialno]: [{identity}]\n[ro.product.model]: [PJZ110]\n"
                if args[2:] == ("shell", "ip", "-o", "-4", "addr", "show"):
                    return 0, state["addresses"]
            return 0, ""

        with (
            patch.object(AdbLan, "command", side_effect=command),
            patch.object(adb_lan, "run_command", side_effect=lambda args, **_kw:
                         (0, self.interfaces if args == ["/sbin/ifconfig"] else "")),
            patch.object(adb_lan, "port_open", side_effect=lambda endpoint, *_a, **_kw:
                         state["port"] and endpoint == self.endpoint),
            patch.object(adb_lan.time, "sleep"),
            patch.object(AdbLan, "_discover_lan_ports", side_effect=AssertionError("unexpected subnet probe")),
        ):
            manager = AdbLan()
            manager.networks = [ipaddress.IPv4Network("100.74.48.0/20")]
            yield manager, state, calls

    def scan(self, manager):
        return manager.scan(include_subnet_scan=False, usb_check=True)

    def test_usb_connects_routed_wifi_and_saves_verified_identity(self):
        with self.device() as (manager, _state, calls):
            report = self.scan(manager)
        self.assertEqual(report["usb_issues"], [])
        self.assertTrue(report["devices"][0]["wireless"])
        self.assertIn(("connect", self.endpoint), calls)
        self.assertFalse(any("tcpip" in call for call in calls))
        self.assertEqual(self.trusted(), {self.endpoint: self.serial})

    def test_usb_enables_routed_wifi_port_before_connecting(self):
        with self.device(port=False) as (manager, _state, calls):
            report = self.scan(manager)
        self.assertTrue(report["devices"][0]["wireless"])
        self.assertLess(calls.index(("-s", self.serial, "tcpip", "5555")),
                        calls.index(("connect", self.endpoint)))
        self.assertEqual(self.trusted(), {self.endpoint: self.serial})

    def test_identity_mismatch_or_read_failure_is_not_trusted(self):
        for actual in ("other-phone", ""):
            with self.subTest(actual=actual), self.device(wireless_identity=actual) as (manager, state, calls):
                report = self.scan(manager)
                self.assertIn(("connect", self.endpoint), calls)
                self.assertIn(("disconnect", self.endpoint), calls)
                self.assertFalse(state["connected"])
                self.assertFalse(any(device["wireless"] for device in report["devices"]))
                self.assertEqual(manager.load_known(), {})
                self.assertEqual(self.trusted(), {})
                self.assertIn("身份", report["failed"][0]["reason"])

    def test_only_authorized_physical_usb_allows_cross_subnet(self):
        for overrides in ({"usb_state": "unauthorized"}, {"usb_tag": False}):
            with self.subTest(overrides=overrides), self.device(**overrides) as (manager, _state, calls):
                self.scan(manager)
                self.assertFalse(any(c[0] == "connect" or "tcpip" in c for c in calls))
                self.assertEqual(self.trusted(), {})

    def test_usb_ignores_vpn_cellular_and_special_addresses(self):
        with self.device(addresses=(
            "1: lo inet 127.0.0.1/8 scope host lo\n"
            "2: vgate0 inet 100.74.13.243/32 scope global vgate0\n"
            "3: rmnet0 inet 100.74.13.243/20 scope global rmnet0\n"
            "4: wlan0 inet 8.8.8.8/24 scope global wlan0\n"
            "5: wlan1 inet 169.254.1.2/16 scope link wlan1\n"
        )) as (manager, _state, calls):
            self.scan(manager)
        self.assertFalse(any(c[0] == "connect" or "tcpip" in c for c in calls))

    def test_unreachable_port_or_failed_authentication_is_not_saved(self):
        for overrides in ({"port": False, "opens": False}, {"connect_error": "failed to authenticate"}):
            with self.subTest(overrides=overrides), self.device(**overrides) as (manager, _state, _calls):
                report = self.scan(manager)
                self.assertFalse(report["devices"][0]["wireless"])
                self.assertEqual(self.trusted(), {})
                self.assertEqual(manager.load_known(), {})

    def test_fresh_scan_reconnects_verified_endpoint_after_usb_removed(self):
        with self.device() as (manager, state, calls):
            self.scan(manager)
            self.assertEqual(self.trusted(), {self.endpoint: self.serial})
            state.update(usb=False, connected=False)
            calls.clear()
            report = self.scan(AdbLan())
            self.assertTrue(report["devices"][0]["wireless"])
            self.assertEqual([c for c in calls if c[0] == "connect"], [("connect", self.endpoint)])

    def test_reconnect_known_checks_identity_for_usb_verified_endpoint(self):
        with self.device() as (manager, state, calls):
            self.scan(manager)
            self.assertEqual(self.trusted(), {self.endpoint: self.serial})
            state.update(usb=False, connected=False)
            self.assertTrue(manager.reconnect_known())
            self.assertTrue(state["connected"])
            state.update(connected=False, wireless_identity="other-phone")
            manager.reconnect_known()
            self.assertFalse(state["connected"])
            self.assertIn(("disconnect", self.endpoint), calls)
            self.assertEqual(self.trusted(), {})
            self.assertEqual(manager.load_known(), {})

    def test_cached_connection_is_revalidated_even_when_already_online(self):
        with self.device() as (manager, state, _calls):
            self.scan(manager)
            self.assertEqual(self.trusted(), {self.endpoint: self.serial})
            state.update(usb=False, wireless_identity="other-phone")
            report = self.scan(manager)
            self.assertFalse(state["connected"])
            self.assertEqual(report["devices"], [])
            self.assertEqual(self.trusted(), {})

    def test_plain_known_endpoint_does_not_grant_cross_subnet_access(self):
        with self.device(usb=False) as (manager, _state, calls):
            manager.save_known({self.endpoint: self.serial})
            self.scan(manager)
            manager.reconnect_known()
        self.assertFalse(any(c[0] == "connect" for c in calls))
        self.assertEqual(self.trusted(), {})

    def test_reconnect_revalidates_already_online_usb_endpoint(self):
        with self.device() as (manager, state, calls):
            self.scan(manager)
            self.assertEqual(self.trusted(), {self.endpoint: self.serial})
            state.update(usb=False, wireless_identity="other-phone")
            manager.reconnect_known()
            self.assertIn(("disconnect", self.endpoint), calls)
            self.assertFalse(state["connected"])
            self.assertEqual(self.trusted(), {})
            self.assertEqual(manager.load_known(), {})

    def test_forget_revokes_verified_endpoint_reconnection(self):
        with self.device() as (manager, state, calls):
            self.scan(manager)
            self.assertEqual(self.trusted(), {self.endpoint: self.serial})
            state.update(usb=False, connected=False)
            manager.forget(self.endpoint)
            self.assertEqual(self.trusted(), {})
            calls.clear()
            self.scan(manager)
            manager.reconnect_known()
        self.assertFalse(any(c[0] == "connect" for c in calls))

    def test_routed_retry_does_not_bypass_identity_check(self):
        self.trusted_file.write_text(json.dumps({self.endpoint: self.serial}))
        # 明确满足重启冷却期，不依赖 Python 版本或机器的单调时钟起点。
        with (
            self.device(usb=False, first_route_error=True, wireless_identity="other-phone") as (manager, state, calls),
            patch.object(adb_lan.time, "monotonic", return_value=120.0),
        ):
            manager.save_known({self.endpoint: self.serial})
            manager.reconnect_known()
            self.assertIn(("kill-server",), calls)
            self.assertFalse(state["connected"])
            self.assertEqual(self.trusted(), {})

    def test_routed_retry_respects_restart_cooldown(self):
        for elapsed, should_restart in ((0, False), (60, False), (61, True)):
            with (
                self.subTest(elapsed=elapsed),
                self.device(usb=False, first_route_error=True) as (manager, state, calls),
                patch.object(adb_lan.time, "monotonic", return_value=120.0),
            ):
                manager.save_known({self.endpoint: self.serial})
                manager.save_usb_wireless({self.endpoint: self.serial})
                manager._last_server_restart = 120.0 - elapsed
                self.assertEqual(manager.reconnect_known(), should_restart)
                self.assertEqual(calls.count(("kill-server",)), int(should_restart))
                self.assertEqual(calls.count(("connect", self.endpoint)), 2 if should_restart else 1)
                self.assertEqual(state["connected"], should_restart)
                self.assertEqual(self.trusted(), {self.endpoint: self.serial})
