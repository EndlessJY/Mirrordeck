import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One `logcat -v threadtime` line.
struct LogEntry: Identifiable {
    let id: Int
    let time: String
    let pid: Int
    let tid: Int
    let level: Character
    let tag: String
    let message: String
    /// Java crash, native crash or ANR report.
    let crash: Bool

    var text: String {
        "\(time) \(pid) \(tid) \(level) \(tag): \(message)"
    }

    /// "11-09 07:40:01.123  1234  1256 E Tag     : message"
    static func parse(_ line: Substring, id: Int) -> LogEntry? {
        let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard fields.count == 6, fields[0].count == 5, fields[1].count >= 8,
              let pid = Int(fields[2]), let tid = Int(fields[3]),
              fields[4].count == 1, let level = fields[4].first, "VDIWEFA".contains(level)
        else { return nil }
        let rest = fields[5]
        let tag: String
        let message: String
        if let colon = rest.range(of: ": ") {
            tag = rest[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            message = String(rest[colon.upperBound...])
        } else {
            tag = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            message = ""
        }
        let crash = (tag == "AndroidRuntime" && (level == "E" || level == "F")) ||
            (tag == "DEBUG" && level == "F") || tag == "libc" && level == "F" ||
            (tag == "ActivityManager" && message.hasPrefix("ANR in"))
        return LogEntry(id: id, time: "\(fields[0]) \(fields[1])", pid: pid, tid: tid,
                        level: level, tag: tag, message: message, crash: crash)
    }
}

enum LogLevel: Int, CaseIterable, Identifiable {
    case verbose, debug, info, warning, error
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .verbose: return "全部级别"
        case .debug: return "调试及以上"
        case .info: return "信息及以上"
        case .warning: return "警告及以上"
        case .error: return "仅错误"
        }
    }
    static func rank(_ level: Character) -> Int {
        switch level {
        case "V": return 0
        case "D": return 1
        case "I": return 2
        case "W": return 3
        default: return 4
        }
    }
}

/// Streams a device's log. Lines are parsed off the main thread and handed to
/// the view in batches, a few times a second, so a busy log stays smooth.
final class DeviceLogStore: ObservableObject {
    static let limit = 60_000

    let device: ADBDevice
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var running = false
    @Published private(set) var stopReason: String?
    @Published private(set) var crashCount = 0
    /// pids of the app chosen in the filter (refreshed while it restarts).
    @Published private(set) var appPIDs = Set<Int>()
    @Published var appFilter: String? { didSet { refreshPIDs() } }

    private var process: Process?
    private var nextID = 0
    private var buffer = ""
    private var pending: [LogEntry] = []
    private let queue = DispatchQueue(label: "lanadb.logs")
    private var flushTimer: Timer?
    private var pidTimer: Timer?
    private var serial: String?

    init(device: ADBDevice) {
        self.device = device
    }

    private var adb: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools/adb")
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_SERIAL", "ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS",
                    "ANDROID_ADB_SERVER_PORT"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    func start() {
        guard process == nil, let adb,
              let serial = MirrorStore.preferredTransports(for: device).first?.endpoint else {
            stopReason = "设备未连接。"
            return
        }
        self.serial = serial
        stopReason = nil
        let process = Process()
        process.executableURL = adb
        // The last 1000 lines first, then live.
        process.arguments = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1000"]
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.process = nil
                self.running = false
                self.flushTimer?.invalidate()
                self.flush()
                if self.stopReason == nil { self.stopReason = "日志已停止，设备可能已断开。" }
            }
        }
        do {
            try process.run()
            self.process = process
            running = true
            flushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.flush()
            }
        } catch {
            stopReason = "无法读取日志：\(error.localizedDescription)"
        }
        refreshPIDs()
    }

    func stop() {
        stopReason = "已停止。"
        flushTimer?.invalidate()
        pidTimer?.invalidate()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        running = false
    }

    /// Clears what is shown (not the device's own log buffer, which other
    /// tools may still read).
    func clear() {
        queue.async { [weak self] in self?.pending.removeAll() }
        entries.removeAll()
        crashCount = 0
    }

    private func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        guard let lastBreak = buffer.lastIndex(of: "\n") else { return }
        let complete = buffer[..<lastBreak]
        buffer = String(buffer[buffer.index(after: lastBreak)...])
        for line in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            if let entry = LogEntry.parse(trimmed, id: nextID) {
                nextID += 1
                pending.append(entry)
            }
        }
    }

    private func flush() {
        queue.async { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            DispatchQueue.main.async {
                self.entries.append(contentsOf: batch)
                self.crashCount += batch.filter(\.crash).count
                if self.entries.count > Self.limit {
                    self.entries.removeFirst(self.entries.count - Self.limit)
                }
            }
        }
    }

    private func refreshPIDs() {
        pidTimer?.invalidate()
        guard let package = appFilter else {
            appPIDs = []
            return
        }
        lookUpPIDs(package)
        // The app may restart (a crash, for one) with a new process id.
        pidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.lookUpPIDs(package)
        }
    }

    private func lookUpPIDs(_ package: String) {
        guard let adb, let serial else { return }
        let environment = environment()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = adb
            process.arguments = ["-s", serial, "shell", "pidof", package]
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let pids = Set(String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
            DispatchQueue.main.async {
                guard let self, self.appFilter == package else { return }
                // Keep earlier pids, so lines of a crashed process stay visible.
                self.appPIDs.formUnion(pids)
            }
        }
    }
}

struct DeviceLogView: View {
    @StateObject private var store: DeviceLogStore
    @ObservedObject private var apps = AppWindowStore.shared
    @State private var minimum = LogLevel.verbose
    @State private var query = ""
    @State private var crashesOnly = false
    @State private var follow = true
    @State private var selection = Set<Int>()

    init(device: ADBDevice) {
        _store = StateObject(wrappedValue: DeviceLogStore(device: device))
    }

    private var visible: [LogEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let rank = minimum.rawValue
        let pids = store.appPIDs
        let filterApp = store.appFilter != nil
        return store.entries.filter { entry in
            if crashesOnly && !entry.crash { return false }
            if LogLevel.rank(entry.level) < rank { return false }
            if filterApp && !pids.contains(entry.pid) { return false }
            if !text.isEmpty && !entry.tag.localizedCaseInsensitiveContains(text) &&
                !entry.message.localizedCaseInsensitiveContains(text) { return false }
            return true
        }
    }

    var body: some View {
        let rows = visible
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.crashCount > 0 && !crashesOnly {
                Button {
                    crashesOnly = true
                } label: {
                    Label("发现 \(store.crashCount) 条崩溃记录，点按只看崩溃",
                          systemImage: "exclamationmark.octagon.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.85))
            }
            ScrollViewReader { proxy in
                List(rows, selection: $selection) { entry in
                    LogRow(entry: entry).tag(entry.id)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .onCopyCommand {
                    let lines = rows.filter { selection.contains($0.id) }.map(\.text)
                    return [NSItemProvider(object: lines.joined(separator: "\n") as NSString)]
                }
                .onChange(of: rows.last?.id) { _, last in
                    guard follow, let last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            Divider()
            statusBar(count: rows.count)
        }
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
            store.start()
            apps.load(store.device)
        }
        .onDisappear { store.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("搜索标签或内容", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            Picker("级别", selection: $minimum) {
                ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("应用", selection: $store.appFilter) {
                Text("全部应用").tag(String?.none)
                let list = apps.apps[store.device.id] ?? []
                if !list.isEmpty { Divider() }
                ForEach(list) { app in
                    Text(app.label).tag(Optional(app.package))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            Toggle("只看崩溃", isOn: $crashesOnly)
                .toggleStyle(.button)
            Spacer(minLength: 0)
            Toggle(isOn: $follow) {
                Label("跟随最新", systemImage: "arrow.down.to.line")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("有新日志时自动滚动到底部")
            Button {
                store.clear()
                selection.removeAll()
            } label: {
                Label("清空", systemImage: "trash").labelStyle(.iconOnly)
            }
            .help("清空窗口中的日志（不影响设备）")
            Button {
                export(visible)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
            }
            .help("把当前显示的日志保存为文本文件")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusBar(count: Int) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: store.running ? Theme.online : .secondary, pulsing: store.running)
            Text(store.running ? "正在接收" : (store.stopReason ?? "已停止"))
            Text("·")
            Text("显示 \(count) / 共 \(store.entries.count) 行")
            Spacer()
            if !store.running {
                Button("重新开始") { store.start() }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func export(_ rows: [LogEntry]) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(store.device.title) 日志 \(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = DeviceActions.saveDirectoryURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = rows.map(\.text).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.level {
        case "E", "F", "A": return .red
        case "W": return .orange
        case "I": return Theme.online
        case "D": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .frame(width: 136, alignment: .leading)
            Text(String(entry.pid)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 46, alignment: .trailing)
            Text(String(entry.level))
                .fontWeight(.bold)
                .foregroundStyle(levelColor)
                .frame(width: 12)
            Text(entry.tag).foregroundStyle(levelColor.opacity(0.9))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(entry.crash ? Color.red : Color.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 0.5)
        .listRowBackground(entry.crash ? Color.red.opacity(0.08) : Color.clear)
    }
}

/// One log window per device; opening it again brings that window forward.
enum DeviceLogWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show(_ device: ADBDevice) {
        if let window = windows[device.identity] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(device.title) · 日志"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DeviceLogView(device: device))
        // The hosting view sizes the window to its minimum; start roomier.
        window.setContentSize(NSSize(width: 1040, height: 640))
        window.center()
        window.setFrameAutosaveName("DeviceLog")
        let id = device.identity
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            // Dropping the hosting view stops its logcat process.
            windows[id]?.contentViewController = nil
            windows.removeValue(forKey: id)
        }
        windows[device.identity] = window
        window.makeKeyAndOrderFront(nil)
    }
}
