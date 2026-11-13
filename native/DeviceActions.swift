import Foundation

enum DeviceActions {
    /// Saves a full-size screenshot taken by the device. When the device blocks
    /// `screencap` (some TVs), the frame the mirror showed is used instead.
    /// `frameOnly` (single-app windows on a virtual display, which the
    /// device's own screencap cannot reach) saves the mirror's frame directly.
    static func saveScreenshot(of device: ADBDevice, serial: String? = nil, fallback: URL? = nil,
                               title: String? = nil, frameOnly: Bool = false,
                               completion: @escaping (URL?, String?) -> Void) {
        guard let endpoint = serial ?? MirrorStore.preferredTransports(for: device).first?.endpoint else {
            completion(nil, "设备未连接，无法截图。")
            return
        }
        guard let destination = destination(for: device, kind: "截图", extension: "png",
                                            title: title) else {
            completion(nil, "保存位置无法写入，请在设置中更换。")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = frameOnly ? (fallback == nil ? "无法读取窗口画面。" : "无法保存截图。") :
                capture(serial: endpoint, destination: destination)
            if let fallback {
                if outcome != nil, (try? FileManager.default.moveItem(at: fallback, to: destination)) != nil {
                    outcome = nil
                } else {
                    try? FileManager.default.removeItem(at: fallback)
                }
            }
            DispatchQueue.main.async { completion(outcome == nil ? destination : nil, outcome) }
        }
    }

    /// "p3" when the device currently renders its screen in Display P3 (or a
    /// wider gamut), otherwise "srgb".
    static func displayGamut(serial: String) -> String {
        guard let adb = Bundle.main.resourceURL?.appendingPathComponent("Tools/adb") else { return "srgb" }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial, "shell",
                             "dumpsys SurfaceFlinger | grep -m1 'Current color mode'"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "srgb" }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        timeout.cancel()
        let wide = ["DISPLAY_P3", "DCI_P3", "BT2020", "BT2100"]
        return wide.contains { text.contains($0) } ? "p3" : "srgb"
    }

    /// Temporary files of earlier sessions (snapshots, posters, GIF sources).
    static func removeTemporaryFiles() {
        let folder = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("lanadb-snapshot-") || name.hasPrefix("lanadb-poster-")
            || name.hasPrefix("lanadb-gif-") || name.hasPrefix("lanadb-icon-") || name.hasPrefix("lanadb-ios-")
            || name.hasPrefix("lan-adb-scrcpy-") || name.hasPrefix("lan-adb-recording-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static let directoryKey = "capture.directory"

    /// The chosen folder, or the Desktop by default.
    static func saveDirectoryURL(_ path: String? = nil) -> URL {
        let stored = path ?? UserDefaults.standard.string(forKey: directoryKey) ?? ""
        if !stored.isEmpty { return URL(fileURLWithPath: stored, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
    }

    static func screenshotDirectory() -> URL? { captureDirectory() }
    static func recordingDirectory() -> URL? { captureDirectory() }

    static func recordingDestination(for device: ADBDevice, title: String? = nil) -> URL? {
        let format = UserDefaults.standard.string(forKey: RecordingSettings.formatKey) ?? "mp4"
        return destination(for: device, kind: "录屏", extension: format == "mkv" ? "mkv" : "mp4",
                           title: title)
    }

    /// The animated capture: GIF, or animated WebP when chosen in Settings.
    static func gifDestination(for device: ADBDevice, title: String? = nil) -> URL? {
        RecordingSettings.animatedIsWebP ?
            destination(for: device, kind: "WebP", extension: "webp", title: title) :
            destination(for: device, kind: "GIF", extension: "gif", title: title)
    }

    /// "Xiaomi Civi 4 Pro 截图 2026-11-07 21.53.11.png", like macOS screenshots.
    /// `title` replaces the device name (a single-app window: "计算器 · 设备名").
    static func destination(for device: ADBDevice, kind: String, extension ext: String,
                            title: String? = nil) -> URL? {
        guard let directory = captureDirectory() else { return nil }
        let base = "\(safeName(title ?? device.title)) \(kind) \(fileTimestamp())"
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    private static func captureDirectory() -> URL? {
        let directory = saveDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private static func safeName(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func capture(serial: String, destination: URL) -> String? {
        guard let resources = Bundle.main.resourceURL else { return "应用资源缺失。" }
        let adb = resources.appendingPathComponent("Tools/adb")
        guard FileManager.default.isExecutableFile(atPath: adb.path) else {
            return "应用内的 ADB 缺失。"
        }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 15, execute: timeout)
            defer { timeout.cancel() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                let detail = String(data: diagnostic, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return detail.isEmpty ? "截图失败，请检查设备连接。" : "截图失败：\(detail)"
            }
            try bytes.write(to: destination, options: .atomic)
            return nil
        } catch {
            return "截图失败：\(error.localizedDescription)"
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// Recording and GIF quality chosen in Settings.
enum RecordingSettings {
    static let qualityKey = "record.quality"
    static let formatKey = "record.format"
    static let audioKey = "record.audio"
    static let gifQualityKey = "gif.quality"
    /// "gif" or "webp": the file format of the GIF button's capture.
    static let animatedFormatKey = "anim.format"

    static var animatedIsWebP: Bool {
        (UserDefaults.standard.string(forKey: animatedFormatKey) ?? "webp") == "webp"
    }

    struct Video {
        let maxSize: Int
        let bitrateMbps: Int
        let fps: Int
    }

    /// nil means "same as the mirror".
    static func video() -> Video? {
        switch UserDefaults.standard.string(forKey: qualityKey) ?? "standard" {
        case "high": return Video(maxSize: 0, bitrateMbps: 16, fps: 60)
        case "compact": return Video(maxSize: 1280, bitrateMbps: 4, fps: 30)
        case "mirror": return nil
        default: return Video(maxSize: 1920, bitrateMbps: 8, fps: 60)
        }
    }

    static var recordsAudio: Bool {
        UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true
    }

    static func gif() -> GIFOptions {
        GIFOptions.preset(UserDefaults.standard.string(forKey: gifQualityKey) ?? "standard")
    }
}
