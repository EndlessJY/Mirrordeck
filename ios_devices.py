"""iPhone / iPad support over USB, through the system usbmuxd.

Only local USB is used: usbmuxd is a socket on this Mac, so nothing here
touches the network. Lockdown needs the device to trust this Mac ("信任此电脑"),
the same trust Finder uses. pymobiledevice3 is imported lazily, so Android
scans pay nothing when no Apple device is connected.
"""
from __future__ import annotations

import asyncio
import inspect
import sys
from datetime import datetime
from typing import Any, Callable

LABEL = "Mirrordeck"


def _available() -> bool:
    try:
        import pymobiledevice3  # noqa: F401
        return True
    except Exception:
        return False


async def _value(result):
    return await result if inspect.isawaitable(result) else result


def _run(coroutine):
    return asyncio.run(coroutine)


def _format_bytes(value: Any) -> str:
    try:
        size = float(value)
    except (TypeError, ValueError):
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1000 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1000
    return ""


async def _close(resource: Any) -> None:
    if resource is None:
        return
    close = getattr(resource, "close", None)
    if callable(close):
        try:
            await _value(close())
        except Exception:
            pass


async def _lockdown(udid: str, autopair: bool):
    from pymobiledevice3.lockdown import create_using_usbmux
    return await asyncio.wait_for(
        create_using_usbmux(serial=udid, autopair=autopair, label=LABEL,
                            connection_type="USB", pair_timeout=1),
        timeout=5.0,
    )


def _os_trace_service(client: Any):
    from pymobiledevice3.services.os_trace import OsTraceService
    return OsTraceService(lockdown=client)


def _infer_device_class(values: dict) -> str:
    explicit = str(values.get("DeviceClass") or "").strip()
    if explicit:
        return explicit
    product = str(values.get("ProductType") or "")
    return "iPad" if product.startswith("iPad") else "iPhone"


def _trust_state(error: Exception) -> str:
    name = type(error).__name__
    if name == "PasswordRequiredError":
        return "ios_locked"            # unlock the phone to see the trust prompt
    if name == "PairingDialogResponsePendingError":
        return "ios_untrusted"         # the prompt is showing on the phone
    if name == "UserDeniedPairingError":
        return "ios_denied"            # "不信任" was tapped
    if name in ("NotPairedError", "NotTrustedError", "FatalPairingError", "PairingError"):
        return "ios_untrusted"
    return "ios_unavailable"


async def _read_all_values(client: Any) -> dict:
    raw = client.all_values() if callable(getattr(client, "all_values", None)) else client.all_values
    return await asyncio.wait_for(_value(raw), timeout=5.0) or {}


async def _scan() -> tuple[list[dict], list[dict]]:
    from pymobiledevice3.usbmux import list_devices
    devices: list[dict] = []
    issues: list[dict] = []
    seen = set()
    mux_list = await asyncio.wait_for(list_devices(), timeout=5.0)
    for mux in mux_list:
        if getattr(mux, "connection_type", "USB") != "USB" or mux.serial in seen:
            continue
        seen.add(mux.serial)
        client = None
        try:
            # Untrusted devices get the "信任此电脑" prompt on their screen.
            client = await _lockdown(mux.serial, autopair=True)
            values = await _read_all_values(client)
        except Exception as error:      # trust pending, locked, denied...
            issues.append({"serial": mux.serial, "state": _trust_state(error), "kind": "iPhone"})
            continue
        finally:
            await _close(client)
        device_class = _infer_device_class(values)
        name = values.get("DeviceName") or device_class
        devices.append({
            "identity": mux.serial,
            "platform": "ios",
            "manufacturer": "Apple",
            "model": values.get("ProductType", ""),
            "market_name": name,
            "tv": False,
            "emulator": False,
            "device_class": device_class,
            "transports": [{"endpoint": mux.serial, "type": "USB", "label": "USB",
                            "state": "已连接"}],
            "wireless": False,
        })
    return devices, issues


def scan() -> tuple[list[dict], list[dict]]:
    """Connected, trusted Apple devices and the ones waiting for trust."""
    if sys.platform != "darwin" or not _available():
        return [], []
    try:
        return _run(_scan())
    except Exception:
        # usbmuxd missing or busy: Apple devices are simply not listed now.
        return [], []


async def _info(udid: str) -> list[dict]:
    client = None
    try:
        client = await _lockdown(udid, autopair=False)
        values = await _read_all_values(client)

        async def domain(name: str) -> dict:
            try:
                return await asyncio.wait_for(_value(client.get_value(domain=name)), timeout=4.0) or {}
            except Exception:
                return {}

        battery = await domain("com.apple.mobile.battery")
        disk = await domain("com.apple.disk_usage")
    finally:
        await _close(client)
    sections: list[dict] = []

    def section(title: str, items: list[tuple[str, Any]]) -> None:
        kept = [[label, str(value)] for label, value in items if value not in (None, "", [])]
        if kept:
            sections.append({"title": title, "items": kept})

    device_class = _infer_device_class(values)
    section("概览", [
        ("名称", values.get("DeviceName")),
        ("品牌", "Apple"),
        ("型号", values.get("ProductType")),
        ("型号号码", (values.get("ModelNumber") or "") + (values.get("RegionInfo") or "")),
        ("硬件型号", values.get("HardwareModel")),
        ("序列号", values.get("SerialNumber")),
        ("UDID", udid),
    ])
    section("系统", [
        ("系统", f"{'iPadOS' if device_class == 'iPad' else 'iOS'} {values.get('ProductVersion', '')}".strip()),
        ("版本号", values.get("BuildVersion")),
        ("时区", values.get("TimeZone")),
        ("激活状态", {"Activated": "已激活"}.get(values.get("ActivationState"),
                                                values.get("ActivationState"))),
    ])
    total = disk.get("TotalDiskCapacity")
    available = disk.get("AmountDataAvailable")
    if total and available is not None:
        storage = f"已用 {_format_bytes(total - available)} / 共 {_format_bytes(total)}"
    else:
        storage = _format_bytes(total)
    section("硬件", [
        ("芯片架构", values.get("CPUArchitecture")),
        ("存储", storage),
    ])
    level = battery.get("BatteryCurrentCapacity")
    charging = battery.get("BatteryIsCharging")
    section("电池", [
        ("电量", f"{level}%" if level is not None else None),
        ("状态", None if charging is None else ("正在充电" if charging else
                                                ("已充满" if level == 100 else "未充电"))),
        ("供电", None if battery.get("ExternalConnected") is None else
         ("已连接电源" if battery.get("ExternalConnected") else "电池")),
    ])
    section("网络", [
        ("Wi-Fi 地址", values.get("WiFiAddress")),
        ("蓝牙地址", values.get("BluetoothAddress")),
        ("电话号码", None),
    ])
    return sections


def info(udid: str) -> list[dict]:
    try:
        return _run(_info(udid))
    except Exception as error:
        state = _trust_state(error)
        if state == "ios_locked":
            raise ValueError("请先解锁设备后再读取信息") from error
        if state in ("ios_untrusted", "ios_denied"):
            raise ValueError("请先在设备上点“信任”并输入锁屏密码") from error
        if isinstance(error, asyncio.TimeoutError):
            raise ValueError("读取苹果设备信息超时，请重试") from error
        raise ValueError("无法读取苹果设备信息，请检查 USB 连接") from error


_LEVELS = {0: "I", 1: "I", 2: "D", 16: "E", 17: "F"}


def _level(entry) -> str:
    value = getattr(entry.level, "value", entry.level)
    name = getattr(entry.level, "name", "")
    if name.startswith("ERROR"):
        return "E"
    if name.startswith("FAULT"):
        return "F"
    if name.startswith("DEBUG"):
        return "D"
    if name.startswith("INFO") or name.startswith("NOTICE"):
        return "I"
    return _LEVELS.get(value, "I")


def stream_syslog(udid: str, emit: Callable[[str], None]) -> None:
    """Prints the device log as `logcat -v threadtime` lines, so the log window
    reads both platforms the same way. Runs until the device goes away."""

    async def run() -> None:
        client = None
        service = None
        try:
            client = await _lockdown(udid, autopair=False)
            service = _os_trace_service(client)
            async for entry in service.syslog():
                stamp: datetime = entry.timestamp
                process = (entry.filename or entry.image_name or "").rsplit("/", 1)[-1] or "?"
                message = (entry.message or "").replace("\n", " ⏎ ")
                emit(f"{stamp:%m-%d %H:%M:%S}.{stamp.microsecond // 1000:03d} "
                     f"{entry.pid:5d} {entry.pid:5d} {_level(entry)} {process}: {message}")
        finally:
            await _close(service)
            await _close(client)

    _run(run())
