"""JSON-lines bridge between the native macOS window and adb_lan.py."""

import json
import sys

import ios_devices
from adb_lan import AdbLan, parse_interfaces, run_command


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main():
    if len(sys.argv) != 2:
        raise ValueError("缺少操作名称")
    action = sys.argv[1]
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("请求格式错误")
    manager = AdbLan(progress=lambda message: emit({"progress": message}))
    usb_check = str(payload.get("usb_check", "")) == "1"
    if action == "scan":
        emit({"report": manager.scan(usb_check=usb_check)})
    elif action == "scan_fast":
        emit({"report": manager.scan(include_subnet_scan=False, usb_check=usb_check)})
    elif action == "connect":
        emit({"result": manager.connect_manual(str(payload.get("endpoint", "")).strip())})
    elif action == "pair":
        emit({"result": manager.pair(
            str(payload.get("endpoint", "")).strip(),
            str(payload.get("code", "")).strip(),
        )})
    elif action == "info" and payload.get("platform") == "ios":
        emit({"info": {"sections": ios_devices.info(str(payload.get("serial", "")).strip()),
                       "scope": "all"}})
    elif action == "info":
        emit({"info": manager.device_info(str(payload.get("serial", "")).strip(),
                                          str(payload.get("scope", "all")))})
    elif action == "ios_syslog":
        # Streams until the app stops this process (the log window closed).
        ios_devices.stream_syslog(str(payload.get("serial", "")).strip(),
                                  lambda line: print(line, flush=True))
    elif action == "forget":
        emit({"result": manager.forget(str(payload.get("endpoint", "")).strip())})
    elif action == "reconnect":
        _status, ifconfig = run_command(["/sbin/ifconfig"], timeout=5)
        manager.networks, _notes = parse_interfaces(ifconfig)
        changed = manager.reconnect_known()
        emit({"changed": changed, "devices": manager.devices()})
    else:
        raise ValueError("未知操作")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit({"error": str(exc)})
        raise SystemExit(1)
