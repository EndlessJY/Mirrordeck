import Foundation
import SwiftUI

/// Battery, CPU and memory of one Android device, read live while its page
/// is shown. One `adb shell` loop runs on the phone and prints a sample every
/// two seconds (battery every ten: `dumpsys` costs more than reading /proc),
/// so nothing new is started per sample.
final class DeviceLiveStats: ObservableObject {
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var temperature: Double?
    /// 0...1, busy share of all cores since the previous sample.
    @Published private(set) var cpu: Double?
    @Published private(set) var memoryUsed: Double?
    @Published private(set) var memoryTotalKB: Int?
    @Published private(set) var memoryAvailableKB: Int?
    /// Hottest CPU sensor, °C (nil where the sensors can't be read).
    @Published private(set) var cpuTemperature: Double?
    /// Wi-Fi signal (dBm) and link speed (Mbps); `wifiKnown` with no signal
    /// means the phone is not on Wi-Fi.
    @Published private(set) var wifiRSSI: Int?
    @Published private(set) var wifiSpeed: Int?
    @Published private(set) var wifiKnown = false
    @Published private(set) var wifiName: String?
    enum Link: Equatable { case wifi, mobile, ethernet, none }
    /// How the phone reaches the internet now.
    @Published private(set) var link: Link?
    /// Mobile network: carrier ("中国移动"), generation ("5G"), bars 0...4.
    @Published private(set) var carrier: String?
    @Published private(set) var cellGeneration: String?
    @Published private(set) var cellLevel: Int?
    /// Wi-Fi generation: 4 (11n), 5 (11ac), 6 (11ax), 7 (11be).
    @Published private(set) var wifiGeneration: Int?
    /// Bytes a second over all network interfaces but loopback.
    @Published private(set) var download: Double?
    @Published private(set) var upload: Double?
    enum Front: Equatable {
        case app(String)   // package
        case home
        case locked
        case asleep
    }
    /// What is in front on the phone.
    @Published private(set) var front: Front?
    private var homePackage = ""

    private var process: Process?
    private var buffer = ""
    private var lastCPU: (busy: Double, total: Double)?
    private var lastNet: (rx: Double, tx: Double, at: Date)?
    private var sample: [String] = []

    // A first CPU and network reading half a second in, then one every two
    // seconds; the app in front every four, the battery every ten.
    private static let script = """
    net() { sed 's/:/ /' /proc/net/dev | grep -vE '^ *(Inter|face|lo )' | sed 's/^ */net /'; }; \
    echo "home $(cmd package resolve-activity --brief -a android.intent.action.MAIN \
      -c android.intent.category.HOME | tail -1 | cut -d/ -f1)"; \
    head -1 /proc/stat; net; echo @@; sleep 0.5; \
    i=0; while true; do head -1 /proc/stat; net; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; \
    for z in /sys/class/thermal/thermal_zone*; do read t < $z/type 2>/dev/null; \
      case "$t" in cpu*) read v < $z/temp 2>/dev/null && echo "cputemp $v";; esac; done; \
    if [ $((i % 2)) -eq 0 ]; then echo top; dumpsys power | grep -m1 mWakefulness=; \
      dumpsys activity activities | grep -E 'topResumedActivity|mKeyguardShowing=' | head -2; fi; \
    if [ $((i % 5)) -eq 0 ]; then \
      n=$(dumpsys connectivity | grep -m1 'Active default network' | sed 's/[^0-9]//g'); t=NONE; \
      [ -n "$n" ] && t=$(dumpsys connectivity | grep -m1 "network{$n}" | sed -E 's/.*ni\\{([A-Z]+).*/\\1/'); \
      echo "transport $t"; \
      if [ "$t" = WIFI ]; then echo wifi; dumpsys wifi | grep -m1 mWifiInfo | tr ',' '\\n' \
        | grep -E '(^|[^B])SSID: |^ (RSSI|Link speed|Wi-Fi standard):'; fi; \
      if [ "$t" = MOBILE ]; then echo "carrier $(getprop gsm.operator.alpha)"; \
        echo "rat $(getprop gsm.network.type)"; \
        dumpsys telephony.registry | grep -m2 -E 'mSignalStrength=|mTelephonyDisplayInfo=TelephonyDisplayInfo' \
        | sed -E 's/.*TelephonyDisplayInfo \\{network=([A-Z_]+), overrideNetwork=([A-Z_]+).*/display \\1 \\2/; s/^ *mSignalStrength=.* level=([0-9]).*/celllevel \\1/'; fi; \
    fi; \
    if [ $((i % 5)) -eq 0 ]; then dumpsys battery | grep -E '^  (level|status|temperature):'; fi; \
    i=$((i + 1)); echo @@; sleep 2; done
    """

    var running: Bool { process?.isRunning == true }

    func start(serial: String) {
        guard !running,
              let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true) else { return }
        let process = Process()
        process.executableURL = tools.appendingPathComponent("adb")
        process.arguments = ["-s", serial, "shell", Self.script]
        var environment = ProcessInfo.processInfo.environment
        for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(text) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    /// Stops reading; the last values stay shown until new ones come.
    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        buffer = ""
        sample = []
        lastCPU = nil
        lastNet = nil
    }

    deinit { stop() }

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            if line == "@@" {
                apply(sample)
                sample = []
            } else if !line.isEmpty {
                sample.append(line)
            }
        }
    }

    private static func carrierName(_ raw: String) -> String {
        let names = ["China Mobile": "中国移动", "CMCC": "中国移动", "China Unicom": "中国联通",
                     "CHN-UNICOM": "中国联通", "China Telecom": "中国电信", "CHN-CT": "中国电信",
                     "China Broadnet": "中国广电", "CBN": "中国广电"]
        return names[raw] ?? raw
    }

    /// The status bar's own mark: 5G-A, 5G+, 5G, 4G+, 4G, 3G, 2G.
    private static func displayGeneration(network: String, override: String) -> String {
        switch override {
        case "NR_ADVANCED": return "5G-A"
        case "NR_NSA_MMWAVE": return "5G+"
        case "NR_NSA": return "5G"
        case "LTE_CA", "LTE_ADVANCED_PRO": return "4G+"
        default:
            return network == "LTE_CA" ? "4G+" : generation(network)
        }
    }

    /// "NR" → 5G, "LTE" → 4G, the 3G and 2G families.
    private static func generation(_ rat: String) -> String {
        let upper = rat.uppercased()
        if upper.contains("NR") { return "5G" }
        if upper.contains("LTE") || upper.contains("IWLAN") { return "4G" }
        if ["HSPA", "UMTS", "WCDMA", "TD_SCDMA", "EVDO", "HSDPA", "HSUPA"].contains(where: upper.contains) { return "3G" }
        return "2G"
    }

    private func apply(_ lines: [String]) {
        var rx = 0.0, tx = 0.0, sawNet = false
        var hottest: Double?
        if lines.contains("wifi") {
            wifiKnown = true
            if !lines.contains(where: { $0.hasPrefix("RSSI:") }) { wifiRSSI = nil; wifiSpeed = nil }
            for line in lines {
                if let range = line.range(of: "SSID: "), !line.contains("BSSID") {
                    let name = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                    wifiName = name.isEmpty || name.contains("unknown ssid") ? nil : name
                } else if line.hasPrefix("Wi-Fi standard:") {
                    let standard = line.dropFirst("Wi-Fi standard:".count).trimmingCharacters(in: .whitespaces)
                    wifiGeneration = ["11n": 4, "11ac": 5, "11ax": 6, "11be": 7][standard]
                }
            }
        }
        if lines.contains("top") {
            // Screen off, then lock screen, then the home screen or an app.
            let awake = lines.contains { $0.hasPrefix("mWakefulness=Awake") }
            let locked = lines.contains("mKeyguardShowing=true")
            let package = lines.first { $0.hasPrefix("topResumedActivity") }
                .flatMap { $0.split(separator: " ").first { $0.contains("/") } }
                .map { String($0.split(separator: "/").first ?? "") }
            front = !awake ? .asleep : locked ? .locked :
                (package == nil || package == homePackage) ? .home : .app(package!)
        }
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first else { continue }
            switch key {
            case "cpu":
                // user nice system idle iowait irq softirq steal
                let values = fields.dropFirst().prefix(8).compactMap { Double($0) }
                guard values.count >= 5 else { continue }
                let total = values.reduce(0, +)
                let busy = total - values[3] - values[4]
                if let last = lastCPU, total > last.total {
                    cpu = min(1, max(0, (busy - last.busy) / (total - last.total)))
                }
                lastCPU = (busy, total)
            case "net":
                // net <interface> rx_bytes ... (8 fields) tx_bytes ...
                let values = fields.dropFirst(2).compactMap { Double($0) }
                if values.count >= 9 {
                    rx += values[0]
                    tx += values[8]
                    sawNet = true
                }
            case "RSSI:":
                if fields.count > 1, let rssi = Int(fields[1]) {
                    // -127 and the like: not connected.
                    wifiRSSI = rssi > -110 && rssi < 0 ? rssi : nil
                }
            case "Link":
                // "Link speed: 2401Mbps"
                if fields.count > 2 { wifiSpeed = Int(fields[2].filter(\.isNumber)) }
            case "cputemp":
                // Millidegrees; a few sensors report nonsense, so keep a sane range.
                if fields.count > 1, let raw = Double(fields[1]) {
                    let celsius = raw > 1000 ? raw / 1000 : raw
                    if celsius > 5 && celsius < 130 { hottest = max(hottest ?? 0, celsius) }
                }
            case "transport":
                let kind = fields.count > 1 ? String(fields[1]) : "NONE"
                link = kind == "WIFI" ? .wifi : kind == "MOBILE" ? .mobile :
                       kind == "ETHERNET" ? .ethernet : Link.none
            case "carrier":
                let raw = line.dropFirst("carrier".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                carrier = raw.map(Self.carrierName)
            case "rat":
                let raw = line.dropFirst("rat".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && $0 != "Unknown" }
                cellGeneration = raw.map(Self.generation)
            case "display":
                // network, overrideNetwork: what the status bar shows.
                if fields.count > 2 {
                    cellGeneration = Self.displayGeneration(network: String(fields[1]), override: String(fields[2]))
                }
            case "celllevel":
                cellLevel = fields.count > 1 ? Int(fields[1]) : nil
            case "home":
                homePackage = fields.count > 1 ? String(fields[1]) : ""
            case "MemTotal:":
                memoryTotalKB = fields.count > 1 ? Int(fields[1]) : nil
            case "MemAvailable:":
                memoryAvailableKB = fields.count > 1 ? Int(fields[1]) : nil
            case "level:":
                battery = fields.count > 1 ? Int(fields[1]) : battery
            case "status:":
                // BatteryManager: 2 charging, 5 full.
                if fields.count > 1, let status = Int(fields[1]) { charging = status == 2 || status == 5 }
            case "temperature:":
                if fields.count > 1, let tenths = Double(fields[1]) { temperature = tenths / 10 }
            default:
                break
            }
        }
        if let hottest { cpuTemperature = hottest }
        if sawNet {
            let now = Date()
            if let last = lastNet {
                let seconds = now.timeIntervalSince(last.at)
                if seconds > 0.2, rx >= last.rx, tx >= last.tx {
                    download = (rx - last.rx) / seconds
                    upload = (tx - last.tx) / seconds
                }
            }
            lastNet = (rx, tx, now)
        }
        if let total = memoryTotalKB, let available = memoryAvailableKB, total > 0 {
            memoryUsed = min(1, max(0, Double(total - available) / Double(total)))
        }
    }
}

/// One reader per device, kept for a minute after its page is left, so
/// switching between devices shows their readings at once.
final class LiveStatsRegistry {
    static let shared = LiveStatsRegistry()
    private var entries: [String: DeviceLiveStats] = [:]
    private var pendingStops: [String: DispatchWorkItem] = [:]

    func stats(for id: String) -> DeviceLiveStats {
        if let stats = entries[id] { return stats }
        let stats = DeviceLiveStats()
        entries[id] = stats
        return stats
    }

    /// The page of this device is shown: read (again) if not reading.
    func acquire(_ device: ADBDevice) {
        pendingStops.removeValue(forKey: device.identity)?.cancel()
        guard device.connected,
              let serial = MirrorStore.preferredTransports(for: device).first?.endpoint else { return }
        stats(for: device.identity).start(serial: serial)
    }

    /// The app is quitting: no reader outlives it.
    func stopAll() {
        pendingStops.values.forEach { $0.cancel() }
        pendingStops.removeAll()
        entries.values.forEach { $0.stop() }
    }

    /// The page was left: stop reading a minute later unless it is back.
    func release(_ id: String, after delay: TimeInterval = 60) {
        pendingStops.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingStops.removeValue(forKey: id)
            self?.entries[id]?.stop()
        }
        pendingStops[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// The live readings on a device's page: four rings, and under each of them
/// one more reading (what is in front, speed, CPU temperature, network), in
/// the same columns. Anything not read yet shows as a skeleton.
struct LiveStatusCard: View {
    let device: ADBDevice
    /// Used share of storage and its caption, from the device information.
    let storage: Double?
    let storageDetail: String?
    @ObservedObject private var stats: DeviceLiveStats
    /// For the names and icons of apps (cached from the app list).
    @ObservedObject private var apps = AppWindowStore.shared

    init(device: ADBDevice, storage: Double? = nil, storageDetail: String? = nil) {
        self.device = device
        self.storage = storage
        self.storageDetail = storageDetail
        stats = LiveStatsRegistry.shared.stats(for: device.identity)
    }

    var body: some View {
        Card(title: "实时状态", prominent: true) {
            VStack(spacing: 0) {
                columns {
                    StatRing(title: "电量", value: stats.battery.map { Double($0) / 100 },
                             color: batteryColor,
                             detail: stats.battery == nil ? nil : (stats.charging ? "充电中" : "放电中"),
                             symbol: stats.charging ? "bolt.fill" : nil)
                    StatRing(title: "CPU", value: stats.cpu, color: Theme.accent,
                             detail: stats.cpu == nil ? nil : "全部核心")
                    StatRing(title: "内存", value: stats.memoryUsed, color: Theme.accentSecondary,
                             detail: stats.memoryAvailableKB.map {
                                 String(format: "可用 %.1f GB", Double($0) / 1_048_576)
                             })
                    StatRing(title: "存储", value: storage,
                             color: (storage ?? 0) > 0.9 ? Theme.recording : Color(nsColor: .systemTeal),
                             detail: storageDetail)
                }
                .padding(.vertical, 16)
                Divider()
                columns {
                    FooterCell(title: "前台", ready: stats.front != nil) { frontValue }
                    FooterCell(title: "网速", ready: stats.download != nil) {
                        Text("↓ \(Self.rate(stats.download ?? 0))  ↑ \(Self.rate(stats.upload ?? 0))")
                    }
                    FooterCell(title: "CPU 温度", ready: stats.cpuTemperature != nil || stats.wifiKnown) {
                        if let cpu = stats.cpuTemperature {
                            Text(String(format: "%.0f°C", cpu))
                                .foregroundStyle(cpu >= 70 ? Theme.recording : cpu >= 55 ? Theme.attention : .primary)
                        } else {
                            Text("不可读").foregroundStyle(.secondary)
                        }
                    }
                    FooterCell(title: "网络", ready: stats.link != nil) { networkValue }
                }
                .padding(.vertical, 12)
            }
        }
        .onAppear { LiveStatsRegistry.shared.acquire(device) }
        .onDisappear { LiveStatsRegistry.shared.release(device.identity) }
        .onChange(of: device.connected) { _, connected in
            if connected {
                LiveStatsRegistry.shared.acquire(device)
            } else {
                LiveStatsRegistry.shared.release(device.identity, after: 0)
            }
        }
    }

    /// Four equal columns, no wider than reads well, centred.
    private func columns<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            content()
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// What is in front on the phone: the app with its real icon, or the
    /// home screen, the lock screen, the screen off.
    @ViewBuilder
    private var frontValue: some View {
        switch stats.front {
        case .app(let package):
            let label = apps.label(for: package, on: device) ?? package
            HStack(spacing: 5) {
                frontIcon(package: package, label: label)
                Text(label)
            }
        case .home:
            Label("桌面", systemImage: "house.fill")
        case .locked:
            Label("已锁屏", systemImage: "lock.fill")
        case .asleep:
            Label("已息屏", systemImage: "moon.fill")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func frontIcon(package: String, label: String) -> some View {
        if let icon = apps.icons[device.identity]?[package] {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.accent.opacity(0.14))
                .frame(width: 16, height: 16)
                .overlay(Text(String(label.prefix(1))).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent))
        }
    }

    /// "1.2 MB/s", "34 KB/s".
    static func rate(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB/s", bytes / 1024) }
        return String(format: "%.0f B/s", bytes)
    }

    /// How the phone is online: Wi-Fi (bars, generation, name), mobile data
    /// (bars, 4G / 5G, carrier), wired, or not at all.
    @ViewBuilder
    private var networkValue: some View {
        switch stats.link {
        case .wifi:
            wifiValue
        case .mobile:
            let level = Double(stats.cellLevel ?? 0) / 4
            let tint = (stats.cellLevel ?? 0) >= 3 ? Theme.online : (stats.cellLevel ?? 0) >= 2 ? Theme.attention : Theme.recording
            HStack(spacing: 5) {
                SignalMark(symbol: "cellularbars", level: level, tint: tint, badge: stats.cellGeneration)
                Text(stats.carrier ?? "移动网络")
            }
            .help("移动网络" + (stats.cellLevel.map { " · 信号 \($0)/4 格" } ?? ""))
        case .ethernet:
            Label("有线网络", systemImage: "cable.connector")
        case .some(.none):
            Text("无网络").foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var wifiValue: some View {
        if let rssi = stats.wifiRSSI {
            let level = rssi >= -55 ? 1.0 : rssi >= -67 ? 0.67 : rssi >= -75 ? 0.34 : 0.0
            let tint = rssi >= -67 ? Theme.online : rssi >= -75 ? Theme.attention : Theme.recording
            HStack(spacing: 5) {
                SignalMark(symbol: "wifi", level: level, tint: tint,
                           badge: stats.wifiGeneration.map(String.init))
                Text(stats.wifiName ?? "Wi‑Fi")
            }
            .help("信号 \(rssi) dBm" + (stats.wifiSpeed.map { " · 速率 \(Self.speed($0))" } ?? "")
                  + (stats.wifiGeneration.map { " · Wi‑Fi \($0)" } ?? ""))
        } else {
            Text("未连接").foregroundStyle(.secondary)
        }
    }

    /// "866 Mbps", "2.4 Gbps".
    static func speed(_ mbps: Int) -> String {
        mbps >= 1000 ? String(format: "%.1f Gbps", Double(mbps) / 1000) : "\(mbps) Mbps"
    }

    private var batteryColor: Color {
        guard let level = stats.battery else { return Theme.online }
        if stats.charging { return Theme.online }
        return level <= 15 ? Theme.recording : level <= 30 ? Theme.attention : Theme.online
    }
}

/// A ring track still waiting for its value breathes gently.
private struct SkeletonPulse: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
            }
    }
}

/// A signal symbol with its bars lit, and its generation ("6", "5G-A")
/// tucked right against its lower corner.
private struct SignalMark: View {
    let symbol: String
    let level: Double
    let tint: Color
    let badge: String?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: -1) {
            Image(systemName: symbol, variableValue: level)
                .font(.system(size: 12, weight: .semibold))
                // The symbol's own right margin pushed the badge away.
                .padding(.trailing, symbol == "wifi" ? -2 : 0)
            if let badge {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .baselineOffset(-1)
            }
        }
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// One reading under a ring: its title, and its value or a skeleton.
private struct FooterCell<Value: View>: View {
    let title: String
    let ready: Bool
    @ViewBuilder let value: Value

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                if ready {
                    value
                        .font(.callout.monospacedDigit())
                        .labelStyle(FooterLabelStyle())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                } else {
                    SkeletonBlock(width: 84, height: 12)
                        .transition(.opacity)
                }
            }
            .frame(height: 18)
            .animation(Theme.quick, value: ready)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }
}

private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// A ring filled to `value` (0...1) with the percentage inside; it eases to
/// each new sample.
struct StatRing: View {
    let title: String
    let value: Double?
    let color: Color
    /// nil until read: a skeleton shows in its place.
    let detail: String?
    var symbol: String?

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                    .modifier(SkeletonPulse(active: value == nil))
                Circle()
                    .trim(from: 0, to: value ?? 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if value == nil {
                    SkeletonBlock(width: 26, height: 14)
                } else {
                HStack(spacing: 1) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color)
                    }
                    Text("\(Int(((value ?? 0) * 100).rounded()))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                }
            }
            .frame(width: 58, height: 58)
            .animation(.easeInOut(duration: 0.6), value: value)
            VStack(spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    SkeletonBlock(width: 52, height: 9).padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded()))%，\(detail ?? "")" } ?? "正在读取")
    }
}
