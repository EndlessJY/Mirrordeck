"""Fast, bounded discovery and connection of local Android ADB transports."""

from __future__ import annotations

import concurrent.futures
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

import ios_devices


APP_DIR = Path.home() / "Library" / "Application Support" / "LAN ADB Manager"
KNOWN_FILE = APP_DIR / "known_endpoints.json"
TCPIP_FILE = APP_DIR / "tcpip_attempts.json"
USB_WIRELESS_FILE = APP_DIR / "usb_wireless_endpoints.json"
# Marks the last ADB server restart. Each scan runs in a new worker process,
# so the cool-down lives on disk.
SERVER_RESTART_FILE = APP_DIR / "adb_server_restart"
SERVER_RESTART_COOLDOWN = 60
# `adb tcpip` restarts adbd and drops the USB link. A device connection or an
# app launch always checks again; periodic scans retry a failed attempt only
# after the back-off. The guard stops the reconnect that `adb tcpip` itself
# causes from triggering another attempt.
TCPIP_RETRY_SECONDS = 30 * 60
TCPIP_LOOP_GUARD_SECONDS = 2 * 60
ADB_PORT = 5037
SCAN_PORTS = (5555, 5557, 16416)
IGNORED_INTERFACES = ("lo", "utun", "awdl", "llw", "bridge", "vmenet")
SHARED_ADDRESS_SPACE = ipaddress.IPv4Network("100.64.0.0/10")
USB_WIFI_NETWORKS = tuple(ipaddress.IPv4Network(network) for network in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
))
ADB_ENV_EXCLUDE = (
    "ADB_SERVER_SOCKET",
    "ANDROID_ADB_SERVER_ADDRESS",
    "ANDROID_ADB_SERVER_PORT",
)


def run_command(args: list[str], timeout: float = 8) -> tuple[int, str]:
    env = os.environ.copy()
    for name in ADB_ENV_EXCLUDE:
        env.pop(name, None)
    try:
        completed = subprocess.run(
            args, capture_output=True, text=True, errors="replace", timeout=timeout, env=env
        )
        return completed.returncode, (completed.stdout + completed.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, f"操作超过 {timeout:g} 秒"
    except OSError as exc:
        return 127, str(exc)


def _scrcpy_commands() -> list[str]:
    _status, output = run_command(["/bin/ps", "-axo", "command="], timeout=3)
    return [line for line in output.splitlines() if "/Contents/MacOS/scrcpy --serial=" in line]


def active_mirror_process() -> bool:
    """Avoid restarting the shared ADB server while a projection is using it."""
    return any("--no-window" not in line for line in _scrcpy_commands())


def mirror_uses_serial(serial: str) -> bool:
    """True when a projection or recording is streaming from this transport."""
    return any(f"--serial={serial}" in line.split() for line in _scrcpy_commands())


def find_adb() -> str:
    choices = [
        os.environ.get("ADB_BIN", ""),
        str(Path.home() / "Library/Android/sdk/platform-tools/adb"),
        shutil.which("adb") or "",
    ]
    for choice in choices:
        if choice and Path(choice).is_file() and os.access(choice, os.X_OK):
            return choice
    raise FileNotFoundError("找不到 adb，请安装 Android SDK Platform-Tools，或设置 ADB_BIN")


def parse_devices(output: str) -> dict[str, dict]:
    found: dict[str, dict] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] == "List" or parts[0].startswith("*"):
            continue
        if parts[1] not in {"device", "offline", "unauthorized", "recovery", "sideload"}:
            continue
        # ADB briefly exposes unresolved TLS mDNS service names as offline
        # transports. They are discovery placeholders, not separate devices.
        if parts[1] != "device" and re.search(
            r"\._adb-tls-(?:connect|pairing)\._tcp$", parts[0]
        ):
            continue
        found[parts[0]] = {
            "serial": parts[0],
            "state": parts[1],
            "usb": any(item.startswith("usb:") for item in parts[2:]),
            "model_hint": next(
                (item[6:] for item in parts[2:] if item.startswith("model:")), ""
            ),
        }
    return found


def parse_mdns(output: str) -> list[dict]:
    services = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        endpoint = parts[-1]
        if not re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}", endpoint):
            continue
        service = next((p for p in parts if p.startswith("_adb")), "")
        if service:
            services.append({"name": parts[0], "service": service, "endpoint": endpoint})
    return services


def parse_interfaces(output: str, *, for_scan: bool = False
                     ) -> tuple[list[ipaddress.IPv4Network], list[str]]:
    """Keep real LAN membership; bound only the addresses actively probed."""
    networks: list[ipaddress.IPv4Network] = []
    notes: list[str] = []
    interface = ""
    for line in output.splitlines():
        if line and not line[0].isspace() and ":" in line:
            interface = line.split(":", 1)[0]
            continue
        if interface.startswith(IGNORED_INTERFACES):
            continue
        match = re.search(r"\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)", line)
        if not match:
            continue
        ip = ipaddress.IPv4Address(match.group(1))
        if not (ip.is_private or ip in SHARED_ADDRESS_SPACE) or ip.is_loopback or ip.is_link_local:
            continue
        mask = str(ipaddress.IPv4Address(int(match.group(2), 16)))
        network = ipaddress.IPv4Network(f"{ip}/{mask}", strict=False)
        if for_scan and network.num_addresses > 256:
            network = ipaddress.IPv4Network(f"{ip}/24", strict=False)
            notes.append(f"{interface} 网段较大，本次仅扫描本机所在的 {network}")
        if network not in networks:
            networks.append(network)
    return networks, notes


def parse_emulator_listeners(output: str) -> dict[str, int]:
    listeners: dict[str, int] = {}
    for line in output.splitlines():
        fields = line.split()
        process = fields[0] if fields else ""
        if not re.search(r"mumu|emulator|qemu|nox|bluestack|genymo|ldplayer", process, re.I):
            continue
        match = re.search(r"TCP\s+\S+:(\d+)\s+\(LISTEN\)", line)
        if not match or len(fields) < 2 or not fields[1].isdigit():
            continue
        port = int(match.group(1))
        if (
            port in {5555, 16416, 62001, 62025}
            or (5555 <= port <= 5585 and port % 2 == 1)
        ):
            listeners[f"127.0.0.1:{port}"] = int(fields[1])
    return listeners


def parse_listeners(output: str) -> list[str]:
    return sorted(parse_emulator_listeners(output), key=lambda ep: int(ep.rsplit(":", 1)[1]))


def endpoint_parts(endpoint: str) -> tuple[str, int] | None:
    match = re.fullmatch(r"([^:]+):(\d{1,5})", endpoint.strip())
    if not match:
        return None
    try:
        ipaddress.IPv4Address(match.group(1))
        port = int(match.group(2))
    except ValueError:
        return None
    return (match.group(1), port) if 1 <= port <= 65535 else None


def is_mdns_transport(serial: str) -> bool:
    """A wireless-debugging transport ADB connected through mDNS by itself,
    named like `adb-<serial>-<id>._adb-tls-connect._tcp`: wireless, not USB."""
    return "._adb-tls-connect." in serial or "._adb._tcp" in serial


def is_network_transport(serial: str) -> bool:
    return bool(endpoint_parts(serial)) or is_mdns_transport(serial)


def port_open(endpoint: str, timeout: float = 0.45) -> bool:
    parsed = endpoint_parts(endpoint)
    if not parsed:
        return False
    try:
        with socket.create_connection(parsed, timeout=timeout):
            return True
    except OSError:
        return False


def usb_wireless_endpoint(endpoint: str) -> bool:
    parsed = endpoint_parts(endpoint)
    return bool(parsed and parsed[1] == 5555 and any(
        ipaddress.IPv4Address(parsed[0]) in network for network in USB_WIFI_NETWORKS
    ))


def port_open_stable(endpoint: str, attempts: int = 3) -> bool:
    for attempt in range(attempts):
        if port_open(endpoint, 0.45):
            return True
        if attempt + 1 < attempts:
            time.sleep(0.12)
    return False


def same_lan(ip: str, networks: list[ipaddress.IPv4Network]) -> bool:
    try:
        address = ipaddress.IPv4Address(ip)
    except ValueError:
        return False
    return address.is_loopback or any(address in network for network in networks)


MARKET_NAME_PROPS = (
    "ro.product.marketname",
    "ro.product.odm.marketname",
    "ro.product.vendor.marketname",
    "ro.vendor.oplus.market.name",
    "ro.oppo.market.name",
    "ro.vivo.market.name",
    "ro.config.marketing_name",
    "ro.product.system.marketname",
)


def tcpip_decision(last: dict | None, now: float, forced: bool) -> str:
    """Whether to run `adb tcpip` for a USB device whose wireless port is closed.

    `last` is the previous attempt ({"at": seconds, "ok": bool}) or None.
    Returns "try", "loop_guard" (attempted moments ago) or "backoff".
    """
    if not last:
        return "try"
    elapsed = now - float(last.get("at", 0.0))
    if elapsed < TCPIP_LOOP_GUARD_SECONDS:
        return "loop_guard"
    if not forced and not last.get("ok") and elapsed < TCPIP_RETRY_SECONDS:
        return "backoff"
    return "try"


def market_name(props: dict[str, str]) -> str:
    """The retail name (e.g. "Xiaomi Civi 4 Pro") instead of a model code."""
    for key in MARKET_NAME_PROPS:
        value = props.get(key, "").strip()
        if value and value.lower() != "unknown":
            return value
    return ""


INFO_SEPARATOR = "__LANADB_INFO__"
# Properties that do not change while the device runs; cached by the app.
STATIC_INFO_COMMANDS = {
    "getprop": "getprop",
    "screen": "wm size; wm density",
    "device_name": "settings get global device_name",
    "kernel": "uname -r",
    "cpu_possible": "cat /sys/devices/system/cpu/possible",
    "cpu_freq": "cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 2>/dev/null",
}
# Battery, memory, storage, uptime and addresses change; read on each visit.
DYNAMIC_INFO_COMMANDS = {
    "meminfo": "cat /proc/meminfo",
    "df": "df -k /data",
    "battery": "dumpsys battery",
    "uptime": "cat /proc/uptime",
    "ip_addr": "ip -o -4 addr show",
    "display": "dumpsys display | grep -oE 'renderFrameRate [0-9.]+|fps=[0-9.]+'",
    "public_ip": "curl -s -m 3 https://api.ipify.org 2>/dev/null",
}
INFO_COMMANDS = {**STATIC_INFO_COMMANDS, **DYNAMIC_INFO_COMMANDS}


def info_script(keys: list[str]) -> str:
    return f"; echo {INFO_SEPARATOR}; ".join(INFO_COMMANDS[key] for key in keys)


def split_info_output(output: str, keys: list[str]) -> dict[str, str]:
    parts = [part.strip() for part in output.split(INFO_SEPARATOR)]
    parts += [""] * (len(keys) - len(parts))
    return dict(zip(keys, parts))


def _interface_kind(name: str) -> str:
    if name.startswith(("wlan", "eth", "ap", "swlan")):
        return "lan"
    if name.startswith(("rmnet", "ccmni", "pdp", "seth", "v4-rmnet")):
        return "mobile"
    if name.startswith(("tun", "ppp", "vgate", "ipsec", "wg")):
        return "vpn"
    return "other"


def _format_bytes(value: float) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    index = 0
    while value >= 1024 and index < len(units) - 1:
        value /= 1024
        index += 1
    return f"{value:.1f} {units[index]}" if index >= 3 else f"{value:.0f} {units[index]}"


def _rom_name(props: dict[str, str]) -> str:
    if props.get("ro.mi.os.version.name"):
        return "Xiaomi HyperOS " + props["ro.mi.os.version.name"].removeprefix("OS")
    if props.get("ro.miui.ui.version.name"):
        return "MIUI " + props["ro.miui.ui.version.name"].removeprefix("V")
    if props.get("ro.build.version.oplusrom.display") or props.get("ro.build.version.oplusrom"):
        version = (props.get("ro.build.version.oplusrom.display")
                   or props["ro.build.version.oplusrom"].removeprefix("V"))
        return "ColorOS " + version
    if props.get("ro.build.version.oneui"):
        code = props["ro.build.version.oneui"]
        if code.isdigit() and len(code) >= 5:
            number = int(code)
            return f"One UI {number // 10000}.{number // 100 % 100}"
    if props.get("ro.vivo.os.build.display.id"):
        return props["ro.vivo.os.build.display.id"]
    if props.get("ro.build.version.magic"):
        return "MagicOS " + props["ro.build.version.magic"]
    if props.get("hw_sc.build.platform.version"):
        return "HarmonyOS " + props["hw_sc.build.platform.version"]
    if props.get("ro.build.version.emui"):
        return props["ro.build.version.emui"]
    return ""


def _build_time(epoch: str) -> str:
    if not epoch.isdigit():
        return ""
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(epoch)))


def _uptime(seconds: float) -> str:
    total = int(seconds)
    days, rest = divmod(total, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    parts = []
    if days:
        parts.append(f"{days} 天")
    if hours or days:
        parts.append(f"{hours} 小时")
    parts.append(f"{minutes} 分钟")
    return " ".join(parts)


BATTERY_STATUS = {"1": "未知", "2": "正在充电", "3": "放电中", "4": "未充电", "5": "已充满"}
BATTERY_HEALTH = {"1": "未知", "2": "良好", "3": "过热", "4": "损坏", "5": "电压过高",
                  "6": "故障", "7": "过冷"}


def parse_device_info(parts: dict[str, str] | str) -> list[dict]:
    """Builds the grouped rows; works with all parts or the dynamic ones only."""
    if isinstance(parts, str):
        parts = split_info_output(parts, list(INFO_COMMANDS))
    get = lambda key: parts.get(key, "")  # noqa: E731
    getprop, screen, meminfo, df, battery = (get("getprop"), get("screen"), get("meminfo"),
                                             get("df"), get("battery"))
    device_name, kernel, uptime, cpu_possible = (get("device_name"), get("kernel"),
                                                 get("uptime"), get("cpu_possible"))
    cpu_freq, ip_addr, display = get("cpu_freq"), get("ip_addr"), get("display")
    public_ip = get("public_ip").strip()
    props = dict(re.findall(r"^\[([^\]]+)\]: \[([^\]]*)\]$", getprop, re.M))

    def prop(*keys: str) -> str:
        for key in keys:
            value = props.get(key, "").strip()
            if value and value.lower() not in {"unknown", "null"}:
                return value
        return ""

    sections: list[dict] = []

    def section(title: str, items: list[tuple[str, str]]) -> None:
        kept = [[label, value] for label, value in items if value]
        if kept:
            sections.append({"title": title, "items": kept})

    name = device_name.strip()
    retail = market_name(props)
    section("概览", [
        # The name chosen on the device wins; the retail name is the model.
        ("名称", name if name not in {"", "null"} else retail),
        ("机型", retail if retail and name not in {"", "null", retail} else ""),
        ("品牌", prop("ro.product.brand") or prop("ro.product.manufacturer")),
        ("制造商", "" if prop("ro.product.manufacturer").lower() in
            {prop("ro.product.brand").lower(), ""} else prop("ro.product.manufacturer")),
        ("型号", prop("ro.product.model")),
        ("产品代号", prop("ro.product.device")),
        ("序列号", prop("ro.serialno", "ro.boot.serialno")),
    ])

    android = prop("ro.build.version.release")
    sdk = prop("ro.build.version.sdk")
    section("系统", [
        ("Android", f"{android}（API {sdk}）" if android and sdk else android),
        ("系统界面", _rom_name(props)),
        ("安全补丁", prop("ro.build.version.security_patch")),
        ("版本号", prop("ro.build.display.id")),
        ("增量版本", prop("ro.build.version.incremental")),
        ("编译时间", _build_time(prop("ro.build.date.utc")) or prop("ro.build.date")),
        ("内核", kernel.strip()),
        ("基带", prop("gsm.version.baseband").split(",")[0]),
        ("已运行", _uptime(float(uptime.split()[0])) if uptime.split() and
            re.fullmatch(r"[0-9.]+", uptime.split()[0]) else ""),
    ])

    soc = " ".join(value for value in (prop("ro.soc.manufacturer"), prop("ro.soc.model")) if value)
    cores = ""
    match = re.fullmatch(r"(\d+)-(\d+)", cpu_possible.strip())
    if match:
        cores = f"{int(match.group(2)) - int(match.group(1)) + 1} 核"
    freqs = [int(value) for value in cpu_freq.split() if value.isdigit()]
    cpu = " · ".join(value for value in (
        cores, f"最高 {max(freqs) / 1_000_000:.2f} GHz" if freqs else "") if value)
    mem = dict(re.findall(r"^(\w+):[ \t]+(\d+) kB", meminfo, re.M))
    memory = ""
    if mem.get("MemTotal"):
        memory = _format_bytes(int(mem["MemTotal"]) * 1024)
        if mem.get("MemAvailable"):
            memory += f"（可用 {_format_bytes(int(mem['MemAvailable']) * 1024)}）"
    storage = ""
    df_lines = [line.split() for line in df.splitlines() if line and not line.startswith("Filesystem")]
    if df_lines and len(df_lines[-1]) >= 4 and df_lines[-1][1].isdigit():
        total, used = int(df_lines[-1][1]) * 1024, int(df_lines[-1][2]) * 1024
        storage = f"已用 {_format_bytes(used)} / 共 {_format_bytes(total)}"
    section("硬件", [
        ("处理器", soc or prop("ro.board.platform", "ro.hardware")),
        ("平台", "" if prop("ro.board.platform") in {soc, ""} or not soc
            else prop("ro.board.platform")),
        ("CPU", cpu),
        ("架构", prop("ro.product.cpu.abi")),
        ("内存", memory),
        ("存储", storage),
    ])

    size = re.search(r"Override size: (\d+x\d+)", screen) or re.search(r"Physical size: (\d+x\d+)", screen)
    density = (re.search(r"Override density: (\d+)", screen)
               or re.search(r"Physical density: (\d+)", screen))
    rates = [float(value) for value in re.findall(r"fps=([0-9.]+)", display)]
    current = re.search(r"renderFrameRate ([0-9.]+)", display)
    refresh = ""
    if rates:
        refresh = f"最高 {round(max(rates))} Hz"
        if current:
            refresh = f"当前 {round(float(current.group(1)))} Hz · " + refresh
    section("屏幕", [
        ("分辨率", size.group(1).replace("x", " × ") if size else ""),
        ("像素密度", f"{density.group(1)} dpi" if density else ""),
        ("刷新率", refresh),
    ])

    bat = dict(re.findall(r"^[ \t]*([A-Za-z][A-Za-z ]*):[ \t]*(\S.*)$", battery, re.M))
    bat = {key.strip(): value.strip() for key, value in bat.items()}
    sources = [label for key, label in (("AC powered", "电源适配器"), ("USB powered", "USB"),
                                        ("Wireless powered", "无线充电"))
               if bat.get(key) == "true"]
    temperature = bat.get("temperature", "")
    voltage = bat.get("voltage", "")
    # TVs report a placeholder battery.
    is_tv = "tv" in prop("ro.build.characteristics").split(",")
    section("电池", [] if is_tv else [
        ("电量", f"{bat['level']}%" if bat.get("level", "").isdigit() else ""),
        ("状态", BATTERY_STATUS.get(bat.get("status", ""), "")),
        ("供电", "、".join(sources) if sources else ("电池" if bat else "")),
        ("健康", BATTERY_HEALTH.get(bat.get("health", ""), "")),
        ("温度", f"{int(temperature) / 10:.1f} °C" if temperature.lstrip("-").isdigit() else ""),
        ("电压", f"{int(voltage) / 1000:.2f} V" if voltage.isdigit() and int(voltage) > 100 else ""),
        ("电池类型", bat.get("technology", "")),
    ])

    by_kind: dict[str, list[str]] = {}
    for interface, address in re.findall(
        r"^\d+:\s+(\S+)\s+inet (\d+\.\d+\.\d+\.\d+)", ip_addr, re.M
    ):
        if interface != "lo":
            by_kind.setdefault(_interface_kind(interface), []).append(address)
    valid_public = re.fullmatch(r"\d+\.\d+\.\d+\.\d+", public_ip)
    section("网络", [
        ("内网 IP", "、".join(by_kind.get("lan", []) or by_kind.get("other", []))),
        ("外网 IP", public_ip if valid_public else ""),
        ("移动网络", "、".join(by_kind.get("mobile", []))),
        ("VPN", "、".join(by_kind.get("vpn", []))),
    ])
    return sections


def host_public_ip(timeout: float = 3) -> str:
    """The Mac's public address, for devices that share its connection."""
    import urllib.request
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=timeout) as reply:
            text = reply.read(64).decode("ascii", "ignore").strip()
    except (OSError, ValueError):
        return ""
    return text if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", text) else ""


def explain_failure(output: str, state: str = "",
                    port_reachable: bool | None = None) -> str:
    lower = output.lower()
    if "端口未开放" in output:
        return "端口暂时不可达；检查设备是否休眠、换网或关闭了无线调试"
    if state == "unauthorized" or "unauthorized" in lower or "authentication" in lower:
        return "需要在设备上授权 USB 调试，或用无线调试配对码完成配对"
    if state == "offline":
        return "ADB 设备离线；请保持设备亮屏并检查无线调试是否仍开启"
    if "host is down" in lower:
        return "设备没有响应；检查设备是否开机、仍连着同一 Wi-Fi，或 IP 已经变化"
    if "no route to host" in lower:
        return "ADB 服务报告无路由；工具将核对端口并重启本机 ADB 后重试"
    if "refused" in lower:
        return "设备拒绝连接；端口可能已关闭或无线调试端口已变化"
    if "timed out" in lower or "超过" in lower:
        return "连接超时；检查 Wi-Fi 隔离、设备休眠或防火墙"
    if port_reachable is False:
        return "端口当前不可达；检查设备是否休眠、换网或关闭了无线调试"
    if port_reachable:
        return "端口开放，但未完成 ADB 握手；可能是其它服务或需要设备授权"
    return "未完成 ADB 连接；检查设备上的无线调试是否仍开启"


class AdbLan:
    def __init__(self, progress: Callable[[str], None] | None = None):
        self.adb = find_adb()
        self.progress = progress or (lambda _message: None)
        self.networks: list[ipaddress.IPv4Network] = []
        self.emulator_pids: dict[str, int] = {}
        self._last_server_restart = 0.0
        self.last_reconnect: list[str] = []
        self._operation_lock = threading.RLock()

    def command(self, *args: str, timeout: float = 8) -> tuple[int, str]:
        return run_command([self.adb, "-P", str(ADB_PORT), *args], timeout)

    def devices(self) -> dict[str, dict]:
        return parse_devices(self.command("devices", "-l", timeout=6)[1])

    def load_known(self) -> dict[str, str]:
        try:
            data = json.loads(KNOWN_FILE.read_text())
            return {
                endpoint: identity
                for endpoint, identity in data.items()
                if endpoint_parts(endpoint) and isinstance(identity, str)
            }
        except (OSError, ValueError, AttributeError):
            return {}

    def save_known(self, known: dict[str, str]) -> None:
        APP_DIR.mkdir(parents=True, exist_ok=True)
        temporary = KNOWN_FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps(known, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, KNOWN_FILE)

    def load_usb_wireless(self) -> dict[str, str]:
        """Only endpoints previously matched to an authorized physical USB device."""
        try:
            data = json.loads(USB_WIRELESS_FILE.read_text())
            return {
                endpoint: identity for endpoint, identity in data.items()
                if usb_wireless_endpoint(endpoint) and isinstance(identity, str)
                and identity.strip() and identity != endpoint and identity.lower() != "unknown"
            }
        except (OSError, ValueError, AttributeError, TypeError):
            return {}

    def save_usb_wireless(self, verified: dict[str, str]) -> None:
        APP_DIR.mkdir(parents=True, exist_ok=True)
        temporary = USB_WIRELESS_FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps(verified, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, USB_WIRELESS_FILE)

    def _verify_usb_identity(self, endpoint: str, expected: str) -> bool | None:
        """True: the wireless device is the USB-authorized one. False: it is
        another device (disconnected). None: its serial could not be read
        this time (Wi-Fi hiccup, timeout); the connection is kept and checked
        again on the next scan rather than dropped."""
        actual = self._device_prop(endpoint, "ro.serialno")
        if not actual or actual.lower() == "unknown":
            return None
        if actual == expected:
            return True
        self.command("disconnect", endpoint, timeout=3)
        return False

    def load_tcpip_attempts(self) -> dict[str, dict]:
        try:
            data = json.loads(TCPIP_FILE.read_text())
        except (OSError, ValueError):
            return {}
        if not isinstance(data, dict):
            return {}
        attempts = {}
        for identity, value in data.items():
            if not isinstance(identity, str):
                continue
            if isinstance(value, (int, float)):
                # Older versions stored only the time of an attempt.
                attempts[identity] = {"at": float(value), "ok": False}
            elif isinstance(value, dict) and isinstance(value.get("at"), (int, float)):
                attempts[identity] = {"at": float(value["at"]), "ok": bool(value.get("ok"))}
        return attempts

    def save_tcpip_attempts(self, attempts: dict[str, dict]) -> None:
        APP_DIR.mkdir(parents=True, exist_ok=True)
        temporary = TCPIP_FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps(attempts, indent=2) + "\n")
        os.replace(temporary, TCPIP_FILE)

    def restart_server(self) -> bool:
        """Restart the local ADB server unless a projection depends on it."""
        if active_mirror_process():
            return False
        # A restart reconnects the app's device tracker, which starts another
        # scan; without a cool-down a lasting "no route" would restart it
        # again and again.
        try:
            if time.time() - SERVER_RESTART_FILE.stat().st_mtime < SERVER_RESTART_COOLDOWN:
                return False
        except OSError:
            pass
        try:
            APP_DIR.mkdir(parents=True, exist_ok=True)
            SERVER_RESTART_FILE.touch()
        except OSError:
            pass
        self.command("kill-server", timeout=5)
        self.command("start-server", timeout=6)
        self._last_server_restart = time.monotonic()
        return True

    def _device_prop(self, serial: str, prop: str) -> str:
        status, output = self.command("-s", serial, "shell", "getprop", prop, timeout=3)
        return output.strip() if status == 0 else ""

    def _wifi_ips(self, serial: str) -> list[str]:
        status, output = self.command("-s", serial, "shell", "ip", "-o", "-4", "addr", "show", timeout=4)
        if status != 0:
            return []
        ips = []
        for interface, ip in re.findall(
            r"^\d+:\s+(\S+)\s+.*?\binet (\d+\.\d+\.\d+\.\d+)/\d+", output, re.M
        ):
            interface = interface.split("@", 1)[0].split(":", 1)[0]
            routed_wifi = bool(re.fullmatch(r"(?:wlan|wifi)\d+", interface)) and usb_wireless_endpoint(f"{ip}:5555")
            if ip != "127.0.0.1" and (same_lan(ip, self.networks) or routed_wifi) and ip not in ips:
                ips.append(ip)
        return ips

    def _identity(self, serial: str, props: dict[str, str] | None = None) -> str:
        if serial.startswith("emulator-"):
            try:
                local_adb = f"127.0.0.1:{int(serial.split('-', 1)[1]) + 1}"
                if local_adb in self.emulator_pids:
                    return f"emulator-process:{self.emulator_pids[local_adb]}"
            except ValueError:
                pass
        if serial in self.emulator_pids:
            return f"emulator-process:{self.emulator_pids[serial]}"
        if serial.startswith("emulator-") or serial.startswith("127.0.0.1:"):
            status, android_id = self.command(
                "-s", serial, "shell", "settings", "get", "secure", "android_id", timeout=3
            )
            if status == 0 and re.fullmatch(r"[0-9a-fA-F]{8,32}", android_id):
                return "emulator:" + android_id.lower()
        identity = (
            props.get("ro.serialno", "") if props is not None
            else self._device_prop(serial, "ro.serialno")
        )
        return identity if identity and identity.lower() != "unknown" else serial

    def _connect(self, endpoint: str, attempts: int = 2, timeout: float = 3) -> str:
        result = ""
        for attempt in range(attempts):
            _code, result = self.command("connect", endpoint, timeout=timeout)
            if "connected to" in result.lower() or "already connected" in result.lower():
                return result
            if attempt + 1 < attempts:
                time.sleep(0.35)
        return result

    def _discover_lan_ports(self) -> list[str]:
        _code, output = run_command(["/sbin/ifconfig"], timeout=5)
        scan_networks, _notes = parse_interfaces(output, for_scan=True)
        hosts = [
            str(ip)
            for network in scan_networks
            for ip in network.hosts()
        ]
        local_ips = set(re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)", output))
        targets = (
            f"{host}:{port}"
            for host in dict.fromkeys(hosts)
            if host not in local_ips
            for port in SCAN_PORTS
        )
        found = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=96) as pool:
            futures = {pool.submit(port_open, endpoint, 0.35): endpoint for endpoint in targets}
            for future in concurrent.futures.as_completed(futures):
                if future.result():
                    found.append(futures[future])
        return sorted(found, key=lambda value: tuple(map(int, value.replace(":", ".").split("."))))

    def _discover_emulators(self) -> list[str]:
        _code, output = run_command(
            ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout=6
        )
        self.emulator_pids = parse_emulator_listeners(output)
        return list(self.emulator_pids)

    def _details(self, serial: str, hint: str = "") -> dict:
        status, output = self.command("-s", serial, "shell", "getprop", timeout=3)
        props = dict(re.findall(r"^\[([^\]]+)\]: \[([^\]]*)\]$", output, re.M)) if status == 0 else {}
        model = props.get("ro.product.model") or hint or "未知型号"
        manufacturer = props.get("ro.product.manufacturer", "")
        identity = self._identity(serial, props)
        qemu = props.get("ro.kernel.qemu", "")
        return {
            "identity": identity,
            "manufacturer": "本机模拟器" if serial.startswith("127.0.0.1:") else manufacturer,
            "model": model,
            "market_name": market_name(props),
            "tv": "tv" in props.get("ro.build.characteristics", "").split(","),
            "emulator": serial.startswith(("emulator-", "127.0.0.1:")) or qemu == "1",
        }

    def device_info(self, serial: str, scope: str = "all") -> dict:
        """Collects the device detail with one adb shell.

        scope "dynamic" only reads values that change (battery, memory...);
        the app keeps the rest cached."""
        if not serial or any(ch.isspace() for ch in serial):
            raise ValueError("设备地址无效")
        keys = list(DYNAMIC_INFO_COMMANDS if scope == "dynamic" else INFO_COMMANDS)
        status, output = self.command("-s", serial, "shell", info_script(keys), timeout=15)
        if status != 0 and INFO_SEPARATOR not in output and len(keys) > 1:
            raise ValueError(explain_failure(output) if output else "无法读取设备信息")
        parts = split_info_output(output, keys)
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", parts.get("public_ip", "").strip()):
            # Emulators and phones without curl share the Mac's connection
            # when they sit on its network.
            lan = re.findall(r"^\d+:\s+(?:wlan|eth)\S*\s+inet (\d+\.\d+\.\d+\.\d+)",
                             parts.get("ip_addr", ""), re.M)
            if not self.networks:
                _code, ifconfig = run_command(["/sbin/ifconfig"], timeout=5)
                self.networks, _notes = parse_interfaces(ifconfig)
            local = serial.startswith(("127.0.0.1:", "emulator-"))
            if local or any(same_lan(ip, self.networks) for ip in lan):
                parts["public_ip"] = host_public_ip()
        return {"sections": parse_device_info(parts), "scope": scope}

    def _start_server(self) -> None:
        """Starts the ADB server; a fresh one lists USB devices only after a
        moment, so wait until the list settles instead of missing them."""
        _status, output = self.command("start-server", timeout=6)
        if "daemon started" not in output and "starting it now" not in output:
            return
        previous = None
        deadline = time.monotonic() + 2.5
        while time.monotonic() < deadline:
            time.sleep(0.35)
            current = sorted(self.devices())
            if current and current == previous:
                return
            previous = current

    def _wifi_ips_settled(self, serial: str, wait: bool) -> list[str]:
        """A device that has just connected may not report its address yet."""
        ips = self._wifi_ips(serial)
        for _ in range(4 if wait else 0):
            if ips:
                break
            time.sleep(0.75)
            ips = self._wifi_ips(serial)
        return ips

    def scan(self, include_subnet_scan: bool = True, usb_check: bool = False) -> dict:
        """`usb_check` is set for scans caused by a device connection or the
        app's launch: every USB device without wireless ADB is then set up,
        even if an earlier attempt failed."""
        with self._operation_lock:
            started = time.monotonic()
            self.progress("检查本机 ADB 与网卡")
            self._start_server()
            _code, ifconfig = run_command(["/sbin/ifconfig"], timeout=5)
            self.networks, notes = parse_interfaces(ifconfig)
            if include_subnet_scan:
                _scan_networks, notes = parse_interfaces(ifconfig, for_scan=True)
            before = self.devices()
            known = self.load_known()
            verified = self.load_usb_wireless()
            original_verified = verified.copy()
            expected_usb = verified.copy()
            candidates: dict[str, set[str]] = {}
            pairing = []

            def add(endpoint: str, source: str) -> None:
                parsed = endpoint_parts(endpoint)
                if parsed and (same_lan(parsed[0], self.networks) or (
                    endpoint in expected_usb and usb_wireless_endpoint(endpoint)
                )):
                    candidates.setdefault(endpoint, set()).add(source)

            for endpoint in dict.fromkeys([*known, *verified]):
                add(endpoint, "上次成功")
            for endpoint, data in before.items():
                if endpoint_parts(endpoint):
                    add(endpoint, "本机模拟器" if endpoint.startswith("127.0.0.1:") else "当前 ADB")

            self.progress("读取 ADB 广播和模拟器端口")
            mdns = parse_mdns(self.command("mdns", "services", timeout=5)[1])
            if not mdns and include_subnet_scan:
                time.sleep(0.35)
                mdns = parse_mdns(self.command("mdns", "services", timeout=5)[1])
            tls_endpoints = {
                entry["endpoint"] for entry in mdns
                if entry["service"] == "_adb-tls-connect._tcp"
            }
            for entry in mdns:
                if entry["service"] == "_adb-tls-pairing._tcp":
                    pairing.append(entry)
                else:
                    add(entry["endpoint"], "无线调试广播")
            for endpoint in self._discover_emulators():
                add(endpoint, "本机模拟器")

            if include_subnet_scan:
                self.progress("并行扫描局域网常用 ADB 端口")
                for endpoint in self._discover_lan_ports():
                    add(endpoint, "局域网端口")

            self.progress("通过 USB 配置尚未连接无线 ADB 的设备")
            usb_issues = []
            tcpip_attempts = self.load_tcpip_attempts()
            tcpip_changed = False
            wireless_identities = {
                self._identity(endpoint)
                for endpoint, item in before.items()
                if is_network_transport(endpoint) and item["state"] == "device"
            }
            for serial, item in before.items():
                # Only USB transports: never `adb tcpip` a wireless link.
                if is_network_transport(serial) or serial.startswith("emulator-"):
                    continue
                if item["state"] != "device":
                    usb_issues.append({"serial": serial, "state": item["state"]})
                    continue
                identity = self._identity(serial)
                ips = self._wifi_ips_settled(serial, wait=usb_check)
                # Only a real, authorized USB transport may introduce a routed
                # Wi-Fi address. An unresolved mDNS name is not USB proof.
                ips = [ip for ip in ips if same_lan(ip, self.networks) or item.get("usb", False)]
                if not ips:
                    if identity not in wireless_identities:
                        usb_issues.append({"serial": serial, "state": "no_lan_ip"})
                    continue
                if identity in wireless_identities:
                    for ip in ips:
                        endpoint = f"{ip}:5555"
                        if item.get("usb") and before.get(endpoint, {}).get("state") == "device":
                            expected_usb[endpoint] = identity
                            add(endpoint, "USB 已授权")
                    continue
                endpoint = f"{ips[0]}:5555"
                if item.get("usb"):
                    expected_usb[endpoint] = identity
                port_ready = port_open_stable(endpoint)
                if port_ready and known.get(endpoint) == identity:
                    add(endpoint, "USB 已授权")
                    continue
                if not port_ready:
                    # The device works over USB; a closed cached port is not
                    # a separate failure to show.
                    candidates.pop(endpoint, None)
                    # Restarting adbd would cut an active USB projection.
                    if mirror_uses_serial(serial):
                        continue
                    decision = tcpip_decision(tcpip_attempts.get(identity), time.time(),
                                              forced=usb_check)
                    if decision != "try":
                        if not tcpip_attempts[identity]["ok"]:
                            usb_issues.append({"serial": serial, "state": "tcpip_unreachable"})
                        continue
                    self.progress("通过 USB 开启无线 ADB")
                    _code, output = self.command("-s", serial, "tcpip", "5555", timeout=7)
                    opened = False
                    if "restarting in TCP mode" in output or port_open_stable(endpoint):
                        for _ in range(12):
                            if port_open_stable(endpoint, attempts=2):
                                opened = True
                                break
                            time.sleep(0.3)
                    tcpip_attempts[identity] = {"at": time.time(), "ok": opened}
                    tcpip_changed = True
                    if not opened:
                        usb_issues.append({"serial": serial,
                                           "state": "tcpip_unreachable" if "restarting" in output
                                           else (output or "无法启用 TCP ADB")})
                        continue
                add(endpoint, "USB 自动启用")
            if tcpip_changed:
                self.save_tcpip_attempts(tcpip_attempts)

            self.progress("连接候选设备并核对身份")
            outcomes: dict[str, str] = {}

            def attempt(endpoint: str) -> str:
                if before.get(endpoint, {}).get("state") == "device":
                    return "已连接"
                is_emulator_listener = "本机模拟器" in candidates[endpoint]
                is_known = "上次成功" in candidates[endpoint]
                if not port_open_stable(endpoint, attempts=2) and not (is_emulator_listener or is_known):
                    return "端口未开放或已变化"
                return self._connect(
                    endpoint, attempts=1 if is_emulator_listener else 2,
                    timeout=2 if is_emulator_listener else 3
                )

            # Connect in parallel: one offline device no longer delays the rest.
            ordered = sorted(candidates, key=lambda ep: (
                0 if "上次成功" in candidates[ep] else 1,
                0 if "无线调试广播" in candidates[ep] else 1,
                ep,
            ))
            with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(8, len(ordered)))) as pool:
                for endpoint, outcome in zip(ordered, pool.map(attempt, ordered)):
                    outcomes[endpoint] = outcome

            after = self.devices()
            route_failures = [
                ep for ep, outcome in outcomes.items()
                if "no route to host" in outcome.lower() and port_open_stable(ep, attempts=2)
            ]
            if route_failures and self.restart_server():
                self.progress("端口可达但 ADB 报无路由，已重启本机 5037 服务并重试")
                for endpoint in candidates:
                    if port_open_stable(endpoint, attempts=2):
                        outcomes[endpoint] = self._connect(endpoint, attempts=1)
                after = self.devices()
            elif route_failures:
                self.progress("投屏正在运行，保留 ADB 服务并稍后重试异常连接")

            # One short retry for transient offline transports.
            for endpoint, item in list(after.items()):
                if item["state"] == "offline" and endpoint in candidates:
                    self.command("disconnect", endpoint, timeout=4)
                    outcomes[endpoint] = self._connect(endpoint, attempts=1)
            after = self.devices()

            identity_rejections = set()
            for endpoint, expected in expected_usb.items():
                if after.get(endpoint, {}).get("state") != "device":
                    continue
                match = self._verify_usb_identity(endpoint, expected)
                if match:
                    verified[endpoint] = expected
                elif match is False or endpoint not in original_verified:
                    # A new address must prove its identity; one already
                    # trusted survives a read that fails this once.
                    if match is None:
                        self.command("disconnect", endpoint, timeout=3)
                    identity_rejections.add(endpoint)
                    after.pop(endpoint, None)
                    verified.pop(endpoint, None)
                    known.pop(endpoint, None)
                    outcomes[endpoint] = "无线设备身份与 USB 授权记录不一致，未接受该连接"
            if verified != original_verified:
                self.save_usb_wireless(verified)

            self.progress("汇总物理设备与连接状态")
            devices: dict[str, dict] = {}
            for serial, item in after.items():
                if item["state"] == "device":
                    detail = self._details(serial, item["model_hint"])
                    identity = detail["identity"]
                    group = devices.setdefault(identity, {
                        **detail, "transports": [], "wireless": False
                    })
                    kind = "模拟器" if detail["emulator"] else (
                        "无线" if is_network_transport(serial) else "USB"
                    )
                    label = kind
                    if kind == "模拟器":
                        label = "模拟器实例" if serial.startswith("emulator-") else "本机 ADB 端口"
                    elif kind == "无线":
                        label = "无线调试（加密）" if (
                            serial in tls_endpoints or "._adb-tls-connect." in serial
                        ) else "无线 ADB"
                    group["transports"].append({
                        "endpoint": serial, "type": kind, "label": label, "state": "已连接"
                    })
                    group["wireless"] |= kind == "无线" and not detail["emulator"]
                    if endpoint_parts(serial):
                        known[serial] = identity
                else:
                    usb_issues.append({
                        "serial": serial, "state": item["state"],
                        "kind": "模拟器" if serial.startswith("emulator-") else "ADB",
                    })
            usb_issues_by_serial = {
                issue["serial"]: issue for issue in usb_issues
                if not devices.get(issue["serial"], {}).get("wireless")
            }
            usb_issues = list(usb_issues_by_serial.values())
            # Android's encrypted wireless-debugging port changes after restarts.
            # Drop a stale cached port once the same physical device is reachable
            # through another wireless transport.
            stale = {
                endpoint for endpoint, identity in known.items()
                if after.get(endpoint, {}).get("state") != "device"
                and devices.get(identity, {}).get("wireless")
                and not port_open(endpoint, 0.25)
            }
            for endpoint in stale:
                known.pop(endpoint, None)
            self.save_known({
                endpoint: identity for endpoint, identity in known.items()
                if not endpoint.startswith("127.0.0.1:")
            })

            failed = []
            for endpoint, sources in candidates.items():
                if endpoint in stale:
                    continue
                state = after.get(endpoint, {}).get("state", "")
                if state == "device":
                    continue
                reachable = port_open(endpoint, 0.3)
                # Only remembered from an earlier session and not reachable now:
                # the device is simply off or away (a TV on standby), not a
                # problem to show. It stays remembered and reconnects when back.
                if set(sources) <= {"上次成功"} and not state and not reachable:
                    continue
                outcome = outcomes.get(endpoint, "")
                reason = outcome if endpoint in identity_rejections else (
                    ("模拟器实例未运行或 ADB 端口已关闭"
                     if "端口未开放" in outcome
                     else "模拟器端口可见，但 Android 实例未就绪或 ADB 握手失败")
                    if "本机模拟器" in sources else
                    ("无线调试端口已发现，但未完成 ADB 连接。请在设备的无线调试中打开配对码页面，完成配对后重试"
                     if "无线调试广播" in sources and
                        "端口未开放" not in outcome and
                        state not in {"device", "offline"} and
                        "no route to host" not in outcome.lower()
                     else explain_failure(outcome, state, reachable))
                )
                failed.append({
                    "endpoint": endpoint,
                    "sources": sorted(sources),
                    "state": state or "未连接",
                    "reason": reason,
                    "detail": outcome[:220],
                })
            # iPhone / iPad over USB (usbmuxd on this Mac; no network traffic).
            self.progress("读取通过 USB 连接的苹果设备")
            apple_devices, apple_issues = ios_devices.scan()
            usb_issues.extend(apple_issues)
            return {
                # A stable order keeps rows from jumping when a transport changes.
                "devices": sorted(devices.values(), key=lambda d: (
                    d["emulator"], d["model"].lower(), d["identity"]
                )) + apple_devices,
                "failed": failed,
                "usb_issues": usb_issues,
                "pairing": pairing,
                "networks": [str(network) for network in self.networks],
                "notes": notes,
                "candidate_count": len(candidates),
                "duration_seconds": round(time.monotonic() - started, 1),
                "adb": self.adb,
            }

    def connect_manual(self, endpoint: str) -> dict:
        with self._operation_lock:
            parsed = endpoint_parts(endpoint)
            if not parsed:
                raise ValueError("请输入 IP:端口，例如 10.0.0.5:5555")
            if not self.networks:
                _code, ifconfig = run_command(["/sbin/ifconfig"], timeout=5)
                self.networks, _notes = parse_interfaces(ifconfig)
            if not same_lan(parsed[0], self.networks):
                raise ValueError("只允许连接本机所在局域网或 127.0.0.1")
            if not port_open(endpoint, 0.6):
                return {"ok": False, "message": "端口未开放，检查设备 IP 和无线调试端口"}
            output = self._connect(endpoint)
            state = self.devices().get(endpoint, {}).get("state", "")
            if "no route to host" in output.lower():
                if not self.restart_server():
                    return {"ok": False, "message": output,
                            "reason": "ADB 报告无路由；投屏正在运行，为避免中断投屏未重启 ADB 服务。"
                                      "结束投屏后再重试连接"}
                output = self._connect(endpoint, attempts=1)
                state = self.devices().get(endpoint, {}).get("state", "")
            if state == "device":
                known = self.load_known()
                known[endpoint] = self._identity(endpoint)
                self.save_known(known)
            return {"ok": state == "device", "message": output or state,
                    "reason": "" if state == "device" else explain_failure(output, state, True)}

    def forget(self, endpoint: str) -> dict:
        """Drop a cached endpoint the user no longer wants to reconnect."""
        with self._operation_lock:
            if not endpoint_parts(endpoint):
                raise ValueError("地址格式无效")
            known = self.load_known()
            known.pop(endpoint, None)
            self.save_known(known)
            verified = self.load_usb_wireless()
            if endpoint in verified:
                verified.pop(endpoint)
                self.save_usb_wireless(verified)
            if self.devices().get(endpoint, {}).get("state") != "device":
                self.command("disconnect", endpoint, timeout=3)
            return {"ok": True, "message": "已忽略 " + endpoint}

    def pair(self, endpoint: str, code: str) -> dict:
        with self._operation_lock:
            parsed = endpoint_parts(endpoint)
            if not parsed or not re.fullmatch(r"\d{6}", code):
                raise ValueError("请输入配对地址 IP:端口和设备显示的 6 位配对码")
            if not self.networks:
                _code, ifconfig = run_command(["/sbin/ifconfig"], timeout=5)
                self.networks, _notes = parse_interfaces(ifconfig)
            if not same_lan(parsed[0], self.networks):
                raise ValueError("配对地址必须在本机局域网内")
            _status, output = self.command("pair", endpoint, code, timeout=10)
            return {"ok": "successfully paired" in output.lower(),
                    "message": output.replace(code, "******")}

    def reconnect_known(self) -> bool:
        if not self._operation_lock.acquire(blocking=False):
            self.last_reconnect = ["扫描进行中，跳过本次重连"]
            return False
        changed = False
        try:
            self.last_reconnect = []
            current = self.devices()
            original_known = self.load_known()
            known = original_known.copy()
            verified = self.load_usb_wireless()
            original_verified = verified.copy()
            known.update(verified)
            mdns = parse_mdns(self.command("mdns", "services", timeout=4)[1])
            for entry in mdns:
                endpoint = entry["endpoint"]
                if entry["service"] != "_adb-tls-pairing._tcp" and endpoint_parts(endpoint):
                    known.setdefault(endpoint, "")
            for endpoint in self._discover_emulators():
                known.setdefault(endpoint, "")
            for endpoint, identity in list(known.items()):
                parsed = endpoint_parts(endpoint)
                if not parsed or not (same_lan(parsed[0], self.networks) or endpoint in verified):
                    continue
                if current.get(endpoint, {}).get("state") == "device":
                    if endpoint in verified and self._verify_usb_identity(endpoint, verified[endpoint]) is False:
                        self.last_reconnect.append(f"{endpoint}: 设备身份与 USB 授权记录不符")
                        known.pop(endpoint, None)
                        verified.pop(endpoint)
                    continue
                if not port_open_stable(endpoint, attempts=2):
                    self.last_reconnect.append(f"{endpoint}: 端口暂不可达")
                    continue
                output = self._connect(endpoint, attempts=1)
                self.last_reconnect.append(f"{endpoint}: {output[:100]}")
                if "connected to" in output.lower():
                    if endpoint in verified:
                        match = self._verify_usb_identity(endpoint, verified[endpoint])
                        if match is not False:
                            # Unreadable this time: keep it, check next time.
                            changed = True
                        else:
                            self.last_reconnect.append(f"{endpoint}: 设备身份与 USB 授权记录不符")
                            known.pop(endpoint, None)
                            verified.pop(endpoint)
                        continue
                    actual = self._identity(endpoint)
                    if identity and actual not in {identity, endpoint}:
                        self.last_reconnect.append(f"{endpoint}: 设备 ID 与缓存不符")
                        self.command("disconnect", endpoint, timeout=3)
                    elif (
                        not identity and actual != endpoint
                        and not endpoint.startswith("127.0.0.1:")
                    ):
                        known[endpoint] = actual
                        changed = True
                    else:
                        changed = True
                elif (
                    "no route to host" in output.lower()
                    and port_open_stable(endpoint, attempts=2)
                    and time.monotonic() - self._last_server_restart > 60
                    and self.restart_server()
                ):
                    for retry_endpoint in list(known):
                        retry_parts = endpoint_parts(retry_endpoint)
                        if (
                            retry_parts
                            and (same_lan(retry_parts[0], self.networks) or retry_endpoint in verified)
                            and port_open_stable(retry_endpoint, attempts=2)
                        ):
                            retry_output = self._connect(retry_endpoint, attempts=1)
                            if (
                                retry_endpoint in verified
                                and "connected to" in retry_output.lower()
                                and self._verify_usb_identity(retry_endpoint, verified[retry_endpoint]) is False
                            ):
                                self.last_reconnect.append(f"{retry_endpoint}: 设备身份与 USB 授权记录不符")
                                known.pop(retry_endpoint, None)
                                verified.pop(retry_endpoint)
                    changed = True
                    break
            kept = {
                ep: value for ep, value in known.items()
                if value and not ep.startswith("127.0.0.1:")
            }
            if kept != original_known:
                self.save_known(kept)
            if verified != original_verified:
                self.save_usb_wireless(verified)
        finally:
            self._operation_lock.release()
        return changed
