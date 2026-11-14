import AppKit
import Foundation

/// Mirror settings kept for one device. nil follows the global setting.
struct DevicePrefs: Codable, Equatable {
    var maxSize: Int?
    var maxFPS: Int?
    var audio: Bool?
    /// Start mirroring as soon as the device connects (or the app opens with
    /// it connected).
    var autoMirror = false

    var isDefault: Bool { self == DevicePrefs() }
}

final class DevicePrefsStore: ObservableObject {
    static let shared = DevicePrefsStore()
    private static let key = "device.prefs"

    @Published private(set) var all: [String: DevicePrefs] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: DevicePrefs].self, from: data) {
            all = saved
        }
    }

    func prefs(for id: String) -> DevicePrefs { all[id] ?? DevicePrefs() }

    func update(_ id: String, _ change: (inout DevicePrefs) -> Void) {
        var value = prefs(for: id)
        change(&value)
        all[id] = value.isDefault ? nil : value
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension MirrorOptions {
    /// The global settings with this device's own choices on top.
    static func current(for device: ADBDevice) -> MirrorOptions {
        let defaults = UserDefaults.standard
        var options = MirrorOptions(
            audio: defaults.object(forKey: "mirror.audio") as? Bool ?? true,
            maxSize: defaults.object(forKey: "mirror.maxSize") as? Int ?? 1920,
            maxFPS: defaults.object(forKey: "mirror.maxFPS") as? Int ?? 60,
            videoBitrateMbps: defaults.object(forKey: "mirror.videoBitrateMbps") as? Int ?? 8,
            audioBitrateKbps: defaults.object(forKey: "mirror.audioBitrateKbps") as? Int ?? 128,
            videoCodec: defaults.string(forKey: "mirror.videoCodec") ?? "h265")
        let prefs = DevicePrefsStore.shared.prefs(for: device.identity)
        if let value = prefs.maxSize { options.maxSize = value }
        if let value = prefs.maxFPS { options.maxFPS = value }
        if let value = prefs.audio { options.audio = value }
        return options
    }
}

/// Where each mirror window was last left, per device (and per app for
/// single-app windows). Stored in scrcpy's terms: the picture area's top-left
/// corner from the top-left of the main display, and its size, in points.
enum WindowPlaces {
    private static let key = "window.places"

    static func save(_ id: String, x: Int, y: Int, width: Int, height: Int) {
        guard width >= 200, height >= 200 else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        all[id] = [x, y, width, height]
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(_ id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        all = all.filter { $0.key != id && !$0.key.hasPrefix(id + "|") }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func has(_ id: String) -> Bool {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        return all.keys.contains { $0 == id || $0.hasPrefix(id + "|") }
    }

    /// scrcpy arguments for the saved place, when it is still on a screen
    /// (a display may have been unplugged since).
    static func arguments(_ id: String) -> [String] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        guard let place = all[id], place.count == 4,
              let primary = NSScreen.screens.first?.frame else { return [] }
        let rect = NSRect(x: CGFloat(place[0]), y: primary.maxY - CGFloat(place[1] + place[3]),
                          width: CGFloat(place[2]), height: CGFloat(place[3]))
        let visible = NSScreen.screens.contains { screen in
            let shared = screen.visibleFrame.intersection(rect)
            return shared.width >= 120 && shared.height >= 120
        }
        guard visible else { return [] }
        return ["--window-x=\(place[0])", "--window-y=\(place[1])",
                "--window-width=\(place[2])", "--window-height=\(place[3])"]
    }
}

/// Mirror settings that change the phone for the time of a session.
enum PhoneSettings {
    /// Keep the phone's screen on while it is mirrored (the phone's own
    /// timeout is restored afterwards). On by default.
    static let stayAwakeKey = "mirror.stayAwake"
    /// Turn the phone's screen off when its mirror is ended. Off by default.
    static let lockOnCloseKey = "mirror.lockOnClose"
    /// Do Not Disturb while recording, so notifications are not recorded.
    static let quietRecordingKey = "record.quietPhone"

    static var stayAwake: Bool { UserDefaults.standard.object(forKey: stayAwakeKey) as? Bool ?? true }
    static var lockOnClose: Bool { UserDefaults.standard.object(forKey: lockOnCloseKey) as? Bool ?? false }
    static var quietRecording: Bool {
        UserDefaults.standard.object(forKey: quietRecordingKey) as? Bool ?? true
    }
}

/// Do Not Disturb on the phone while it records. Only turned on when it was
/// off, and only turned off again by us; a phone recording in two windows
/// keeps it until both end.
enum PhoneQuiet {
    private static var counts: [String: Int] = [:]
    private static var turnedOn = Set<String>()
    private static let queue = DispatchQueue(label: "uk.agpt.lanadbmanager.quiet")

    static func begin(serial: String) {
        guard PhoneSettings.quietRecording else { return }
        queue.async {
            counts[serial, default: 0] += 1
            guard counts[serial] == 1 else { return }
            let mode = shell(serial, "settings get global zen_mode").trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == "0" {
                _ = shell(serial, "cmd notification set_dnd on")
                turnedOn.insert(serial)
            }
        }
    }

    static func end(serial: String) {
        queue.async {
            guard let count = counts[serial] else { return }
            if count > 1 {
                counts[serial] = count - 1
                return
            }
            counts.removeValue(forKey: serial)
            if turnedOn.remove(serial) != nil {
                _ = shell(serial, "cmd notification set_dnd off")
            }
        }
    }

    /// At quit: give every phone its notifications back.
    static func endAll() {
        queue.sync {
            for serial in turnedOn { _ = shell(serial, "cmd notification set_dnd off") }
            turnedOn.removeAll()
            counts.removeAll()
        }
    }

    private static func shell(_ serial: String, _ command: String) -> String {
        guard let adb = Bundle.main.resourceURL?.appendingPathComponent("Tools/adb") else { return "" }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial, "shell", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        timeout.cancel()
        return text
    }
}

extension IssueItem {
    /// Where each brand hides the tap-7-times entry for Developer options.
    static let developerOptionsHelp: [(String, String)] = [
        ("小米 / 红米", "设置 › 我的设备 › 全部参数与信息 › 连续点按“OS 版本”"),
        ("华为 / 荣耀", "设置 › 关于手机 › 连续点按“版本号”"),
        ("OPPO / 一加", "设置 › 关于本机 › 版本信息 › 连续点按“版本号”"),
        ("vivo / iQOO", "设置 › 系统管理 › 关于手机 › 连续点按“软件版本号”"),
        ("三星", "设置 › 关于手机 › 软件信息 › 连续点按“编译编号”"),
        ("其他 Android", "设置 › 关于手机 › 连续点按“版本号”"),
    ]
}
