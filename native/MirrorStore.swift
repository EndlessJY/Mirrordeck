import Foundation
import SwiftUI
import AppKit
import CryptoKit
import AVFoundation
import UniformTypeIdentifiers

struct MirrorOptions {
    var audio = true
    var maxSize = 1920
    var maxFPS = 60
    var videoBitrateMbps = 8
    var audioBitrateKbps = 128
    /// "h265" means H.265 when the device can encode it, H.264 otherwise.
    var videoCodec = "h265"
}

struct MirrorSession {
    let endpoint: String
    let transport: String
    let recording: Bool
    /// The mirror window is on screen (the title bar reported in).
    var ready = false
}

final class MirrorStore: ObservableObject {
    static let shared = MirrorStore()
    static let revealInFinderKey = "capture.revealInFinder"
    static let copyToClipboardKey = "capture.copyToClipboard"
    private var copyAutomatically: Bool {
        UserDefaults.standard.object(forKey: Self.copyToClipboardKey) as? Bool ?? true
    }
    private var revealAutomatically: Bool {
        UserDefaults.standard.object(forKey: Self.revealInFinderKey) as? Bool ?? false
    }
    private static let actionName = Notification.Name("uk.agpt.lanadbmanager.mirror.action")
    private static let stateName = Notification.Name("uk.agpt.lanadbmanager.mirror.state")

    @Published private(set) var sessions: [String: MirrorSession] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var messages: [String: String] = [:]
    /// Mirrors being prepared (the device's colour mode is being read).
    @Published private(set) var starting: Set<String> = []
    /// "p3" or "srgb": the device's current display colour mode.
    private var processes: [String: Process] = [:]
    private var recordingProcesses: [String: Process] = [:]
    private var recordingKinds: [String: String] = [:]
    private var recordingStops = Set<String>()
    private var expectedStops = Set<String>()
    private var startupRetries: [String: Int] = [:]
    /// Mirrors stopped because the device could not encode H.265; they are
    /// started again with H.264.
    private var h264Relaunches = Set<String>()
    private var startupTokens: [String: UUID] = [:]
    private var sessionTokens: [String: String] = [:]
    private var sessionDevices: [String: ADBDevice] = [:]
    private var sessionOptions: [String: MirrorOptions] = [:]
    /// Single-app windows ("identity|package") and the name their captures use.
    private var appWindowTitles: [String: String] = [:]
    /// A recording a single-app window is writing itself: its own virtual
    /// display cannot be captured by another process.
    private struct AppRecording {
        let kind: String
        let destination: URL
        let source: URL
    }
    private var appRecordings: [String: AppRecording] = [:]
    private var actionObserver: NSObjectProtocol?

    func mirrorExecutable(for device: ADBDevice) throws -> URL {
        let source = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/LANADBMirror.app", isDirectory: true)
        let sourceBinary = source.appendingPathComponent("Contents/MacOS/scrcpy")
        let binary = try Data(contentsOf: sourceBinary)
        let version = SHA256.hash(data: binary).prefix(5)
            .map { String(format: "%02x", Int($0)) }.joined()
        let identity = SHA256.hash(data: Data(device.identity.utf8)).prefix(8)
            .map { String(format: "%02x", Int($0)) }.joined()
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LAN ADB Manager/Mirrors",
                                  isDirectory: true)
        // The Dock shows the bundle's folder name, so the .app is named after
        // the device and kept in a folder keyed by device and build.
        let bundleName = Self.bundleName(for: device.title)
        let container = directory.appendingPathComponent("\(identity)-\(version)", isDirectory: true)
        let destination = container.appendingPathComponent("\(bundleName).app", isDirectory: true)
        let executable = destination.appendingPathComponent("Contents/MacOS/scrcpy")
        Self.removeStaleMirrors(in: directory, keeping: container, version: version)
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }

        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if let leftovers = try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil) {
            // A renamed device leaves its previous bundle here.
            leftovers.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let plist = staging.appendingPathComponent("Contents/Info.plist")
        let contents = try Data(contentsOf: plist)
        guard var info = try PropertyListSerialization.propertyList(
            from: contents, options: [], format: nil) as? [String: Any] else {
            throw WorkerError.failed("投屏程序包配置无效。")
        }
        info["CFBundleDisplayName"] = device.title
        info["CFBundleName"] = device.title
        info["CFBundleIdentifier"] = Self.bundleIdentifier(for: device)
        info["LSUIElement"] = false
        let updated = try PropertyListSerialization.data(fromPropertyList: info,
                                                           format: .xml, options: 0)
        try updated.write(to: plist, options: .atomic)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--deep", "--sign", "-", staging.path]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else {
            throw WorkerError.failed("无法签名设备专属投屏程序包。")
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return executable
    }

    static func bundleIdentifier(for device: ADBDevice) -> String {
        let identity = SHA256.hash(data: Data(device.identity.utf8)).prefix(8)
            .map { String(format: "%02x", Int($0)) }.joined()
        return "uk.agpt.lanadbmanager.mirror.\(identity)"
    }

    private static func bundleName(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "LANADBMirror" : cleaned
    }

    /// Deletes per-device copies built from an older scrcpy binary, plus the
    /// old hash-named bundles; each copy is about 60 MB.
    private static func removeStaleMirrors(in directory: URL, keeping container: URL,
                                           version: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != container.lastPathComponent {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            let isLegacyBundle = entry.pathExtension == "app"
            let isOldVersion = !name.hasSuffix("-" + version)
            if isLegacyBundle || isOldVersion {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private init() {
        actionObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.actionName, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleMirrorAction(notification)
        }
    }

    private func handleMirrorAction(_ notification: Notification) {
        guard let token = notification.userInfo?["token"] as? String,
              let action = notification.userInfo?["action"] as? String,
              let id = sessionTokens.first(where: { $0.value == token })?.key,
              let session = sessions[id], let device = sessionDevices[id],
              let process = processes[id], process.isRunning else { return }
        switch action {
        case "screenshot":
            notifyMirror(id: id, kind: "screenshot", success: true, message: "正在保存截图…")
            // The mirror may hand over the frame it showed, as a fallback.
            let fallback = (notification.userInfo?["path"] as? String).map { URL(fileURLWithPath: $0) }
                .flatMap { url -> URL? in
                    let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
                    return url.standardizedFileURL.deletingLastPathComponent().path == temporary &&
                        url.lastPathComponent.hasPrefix("lanadb-snapshot-") ? url : nil
                }
            DeviceActions.saveScreenshot(of: device, serial: session.endpoint,
                                         fallback: fallback, title: appWindowTitles[id],
                                         frameOnly: appWindowTitles[id] != nil) { [weak self] url, error in
                if let url {
                    self?.messages[id] = nil
                    self?.errors[id] = nil
                    // The mirror shows a thumbnail (click reveals the file); Finder
                    // opens by itself only when the user turned that on.
                    let copied = self?.copyAutomatically == true && Self.copyToClipboard(url)
                    self?.notifyMirror(id: id, kind: "screenshot", success: true, message: "",
                                       path: url.path, copied: copied)
                    if self?.revealAutomatically == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                            self?.revealCapture(url, deviceID: id)
                        }
                    }
                } else {
                    self?.notifyMirror(id: id, kind: "screenshot",
                                       success: false, message: error ?? "截图失败。")
                }
            }
        case "ready":
            if var current = sessions[id] {
                current.ready = true
                sessions[id] = current
            }
            // The mirror asks to come forward itself; while this app is active
            // it can also bring it forward, which macOS always allows.
            if NSApp.isActive {
                NSRunningApplication(processIdentifier: process.processIdentifier)?
                    .activate(options: [.activateAllWindows])
            }
        case "reveal":
            guard let path = notification.userInfo?["path"] as? String else { return }
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let folders = [DeviceActions.screenshotDirectory(), DeviceActions.recordingDirectory()]
                .compactMap { $0?.standardizedFileURL.path }
            // Only files this app saved may be revealed on request of the mirror.
            guard folders.contains(file.deletingLastPathComponent().path),
                  FileManager.default.fileExists(atPath: file.path) else { return }
            revealCapture(file, deviceID: id)
        case "record", "gif":
            // (A `where` clause would only guard the last pattern of the case.)
            if appWindowTitles[id] != nil {
                handleAppRecording(id: id, device: device, kind: action,
                                   info: notification.userInfo ?? [:])
                return
            }
            if let recorder = recordingProcesses[id] {
                guard recordingKinds[id] == action else { return }
                recordingStops.insert(id)
                messages[id] = "正在结束录制并保存文件…"
                if recorder.isRunning { recorder.terminate() }
            } else if let options = sessionOptions[id] {
                startRecording(id: id, device: device, session: session,
                               options: options, kind: action)
            }
        default:
            return
        }
    }

    private func notifyMirror(id: String, kind: String, success: Bool, message: String,
                              recording: Bool? = nil, path: String? = nil,
                              thumb: String? = nil, recordTo: String? = nil,
                              copied: Bool = false) {
        guard let token = sessionTokens[id] else { return }
        var info: [String: Any] = ["token": token, "kind": kind,
                                   "success": success, "message": message]
        if let recordTo { info["recordTo"] = recordTo }
        if copied { info["copied"] = true }
        if let recording { info["recording"] = recording }
        if let path { info["path"] = path }
        if let thumb { info["thumb"] = thumb }
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// H.265 halves recordings at the same quality. It is tried on devices
    /// not known to lack a hardware encoder; a quick failure falls back.
    static func hevcKey(_ device: ADBDevice) -> String { "record.hevc." + device.identity }

    private func startRecording(id: String, device: ADBDevice, session: MirrorSession,
                                options: MirrorOptions, kind: String) {
        let isGIF = kind == "gif"
        guard let destination = isGIF ? DeviceActions.gifDestination(for: device) :
                DeviceActions.recordingDestination(for: device) else {
            let message = "录屏目录无法创建，请在设置中更换目录。"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
            return
        }
        let url = isGIF ? FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-gif-\(UUID().uuidString).mp4") : destination
        guard let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true) else {
            let message = "应用内的录屏组件缺失。"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
            return
        }
        let scrcpy: URL
        do {
            scrcpy = try mirrorExecutable(for: device)
        } catch {
            let message = "无法准备设备专属投屏程序：\(error.localizedDescription)"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
            return
        }
        let adb = tools.appendingPathComponent("adb")
        let server = tools.appendingPathComponent("scrcpy-server")
        guard FileManager.default.isExecutableFile(atPath: scrcpy.path),
              FileManager.default.isExecutableFile(atPath: adb.path),
              FileManager.default.fileExists(atPath: server.path) else {
            let message = "应用内的 scrcpy、ADB 或设备端组件缺失。"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
            return
        }
        let recorder = Process()
        recorder.executableURL = scrcpy
        recorder.currentDirectoryURL = tools
        let hevcKnown = UserDefaults.standard.object(forKey: Self.hevcKey(device)) as? Bool
        let useHEVC = !isGIF && !device.emulator && hevcKnown != false
        var arguments = ["--serial=\(session.endpoint)", "--no-playback", "--no-control",
                         "--no-window", "--record=\(url.path)",
                         "--video-codec=\(isGIF ? options.videoCodec : useHEVC ? "h265" : "h264")"]
        if isGIF {
            // The GIF only needs its own size and rate: a small, silent source
            // keeps conversion quick.
            let gif = RecordingSettings.gif()
            arguments += ["--max-size=\(gif.maxSide)", "--max-fps=30",
                          "--video-bit-rate=8M", "--no-audio"]
        } else {
            let video = RecordingSettings.video()
            let maxSize = video?.maxSize ?? options.maxSize
            let bitrate = Double(video?.bitrateMbps ?? options.videoBitrateMbps)
            // H.265 reaches the same quality at about 60% of the H.264 rate.
            let kbps = Int((useHEVC ? bitrate * 0.6 : bitrate) * 1000)
            arguments += ["--max-fps=\(video?.fps ?? options.maxFPS)",
                          "--video-bit-rate=\(kbps)K",
                          "--audio-bit-rate=\(options.audioBitrateKbps)K"]
            if maxSize > 0 { arguments.append("--max-size=\(maxSize)") }
            // AAC rather than scrcpy's default Opus: chat apps (Feishu...) only
            // send an MP4 with AAC sound as a playable video, not as a file.
            arguments.append(RecordingSettings.recordsAudio ? "--audio-codec=aac" : "--no-audio")
        }
        recorder.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        environment["SCRCPY_SERVER_PATH"] = server.path
        environment["LANADB_GAMUT"] = "srgb"
        environment["PATH"] = "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment.removeValue(forKey: "ANDROID_SERIAL")
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        recorder.environment = environment
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-adb-recording-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            let message = "无法创建录屏诊断记录。"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
            return
        }
        recorder.standardOutput = logHandle
        recorder.standardError = logHandle
        let startedAt = Date()
        recorder.terminationHandler = { [weak self] finished in
            logHandle.closeFile()
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            DispatchQueue.main.async {
                guard let self, self.recordingProcesses[id] === finished else { return }
                self.recordingProcesses.removeValue(forKey: id)
                self.recordingKinds.removeValue(forKey: id)
                let requested = self.recordingStops.remove(id) != nil
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let success = requested && finished.terminationStatus == 0 && size > 0
                if useHEVC && !requested && Date().timeIntervalSince(startedAt) < 8 {
                    // No usable H.265 encoder: remember it and record in H.264.
                    UserDefaults.standard.set(false, forKey: Self.hevcKey(device))
                    try? FileManager.default.removeItem(at: url)
                    if let current = self.sessions[id], let options = self.sessionOptions[id] {
                        self.startRecording(id: id, device: device, session: current,
                                            options: options, kind: kind)
                    }
                    return
                }
                if useHEVC && success {
                    UserDefaults.standard.set(true, forKey: Self.hevcKey(device))
                }
                if let current = self.sessions[id] {
                    self.sessions[id] = MirrorSession(endpoint: current.endpoint,
                        transport: current.transport, recording: false, ready: current.ready)
                }
                if success && isGIF {
                    self.convertAnimation(id: id, kind: kind, source: url, destination: destination)
                } else if success {
                    self.finishCapture(id: id, kind: kind, destination: destination, error: nil)
                } else {
                    if isGIF { try? FileManager.default.removeItem(at: url) }
                    let detail = output.split(separator: "\n").suffix(2).joined(separator: " ")
                    self.finishCapture(id: id, kind: kind, destination: destination,
                                       error: "录制失败：\(detail)")
                }
            }
        }
        do {
            try recorder.run()
            recordingProcesses[id] = recorder
            recordingKinds[id] = kind
            sessions[id] = MirrorSession(endpoint: session.endpoint,
                                         transport: session.transport, recording: true,
                                         ready: session.ready)
            messages[id] = isGIF ? "正在录制 GIF。" : "正在录屏。"
            notifyMirror(id: id, kind: kind, success: true, message: "正在录制。",
                         recording: true)
        } catch {
            logHandle.closeFile()
            try? FileManager.default.removeItem(at: logURL)
            let message = "无法启动录屏：\(error.localizedDescription)"
            notifyMirror(id: id, kind: kind, success: false, message: message,
                         recording: false)
        }
    }

    /// Turns a recorded source video into the GIF or WebP, then saves it.
    private func convertAnimation(id: String, kind: String, source: URL, destination: URL) {
        let webp = destination.pathExtension == "webp"
        let busy = "正在生成 GIF…"
        messages[id] = busy
        notifyMirror(id: id, kind: kind, success: true, message: busy, recording: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let conversionError: String?
            do {
                let gif = RecordingSettings.gif()
                if webp {
                    try WebPConverter.convert(video: source, to: destination, options: gif)
                } else {
                    try GIFConverter.convert(video: source, to: destination, options: gif)
                }
                conversionError = nil
            } catch {
                conversionError = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: source)
            DispatchQueue.main.async {
                self.finishCapture(id: id, kind: kind, destination: destination,
                                   error: conversionError)
            }
        }
    }

    // MARK: Single-app windows

    func registerAppWindow(key: String, device: ADBDevice, transport: ADBTransport,
                           process: Process, token: String, options: MirrorOptions,
                           title: String) {
        processes[key] = process
        sessionTokens[key] = token
        sessionDevices[key] = device
        sessionOptions[key] = options
        sessions[key] = MirrorSession(endpoint: transport.endpoint, transport: transport.type,
                                      recording: false)
        appWindowTitles[key] = title
    }

    func unregisterAppWindow(key: String) {
        processes.removeValue(forKey: key)
        sessionTokens.removeValue(forKey: key)
        sessionDevices.removeValue(forKey: key)
        sessionOptions.removeValue(forKey: key)
        sessions.removeValue(forKey: key)
        appWindowTitles.removeValue(forKey: key)
        messages.removeValue(forKey: key)
        if let recording = appRecordings.removeValue(forKey: key), recording.kind == "gif" {
            try? FileManager.default.removeItem(at: recording.source)
        }
    }

    /// Start: picks the file and hands it to the window, which records its own
    /// stream. Stop: the window has finished the file ("finished").
    private func handleAppRecording(id: String, device: ADBDevice, kind: String,
                                    info: [AnyHashable: Any]) {
        let title = appWindowTitles[id]
        if let recording = appRecordings[id] {
            guard recording.kind == kind else { return }
            appRecordings.removeValue(forKey: id)
            if let current = sessions[id] {
                sessions[id] = MirrorSession(endpoint: current.endpoint, transport: current.transport,
                                             recording: false, ready: current.ready)
            }
            if info["failed"] as? String == "1" {
                try? FileManager.default.removeItem(at: recording.source)
                return
            }
            guard info["finished"] as? String == "1",
                  FileManager.default.fileExists(atPath: recording.source.path) else {
                try? FileManager.default.removeItem(at: recording.source)
                finishCapture(id: id, kind: kind, destination: recording.destination,
                              error: "录制失败，请重试。")
                return
            }
            if kind == "gif" {
                convertAnimation(id: id, kind: kind, source: recording.source,
                                 destination: recording.destination)
            } else {
                finishCapture(id: id, kind: kind, destination: recording.destination, error: nil)
            }
            return
        }
        let isGIF = kind == "gif"
        guard let destination = isGIF ? DeviceActions.gifDestination(for: device, title: title) :
                DeviceActions.recordingDestination(for: device, title: title) else {
            notifyMirror(id: id, kind: kind, success: false,
                         message: "保存位置无法写入，请在设置中更换。", recording: false)
            return
        }
        let source = isGIF ? FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-gif-\(UUID().uuidString).mp4") : destination
        appRecordings[id] = AppRecording(kind: kind, destination: destination, source: source)
        if let current = sessions[id] {
            sessions[id] = MirrorSession(endpoint: current.endpoint, transport: current.transport,
                                         recording: true, ready: current.ready)
        }
        notifyMirror(id: id, kind: kind, success: true, message: "正在录制。", recording: true,
                     recordTo: source.path)
    }

    private func finishCapture(id: String, kind: String, destination: URL, error: String?) {
        if let error {
            notifyMirror(id: id, kind: kind, success: false, message: error, recording: false)
            return
        }
        messages[id] = nil
        errors[id] = nil
        let reveal = revealAutomatically
        let copied = copyAutomatically && Self.copyToClipboard(destination)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A still of the recording for the thumbnail in the mirror window.
            let thumb = kind == "gif" ? destination : Self.posterFrame(for: destination)
            DispatchQueue.main.async {
                guard let self else { return }
                self.notifyMirror(id: id, kind: kind, success: true, message: "",
                                  recording: false, path: destination.path, thumb: thumb?.path,
                                  copied: copied)
                if reveal { self.revealCapture(destination, deviceID: id) }
            }
        }
    }

    /// Puts a saved capture on the clipboard the way Finder's Copy does, so
    /// pasting into a chat sends the file itself (a video as a playable video,
    /// a GIF or WebP as an animation). A screenshot also carries its PNG data,
    /// for apps that paste images but not files (Notes, Preview, documents);
    /// both live in one pasteboard item, so it pastes once.
    @discardableResult
    static func copyToClipboard(_ url: URL) -> Bool {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func posterFrame(for video: URL) -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                     actualTime: nil) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-poster-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    private func revealCapture(_ url: URL, deviceID id: String) {
        notifyMirror(id: id, kind: "reveal", success: true, message: "")
        // A background app may not activate Finder itself (macOS 14+ ignores
        // it), but `open -R` asks Launch Services, which brings Finder forward.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-R", url.path]
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        if (try? opener.run()) == nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// H.265 only where the device encodes it: emulators have just a software
    /// encoder that fails, and a device that failed once is remembered.
    static func effectiveCodec(_ codec: String, for device: ADBDevice) -> String {
        if codec == "h265",
           device.emulator || UserDefaults.standard.object(forKey: hevcKey(device)) as? Bool == false {
            return "h264"
        }
        return codec
    }

    static func preferredTransports(for device: ADBDevice) -> [ADBTransport] {
        device.transports.filter { $0.state == "已连接" }.sorted { left, right in
            func rank(_ transport: ADBTransport) -> Int {
                switch transport.type {
                case "USB": return 0
                case "模拟器": return 1
                default: return 2
                }
            }
            let first = rank(left)
            let second = rank(right)
            return first == second ? left.endpoint < right.endpoint : first < second
        }
    }

    func start(device: ADBDevice, options: MirrorOptions) {
        let id = device.identity
        guard processes[id] == nil, !starting.contains(id) else { return }
        let transports = Self.preferredTransports(for: device)
        guard let primary = transports.first else {
            errors[id] = "设备未连接，请先扫描或重新连接 ADB。"
            return
        }
        errors[id] = nil
        messages[id] = nil
        startupRetries[id] = 0
        let token = UUID()
        startupTokens[id] = token
        starting.insert(id)
        let fallback = transports.first { $0.type == "无线" && $0.endpoint != primary.endpoint }
        // Android's encoder converts the screen to sRGB before encoding (checked
        // against the device's own Display P3 screencap), so the mirror,
        // recordings and GIFs are all treated as sRGB.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.starting.remove(id)
            guard self.startupTokens[id] == token, self.processes[id] == nil else { return }
            self.launch(device: device, transport: primary, fallback: fallback,
                        options: options)
        }
    }

    private func launch(device: ADBDevice, transport: ADBTransport, fallback: ADBTransport?,
                        options: MirrorOptions) {
        let id = device.identity
        guard let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true) else {
            errors[id] = "应用缺少投屏组件，请重新安装。"
            return
        }
        let scrcpy: URL
        do {
            scrcpy = try mirrorExecutable(for: device)
        } catch {
            errors[id] = "无法准备设备专属投屏程序：\(error.localizedDescription)"
            return
        }
        let adb = tools.appendingPathComponent("adb")
        let server = tools.appendingPathComponent("scrcpy-server")
        guard FileManager.default.isExecutableFile(atPath: scrcpy.path),
              FileManager.default.isExecutableFile(atPath: adb.path),
              FileManager.default.fileExists(atPath: server.path) else {
            errors[id] = "应用内的 scrcpy、adb 或设备端组件缺失。"
            return
        }

        var options = options
        options.videoCodec = Self.effectiveCodec(options.videoCodec, for: device)
        let process = Process()
        process.executableURL = scrcpy
        process.currentDirectoryURL = tools
        var arguments = ["--serial=\(transport.endpoint)", "--window-title=\(device.title)",
                         "--max-fps=\(options.maxFPS)",
                         "--video-bit-rate=\(options.videoBitrateMbps)M",
                         "--audio-bit-rate=\(options.audioBitrateKbps)K",
                         "--video-codec=\(options.videoCodec)"]
        if options.maxSize > 0 { arguments.append("--max-size=\(options.maxSize)") }
        if !options.audio { arguments.append("--no-audio") }
        // Letters travel as text too, so a host input method (Pinyin...) never
        // leaks raw keys; the title bar build pastes non-ASCII text.
        arguments.append("--prefer-text")
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adb.path
        environment["LANADB_ADB"] = adb.path
        environment["LANADB_SERIAL"] = transport.endpoint
        let actionToken = UUID().uuidString
        environment["LANADB_SESSION_TOKEN"] = actionToken
        environment["LANADB_RECORDING"] = "0"
        environment["LANADB_AUDIO_ENABLED"] = options.audio ? "1" : "0"
        environment["LANADB_GAMUT"] = "srgb"
        environment["SCRCPY_SERVER_PATH"] = server.path
        environment["SCRCPY_ICON_DIR"] = tools.path
        environment["PATH"] = "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment.removeValue(forKey: "ANDROID_SERIAL")
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        process.environment = environment

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-adb-scrcpy-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            errors[id] = "无法创建投屏诊断记录。"
            return
        }
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] finished in
            logHandle.closeFile()
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            DispatchQueue.main.async {
                self?.didFinish(device: device, process: finished, transport: transport,
                                fallback: fallback, options: options,
                                output: output)
            }
        }
        // The mirror activates itself once its window is up; macOS only allows
        // that when the active app (this one, the user just clicked) yields.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: Self.bundleIdentifier(for: device))
        do {
            try process.run()
            processes[id] = process
            sessionTokens[id] = actionToken
            sessionDevices[id] = device
            sessionOptions[id] = options
            sessions[id] = MirrorSession(endpoint: transport.endpoint,
                                         transport: transport.type, recording: false)
            errors[id] = nil
            if options.videoCodec == "h265" {
                watchForEncoderFailure(id: id, device: device, process: process, log: logURL)
            }
        } catch {
            logHandle.closeFile()
            try? FileManager.default.removeItem(at: logURL)
            errors[id] = "无法启动投屏：\(error.localizedDescription)"
        }
    }

    private func didFinish(device: ADBDevice, process: Process, transport: ADBTransport,
                           fallback: ADBTransport?, options: MirrorOptions,
                           output: String) {
        let id = device.identity
        guard processes[id] === process else { return }
        processes.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        sessionTokens.removeValue(forKey: id)
        sessionDevices.removeValue(forKey: id)
        sessionOptions.removeValue(forKey: id)
        if h264Relaunches.remove(id) != nil {
            var options = options
            options.videoCodec = "h264"
            launch(device: device, transport: transport, fallback: fallback, options: options)
            return
        }
        if expectedStops.remove(id) != nil {
            startupRetries.removeValue(forKey: id)
            startupTokens.removeValue(forKey: id)
            return
        }
        if process.terminationStatus == 0 {
            startupRetries.removeValue(forKey: id)
            startupTokens.removeValue(forKey: id)
            return
        }
        if let fallback {
            launch(device: device, transport: fallback, fallback: nil,
                   options: options)
            return
        }
        let useful = output.split(separator: "\n").map(String.init)
            .filter { $0.contains("ERROR") || $0.contains("WARN") || $0.contains("failed") }
            .suffix(2).joined(separator: " ")
        if useful.localizedCaseInsensitiveContains("server connection failed") {
            let attempts = startupRetries[id] ?? 0
            if attempts < 1 {
                startupRetries[id] = attempts + 1
                let token = startupTokens[id]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.processes[id] == nil,
                          self.startupTokens[id] == token else { return }
                    self.launch(device: device, transport: transport, fallback: nil,
                                options: options)
                }
                return
            }
            errors[id] = "投屏启动时 ADB 连接中断，请检查设备连接后重试。"
        } else {
            errors[id] = useful.isEmpty ?
                "投屏已停止（退出码 \(process.terminationStatus)）。请检查 ADB 连接。" : useful
        }
        startupRetries.removeValue(forKey: id)
        startupTokens.removeValue(forKey: id)
    }

    /// When the device cannot encode H.265 the mirror keeps running without a
    /// picture, so its first seconds of output are checked for the encoder
    /// error; the mirror is then restarted with H.264.
    private func watchForEncoderFailure(id: String, device: ADBDevice, process: Process,
                                        log: URL, checks: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.processes[id] === process, process.isRunning else { return }
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let failed = output.split(separator: "\n").contains { line in
                line.contains("ERROR") && line.localizedCaseInsensitiveContains("encod")
            }
            if failed {
                UserDefaults.standard.set(false, forKey: Self.hevcKey(device))
                self.h264Relaunches.insert(id)
                process.terminate()
            } else if checks < 24 {
                self.watchForEncoderFailure(id: id, device: device, process: process,
                                            log: log, checks: checks + 1)
            }
        }
    }

    func stop(deviceID: String) {
        startupTokens.removeValue(forKey: deviceID)
        starting.remove(deviceID)
        if let recorder = recordingProcesses[deviceID] {
            recordingStops.insert(deviceID)
            if recorder.isRunning { recorder.terminate() }
        }
        guard let process = processes[deviceID] else { return }
        expectedStops.insert(deviceID)
        if process.isRunning { process.terminate() }
    }

    func stopAll() {
        startupTokens.removeAll()
        for id in processes.keys { stop(deviceID: id) }
    }
}
