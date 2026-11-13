import AppKit
import Foundation
import Network
import SwiftUI

struct ADBTransport: Codable, Hashable {
    let endpoint: String
    let type: String
    let label: String?
    var state: String

    var displayName: String { label ?? type }
}

struct ADBDevice: Codable, Identifiable {
    let identity: String
    let manufacturer: String
    let model: String
    let marketName: String?
    let tv: Bool?
    let emulator: Bool
    var transports: [ADBTransport]
    var wireless: Bool
    /// "ios" for an iPhone / iPad over USB; nil (Android) otherwise.
    let platform: String?
    let deviceClass: String?

    var id: String { identity }
    var isApple: Bool { platform == "ios" }
    var connected: Bool { transports.contains { $0.state == "已连接" } }
    /// Prefers the retail name ("Xiaomi Civi 4 Pro") over the model code.
    var title: String {
        if emulator { return "模拟器 · \(model)" }
        if let name = marketName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return "\(manufacturer) \(model)".trimmingCharacters(in: .whitespaces)
    }
    /// "USB · 无线" — every way the device is reachable right now.
    var connectionSummary: String {
        if !connected { return "已断开" }
        if emulator { return "本机模拟器" }
        var kinds: [String] = []
        if transports.contains(where: { $0.type == "USB" }) { kinds.append("USB") }
        if transports.contains(where: { $0.type == "无线" }) { kinds.append("无线") }
        return kinds.joined(separator: " · ")
    }
    var subtitle: String {
        if !connected { return "已断开" }
        if emulator { return "本机模拟器" }
        if transports.contains(where: { $0.type == "USB" && $0.state == "已连接" }) {
            return "USB 已连接"
        }
        return "无线已连接"
    }
    var symbol: String {
        if isApple { return deviceClass == "iPad" ? "ipad" : "iphone" }
        return emulator ? "macwindow" : tv == true ? "tv" : "smartphone"
    }
}

struct ADBFailure: Codable {
    let endpoint: String
    let sources: [String]
    let state: String
    let reason: String
    let detail: String
}

struct ADBUSBIssue: Codable {
    let serial: String
    let state: String
    let kind: String?
}

struct ADBPairing: Codable {
    let name: String
    let service: String
    let endpoint: String
}

struct ADBReport: Codable {
    var devices: [ADBDevice]
    var failed: [ADBFailure]
    var usbIssues: [ADBUSBIssue]
    let pairing: [ADBPairing]
    let networks: [String]
    let notes: [String]
    let candidateCount: Int
    let durationSeconds: Double
    let adb: String

    var issues: [IssueItem] {
        let failedItems = failed.map {
            IssueItem(id: "port:" + $0.endpoint, title: $0.endpoint,
                      summary: $0.reason, detail: $0.detail,
                      source: $0.sources.joined(separator: " · "), endpoint: $0.endpoint)
        }
        let usbItems = usbIssues.map {
            IssueItem(id: "usb:" + $0.serial,
                      title: $0.state.hasPrefix("ios_") ? "iPhone（\($0.serial.prefix(8))…）" : $0.serial,
                      summary: $0.state == "unauthorized" ? "请在设备上允许 USB 调试" :
                               $0.state == "no_lan_ip" ? "未找到可用于自动无线 ADB 的 Wi-Fi 地址" :
                               $0.state == "tcpip_unreachable" ?
                                   "已尝试开启无线 ADB，但 5555 端口不可达；检查路由器 AP 隔离或防火墙" :
                               $0.state == "offline" ? "设备离线，请解锁或启动模拟器" :
                               $0.state == "ios_untrusted" ? "请在 iPhone 上点“信任”，并输入锁屏密码" :
                               $0.state == "ios_locked" ? "请解锁 iPhone，然后在弹出的提示中点“信任”" :
                               $0.state == "ios_denied" ? "已在 iPhone 上选择“不信任”；重新插拔数据线后再试" :
                               $0.state == "ios_unavailable" ? "暂时无法读取这台 iPhone，请重新插拔数据线" : $0.state,
                      detail: "", source: $0.kind ?? "USB", endpoint: nil)
        }
        let pairItems = pairing.map {
            IssueItem(id: "pair:" + $0.endpoint, title: $0.endpoint,
                      summary: "等待设备显示的 6 位配对码", detail: "",
                      source: "无线调试配对", endpoint: $0.endpoint)
        }
        let all = failedItems + usbItems + pairItems
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }
}

struct IssueItem: Identifiable {
    let id: String
    let title: String
    let summary: String
    let detail: String
    let source: String
    let endpoint: String?

    /// Pairing waits for the user (blue); other items need attention (orange).
    var symbol: String {
        if id.hasPrefix("pair:") { return "lock.open.fill" }
        if id.hasPrefix("usb:") { return "cable.connector.slash" }
        return "exclamationmark.triangle.fill"
    }
    var tint: Color { id.hasPrefix("pair:") ? Theme.accent : Theme.attention }
}

enum WorkerError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

enum Worker {
    static func run(_ action: String, payload: [String: String] = [:],
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let resources = Bundle.main.resourceURL else {
                    throw WorkerError.failed("应用缺少扫描组件，请重新安装")
                }
                let worker = resources.appendingPathComponent("Worker/adb-worker")
                let tools = resources.appendingPathComponent("Tools", isDirectory: true)
                let adb = tools.appendingPathComponent("adb")
                guard FileManager.default.isExecutableFile(atPath: worker.path),
                      FileManager.default.isExecutableFile(atPath: adb.path) else {
                    throw WorkerError.failed("应用内的扫描组件或 ADB 缺失，请重新安装")
                }
                let process = Process()
                process.executableURL = worker
                process.arguments = [action]
                process.currentDirectoryURL = worker.deletingLastPathComponent()
                var environment = ProcessInfo.processInfo.environment
                environment["ADB_BIN"] = adb.path
                environment["PATH"] = "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin"
                environment.removeValue(forKey: "ADB_SERVER_SOCKET")
                environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
                environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
                environment["PYTHONDONTWRITEBYTECODE"] = "1"
                environment["PYTHONUNBUFFERED"] = "1"
                process.environment = environment

                let input = Pipe()
                let output = Pipe()
                let errorPipe = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errorPipe
                try process.run()
                let request = try JSONSerialization.data(withJSONObject: payload)
                // try write(contentsOf:): a worker that already exited makes
                // this throw instead of raising an uncatchable exception.
                try? input.fileHandleForWriting.write(contentsOf: request)
                try? input.fileHandleForWriting.close()

                var bytes = Data()
                var errBytes = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    bytes = output.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBytes = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()

                let lines = String(data: bytes, encoding: .utf8)?.split(separator: "\n") ?? []
                guard let last = lines.last,
                      let data = String(last).data(using: .utf8),
                      let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    let errLine = String(data: errBytes, encoding: .utf8)?
                        .split(separator: "\n").last.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw WorkerError.failed(errLine.isEmpty ? "设备扫描没有返回结果" : errLine)
                }
                if let error = response["error"] as? String {
                    throw WorkerError.failed(error)
                }
                if process.terminationStatus != 0 {
                    throw WorkerError.failed("操作失败，请检查设备连接")
                }
                DispatchQueue.main.async { completion(.success(response)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

final class DiscoveryMonitor: NSObject, NetServiceBrowserDelegate {
    var onADBChange: (() -> Void)?
    var onBonjourChange: (() -> Void)?
    var onNetworkChange: (() -> Void)?

    private var browsers: [NetServiceBrowser] = []
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.network")
    private var tracker: Process?
    private let appleMonitor = AppleDeviceMonitor()
    private var stopped = false
    private var lastPathSignature: String?
    private static let instances = NSHashTable<DiscoveryMonitor>.weakObjects()

    /// Stops every monitor so `adb track-devices` does not outlive the app.
    static func stopAll() {
        instances.allObjects.forEach { $0.stop() }
    }

    func start() {
        Self.instances.add(self)
        DispatchQueue.global(qos: .utility).async { Self.killOrphanTrackers() }
        for type in ["_adb._tcp.", "_adb-tls-connect._tcp.", "_adb-tls-pairing._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            // NWPathMonitor also reports updates when nothing a scan depends on
            // changed (e.g. while the subnet probe runs), which used to start
            // an endless chain of full scans.
            let signature = Self.signature(of: path)
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                if let previous, previous != signature { self.onNetworkChange?() }
            }
        }
        networkMonitor.start(queue: networkQueue)
        startADBTracker()
        // iPhones / iPads plugged in or out count as a device change.
        appleMonitor.onChange = { [weak self] in self?.onADBChange?() }
        appleMonitor.start()
    }

    private static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name)/\(String(describing: $0.type))" }.sorted()
        return "\(path.status)|\(interfaces.joined(separator: ","))|" +
            localIPv4Addresses().joined(separator: ",")
    }

    private static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let netmask = entry.ifa_netmask else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            getnameinfo(netmask, socklen_t(netmask.pointee.sa_len), &mask, socklen_t(mask.count),
                        nil, 0, NI_NUMERICHOST)
            result.append("\(String(cString: entry.ifa_name))=\(String(cString: host))/\(String(cString: mask))")
        }
        return result.sorted()
    }

    /// Removes `track-devices` clients left behind by an earlier crash.
    private static func killOrphanTrackers() {
        guard let adb = Bundle.main.resourceURL?.appendingPathComponent("Tools/adb").path else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let target = "\(adb) -P 5037 track-devices"
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1", String(fields[2]) == target,
                  let pid = pid_t(fields[0]) else { continue }
            kill(pid, SIGTERM)
        }
    }

    func stop() {
        stopped = true
        appleMonitor.stop()
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        networkMonitor.cancel()
        (tracker?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if tracker?.isRunning == true { tracker?.terminate() }
        tracker = nil
    }

    private func startADBTracker() {
        guard !stopped,
              let adb = Bundle.main.resourceURL?.appendingPathComponent("Tools/adb"),
              FileManager.default.isExecutableFile(atPath: adb.path) else { return }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-P", "5037", "track-devices"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS",
                    "ANDROID_ADB_SERVER_PORT"] { environment.removeValue(forKey: key) }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.onADBChange?() }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.stopped else { return }
                self.startADBTracker()
            }
        }
        do {
            try process.run()
            tracker = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        onBonjourChange?()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService, moreComing: Bool) {
        onBonjourChange?()
    }
}

final class DeviceStore: ObservableObject {
    @Published var report: ADBReport?
    @Published var selectedID: String?
    @Published var scanning = false
    /// False until the first full scan after launch has finished; devices
    /// found only by that scan may still appear.
    @Published private(set) var initialSweepDone = false
    @Published var actionBusy = false
    /// A connect or pair request waiting for the running scan to finish.
    @Published private(set) var actionQueued = false
    private var queuedAction: (() -> Void)?
    @Published var phase = "准备扫描"
    @Published var error: String?
    private var timer: Timer?
    private var monitor: DiscoveryMonitor?
    private var scheduledScan: DispatchWorkItem?
    private var scheduledFull = false
    private var pendingScan: Bool?
    private var initialSweepPending = true
    private var lastRecoverySweep = Date.distantPast
    /// Set by the app's launch and by every ADB device change: the next scan
    /// turns on wireless ADB for USB devices that do not have it yet.
    private var usbCheckPending = true
    /// A sweep of the whole subnet's ADB ports is running (only on request,
    /// or periodically when the user turned that on).
    @Published private(set) var scanningNetwork = false

    /// Off by default: probing every address of the network looks like a port
    /// scan to company security tools. Devices are found without it through
    /// wireless-debugging broadcasts, USB, remembered addresses and emulators.
    static let subnetScanKey = "discovery.subnetScan"
    private var autoSubnet: Bool { UserDefaults.standard.bool(forKey: Self.subnetScanKey) }

    init() {
        // Show already-connected and broadcasting devices first; a second
        // pass a moment later settles macOS local-network access.
        scan(full: false)
        pendingScan = autoSubnet
        let monitor = DiscoveryMonitor()
        monitor.onADBChange = { [weak self] in
            self?.usbCheckPending = true
            self?.requestScan(full: false)
        }
        monitor.onBonjourChange = { [weak self] in self?.requestScan(full: false) }
        monitor.onNetworkChange = { [weak self] in
            guard let self else { return }
            self.requestScan(full: self.autoSubnet)
        }
        self.monitor = monitor
        monitor.start()
    }

    deinit {
        timer?.invalidate()
        scheduledScan?.cancel()
        monitor?.stop()
    }

    var busy: Bool { scanning || actionBusy }

    private func requestScan(full: Bool, delay: TimeInterval = 0.45) {
        if busy {
            pendingScan = (pendingScan ?? false) || full
            return
        }
        scheduledFull = scheduledFull || full
        scheduledScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let full = self.scheduledFull
            self.scheduledFull = false
            self.scan(full: full)
        }
        scheduledScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFallback() {
        timer?.invalidate()
        let waitingIOSAuth = report?.usbIssues.contains {
            $0.state == "ios_untrusted" || $0.state == "ios_locked"
        } == true
        if waitingIOSAuth {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.scan(full: false)
            }
            return
        }
        let needsRecovery = report?.devices.isEmpty != false || report?.issues.isEmpty == false
        timer = Timer.scheduledTimer(withTimeInterval: needsRecovery ? 45 : 90,
                                     repeats: false) { [weak self] _ in
            guard let self else { return }
            self.scan(full: self.autoSubnet)
        }
    }

    /// Probes the subnet's common ADB ports once, at the user's request.
    func scanNetwork() {
        requestScan(full: true, delay: 0)
    }

    func scan(full: Bool) {
        guard !busy else {
            pendingScan = (pendingScan ?? false) || full
            return
        }
        scheduledScan?.cancel()
        scheduledScan = nil
        scheduledFull = false
        timer?.invalidate()
        scanning = true
        scanningNetwork = full
        error = nil
        if report == nil || phase == "扫描失败" { phase = "正在发现设备…" }
        if full { phase = "正在刷新设备…" }
        let usbCheck = usbCheckPending
        usbCheckPending = false
        Worker.run(full ? "scan" : "scan_fast",
                   payload: usbCheck ? ["usb_check": "1"] : [:]) { [weak self] result in
            guard let self else { return }
            self.scanning = false
            self.scanningNetwork = false
            if full || !self.initialSweepPending { self.initialSweepDone = true }
            var needsImmediateRecovery = false
            switch result {
            case .success(let response):
                do {
                    guard let value = response["report"] else {
                        throw WorkerError.failed("扫描结果不完整")
                    }
                    let data = try JSONSerialization.data(withJSONObject: value)
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    var report = try decoder.decode(ADBReport.self, from: data)
                    if !full && self.initialSweepPending {
                        // Right after launch (notably after an update) macOS may
                        // still be settling local-network access, so network
                        // failures are left to the full scan that follows.
                        report.failed.removeAll()
                        report.usbIssues.removeAll {
                            ["tcpip_unreachable", "no_lan_ip"].contains($0.state)
                        }
                    }
                    needsImmediateRecovery = !full &&
                        Date().timeIntervalSince(self.lastRecoverySweep) > 30 &&
                        report.failed.contains { $0.reason.contains("无路由") }
                    if needsImmediateRecovery {
                        // The full recovery scan runs immediately. Avoid showing
                        // its transient route failures as disconnected devices.
                        report.failed.removeAll { $0.reason.contains("无路由") }
                        self.lastRecoverySweep = Date()
                    }
                    self.report = report
                    let count = report.devices.count
                    self.phase = count == 0 ? "未发现设备" : "已连接 \(count) 台设备"
                    let valid = Set(report.devices.map { "device:" + $0.identity } +
                                    report.issues.map { $0.id })
                    if self.selectedID == nil || !valid.contains(self.selectedID!) {
                        self.selectedID = report.devices.first.map { "device:" + $0.identity } ??
                                          report.issues.first?.id
                    }
                } catch {
                    self.error = error.localizedDescription
                    self.phase = "扫描失败"
                }
            case .failure(let failure):
                self.error = failure.localizedDescription
                self.phase = "扫描失败"
            }
            if let action = self.queuedAction {
                // The user's request goes first; it schedules the next scan.
                self.queuedAction = nil
                self.actionQueued = false
                if needsImmediateRecovery {
                    self.pendingScan = (self.pendingScan ?? false) || self.autoSubnet
                } else if self.initialSweepPending && self.pendingScan == nil {
                    self.pendingScan = self.autoSubnet
                }
                action()
            } else if let pending = self.pendingScan {
                self.pendingScan = nil
                let delay: TimeInterval = needsImmediateRecovery ? 0.25 :
                    (self.initialSweepPending && pending ? 3 : 0.45)
                self.initialSweepPending = false
                self.requestScan(full: pending || (needsImmediateRecovery && self.autoSubnet),
                                 delay: delay)
            } else if needsImmediateRecovery {
                self.initialSweepPending = false
                self.requestScan(full: self.autoSubnet, delay: 0.25)
            } else {
                self.scheduleFallback()
            }
        }
    }

    func cancelQueuedAction() {
        guard actionQueued else { return }
        queuedAction = nil
        actionQueued = false
    }

    /// Stops reconnecting to a cached address the user no longer uses.
    func forget(endpoint: String) {
        perform("forget", endpoint: endpoint) { [weak self] ok, message in
            guard let self else { return }
            if ok {
                self.report?.failed.removeAll { $0.endpoint == endpoint }
                if self.selectedID == "port:" + endpoint {
                    self.selectedID = self.report?.devices.first.map { "device:" + $0.identity }
                }
            } else {
                self.error = message
            }
        }
    }

    func perform(_ action: String, endpoint: String, code: String = "",
                 completion: @escaping (Bool, String) -> Void) {
        if actionBusy || actionQueued {
            completion(false, "上一项操作还没有完成，请稍候。")
            return
        }
        if scanning {
            // Scans and actions share the ADB server; run right after the scan
            // instead of dropping the request.
            actionQueued = true
            queuedAction = { [weak self] in
                self?.perform(action, endpoint: endpoint, code: code, completion: completion)
            }
            return
        }
        scheduledScan?.cancel()
        scheduledScan = nil
        actionBusy = true
        Worker.run(action, payload: ["endpoint": endpoint, "code": code]) { [weak self] response in
            guard let self else { return }
            self.actionBusy = false
            let pending = self.pendingScan
            self.pendingScan = nil
            let wasInitialSweep = self.initialSweepPending
            self.initialSweepPending = false
            switch response {
            case .success(let value):
                let result = value["result"] as? [String: Any] ?? [:]
                let ok = result["ok"] as? Bool ?? false
                let message = result["reason"] as? String ??
                              result["message"] as? String ?? "操作未完成"
                completion(ok, message)
                if ok || pending != nil || wasInitialSweep {
                    self.requestScan(full: pending ?? false)
                } else {
                    self.scheduleFallback()
                }
            case .failure(let failure):
                completion(false, failure.localizedDescription)
                if pending != nil || wasInitialSweep {
                    self.requestScan(full: pending ?? false)
                } else {
                    self.scheduleFallback()
                }
            }
        }
    }
}

/// Selection painted like a native sidebar: brand accent while the window is
/// key, neutral grey when another window is in front.
struct SidebarSelection: ViewModifier {
    let selected: Bool
    @Environment(\.controlActiveState) private var activeState
    @ObservedObject private var theme = ThemeStore.shared
    @State private var hovering = false

    private var active: Bool { activeState == .key || activeState == .active }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? (active ? Theme.accent : Color.primary.opacity(0.11)) :
                          hovering ? Color.primary.opacity(0.05) : Color.clear)
                    .animation(Theme.quick, value: selected)
                    .animation(Theme.quick, value: theme.style)
            )
            .environment(\.sidebarRowHighlighted, selected && active)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct SidebarRowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarRowHighlighted: Bool {
        get { self[SidebarRowHighlightedKey.self] }
        set { self[SidebarRowHighlightedKey.self] = newValue }
    }
}

struct SidebarRowContent: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var status: Color?
    var pulsing = false
    var customIcon: AnyView? = nil
    @Environment(\.sidebarRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 10) {
            if let customIcon {
                customIcon
            } else {
                IconTile(symbol: symbol, size: 30,
                         style: highlighted ? .plain : .tinted(tint))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(highlighted ? Color.white : Color.primary)
                Text(subtitle).font(.caption).lineLimit(1)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.82) : Color.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let status {
                StatusDot(color: highlighted ? .white : status, pulsing: pulsing)
            }
        }
    }
}

struct DeviceSidebarRow: View {
    let device: ADBDevice
    let selected: Bool
    @ObservedObject private var mirror = MirrorStore.shared
    @ObservedObject private var iosMirror = IOSMirrorStore.shared
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let live = mirror.sessions[device.id] != nil || iosMirror.open.contains(device.id)
        SidebarRowContent(
            symbol: device.symbol,
            tint: Theme.accent,
            title: device.title,
            subtitle: live ? "投屏中 · " + device.connectionSummary : device.connectionSummary,
            status: !device.connected ? .gray : live ? Theme.accent : Theme.online,
            pulsing: live,
            customIcon: theme.isAppleNative ? AnyView(DeviceSidebarIcon(device: device)) : nil
        )
        .modifier(SidebarSelection(selected: selected))
    }
}

struct IssueSidebarRow: View {
    let issue: IssueItem
    let selected: Bool
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let _ = theme.style
        SidebarRowContent(symbol: issue.symbol, tint: issue.tint,
                          title: issue.title, subtitle: issue.summary)
            .modifier(SidebarSelection(selected: selected))
    }
}

/// Sidebar section title with a count.
struct SidebarHeader: View {
    let title: String
    /// nil before the first result: no number yet.
    let count: Int?
    var searching = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if searching {
                Spacer()
                ProgressView().controlSize(.mini)
                Text("正在查找").font(.caption2)
            }
        }
        .animation(Theme.quick, value: searching)
    }
}

struct DeviceInfoSection: Identifiable, Codable {
    struct Item: Codable {
        let label: String
        let value: String
    }
    let title: String
    let items: [Item]
    var id: String { title }
}

/// Device details. Fixed properties are kept on disk and refreshed weekly or on
/// request; battery, memory and other changing values are read on each visit.
final class DeviceInfoStore: ObservableObject {
    static let shared = DeviceInfoStore()
    private struct Entry: Codable {
        var sections: [DeviceInfoSection]
        var fullAt: Date
        /// Field layout of the cached rows; an older layout is read again.
        var version: Int?
    }
    private static let cacheVersion = 3
    private static let persistQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.deviceinfo", qos: .utility)

    @Published private(set) var sections: [String: [DeviceInfoSection]] = [:]
    @Published private(set) var loading: Set<String> = []
    /// Full reads only; the quick refresh of changing values stays silent.
    @Published private(set) var fullLoading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    private var fullAt: [String: Date] = [:]
    private var dynamicAt: [String: Date] = [:]
    private static let fullLifetime: TimeInterval = 7 * 24 * 3600
    private static let dynamicLifetime: TimeInterval = 60
    /// Sections made only of changing values are replaced as a whole.
    private static let dynamicSections: Set<String> = ["电池", "网络"]

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LAN ADB Manager/device_info.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        let current = cached.filter { $0.value.version == Self.cacheVersion }
        sections = current.mapValues(\.sections)
        fullAt = current.mapValues(\.fullAt)
    }

    private func persist() {
        var entries: [String: Entry] = [:]
        for (id, value) in sections {
            if let date = fullAt[id] {
                entries[id] = Entry(sections: value, fullAt: date, version: Self.cacheVersion)
            }
        }
        let targetURL = Self.cacheURL
        Self.persistQueue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: targetURL, options: .atomic)
        }
    }

    func load(_ device: ADBDevice, force: Bool = false) {
        let id = device.identity
        guard !loading.contains(id) else { return }
        let now = Date()
        let needsFull = force || sections[id] == nil ||
            now.timeIntervalSince(fullAt[id] ?? .distantPast) > Self.fullLifetime
        if !needsFull, now.timeIntervalSince(dynamicAt[id] ?? .distantPast) < Self.dynamicLifetime {
            return
        }
        guard let serial = MirrorStore.preferredTransports(for: device).first?.endpoint else {
            if sections[id] == nil { errors[id] = "设备未连接，无法读取信息。" }
            return
        }
        loading.insert(id)
        let scope = needsFull ? "all" : "dynamic"
        if needsFull { fullLoading.insert(id) }
        Worker.run("info", payload: ["serial": serial, "scope": scope,
                                     "platform": device.platform ?? "android"]) { [weak self] result in
            guard let self else { return }
            self.loading.remove(id)
            self.fullLoading.remove(id)
            switch result {
            case .success(let response):
                let info = response["info"] as? [String: Any]
                let raw = info?["sections"] as? [[String: Any]] ?? []
                let fresh: [DeviceInfoSection] = raw.compactMap { entry in
                    guard let title = entry["title"] as? String,
                          let items = entry["items"] as? [[String]] else { return nil }
                    return DeviceInfoSection(title: title, items: items.compactMap {
                        $0.count == 2 ? DeviceInfoSection.Item(label: $0[0], value: $0[1]) : nil
                    })
                }
                if scope == "all" {
                    self.sections[id] = fresh
                    if !fresh.isEmpty {
                        self.fullAt[id] = Date()
                    }
                } else {
                    self.sections[id] = Self.merge(self.sections[id] ?? [], with: fresh)
                }
                if !fresh.isEmpty {
                    self.dynamicAt[id] = Date()
                }
                self.errors[id] = nil
                self.persist()
            case .failure(let failure):
                self.errors[id] = failure.localizedDescription
            }
        }
    }

    private static func merge(_ cached: [DeviceInfoSection],
                              with fresh: [DeviceInfoSection]) -> [DeviceInfoSection] {
        guard !fresh.isEmpty else { return cached }
        var result = cached
        if !fresh.contains(where: { $0.title == "电池" }) {
            result.removeAll { $0.title == "电池" }
        }
        for section in fresh {
            guard let index = result.firstIndex(where: { $0.title == section.title }) else {
                result.append(section)
                continue
            }
            if dynamicSections.contains(section.title) {
                result[index] = section
                continue
            }
            var items = result[index].items
            for item in section.items {
                if let position = items.firstIndex(where: { $0.label == item.label }) {
                    items[position] = item
                } else {
                    items.append(item)
                }
            }
            result[index] = DeviceInfoSection(title: section.title, items: items)
        }
        return result
    }

    func value(_ label: String, for id: String) -> String? {
        sections[id]?.lazy.flatMap(\.items).first { $0.label == label }?.value
    }
}

private struct StorageOverview {
    let raw: String
    let summaryText: String
    let remainingText: String
    let fraction: Double

    static func parse(_ raw: String) -> StorageOverview? {
        let parts = raw.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let used = parseAmount(parts[0], prefix: "已用"),
              let total = parseAmount(parts[1], prefix: "共"),
              total.bytes > 0 else { return nil }
        let fraction = min(1.0, max(0.0, used.bytes / total.bytes))
        let freeBytes = max(0.0, total.bytes - used.bytes)
        return StorageOverview(
            raw: raw,
            summaryText: "\(used.display) / \(total.display)",
            remainingText: "剩余可用 \(formatBytes(freeBytes))",
            fraction: fraction
        )
    }

    private static func parseAmount(_ part: Substring, prefix: String) -> (bytes: Double, display: String)? {
        var text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 2, let value = Double(tokens[0]) else { return nil }
        let unit = tokens[1].uppercased()
        let scale: Double
        switch unit {
        case "TB": scale = 1024 * 1024 * 1024 * 1024
        case "GB": scale = 1024 * 1024 * 1024
        case "MB": scale = 1024 * 1024
        case "KB": scale = 1024
        case "B": scale = 1
        default: return nil
        }
        return (value * scale, "\(tokens[0]) \(unit)")
    }

    private static func formatBytes(_ bytes: Double) -> String {
        let gb = 1024.0 * 1024.0 * 1024.0
        let tb = gb * 1024.0
        let mb = 1024.0 * 1024.0
        if bytes >= tb { return String(format: "%.2f TB", bytes / tb) }
        if bytes >= gb { return String(format: "%.1f GB", bytes / gb) }
        return String(format: "%.0f MB", max(0, bytes / mb))
    }
}

struct DeviceDetail: View {
    let device: ADBDevice
    @ObservedObject private var mirror = MirrorStore.shared
    @ObservedObject private var info = DeviceInfoStore.shared
    @ObservedObject private var appWindows = AppWindowStore.shared
    @ObservedObject private var iosMirror = IOSMirrorStore.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var pickingApp = false
    @State private var storageCopied = false
    @AppStorage("mirror.audio") private var audioEnabled = true
    @AppStorage("mirror.maxSize") private var maxSize = 1920
    @AppStorage("mirror.maxFPS") private var maxFPS = 60
    @AppStorage("mirror.videoBitrateMbps") private var videoBitrateMbps = 8
    @AppStorage("mirror.audioBitrateKbps") private var audioBitrateKbps = 128
    @AppStorage("mirror.videoCodec") private var videoCodec = "h265"

    private var mirrorOptions: MirrorOptions {
        MirrorOptions(audio: audioEnabled,
                      maxSize: maxSize, maxFPS: maxFPS,
                      videoBitrateMbps: videoBitrateMbps,
                      audioBitrateKbps: audioBitrateKbps, videoCodec: videoCodec)
    }

    private enum MirrorState: Equatable { case idle, starting, live }
    private var mirrorState: MirrorState {
        if device.isApple {
            if iosMirror.starting.contains(device.id) { return .starting }
            return iosMirror.open.contains(device.id) ? .live : .idle
        }
        if mirror.starting.contains(device.id) { return .starting }
        guard let session = mirror.sessions[device.id] else { return .idle }
        return session.ready ? .live : .starting
    }

    private var storageOverview: StorageOverview? {
        info.value("存储", for: device.id).flatMap(StorageOverview.parse)
    }

    private var nativeSubtitle: String {
        if device.isApple {
            let parts = [info.value("系统", for: device.id), device.subtitle].compactMap { $0 }
            return parts.isEmpty ? device.subtitle : parts.joined(separator: " · ")
        }
        let androidVer = info.value("Android", for: device.id).map { "Android \($0)" }
        let rom = info.value("系统界面", for: device.id)
        let parts = [androidVer, rom].compactMap { $0 }
        return parts.isEmpty ? device.subtitle : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.isAppleNative ? 20 : 26) {
                header
                if device.isApple, let error = iosMirror.errors[device.id] {
                    Banner(text: error)
                } else if let error = mirror.errors[device.id] {
                    Banner(text: error)
                } else if let error = appWindows.errors[device.id], !pickingApp {
                    Banner(text: error)
                } else if let message = mirror.messages[device.id] {
                    Banner(text: message, symbol: "record.circle", tint: Theme.recording)
                }
                if theme.isAppleNative {
                    nativeTelemetryStrip
                } else {
                    connections
                }
                infoSection
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(Theme.quick, value: mirrorState)
            .animation(Theme.quick, value: theme.style)
        }
        .sheet(isPresented: $pickingApp) {
            AppPickerView(device: device, options: mirrorOptions)
        }
        // A different device starts at the top instead of the old scroll offset.
        .id(device.identity)
        .task(id: "\(device.identity)|\(device.connected)") { info.load(device) }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if theme.isAppleNative {
            HStack(alignment: .center, spacing: 16) {
                DeviceHeroIllustration(device: device)
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(nativeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    chips
                        .padding(.top, 2)
                }
                Spacer(minLength: 12)
                tools
                mirrorControl
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 5, y: 1.5)
        } else {
            HStack(alignment: .center, spacing: 16) {
                IconTile(symbol: device.symbol, size: 64, style: .gradient)
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    chips
                }
                Spacer(minLength: 12)
                tools
                mirrorControl
            }
        }
    }

    /// Secondary tools beside the main mirror action.
    private var tools: some View {
        HStack(spacing: 8) {
            // iOS has no way to show one app on its own screen.
            if !device.isApple {
                Button {
                    appWindows.errors[device.id] = nil
                    pickingApp = true
                } label: {
                    Label("应用", systemImage: "macwindow.on.rectangle")
                }
                .help("把手机上的某个应用单独开成一个 Mac 窗口，不影响手机屏幕")
            }
            Button {
                DeviceLogWindows.show(device)
            } label: {
                Label("日志", systemImage: "list.bullet.rectangle.portrait")
            }
            .help("查看这台设备的实时日志")
        }
        .controlSize(.large)
        .disabled(!device.connected)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if mirrorState == .live {
                Chip(text: "投屏中", symbol: "dot.radiowaves.left.and.right", tint: Theme.accent)
            }
            Chip(text: device.connectionSummary,
                 symbol: device.connected ? "checkmark.circle.fill" : "circle.dashed",
                 tint: device.connected ? Theme.online : nil)
            if let level = info.value("电量", for: device.id) {
                Chip(text: level, symbol: batterySymbol(level),
                     tint: info.value("状态", for: device.id) == "正在充电" ? Theme.online : nil)
            }
        }
    }

    private func batterySymbol(_ level: String) -> String {
        if info.value("状态", for: device.id) == "正在充电" { return "battery.100.bolt" }
        let value = Int(level.filter(\.isNumber)) ?? 100
        switch value {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    @ViewBuilder
    private var mirrorControl: some View {
        switch mirrorState {
        case .starting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在启动投屏…").font(.callout).foregroundStyle(.secondary)
                Button("取消") { stopMirror() }
                    .controlSize(.large)
            }
            .transition(.opacity)
        case .live:
            Button {
                stopMirror()
            } label: {
                Label("结束投屏", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .tint(theme.isAppleNative ? Theme.recording : nil)
            .help("关闭这台设备的投屏窗口")
            .transition(.opacity)
        case .idle:
            Button {
                if device.isApple {
                    iosMirror.start(device: device)
                } else {
                    mirror.start(device: device, options: mirrorOptions)
                }
            } label: {
                Label(theme.isAppleNative ? "开始投屏" : "投屏", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(!device.connected)
            .keyboardShortcut(.defaultAction)
            .help(device.isApple ? "在 Mac 上显示这台设备的画面和声音（↩）" :
                    "在 Mac 上显示并操作这台设备（↩）")
            .transition(.opacity)
        }
    }

    private func stopMirror() {
        if device.isApple { iosMirror.stop(deviceID: device.id) } else { mirror.stop(deviceID: device.id) }
    }

    // MARK: Connections & Apple Native Telemetry

    @ViewBuilder
    private var nativeTelemetryStrip: some View {
        if let storage = storageOverview {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    nativeStorageCard(storage)
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    nativeConnectionsCard
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    nativeStorageCard(storage)
                    nativeConnectionsCard
                }
            }
        } else {
            nativeConnectionsCard
        }
    }

    private func nativeStorageCard(_ storage: StorageOverview) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(storage.raw, forType: .string)
            withAnimation(Theme.quick) { storageCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(Theme.quick) { storageCopied = false }
            }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("存储空间")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if storageCopied {
                        Label("已复制", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.online)
                    } else {
                        Text(storage.summaryText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(storage.fraction > 0.9 ? Theme.recording : Theme.accent)
                            .frame(width: max(6, geo.size.width * storage.fraction))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(storage.remainingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((storage.fraction * 100).rounded()))% 已使用")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 5, y: 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(storage.raw)\n点按复制")
    }

    private var nativeConnectionsCard: some View {
        let preferredEndpoint = MirrorStore.preferredTransports(for: device).first?.endpoint
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("连接通道")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if device.transports.count > 1 {
                    Text("USB 在线时自动优先")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(spacing: 6) {
                ForEach(device.transports, id: \.endpoint) { transport in
                    let isPreferred = transport.state == "已连接" && transport.endpoint == preferredEndpoint
                    HStack(spacing: 9) {
                        Circle()
                            .fill(transport.state != "已连接" ? Color.secondary.opacity(0.45) :
                                  isPreferred ? Theme.online : Theme.accent)
                            .frame(width: 7, height: 7)
                        Text(transport.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(transport.endpoint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        if transport.state == "已连接" {
                            Text(isPreferred ? "当前优先" : "热备")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(isPreferred ? Theme.online : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill((isPreferred ? Theme.online : Color.secondary).opacity(0.11))
                                )
                        } else {
                            Text(transport.state)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.subtleFill)
                    )
                }
                if device.emulator {
                    Text("同一模拟器的多个 ADB 端口已合并显示。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 5, y: 1.5)
    }

    private var connections: some View {
        Card(title: "连接") {
            ForEach(Array(device.transports.enumerated()), id: \.element.endpoint) { index, transport in
                if index > 0 { CardDivider(inset: 56) }
                transportRow(transport)
            }
            if device.emulator {
                CardDivider(inset: 14)
                Text("同一模拟器的多个 ADB 端口已合并显示。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
    }

    private func transportRow(_ transport: ADBTransport) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: transport.type == "USB" ? "cable.connector" :
                        transport.type == "模拟器" ? "macwindow" : "wifi",
                     size: 30, style: .tinted(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(transport.displayName)
                Text(transport.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Device information

    /// The info sections plus the ADB identity when it differs from the serial.
    private var displaySections: [DeviceInfoSection] {
        var sections = info.sections[device.id] ?? []
        if !device.isApple, !sections.isEmpty, info.value("序列号", for: device.id) != device.identity {
            sections.append(DeviceInfoSection(title: "识别",
                                              items: [.init(label: "ADB 标识", value: device.identity)]))
        }
        return sections
    }

    /// Splits sections over two columns so both end at about the same height.
    private func balancedColumns(_ sections: [DeviceInfoSection]) -> [[DeviceInfoSection]] {
        var columns: [[DeviceInfoSection]] = [[], []]
        var heights = [0, 0]
        for section in sections {
            let target = heights[0] <= heights[1] ? 0 : 1
            columns[target].append(section)
            heights[target] += section.items.count + 2
        }
        return columns
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(theme.isAppleNative ? "硬件与系统规格" : "设备信息")
                    .font(.headline)
                if theme.isAppleNative {
                    Text("点按任意行复制")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if info.fullLoading.contains(device.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        info.load(device, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新读取全部设备信息")
                    .disabled(!device.connected)
                }
            }
            let sections = displaySections
            if sections.isEmpty {
                Card {
                    HStack(spacing: 8) {
                        if info.errors[device.id] == nil { ProgressView().controlSize(.small) }
                        Text(info.errors[device.id] ?? "正在读取设备信息…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                let columns = balancedColumns(sections)
                // Two columns when the window is wide enough keep the list short.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<2, id: \.self) { index in
                            infoColumn(columns[index])
                                .frame(minWidth: 270, maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    infoColumn(sections)
                }
            }
        }
    }

    private func infoColumn(_ sections: [DeviceInfoSection]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                Card(title: section.title) {
                    ForEach(Array(section.items.enumerated()), id: \.element.label) { index, item in
                        if index > 0 { CardDivider() }
                        InfoRow(item: item)
                    }
                }
            }
        }
    }
}

/// Label on the left, value on the right; long technical strings stay on one
/// line. Clicking the row copies the value; "已复制" shows in its place.
struct InfoRow: View {
    let item: DeviceInfoSection.Item
    @ObservedObject private var theme = ThemeStore.shared
    @State private var hovering = false
    @State private var copied = false
    @State private var resetTask: DispatchWorkItem?

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        value
                        if theme.isAppleNative {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .opacity(hovering ? 1 : 0)
                        }
                    }
                    .opacity(copied ? 0 : 1)
                    if copied {
                        Label("已复制", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.online)
                            .fontWeight(.medium)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? (theme.isAppleNative ? 0.035 : 0.05) : 0))
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if !theme.isAppleNative {
                // set(), not push()/pop(): a row removed while hovered never gets
                // its exit call, and an unbalanced push left the hand everywhere.
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .help(item.value.contains("\n") ? "点按复制" : "\(item.value)\n点按复制")
        .animation(Theme.quick, value: copied)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var value: some View {
        if item.value.contains("\n") {
            Text(item.value).multilineTextAlignment(.trailing)
        } else {
            Text(item.value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.value, forType: .string)
        copied = true
        resetTask?.cancel()
        let task = DispatchWorkItem { copied = false }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: task)
    }
}

struct MirrorSettingsView: View {
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("mirror.audio") private var audioEnabled = true
    @AppStorage("mirror.maxSize") private var maxSize = 1920
    @AppStorage("mirror.maxFPS") private var maxFPS = 60
    @AppStorage("mirror.videoBitrateMbps") private var videoBitrateMbps = 8
    @AppStorage("mirror.audioBitrateKbps") private var audioBitrateKbps = 128
    @AppStorage("mirror.videoCodec") private var videoCodec = "h265"
    @AppStorage(DeviceActions.directoryKey) private var saveDirectory = ""
    @AppStorage(MirrorStore.revealInFinderKey) private var revealInFinder = false
    @AppStorage(MirrorStore.copyToClipboardKey) private var copyToClipboard = true
    @AppStorage(RecordingSettings.qualityKey) private var recordQuality = "standard"
    @AppStorage(RecordingSettings.formatKey) private var recordFormat = "mp4"
    @AppStorage(RecordingSettings.audioKey) private var recordAudio = true
    @AppStorage(RecordingSettings.gifQualityKey) private var gifQuality = "standard"
    @AppStorage(RecordingSettings.animatedFormatKey) private var animatedFormat = "webp"
    @AppStorage(DeviceStore.subnetScanKey) private var subnetScan = false

    private var saveURL: URL { DeviceActions.saveDirectoryURL(saveDirectory) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveURL
        panel.prompt = "选取"
        panel.message = "截图、录屏和动图将保存到这个文件夹"
        panel.begin { response in
            if response == .OK, let url = panel.url { saveDirectory = url.path }
        }
    }

    var body: some View {
        TabView {
            Form {
                Section("视频") {
                    Picker("清晰度上限", selection: $maxSize) {
                        Text("1280 像素").tag(1280)
                        Text("1600 像素").tag(1600)
                        Text("1920 像素（推荐）").tag(1920)
                        Text("2560 像素").tag(2560)
                        Text("设备原始分辨率").tag(0)
                    }
                    if theme.isAppleNative {
                        Picker("最高帧率", selection: $maxFPS) {
                            ForEach([30, 45, 60, 90, 120], id: \.self) { value in
                                Text("\(value)").tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("最高帧率", selection: $maxFPS) {
                            ForEach([30, 45, 60, 90, 120], id: \.self) { value in
                                Text("\(value) FPS").tag(value)
                            }
                        }
                    }
                    Picker("视频码率", selection: $videoBitrateMbps) {
                        ForEach([4, 8, 12, 20, 32], id: \.self) { value in
                            Text("\(value) Mbps").tag(value)
                        }
                    }
                    Picker("视频编码", selection: $videoCodec) {
                        Text("H.264（兼容性最好）").tag("h264")
                        Text("H.265（设备支持时）").tag("h265")
                    }
                }
                Section {
                    Toggle("播放设备声音", isOn: $audioEnabled)
                    Picker("音频码率", selection: $audioBitrateKbps) {
                        ForEach([96, 128, 192, 256], id: \.self) { value in
                            Text("\(value) Kbps").tag(value)
                        }
                    }
                    .disabled(!audioEnabled)
                } header: {
                    Text("音频")
                }
                Section {
                    Toggle("定时刷新设备", isOn: $subnetScan)
                } header: {
                    Text("发现设备")
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 452)
            .tabItem { Label("投屏", systemImage: "display") }

            Form {
                Section {
                    LabeledContent("保存位置") {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: saveURL.path))
                                .resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: saveURL.path))
                                .lineLimit(1).truncationMode(.middle)
                                .help(saveURL.path)
                            Button("更改…", action: chooseFolder)
                        }
                    }
                    Toggle("保存后在访达中显示", isOn: $revealInFinder)
                    Toggle("保存后复制到剪贴板", isOn: $copyToClipboard)
                } header: {
                    Text("截图与录屏")
                }
                Section("录屏") {
                    Picker("画质", selection: $recordQuality) {
                        Text("高（原始分辨率 · 16 Mbps · 60 帧）").tag("high")
                        Text("标准（1920 像素 · 8 Mbps · 60 帧）").tag("standard")
                        Text("节省空间（1280 像素 · 4 Mbps · 30 帧）").tag("compact")
                        Text("与投屏设置一致").tag("mirror")
                    }
                    Picker("格式", selection: $recordFormat) {
                        Text("MP4（推荐，可直接播放）").tag("mp4")
                        Text("MKV（录制意外中断时文件仍可用）").tag("mkv")
                    }
                    Toggle("录制设备声音", isOn: $recordAudio)
                }
                Section {
                    if theme.isAppleNative {
                        Picker("格式", selection: $animatedFormat) {
                            Text("WebP（体积更小）").tag("webp")
                            Text("GIF（兼容通用）").tag("gif")
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Picker("格式", selection: $animatedFormat) {
                            Text("GIF（兼容性最好）").tag("gif")
                            Text("WebP（体积约为 GIF 的 1/3，画质更好）").tag("webp")
                        }
                    }
                    Picker("画质", selection: $gifQuality) {
                        Text("高（最长边 1280 像素 · 15 帧/秒）").tag("high")
                        Text("标准（最长边 960 像素 · 12 帧/秒）").tag("standard")
                        Text("小巧（最长边 640 像素 · 10 帧/秒）").tag("small")
                    }
                } header: {
                    Text("动图")
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 510)
            .tabItem { Label("录制", systemImage: "record.circle") }

            Form {
                Section {
                    HStack(spacing: 12) {
                        ForEach(AppThemeStyle.allCases) { option in
                            ThemeStyleOptionCard(
                                option: option,
                                selected: theme.style == option
                            ) {
                                withAnimation(Theme.quick) {
                                    theme.style = option
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("界面主题")
                } footer: {
                    Text("切换后将实时热更新主窗口、应用面板、日志窗口与已打开的投屏窗口配色，无需重启应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("深浅外观") {
                    Picker("外观模式", selection: $theme.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            .tabItem { Label("外观", systemImage: "paintbrush") }
        }
        .tint(Theme.accent)
        .frame(width: 540)
    }
}

private struct ThemeStyleOptionCard: View {
    let option: AppThemeStyle
    let selected: Bool
    let action: () -> Void

    private var optionAccent: Color {
        option == .appleNative ? Color(nsColor: .systemBlue) : Color(nsColor: .systemIndigo)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                // Visual miniature preview of the theme's signature header & palette
                HStack(spacing: 10) {
                    if option == .classic {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(nsColor: .systemIndigo), Color(nsColor: .systemPurple)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "smartphone")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                            )
                    } else {
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(Color(nsColor: .systemBlue).opacity(0.10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.65), lineWidth: 1.3)
                                )
                            Capsule()
                                .fill(Color.primary.opacity(0.75))
                                .frame(width: 6, height: 1.5)
                                .padding(.top, 3)
                        }
                        .frame(width: 19, height: 30)
                        .padding(.horizontal, 5.5)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 72, height: 6)
                        HStack(spacing: 4) {
                            Capsule()
                                .fill(Color(nsColor: .systemGreen).opacity(0.22))
                                .frame(width: 32, height: 6)
                            Capsule()
                                .fill(optionAccent.opacity(0.22))
                                .frame(width: 26, height: 6)
                        }
                    }
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(optionAccent)
                        .frame(width: 28, height: 14)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? optionAccent : .secondary)
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(option.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? optionAccent.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        selected ? optionAccent : Color(nsColor: .separatorColor).opacity(0.6),
                        lineWidth: selected ? 1.6 : 0.7
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IssueDetail: View {
    let issue: IssueItem
    let connect: (String) -> Void
    let pair: (String) -> Void
    let forget: (String) -> Void
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let _ = theme.style
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    IconTile(symbol: issue.symbol, size: 64, style: .tinted(issue.tint))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Chip(text: issue.source, tint: issue.tint)
                    }
                }
                Card(title: "原因") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(issue.summary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !issue.detail.isEmpty {
                            Text(issue.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let endpoint = issue.endpoint {
                    HStack(spacing: 10) {
                        if issue.id.hasPrefix("pair:") {
                            Button("输入配对码") { pair(endpoint) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("重新连接") { connect(endpoint) }
                                .buttonStyle(.borderedProminent)
                        }
                        if issue.id.hasPrefix("port:") {
                            Button("忽略此地址") { forget(endpoint) }
                                .help("不再自动连接这个地址；设备重新出现时仍会被发现")
                        }
                    }
                    .controlSize(.large)
                    .tint(Theme.accent)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

enum ActionSheet: String {
    case connect
    case pair
}

/// The sheet and the address it was opened for travel together, so the
/// address is never read from stale view state.
struct ActionRequest: Identifiable {
    let mode: ActionSheet
    let endpoint: String
    var id: String { mode.rawValue + "|" + endpoint }
}

struct ActionSheetView: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeStore.shared
    let mode: ActionSheet
    let suggestedEndpoint: String
    @State private var endpoint = ""
    @State private var code = ""
    @State private var message = ""

    private var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode == .connect ? "手动连接设备" : "无线调试配对")
                .font(.title3.weight(.semibold))
            Text(mode == .connect ?
                 "输入设备当前的无线 ADB 地址和端口。" :
                 "在设备的“无线调试”中选择“使用配对码配对设备”，输入页面显示的配对地址与 6 位代码。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("IP:端口", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if mode == .pair {
                TextField("6 位配对码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if store.actionQueued || store.actionBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(store.actionQueued ? "正在等待当前扫描结束…" :
                         (mode == .connect ? "正在连接…" : "正在配对…"))
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") {
                    store.cancelQueuedAction()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(mode == .connect ? "连接" : "配对") {
                    store.perform(mode.rawValue, endpoint: trimmedEndpoint,
                                  code: trimmedCode) { ok, text in
                        if ok { dismiss() } else { message = text }
                        code = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.actionBusy || store.actionQueued || trimmedEndpoint.isEmpty ||
                          (mode == .pair && trimmedCode.count != 6))
            }
        }
        .onChange(of: endpoint) { message = "" }
        .onChange(of: code) { if !code.isEmpty { message = "" } }
        .padding(25)
        .frame(width: 430, height: mode == .pair ? 275 : 240)
        .onAppear { endpoint = suggestedEndpoint }
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @StateObject private var store = DeviceStore()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var activeSheet: ActionRequest?
    /// The sidebar stays closed until the first scan has a result, then
    /// slides open, so launch shows one calm loading state instead of an
    /// empty column.
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @FocusState private var sidebarFocused: Bool

    private var selectedDevice: ADBDevice? {
        store.report?.devices.first { "device:" + $0.identity == store.selectedID }
    }
    private var selectedIssue: IssueItem? {
        store.report?.issues.first { $0.id == store.selectedID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Rows draw their own selection; List's native highlight would sit
            // underneath as a second, differently coloured layer.
            ScrollViewReader { proxy in
                List {
                    if let report = store.report, !report.devices.isEmpty {
                        Section {
                            ForEach(report.devices) { device in
                                let id = "device:" + device.identity
                                DeviceSidebarRow(device: device, selected: store.selectedID == id)
                                    .id(id)
                                    .onTapGesture {
                                        store.selectedID = id
                                        sidebarFocused = true
                                    }
                                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            SidebarHeader(title: theme.isAppleNative ? "已连接设备" : "设备",
                                          count: report.devices.count,
                                          searching: !store.initialSweepDone)
                        }
                    }
                    if let issues = store.report?.issues, !issues.isEmpty {
                        Section {
                            ForEach(issues) { issue in
                                IssueSidebarRow(issue: issue, selected: store.selectedID == issue.id)
                                    .id(issue.id)
                                    .onTapGesture {
                                        store.selectedID = issue.id
                                        sidebarFocused = true
                                    }
                                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            SidebarHeader(title: "需要处理", count: issues.count)
                        }
                    }
                }
                .listStyle(.sidebar)
                .focusable()
                .focused($sidebarFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(-1, proxy: proxy) }
                .animation(Theme.quick, value: store.report?.devices.map(\.identity) ?? [])
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            ZStack {
                if let device = selectedDevice {
                    DeviceDetail(device: device)
                        .id("device:" + device.identity)
                        .transition(.opacity)
                } else if let issue = selectedIssue {
                    IssueDetail(issue: issue,
                                connect: { activeSheet = ActionRequest(mode: .connect, endpoint: $0) },
                                pair: { activeSheet = ActionRequest(mode: .pair, endpoint: $0) },
                                forget: { store.forget(endpoint: $0) })
                        .id(issue.id)
                        .transition(.opacity)
                } else if let report = store.report,
                          report.devices.isEmpty && report.issues.isEmpty {
                    ContentUnavailableView {
                        Label("没有发现设备", systemImage: "smartphone")
                    } description: {
                        Text("用 USB 连接设备，或让设备与 Mac 处于同一局域网并打开无线调试。设备出现后会自动显示。")
                    }
                } else if store.report == nil, let error = store.error, !store.scanning {
                    ContentUnavailableView {
                        Label("扫描失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重新扫描") { store.scan(full: false) }
                            .buttonStyle(.borderedProminent)
                    }
                } else if store.report == nil {
                    // The only progress shown before the first result.
                    VStack(spacing: 16) {
                        IconTile(symbol: "dot.radiowaves.left.and.right", size: 64, style: .gradient)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        Text("正在发现设备…").font(.title3.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择一台设备", systemImage: "smartphone",
                                           description: Text("设备的连接、状态和详细信息会显示在这里。"))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: store.selectedID)
            .navigationTitle("幕台")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { openSettings() } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .help("设置（⌘,）")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.report != nil || store.error != nil {
                    statusBar
                }
            }
        }
        .tint(Theme.accent)
        .frame(minWidth: 720, minHeight: 500)
        .onChange(of: store.report != nil) { _, ready in
            guard ready, columns == .detailOnly else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { columns = .all }
        }
        .sheet(item: $activeSheet) { request in
            ActionSheetView(mode: request.mode, suggestedEndpoint: request.endpoint)
                .environmentObject(store)
        }
    }

    /// Arrow keys move through devices and issues, as in a native list.
    private func moveSelection(_ offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let report = store.report else { return .ignored }
        let ids = report.devices.map { "device:" + $0.identity } + report.issues.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = store.selectedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let nextID = ids[max(0, min(ids.count - 1, current + offset))]
        store.selectedID = nextID
        withAnimation(Theme.quick) {
            proxy.scrollTo(nextID)
        }
        return .handled
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if store.scanning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: store.error == nil ? "checkmark.circle.fill" :
                                                       "exclamationmark.triangle.fill")
                    .foregroundStyle(store.error == nil ? Theme.online : Theme.attention)
            }
            Text(store.error ?? store.phase)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer()
            Button {
                store.scanNetwork()
            } label: {
                Label("刷新设备", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.scanningNetwork)
            .help("重新查找设备，包括局域网中开启了无线 ADB、但没有广播也没有连接过的设备（会探测本网段各地址的 ADB 端口）")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(Theme.quick, value: store.scanning)
    }
}

@main
struct LANADBManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            MirrorSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()
        // iPhones then appear as capture devices by the time one is mirrored.
        IOSMirrorStore.enableScreenCaptureDevices()
        DispatchQueue.global(qos: .utility).async { DeviceActions.removeTemporaryFiles() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MirrorStore.shared.stopAll()
        IOSMirrorStore.shared.stopAll()
        AppWindowStore.shared.closeAll()
        DiscoveryMonitor.stopAll()
    }

    /// Closing the main window quits only when nothing else is going on:
    /// Android mirrors run in their own processes (not windows of this app),
    /// and a capture may still be saving. Otherwise the app keeps running and
    /// quits once the last of them ends with no window left open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if Self.busy {
            NSLog("幕台：主窗口已关闭，仍有投屏或录制，继续运行")
            watchUntilIdle()
            return false
        }
        return true
    }

    private static var busy: Bool {
        MirrorStore.shared.hasActiveWork || IOSMirrorStore.shared.hasActiveWork
            || AppWindowStore.shared.hasActiveWork
    }

    private var idleTimer: Timer?

    private func watchUntilIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            // The main window reopened (Dock icon): nothing to do.
            if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                timer.invalidate()
                self?.idleTimer = nil
                return
            }
            guard !Self.busy else { return }
            NSLog("幕台：主窗口已关闭，投屏与录制都已结束，退出")
            timer.invalidate()
            self?.idleTimer = nil
            NSApp.terminate(nil)
        }
    }
}
