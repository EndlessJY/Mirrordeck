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

    var id: String { identity }
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
    var symbol: String { emulator ? "macwindow" : tv == true ? "tv" : "smartphone" }
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
            IssueItem(id: "usb:" + $0.serial, title: $0.serial,
                      summary: $0.state == "unauthorized" ? "请在设备上允许 USB 调试" :
                               $0.state == "no_lan_ip" ? "设备没有同网段的 Wi-Fi 地址" :
                               $0.state == "tcpip_unreachable" ?
                                   "已尝试开启无线 ADB，但 5555 端口不可达；检查路由器 AP 隔离或防火墙" :
                               $0.state == "offline" ? "设备离线，请解锁或启动模拟器" : $0.state,
                      detail: "", source: $0.kind ?? "USB", endpoint: nil)
        }
        let pairItems = pairing.map {
            IssueItem(id: "pair:" + $0.endpoint, title: $0.endpoint,
                      summary: "等待设备显示的 6 位配对码", detail: "",
                      source: "无线调试配对", endpoint: $0.endpoint)
        }
        return failedItems + usbItems + pairItems
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
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let request = try JSONSerialization.data(withJSONObject: payload)
                input.fileHandleForWriting.write(request)
                input.fileHandleForWriting.closeFile()

                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = String(data: bytes, encoding: .utf8)?.split(separator: "\n") ?? []
                guard let last = lines.last,
                      let data = String(last).data(using: .utf8),
                      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WorkerError.failed("设备扫描没有返回结果")
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
    private var stopped = false
    private var lastPathSignature: String?
    private static let instances = NSHashTable<DiscoveryMonitor>.weakObjects()

    /// Stops every monitor so `adb track-devices` does not outlive the app.
    static func stopAll() {
        instances.allObjects.forEach { $0.stop() }
    }

    func start() {
        Self.instances.add(self)
        Self.killOrphanTrackers()
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
        ps.arguments = ["-axo", "pid=,ppid=,command="]
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
        if report == nil { phase = "正在发现设备…" }
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
                if needsImmediateRecovery { self.pendingScan = self.autoSubnet }
                action()
            } else if let pending = self.pendingScan {
                self.pendingScan = nil
                let delay: TimeInterval = needsImmediateRecovery ? 0.25 :
                    (self.initialSweepPending && pending ? 3 : 0.45)
                self.initialSweepPending = false
                self.requestScan(full: pending || (needsImmediateRecovery && self.autoSubnet),
                                 delay: delay)
            } else if needsImmediateRecovery {
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
            switch response {
            case .success(let value):
                let result = value["result"] as? [String: Any] ?? [:]
                let ok = result["ok"] as? Bool ?? false
                let message = result["reason"] as? String ??
                              result["message"] as? String ?? "操作未完成"
                completion(ok, message)
                if ok || pending != nil {
                    self.requestScan(full: pending ?? false)
                } else {
                    self.scheduleFallback()
                }
            case .failure(let failure):
                completion(false, failure.localizedDescription)
                if let pending {
                    self.requestScan(full: pending)
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
    @State private var hovering = false

    private var active: Bool { activeState == .key || activeState == .active }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? (active ? Theme.accent : Color.primary.opacity(0.11)) :
                      hovering ? Color.primary.opacity(0.05) : Color.clear))
            .environment(\.sidebarRowHighlighted, selected && active)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: selected)
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
    @Environment(\.sidebarRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, size: 30,
                     style: highlighted ? .plain : .tinted(tint))
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

    var body: some View {
        let live = mirror.sessions[device.id] != nil
        SidebarRowContent(symbol: device.symbol, tint: Theme.accent,
                          title: device.title,
                          subtitle: live ? "投屏中 · " + device.connectionSummary :
                                           device.connectionSummary,
                          status: !device.connected ? .gray : live ? Theme.accent : Theme.online,
                          pulsing: live)
            .modifier(SidebarSelection(selected: selected))
    }
}

struct IssueSidebarRow: View {
    let issue: IssueItem
    let selected: Bool

    var body: some View {
        SidebarRowContent(symbol: issue.symbol, tint: issue.tint,
                          title: issue.title, subtitle: issue.summary)
            .modifier(SidebarSelection(selected: selected))
    }
}

/// Sidebar section title with a count.
struct SidebarHeader: View {
    let title: String
    let count: Int
    var searching = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
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
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
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
        Worker.run("info", payload: ["serial": serial, "scope": scope]) { [weak self] result in
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
                    self.fullAt[id] = Date()
                } else {
                    self.sections[id] = Self.merge(self.sections[id] ?? [], with: fresh)
                }
                self.dynamicAt[id] = Date()
                self.errors[id] = nil
                self.persist()
            case .failure(let failure):
                self.errors[id] = failure.localizedDescription
            }
        }
    }

    private static func merge(_ cached: [DeviceInfoSection],
                              with fresh: [DeviceInfoSection]) -> [DeviceInfoSection] {
        var result = cached
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

struct DeviceDetail: View {
    let device: ADBDevice
    @ObservedObject private var mirror = MirrorStore.shared
    @ObservedObject private var info = DeviceInfoStore.shared
    @ObservedObject private var appWindows = AppWindowStore.shared
    @State private var pickingApp = false
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
        if mirror.starting.contains(device.id) { return .starting }
        guard let session = mirror.sessions[device.id] else { return .idle }
        return session.ready ? .live : .starting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if let error = mirror.errors[device.id] {
                    Banner(text: error)
                } else if let error = appWindows.errors[device.id], !pickingApp {
                    Banner(text: error)
                } else if let message = mirror.messages[device.id] {
                    Banner(text: message, symbol: "record.circle", tint: Theme.recording)
                }
                connections
                infoSection
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(Theme.quick, value: mirrorState)
        }
        // A different device starts at the top instead of the old scroll offset.
        .id(device.identity)
        .task(id: device.identity) { info.load(device) }
    }

    // MARK: Header

    private var header: some View {
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
        .sheet(isPresented: $pickingApp) {
            AppPickerView(device: device, options: mirrorOptions)
        }
    }

    /// Secondary tools beside the main mirror action.
    private var tools: some View {
        HStack(spacing: 8) {
            Button {
                appWindows.errors[device.id] = nil
                pickingApp = true
            } label: {
                Label("应用", systemImage: "macwindow.on.rectangle")
            }
            .help("把手机上的某个应用单独开成一个 Mac 窗口，不影响手机屏幕")
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
                Button("取消") { mirror.stop(deviceID: device.id) }
                    .controlSize(.large)
            }
            .transition(.opacity)
        case .live:
            Button {
                mirror.stop(deviceID: device.id)
            } label: {
                Label("结束投屏", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .help("关闭这台设备的投屏窗口")
            .transition(.opacity)
        case .idle:
            Button {
                mirror.start(device: device, options: mirrorOptions)
            } label: {
                Label("投屏", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(!device.connected)
            .keyboardShortcut(.defaultAction)
            .help("在 Mac 上显示并操作这台设备（↩）")
            .transition(.opacity)
        }
    }

    // MARK: Connections

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
        if !sections.isEmpty, info.value("序列号", for: device.id) != device.identity {
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
                Text("设备信息").font(.headline)
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
    @State private var hovering = false
    @State private var copied = false
    @State private var resetTask: DispatchWorkItem?

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.label).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    value.opacity(copied ? 0 : 1)
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
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
                    Picker("最高帧率", selection: $maxFPS) {
                        ForEach([30, 45, 60, 90, 120], id: \.self) { value in
                            Text("\(value) FPS").tag(value)
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
            .frame(height: 452)
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
                    Picker("格式", selection: $animatedFormat) {
                        Text("GIF（兼容性最好）").tag("gif")
                        Text("WebP（体积约为 GIF 的 1/3，画质更好）").tag("webp")
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
            .frame(height: 510)
            .tabItem { Label("录制", systemImage: "record.circle") }
        }
        .frame(width: 540)
    }
}

struct IssueDetail: View {
    let issue: IssueItem
    let connect: (String) -> Void
    let pair: (String) -> Void
    let forget: (String) -> Void

    var body: some View {
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
    let mode: ActionSheet
    let suggestedEndpoint: String
    @State private var endpoint = ""
    @State private var code = ""
    @State private var message = ""

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
                    store.perform(mode.rawValue, endpoint: endpoint.trimmingCharacters(in: .whitespaces),
                                  code: code.trimmingCharacters(in: .whitespaces)) { ok, text in
                        if ok { dismiss() } else { message = text }
                        code = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.actionBusy || store.actionQueued || endpoint.isEmpty ||
                          (mode == .pair && code.count != 6))
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
    @State private var activeSheet: ActionRequest?

    private var selectedDevice: ADBDevice? {
        store.report?.devices.first { "device:" + $0.identity == store.selectedID }
    }
    private var selectedIssue: IssueItem? {
        store.report?.issues.first { $0.id == store.selectedID }
    }

    var body: some View {
        NavigationSplitView {
            // Rows draw their own selection; List's native highlight would sit
            // underneath as a second, differently coloured layer.
            List {
                if let report = store.report, !report.devices.isEmpty {
                    Section {
                        ForEach(report.devices) { device in
                            let id = "device:" + device.identity
                            DeviceSidebarRow(device: device, selected: store.selectedID == id)
                                .onTapGesture { store.selectedID = id }
                                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        SidebarHeader(title: "设备", count: report.devices.count,
                                      searching: !store.initialSweepDone)
                    }
                }
                if let issues = store.report?.issues, !issues.isEmpty {
                    Section {
                        ForEach(issues) { issue in
                            IssueSidebarRow(issue: issue, selected: store.selectedID == issue.id)
                                .onTapGesture { store.selectedID = issue.id }
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
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(1) }
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .animation(Theme.quick, value: store.report?.devices.map(\.identity) ?? [])
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
        .sheet(item: $activeSheet) { request in
            ActionSheetView(mode: request.mode, suggestedEndpoint: request.endpoint)
                .environmentObject(store)
        }
    }

    /// Arrow keys move through devices and issues, as in a native list.
    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        guard let report = store.report else { return .ignored }
        let ids = report.devices.map { "device:" + $0.identity } + report.issues.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = store.selectedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        store.selectedID = ids[max(0, min(ids.count - 1, current + offset))]
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
        DispatchQueue.global(qos: .utility).async { DeviceActions.removeTemporaryFiles() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MirrorStore.shared.stopAll()
        AppWindowStore.shared.closeAll()
        DiscoveryMonitor.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
