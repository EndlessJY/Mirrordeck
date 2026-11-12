import unittest
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import patch

import ios_devices


class TrustStateTests(unittest.TestCase):
    def test_pairing_errors_map_to_user_facing_states(self):
        for name, state in (
            ("PasswordRequiredError", "ios_locked"),
            ("PairingDialogResponsePendingError", "ios_untrusted"),
            ("UserDeniedPairingError", "ios_denied"),
            ("NotPairedError", "ios_untrusted"),
            ("ConnectionFailedError", "ios_unavailable"),
        ):
            error = type(name, (Exception,), {})()
            self.assertEqual(ios_devices._trust_state(error), state)

    def test_scan_without_library_lists_nothing(self):
        with patch.object(ios_devices, "_available", return_value=False):
            self.assertEqual(ios_devices.scan(), ([], []))

    def test_infer_device_class_falls_back_to_product_type(self):
        self.assertEqual(ios_devices._infer_device_class({"ProductType": "iPad14,5"}), "iPad")
        self.assertEqual(ios_devices._infer_device_class({"ProductType": "iPhone16,2"}), "iPhone")
        self.assertEqual(ios_devices._infer_device_class({"DeviceClass": "iPad"}), "iPad")

    def test_info_maps_lockdown_errors_to_friendly_messages(self):
        locked = type("PasswordRequiredError", (Exception,), {})()
        with patch.object(ios_devices, "_info", side_effect=locked):
            with self.assertRaisesRegex(ValueError, "解锁"):
                ios_devices.info("udid")


class SyslogFormatTests(unittest.TestCase):
    def test_entry_is_formatted_like_logcat_and_closes_resources(self):
        entries = [
            SimpleNamespace(
                timestamp=datetime(2026, 11, 10, 9, 18, 19, 832000), pid=35,
                level=SimpleNamespace(name="ERROR", value=16),
                filename="/System/Library/CoreServices/SpringBoard.app/SpringBoard",
                image_name="", message="line one\nline two"),
            SimpleNamespace(
                timestamp=datetime(2026, 11, 10, 9, 18, 20, 5000), pid=42,
                level=SimpleNamespace(name="NOTICE", value=0),
                filename="/usr/libexec/lockdownd",
                image_name="", message="paired"),
        ]
        lines = []
        closed = []

        class FakeClient:
            def close(self):
                closed.append("client")

        class FakeService:
            def __init__(self, lockdown):
                self.lockdown = lockdown

            async def syslog(self):
                for item in entries:
                    yield item

            def close(self):
                closed.append("service")

        async def fake_lockdown(udid, autopair):
            return FakeClient()

        with patch.object(ios_devices, "_lockdown", fake_lockdown), \
                patch.object(ios_devices, "_os_trace_service", FakeService):
            ios_devices.stream_syslog("udid", lines.append)
        self.assertEqual(lines, [
            "11-10 09:18:19.832    35    35 E SpringBoard: line one ⏎ line two",
            "11-10 09:18:20.005    42    42 I lockdownd: paired",
        ])
        self.assertEqual(closed, ["service", "client"])


if __name__ == "__main__":
    unittest.main()
