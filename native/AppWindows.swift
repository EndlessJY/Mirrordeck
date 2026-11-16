import AppKit
import Foundation

/// An app installed on the device, as `scrcpy --list-apps` reports it.
struct DeviceApp: Identifiable, Hashable {
    let label: String
    let package: String
    let system: Bool
    /// Lowercased forms a search may match: name, package, full pinyin
    /// ("jisuanqi"), initials ("jsq"), and initials keeping Latin words
    /// whole ("qqyl" for QQ音乐).
    let searchKeys: [String]
    var id: String { package }

    init(label: String, package: String, system: Bool) {
        self.label = label
        self.package = package
        self.system = system
        searchKeys = Self.keys(for: label) + [package.lowercased()]
    }

    private static func latin(_ text: String) -> [String] {
        let string = NSMutableString(string: text)
        CFStringTransform(string, nil, kCFStringTransformToLatin, false)
        CFStringTransform(string, nil, kCFStringTransformStripDiacritics, false)
        return (string as String).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func keys(for label: String) -> [String] {
        let tokens = latin(label)
        var wordInitials = ""
        var run = ""
        for character in label {
            if character.isASCII && (character.isLetter || character.isNumber) {
                run.append(character)
                continue
            }
            wordInitials += run.lowercased()
            run = ""
            if let first = latin(String(character)).first?.first { wordInitials.append(first) }
        }
        wordInitials += run.lowercased()
        let keys = [label.lowercased(), tokens.joined(),
                    String(tokens.compactMap(\.first)), wordInitials]
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 0: name, pinyin or initials start with the query; 1: contained; nil: no match.
    func rank(for query: String) -> Int? {
        let text = query.lowercased().filter { !$0.isWhitespace }
        guard !text.isEmpty else { return 0 }
        if searchKeys.contains(where: { $0.hasPrefix(text) }) { return 0 }
        if searchKeys.contains(where: { $0.contains(text) }) { return 1 }
        return nil
    }
}

/// Opens single apps of a device in their own Mac windows. Each window runs
/// the device's mirror program on a new virtual display (Android 10+), so the
/// phone's own screen stays as it is.
final class AppWindowStore: ObservableObject {
    static let shared = AppWindowStore()

    @Published private(set) var apps: [String: [DeviceApp]] = [:]
    /// Launcher icons per device, by package.
    @Published private(set) var icons: [String: [String: NSImage]] = [:]
    @Published private(set) var loading = Set<String>()
    @Published var errors: [String: String] = [:]
    /// Packages whose window is starting or open, per device.
    @Published private(set) var open: [String: Set<String>] = [:]
    /// Packages opened most recently, per device (newest first).
    @Published private(set) var recent: [String: [String]] = [:]
    private static let recentLimit = 8
    private static func recentKey(_ id: String) -> String { "apps.recent." + id }

    func recentPackages(for device: ADBDevice) -> [String] {
        if let list = recent[device.identity] { return list }
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentKey(device.identity)) ?? []
        DispatchQueue.main.async { self.recent[device.identity] = stored }
        return stored
    }

    private func remember(_ package: String, on device: ADBDevice) {
        var list = recentPackages(for: device).filter { $0 != package }
        list.insert(package, at: 0)
        list = Array(list.prefix(Self.recentLimit))
        recent[device.identity] = list
        UserDefaults.standard.set(list, forKey: Self.recentKey(device.identity))
    }
    private var processes: [String: Process] = [:]
    private var starting = Set<String>()
    private var iconData: [String: [String: Data]] = [:]
    private var watchers: [String: DispatchSourceTimer] = [:]
    /// Windows this app closed itself (the app left its display, or quitting).
    private var closing = Set<String>()

    var hasActiveWork: Bool { !processes.isEmpty || !starting.isEmpty }

    private var tools: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
    }

    private func environment(serial: String, tools: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let adb = tools.appendingPathComponent("adb").path
        environment["ADB"] = adb
        environment["LANADB_ADB"] = adb
        environment["LANADB_SERIAL"] = serial
        environment["LANADB_APP_WINDOW"] = "1"
        environment["LANADB_ARROW_SWIPE"] = MirrorStore.arrowSwipe ? "1" : "0"
        environment["LANADB_RECORDING"] = "0"
        environment["LANADB_GAMUT"] = "srgb"
        environment["LANADB_THEME"] = "classic"
        environment["LANADB_APPEARANCE"] = ThemeStore.shared.appearanceMode.rawValue
        environment["SCRCPY_SERVER_PATH"] = tools.appendingPathComponent("scrcpy-server").path
        environment["SCRCPY_ICON_DIR"] = tools.path
        environment["PATH"] = "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin"
        for key in ["ANDROID_SERIAL", "ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS",
                    "ANDROID_ADB_SERVER_PORT", "LANADB_SESSION_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static func run(_ executable: URL, _ arguments: [String],
                            environment: [String: String]? = nil,
                            directory: URL? = nil,
                            timeout: TimeInterval = 12) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return "" }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = reader.readDataToEndOfFile()
            readDone.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            try? reader.close()
            return ""
        }
        _ = readDone.wait(timeout: .now() + 2)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the device's apps and their icons (a second or two); kept until
    /// `reload`.
    /// Devices whose list was read from the device in this run (a cached one
    /// shows at once, and is checked against the device once).
    private var refreshed = Set<String>()

    /// The last list and icons of each device, kept on disk so the picker
    /// shows them at once, even right after launch.
    private struct Cache: Codable {
        struct App: Codable { let label: String; let package: String; let system: Bool }
        var apps: [App]
        var icons: [String: Data]
    }

    private static func cacheURL(_ id: String) -> URL {
        let name = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LAN ADB Manager/AppCache", isDirectory: true)
            .appendingPathComponent(name + ".plist")
    }

    private func restoreCache(_ id: String) {
        guard apps[id] == nil,
              let data = try? Data(contentsOf: Self.cacheURL(id)),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              !cache.apps.isEmpty else { return }
        apps[id] = cache.apps.map { DeviceApp(label: $0.label, package: $0.package, system: $0.system) }
        iconData[id] = cache.icons
        icons[id] = cache.icons.compactMapValues { NSImage(data: $0) }
    }

    private func saveCache(_ id: String) {
        guard let list = apps[id] else { return }
        let cache = Cache(apps: list.map { .init(label: $0.label, package: $0.package, system: $0.system) },
                          icons: iconData[id] ?? [:])
        let url = Self.cacheURL(id)
        DispatchQueue.global(qos: .utility).async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(cache) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// An app's name from the list read before (or cached), if known.
    func label(for package: String, on device: ADBDevice) -> String? {
        let id = device.identity
        guard let list = apps[id] else {
            // Not while a view is being drawn: the cached list, or the
            // device's own (with icons) when there is none, loads just after.
            DispatchQueue.main.async {
                self.restoreCache(id)
                if self.apps[id] == nil { self.load(device) }
            }
            return nil
        }
        return list.first { $0.package == package }?.label
    }

    func load(_ device: ADBDevice, reload: Bool = false) {
        let id = device.identity
        restoreCache(id)
        guard !device.isApple, !loading.contains(id), reload || !refreshed.contains(id),
              let serial = MirrorStore.preferredTransports(for: device).first?.endpoint,
              let tools else { return }
        let preserveRunning = MirrorStore.shared.hasRunningSession(for: device)
        loading.insert(id)
        errors[id] = nil
        let environment = environment(serial: serial, tools: tools)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let executable: URL
            do {
                executable = try MirrorStore.shared.mirrorExecutable(
                    for: device, preserveRunningBundle: preserveRunning)
            } catch {
                DispatchQueue.main.async {
                    self?.loading.remove(id)
                    self?.errors[id] = "无法准备投屏程序：\(error.localizedDescription)"
                }
                return
            }
            let output = Self.run(executable, ["--serial=\(serial)", "--list-apps"],
                                  environment: environment, directory: tools, timeout: 15)
            let parsed = Self.parseApps(output)
            DispatchQueue.main.async {
                guard let self else { return }
                if parsed.isEmpty {
                    self.loading.remove(id)
                    // A cached list stays; only with none is it an error.
                    if self.apps[id] == nil { self.errors[id] = "无法读取应用列表，请确认设备已连接。" }
                    return
                }
                self.refreshed.insert(id)
                self.apps[id] = parsed
            }
            guard !parsed.isEmpty else { return }
            let adb = tools.appendingPathComponent("adb")
            // Icons already cached are not read again (a reload reads them all).
            let known = DispatchQueue.main.sync { reload ? [:] : (self?.iconData[id] ?? [:]) }
            let wanted = parsed.map(\.package).filter { known[$0] == nil }
            var pictures = Self.readIcons(serial: serial, packages: wanted, adb: adb)
            // An icon can fail once (the app was busy starting, say): ask again
            // for just those.
            let missing = wanted.filter { pictures[$0] == nil }
            if !missing.isEmpty && missing.count < wanted.count {
                pictures.merge(Self.readIcons(serial: serial, packages: missing, adb: adb)) { a, _ in a }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(id)
                // A reload never loses an icon read before.
                let installed = Set(parsed.map(\.package))
                let merged = (self.iconData[id] ?? [:]).merging(pictures) { _, new in new }
                    .filter { installed.contains($0.key) }
                self.iconData[id] = merged
                if !pictures.isEmpty || self.icons[id]?.count != merged.count {
                    self.icons[id] = merged.compactMapValues { NSImage(data: $0) }
                }
                self.saveCache(id)
            }
        }
    }

    /// Launcher icons, read by a small program run once with `app_process`
    /// (the way scrcpy runs on the device). Nothing is installed: the file is
    /// placed in /data/local/tmp for the moment it runs and deleted after.
    private static func readIcons(serial: String, packages: [String], adb: URL) -> [String: Data] {
        guard !packages.isEmpty,
              let dex = Bundle.main.resourceURL?.appendingPathComponent("lanadb-icons.dex"),
              FileManager.default.fileExists(atPath: dex.path) else { return [:] }
        let remote = "/data/local/tmp/lanadb-icons-\(UUID().uuidString.prefix(8)).dex"
        _ = run(adb, ["-s", serial, "push", dex.path, remote], timeout: 15)
        let output = run(adb, ["-s", serial, "shell",
                               "CLASSPATH=\(remote) app_process / IconDump 96 " +
                               packages.joined(separator: " ") + "; rm -f \(remote)"], timeout: 25)
        var result: [String: Data] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1] != "-",
                  let data = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces))
            else { continue }
            result[String(parts[0])] = data
        }
        return result
    }

    /// " * 设置    com.android.settings" (system) / " - 计算器    com.miui.calculator".
    static func parseApps(_ output: String) -> [DeviceApp] {
        var seen = Set<String>()
        var result: [DeviceApp] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = trimmed.first, marker == "*" || marker == "-" else { continue }
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let split = rest.range(of: #"\s+\S+$"#, options: .regularExpression) else { continue }
            let package = rest[split].trimmingCharacters(in: .whitespaces)
            let label = rest[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
            guard package.contains("."), seen.insert(package).inserted else { continue }
            result.append(DeviceApp(label: label.isEmpty ? package : label,
                                    package: package, system: marker == "*"))
        }
        return result.sorted {
            $0.system != $1.system ? !$0.system :
                $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private func key(_ device: ADBDevice, _ package: String) -> String {
        device.identity + "|" + package
    }

    /// Opens the app in its own window, or brings its open window forward.
    func openWindow(for app: DeviceApp, on device: ADBDevice, options: MirrorOptions) {
        let id = device.identity
        let key = key(device, app.package)
        if let running = processes[key], running.isRunning {
            NSRunningApplication(processIdentifier: running.processIdentifier)?
                .activate(options: [.activateAllWindows])
            return
        }
        guard !starting.contains(key) else { return }
        guard let transport = MirrorStore.preferredTransports(for: device).first, let tools else {
            errors[id] = "设备未连接。"
            return
        }
        remember(app.package, on: device)
        starting.insert(key)
        open[id, default: []].insert(app.package)
        errors[id] = nil
        let preserveRunning = MirrorStore.shared.hasRunningSession(for: device)
        let adb = tools.appendingPathComponent("adb")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let preparedResult = Result { try MirrorStore.shared.mirrorExecutable(
                for: device, preserveRunningBundle: preserveRunning) }
            let before = Set(Self.displays(in: Self.run(adb, ["-s", transport.endpoint, "shell",
                Self.activitiesCommand], timeout: 6)))
            // The app's uid, so the window captures only its sound.
            let uid = Self.uid(of: app.package, in: Self.run(adb, ["-s", transport.endpoint, "shell",
                "pm list packages -U \(app.package)"], timeout: 6))
            let sdk = Int(Self.run(adb, ["-s", transport.endpoint, "shell", "getprop ro.build.version.sdk"],
                                   timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.starting.remove(key) != nil else { return }
                let executable: URL
                switch preparedResult {
                case .success(let exec):
                    executable = exec
                case .failure(let error):
                    self.open[id]?.remove(app.package)
                    self.errors[id] = "无法准备投屏程序：\(error.localizedDescription)"
                    return
                }
                self.launchWindow(for: app, on: device, transport: transport, options: options,
                                  tools: tools, executable: executable, existingDisplays: before,
                                  appUID: sdk >= 33 ? uid : nil)
            }
        }
    }

    private func launchWindow(for app: DeviceApp, on device: ADBDevice, transport: ADBTransport,
                              options: MirrorOptions, tools: URL, executable: URL,
                              existingDisplays: Set<Int>, appUID: Int?) {
        let id = device.identity
        let key = key(device, app.package)
        let title = "\(app.label) · \(device.title)"
        let effectiveCodec = MirrorStore.effectiveCodec(options.videoCodec, for: device)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = tools
        var arguments = [
            "--serial=\(transport.endpoint)",
            "--window-title=\(title)",
            // A display of the phone's size and density, so the app lays out
            // as it does on the phone. Closing the window closes the app with
            // it: it never turns up on the phone's own screen (or its mirror).
            "--new-display",
            // The keyboard shows inside this window, on the app's own display,
            // not on the phone's screen.
            "--display-ime-policy=local",
            "--start-app=\(app.package)",
            "--max-fps=\(options.maxFPS)",
            "--video-bit-rate=\(options.videoBitrateMbps)M",
            "--audio-bit-rate=\(options.audioBitrateKbps)K",
            "--video-codec=\(effectiveCodec)",
            "--prefer-text",
        ]
        if options.maxSize > 0 { arguments.append("--max-size=\(options.maxSize)") }
        if PhoneSettings.stayAwake { arguments.append("--screen-off-timeout=1800") }
        // Where this app's window was last left on this device.
        arguments += WindowPlaces.arguments(key)
        // AAC allows single-app MP4 recordings to mux live audio playable in chat apps.
        // Android 13+: the window captures only its app's sound, which then
        // plays nowhere else (not on the phone, not in the main mirror), so
        // the two stay independent. Before that, sound is device-wide: the
        // window leaves it to a main mirror that carries it.
        let audio: Bool
        var ownAudio = false
        if options.audio, let appUID {
            audio = true
            ownAudio = true
            arguments += ["--audio-source=playback", "--audio-uid=\(appUID)"]
        } else {
            audio = options.audio && !MirrorStore.shared.mainMirrorCapturesAudio(for: device)
        }
        arguments.append(audio ? "--audio-codec=aac" : "--no-audio")
        process.arguments = arguments
        let token = UUID().uuidString
        var environment = environment(serial: transport.endpoint, tools: tools)
        environment["LANADB_SESSION_TOKEN"] = token
        environment["LANADB_AUDIO_ENABLED"] = audio ? "1" : "0"
        // Its sound is taken before the phone's volume applies: the window's
        // volume buttons and keys then set this window's own volume.
        environment["LANADB_APP_OWN_AUDIO"] = ownAudio ? "1" : "0"
        environment["LANADB_APP_LABEL"] = app.label
        if let data = iconData[id]?[app.package] {
            let icon = FileManager.default.temporaryDirectory
                .appendingPathComponent("lanadb-icon-\(UUID().uuidString).png")
            if (try? data.write(to: icon)) != nil { environment["LANADB_APP_ICON"] = icon.path }
        }
        process.environment = environment
        // A log file, not a pipe: a pipe nobody drains fast enough would fill
        // and block the window. It is read for the error if the window fails.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-adb-scrcpy-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            open[id]?.remove(app.package)
            errors[id] = "无法打开应用窗口。"
            return
        }
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] finished in
            logHandle.closeFile()
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            if let icon = environment["LANADB_APP_ICON"] {
                try? FileManager.default.removeItem(atPath: icon)
            }
            DispatchQueue.main.async {
                guard let self, self.processes[key] === finished else { return }
                self.processes.removeValue(forKey: key)
                self.watchers.removeValue(forKey: key)?.cancel()
                self.open[id]?.remove(app.package)
                MirrorStore.shared.unregisterAppWindow(key: key)
                let wasClosing = self.closing.remove(key) != nil
                if !wasClosing, effectiveCodec == "h265",
                   MirrorStore.isVideoEncoderFailure(text) {
                    UserDefaults.standard.set(false, forKey: MirrorStore.hevcKey(device))
                    var fallbackOptions = options
                    fallbackOptions.videoCodec = "h264"
                    self.openWindow(for: app, on: device, options: fallbackOptions)
                    return
                }
                if !wasClosing,
                   finished.terminationStatus != 0, finished.terminationReason == .exit {
                    self.errors[id] = Self.failureMessage(text, app: app)
                }
            }
        }
        // The window activates itself once it is up.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier:
            MirrorStore.bundleIdentifier(for: device))
        do {
            try process.run()
            processes[key] = process
            MirrorStore.shared.registerAppWindow(key: key, device: device,
                                                 transport: transport, process: process,
                                                 token: token, options: options,
                                                 title: title)
            watchForExit(key: key, process: process, serial: transport.endpoint,
                         existing: existingDisplays, package: app.package, token: token)
        } catch {
            logHandle.closeFile()
            try? FileManager.default.removeItem(at: logURL)
            if let icon = environment["LANADB_APP_ICON"] {
                try? FileManager.default.removeItem(atPath: icon)
            }
            open[id]?.remove(app.package)
            errors[id] = "无法打开应用窗口：\(error.localizedDescription)"
        }
    }

    private static let activitiesCommand =
        "dumpsys activity activities | grep -E '^Display #|Hist +#'"

    private static func isActivityEntry(_ text: String) -> Bool {
        text.range(of: #"Hist +#[0-9]+:"#, options: .regularExpression) != nil
    }

    /// The uid in `pm list packages -U <package>` ("package:<name> uid:<n>").
    static func uid(of package: String, in output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.first == "package:\(package)" else { continue }
            for field in fields where field.hasPrefix("uid:") {
                return Int(field.dropFirst(4).split(separator: ",").first ?? "")
            }
        }
        return nil
    }

    static func displays(in output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("Display #") else { return nil }
            return Int(line.dropFirst("Display #".count).prefix { $0.isNumber })
        }
    }

    /// Closes the window once the app has left its display: Back on the app's
    /// first page (twice, for apps that ask "press again to exit") finishes it
    /// and only the display's launcher, or nothing, remains.
    private func watchForExit(key: String, process: Process, serial: String,
                              existing: Set<Int>, package: String, token: String) {
        guard watchers[key] == nil, let adb = tools?.appendingPathComponent("adb") else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var display: Int?
        var seen = false
        var lastRoot: Bool?
        timer.schedule(deadline: .now() + 0.8, repeating: 0.8)
        timer.setEventHandler { [weak self] in
            guard process.isRunning else { timer.cancel(); return }
            let output = Self.run(adb, ["-s", serial, "shell", Self.activitiesCommand], timeout: 5)
            if display == nil {
                // The new display that shows this app.
                display = Self.displays(in: output).first { candidate in
                    !existing.contains(candidate) &&
                        (Self.topActivity(in: output, display: candidate) ?? "").contains(package + "/")
                }
            }
            guard let display, let top = Self.topActivity(in: output, display: display) else { return }
            if top.contains(package + "/") {
                seen = true
                // On its first page the window asks for a second Back before
                // closing (the hint shows where the recording clock does).
                let root = Self.activityCount(in: output, display: display, package: package) <= 1
                if root != lastRoot {
                    lastRoot = root
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("uk.agpt.lanadbmanager.mirror.state"), object: nil,
                        userInfo: ["token": token, "kind": "appRoot", "root": root,
                                   "success": true, "message": ""],
                        deliverImmediately: true)
                }
            } else if seen && (top.isEmpty || top.contains("Launcher")) {
                timer.cancel()
                DispatchQueue.main.async {
                    guard let self, self.processes[key] === process else { return }
                    self.closing.insert(key)
                    process.terminate()
                }
            }
        }
        watchers[key] = timer
        timer.resume()
    }

    /// The topmost activity of a display in `dumpsys activity activities`
    /// ("" when the display has none); nil if the display is not listed.
    static func topActivity(in output: String, display: Int) -> String? {
        var inDisplay = false
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Display #") {
                if inDisplay { return "" }
                inDisplay = text.hasPrefix("Display #\(display) ") || text == "Display #\(display)"
                continue
            }
            if inDisplay && isActivityEntry(text) && !text.contains(" f}") {
                return text
            }
        }
        return inDisplay ? "" : nil
    }

    /// How many of the app's pages are open on the display (1: its first page).
    static func activityCount(in output: String, display: Int, package: String) -> Int {
        var inDisplay = false
        var count = 0
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Display #") {
                if inDisplay { break }
                inDisplay = text.hasPrefix("Display #\(display) ") || text == "Display #\(display)"
                continue
            }
            if inDisplay && isActivityEntry(text) && !text.contains(" f}")
                && text.contains(package + "/") {
                count += 1
            }
        }
        return count
    }

    private static func failureMessage(_ output: String, app: DeviceApp) -> String {
        if output.contains("Virtual display") && output.localizedCaseInsensitiveContains("not supported")
            || output.contains("requires Android 10") || output.contains("API 29") {
            return "单应用窗口需要 Android 10 或更新版本。"
        }
        if output.localizedCaseInsensitiveContains("app not found") {
            return "设备上找不到“\(app.label)”。"
        }
        let detail = output.split(separator: "\n").map(String.init)
            .filter { $0.contains("ERROR") }.suffix(1).joined()
        return detail.isEmpty ? "“\(app.label)”的窗口意外关闭。" : "无法打开“\(app.label)”：\(detail)"
    }

    func closeAll(deviceID: String? = nil) {
        if let deviceID {
            starting = starting.filter { !$0.hasPrefix(deviceID + "|") }
            open[deviceID] = nil
        } else {
            starting.removeAll()
            open.removeAll()
        }
        for (key, process) in processes where deviceID == nil || key.hasPrefix(deviceID! + "|") {
            closing.insert(key)
            if process.isRunning { process.terminate() }
        }
    }
}
