import importlib.util
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


class SyslogFormatTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec("pymobiledevice3"),
                         "pymobiledevice3 is not installed")
    def test_entry_is_formatted_like_logcat(self):
        entry = SimpleNamespace(
            timestamp=datetime(2026, 11, 10, 9, 18, 19, 832000), pid=35,
            level=SimpleNamespace(name="ERROR", value=16),
            filename="/System/Library/CoreServices/SpringBoard.app/SpringBoard",
            image_name="", message="line one\nline two")
        lines = []

        class FakeService:
            def __init__(self, lockdown):
                pass

            async def syslog(self):
                yield entry

        async def fake_lockdown(udid, autopair):
            return object()

        with patch.object(ios_devices, "_lockdown", fake_lockdown), \
                patch("pymobiledevice3.services.os_trace.OsTraceService", FakeService, create=True):
            ios_devices.stream_syslog("udid", lines.append)
        self.assertEqual(lines, [
            "11-10 09:18:19.832    35    35 E SpringBoard: line one ⏎ line two"])


if __name__ == "__main__":
    unittest.main()
