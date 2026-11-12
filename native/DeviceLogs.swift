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

    struct FilterCriteria: Equatable {
        var minimum: LogLevel = .verbose
        var trimmedQuery: String = ""
        var crashesOnly = false
        var filterApp = false
        var appPIDs = Set<Int>()

        func matches(_ entry: LogEntry) -> Bool {
            if crashesOnly && !entry.crash { return false }
            if LogLevel.rank(entry.level) < minimum.rawValue { return false }
            if filterApp && !appPIDs.contains(entry.pid) { return false }
            if !trimmedQuery.isEmpty &&
                !entry.tag.localizedCaseInsensitiveContains(trimmedQuery) &&
                !entry.message.localizedCaseInsensitiveContains(trimmedQuery) {
                return false
            }
            return true
        }
    }

    @Published private(set) var device: ADBDevice
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var filtered: [LogEntry] = []
    @Published private(set) var running = false
    @Published private(set) var stopReason: String?
    @Published private(set) var crashCount = 0
    /// pids of the app chosen in the filter (refreshed while it restarts).
    @Published private(set) var appPIDs = Set<Int>() {
        didSet { if appPIDs != oldValue { scheduleRefilter(debounced: false) } }
    }
    @Published var appFilter: String? {
        didSet {
            if appFilter != oldValue {
                refreshPIDs()
                scheduleRefilter(debounced: false)
            }
        }
    }
    @Published var minimum: LogLevel = .verbose {
        didSet { if minimum != oldValue { scheduleRefilter(debounced: false) } }
    }
    @Published var query = "" {
        didSet { if query != oldValue { scheduleRefilter(debounced: true) } }
    }
    @Published var crashesOnly = false {
        didSet { if crashesOnly != oldValue { scheduleRefilter(debounced: false) } }
    }

    private var process: Process?
    private var nextID = 0
    private var buffer = ""
    private var pending: [LogEntry] = []
    private let queue = DispatchQueue(label: "lanadb.logs")
    private let filterQueue = DispatchQueue(label: "lanadb.logs.filter", qos: .userInitiated)
    private var filterWork: DispatchWorkItem?
    private var filterGeneration = 0
    private var flushTimer: Timer?
    private var pidTimer: Timer?
    private var serial: String?

    init(device: ADBDevice) {
        self.device = device
    }

    func updateDevice(_ updated: ADBDevice) {
        device = updated
        if !updated.isApple, let fresh = MirrorStore.preferredTransports(for: updated).first?.endpoint {
            serial = fresh
        }
    }

    private var currentCriteria: FilterCriteria {
        FilterCriteria(
            minimum: minimum,
            trimmedQuery: query.trimmingCharacters(in: .whitespaces),
            crashesOnly: crashesOnly,
            filterApp: appFilter != nil,
            appPIDs: appPIDs
        )
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

    /// iPhone / iPad: the worker streams the system log in logcat's format.
    private func appleLogProcess() -> (Process, Pipe)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let worker = resources.appendingPathComponent("Worker/adb-worker")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { return nil }
        let process = Process()
        process.executableURL = worker
        process.arguments = ["ios_syslog"]
        process.currentDirectoryURL = worker.deletingLastPathComponent()
        var environment = environment()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        let request = (try? JSONSerialization.data(withJSONObject: ["serial": device.identity])) ?? Data()
        try? input.fileHandleForWriting.write(contentsOf: request)
        try? input.fileHandleForWriting.close()
        return (process, input)
    }

    func start() {
        if process != nil { return }
        guard device.connected else {
            stopReason = "设备未连接。"
            return
        }
        let process: Process
        if device.isApple {
            guard let (worker, _) = appleLogProcess() else {
                stopReason = "应用内的日志组件缺失，请重新安装。"
                return
            }
            process = worker
        } else {
            guard let adb, let serial = MirrorStore.preferredTransports(for: device).first?.endpoint else {
                stopReason = "设备未连接。"
                return
            }
            self.serial = serial
            process = Process()
            process.executableURL = adb
            // The last 1000 lines first, then live.
            process.arguments = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1000"]
            process.environment = environment()
        }
        stopReason = nil
        queue.async { [weak self] in self?.buffer = "" }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // End of output: stop being called (it would repeat at full speed).
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.queue.async { self?.consumeRemaining() }
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { self?.consumeRemaining() }
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
        filterWork?.cancel()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        running = false
        queue.async { [weak self] in self?.buffer = "" }
    }

    /// Clears what is shown (not the device's own log buffer, which other
    /// tools may still read).
    func clear() {
        filterGeneration += 1
        filterWork?.cancel()
        queue.async { [weak self] in
            self?.pending.removeAll()
            self?.buffer = ""
        }
        entries.removeAll()
        filtered.removeAll()
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

    private func consumeRemaining() {
        guard !buffer.isEmpty else { return }
        let remaining = buffer
        buffer = ""
        for line in remaining.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            if let entry = LogEntry.parse(trimmed, id: nextID) {
                nextID += 1
                pending.append(entry)
            }
        }
    }

    private func flush() {
        let criteria = currentCriteria
        queue.async { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            let batchCrashes = batch.reduce(0) { $0 + ($1.crash ? 1 : 0) }
            let matchingBatch = batch.filter { criteria.matches($0) }
            DispatchQueue.main.async {
                self.entries.append(contentsOf: batch)
                self.crashCount += batchCrashes
                let overflow = self.entries.count - Self.limit
                if overflow > 0 {
                    let droppedCrashes = self.entries.prefix(overflow).reduce(0) { $0 + ($1.crash ? 1 : 0) }
                    self.entries.removeFirst(overflow)
                    self.crashCount = max(0, self.crashCount - droppedCrashes)
                }
                if self.currentCriteria == criteria {
                    self.filtered.append(contentsOf: matchingBatch)
                    if let minID = self.entries.first?.id,
                       let dropCount = self.filtered.firstIndex(where: { $0.id >= minID }) {
                        if dropCount > 0 { self.filtered.removeFirst(dropCount) }
                    } else if self.entries.isEmpty {
                        self.filtered.removeAll()
                    } else if let minID = self.entries.first?.id,
                              let lastFiltered = self.filtered.last?.id, lastFiltered < minID {
                        self.filtered.removeAll()
                    }
                } else {
                    self.scheduleRefilter(debounced: false)
                }
            }
        }
    }

    private func scheduleRefilter(debounced: Bool) {
        filterWork?.cancel()
        filterGeneration += 1
        let generation = filterGeneration
        let run = DispatchWorkItem { [weak self] in
            guard let self, self.filterGeneration == generation else { return }
            let snapshot = self.entries
            let snapshotLastID = snapshot.last?.id
            let criteria = self.currentCriteria
            self.filterQueue.async { [weak self] in
                let matched = snapshot.filter { criteria.matches($0) }
                DispatchQueue.main.async {
                    guard let self, self.filterGeneration == generation else { return }
                    if self.entries.isEmpty {
                        self.filtered = []
                        return
                    }
                    var combined = matched
                    if let lastID = snapshotLastID,
                       let tailStart = self.entries.firstIndex(where: { $0.id > lastID }) {
                        combined.append(contentsOf: self.entries[tailStart...].filter { criteria.matches($0) })
                    } else if snapshotLastID == nil {
                        combined = self.entries.filter { criteria.matches($0) }
                    }
                    if let minID = self.entries.first?.id {
                        if let dropCount = combined.firstIndex(where: { $0.id >= minID }) {
                            if dropCount > 0 { combined.removeFirst(dropCount) }
                        } else if let last = combined.last?.id, last < minID {
                            combined.removeAll()
                        }
                    }
                    self.filtered = combined
                }
            }
        }
        filterWork = run
        if debounced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: run)
        } else {
            run.perform()
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
            let reader = pipe.fileHandleForReading
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            guard (try? process.run()) != nil else { return }
            var data = Data()
            let readDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                data = reader.readDataToEndOfFile()
                readDone.signal()
            }
            if finished.wait(timeout: .now() + 3) == .timedOut {
                if process.isRunning { process.terminate() }
                try? reader.close()
                return
            }
            _ = readDone.wait(timeout: .now() + 1)
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
    @ObservedObject var store: DeviceLogStore
    @ObservedObject private var apps = AppWindowStore.shared
    @State private var follow = true
    @State private var selection = Set<Int>()

    var body: some View {
        let rows = store.filtered
        VStack(spacing: 0) {
            toolbar(rows: rows)
            Divider()
            if store.crashCount > 0 && !store.crashesOnly {
                Button {
                    store.crashesOnly = true
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
                    LogRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("复制") {
                                let targetIDs = selection.contains(entry.id) ? selection : [entry.id]
                                copyLines(rows.filter { targetIDs.contains($0.id) })
                            }
                        }
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
            if !store.device.isApple { apps.load(store.device) }
        }
        .onDisappear { store.stop() }
    }

    private func copyLines(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entries.map(\.text).joined(separator: "\n"), forType: .string)
    }

    private func toolbar(rows: [LogEntry]) -> some View {
        HStack(spacing: 10) {
            TextField("搜索标签或内容", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
            Picker("级别", selection: $store.minimum) {
                ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if !store.device.isApple {
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
            }
            Toggle("只看崩溃", isOn: $store.crashesOnly)
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
                export(rows)
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
        let safeTitle = store.device.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle) 日志 \(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = DeviceActions.saveDirectoryURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = rows.map(\.text).joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
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
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 0.5)
        .listRowBackground(entry.crash ? Color.red.opacity(0.08) : Color.clear)
    }
}

/// One log window per device; opening it again brings that window forward.
enum DeviceLogWindows {
    private struct WindowEntry {
        let window: NSWindow
        let store: DeviceLogStore
        let observer: NSObjectProtocol
    }

    private static var windows: [String: WindowEntry] = [:]

    static func show(_ device: ADBDevice) {
        if let existing = windows[device.identity] {
            existing.store.updateDevice(device)
            existing.window.title = "\(device.title) · 日志"
            if !existing.store.running && device.connected {
                existing.store.start()
            }
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let store = DeviceLogStore(device: device)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(device.title) · 日志"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DeviceLogView(store: store))
        // The hosting view sizes the window to its minimum; start roomier.
        window.setContentSize(NSSize(width: 1040, height: 640))
        window.center()
        window.setFrameAutosaveName("DeviceLog")
        let id = device.identity
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // Dropping the hosting view stops its logcat process.
            if let removed = windows.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(removed.observer)
                removed.store.stop()
                removed.window.contentViewController = nil
            }
        }
        windows[device.identity] = WindowEntry(window: window, store: store, observer: observer)
        window.makeKeyAndOrderFront(nil)
    }
}
