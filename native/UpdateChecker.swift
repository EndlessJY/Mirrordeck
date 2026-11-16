import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Looks for a newer release on GitHub (each push to main publishes one),
/// shows what changed, and — only when the user says so — downloads it,
/// checks it against its published SHA-256, swaps it in and relaunches.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let autoKey = "update.autoCheck"
    private static let lastCheckKey = "update.lastCheck"
    /// The newest version already offered by an automatic check, so a daily
    /// check doesn't put the same offer up again.
    private static let promptedKey = "update.promptedVersion"
    private static let api = URL(string: "https://api.github.com/repos/EndlessJY/Mirrordeck/releases?per_page=30")!
    static let releasesPage = URL(string: "https://github.com/EndlessJY/Mirrordeck/releases")!
    private static let assetName = "Mirrordeck-macOS-arm64.zip"

    struct Release: Equatable {
        let version: String
        let page: URL
        let archive: URL?
        let checksum: URL?
        /// What changed since the running version, newest first, from every
        /// release in between.
        let changes: [String]
    }

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    /// A release newer than this app, once found.
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var status: String?
    @Published private(set) var phase: Phase = .idle
    /// The update panel is up in the main window.
    @Published var promptShown = false

    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Builds made on this Mac (not by the release pipeline) are "x.y.0".
    static var isLocalBuild: Bool { currentVersion.hasSuffix(".0") }

    /// At launch: at most once a day, when turned on, for released builds.
    func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoKey) as? Bool ?? true, !Self.isLocalBuild else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    /// A check the user asked for always shows the offer; an automatic one
    /// shows each new version once.
    func check(userInitiated: Bool = true) {
        guard !checking else { return }
        checking = true
        status = nil
        var request = URLRequest(url: Self.api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mirrordeck", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            let release = list.flatMap { Self.newest(in: $0, after: Self.currentVersion) }
            DispatchQueue.main.async {
                self.checking = false
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let list else {
                    self.status = error == nil ? "没有读到最新版本信息" : "无法连接 GitHub，请稍后再试"
                    return
                }
                guard let release else {
                    self.available = nil
                    let latest = list.compactMap(Self.version(of:)).max { Self.isNewer($1, than: $0) }
                    self.status = latest.map { "已是最新版本（\($0)）" } ?? "已是最新版本"
                    return
                }
                self.available = release
                self.status = "有新版本 \(release.version)"
                let defaults = UserDefaults.standard
                if userInitiated || defaults.string(forKey: Self.promptedKey) != release.version {
                    defaults.set(release.version, forKey: Self.promptedKey)
                    UpdatePrompt.show()
                }
            }
        }.resume()
    }

    private static func version(of json: [String: Any]) -> String? {
        guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// The newest release above `current`, carrying the changes of every
    /// release between the two.
    private static func newest(in list: [[String: Any]], after current: String) -> Release? {
        let newer = list.compactMap { json -> (String, [String: Any])? in
            guard let version = version(of: json), isNewer(version, than: current) else { return nil }
            return (version, json)
        }.sorted { isNewer($0.0, than: $1.0) }
        guard let (version, json) = newer.first,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        // Each release lists the commits since the one before it that
        // succeeded, so neighbours can repeat a line.
        var seen = Set<String>()
        let changes = newer.flatMap { changeLines($0.1["body"] as? String ?? "") }
            .filter { seen.insert($0).inserted }
        return Release(version: version, page: page, archive: asset(assetName),
                       checksum: asset(assetName + ".sha256"), changes: changes)
    }

    /// The "- …" lines of a release's notes.
    /// One item per change: a line that strings several together with "；"
    /// (as older releases did) is split into its parts.
    private static func changeLines(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- ") else { return [] }
            return text.dropFirst(2).split(separator: "；")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Where this copy of the app lives; the update replaces it there.
    private static var installedApp: URL { Bundle.main.bundleURL }

    /// The app can only replace itself where it may write.
    static var canReplaceItself: Bool {
        let app = installedApp
        let fm = FileManager.default
        return app.pathExtension == "app"
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: app.path)
    }

    func install() {
        guard let release = available, phase == .idle || isFailed else { return }
        guard let archive = release.archive, let checksum = release.checksum else {
            phase = .failed("这个版本没有可下载的安装包，请到 GitHub 下载")
            return
        }
        guard Self.canReplaceItself else {
            phase = .failed("没有权限替换 \(Self.installedApp.deletingLastPathComponent().path) 里的幕台，请到 GitHub 下载后手动替换")
            return
        }
        phase = .downloading(0)
        fetchChecksum(checksum) { [weak self] expected in
            guard let self else { return }
            guard let expected else { return self.fail("无法读取安装包校验值，请稍后再试") }
            let task = URLSession.shared.downloadTask(with: archive) { file, response, error in
                // The temporary file is gone once this handler returns.
                let kept = file.flatMap { try? Self.keep($0) }
                DispatchQueue.main.async {
                    self.progress = nil
                    self.download = nil
                    let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                    guard let kept, ok, error == nil else {
                        if (error as? URLError)?.code == .cancelled { return }
                        return self.fail("下载失败，请检查网络后重试")
                    }
                    self.phase = .installing
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Self.prepare(archive: kept, expected: expected, version: release.version)
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let app): self.relaunch(into: app)
                            case .failure(let message): self.fail(message.text)
                            }
                        }
                    }
                }
            }
            self.progress = task.progress.observe(\.fractionCompleted) { progress, _ in
                DispatchQueue.main.async {
                    if case .downloading = self.phase { self.phase = .downloading(progress.fractionCompleted) }
                }
            }
            self.download = task
            task.resume()
        }
    }

    func cancel() {
        download?.cancel()
        download = nil
        progress = nil
        phase = .idle
    }

    func resetFailure() { if isFailed { phase = .idle } }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) { phase = .failed(message) }

    private func fetchChecksum(_ url: URL, done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let text = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
            let hash = text?.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
            DispatchQueue.main.async { done(hash?.count == 64 ? hash : nil) }
        }.resume()
    }

    private struct Failure: Error { let text: String }

    /// A folder of our own for one update, removed when it is done.
    private static let workFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Mirrordeck-update", isDirectory: true)

    private static func keep(_ file: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: workFolder)
        try fm.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let target = workFolder.appendingPathComponent(assetName)
        try fm.moveItem(at: file, to: target)
        return target
    }

    /// Checks the download and unpacks it next to itself.
    private static func prepare(archive: URL, expected: String, version: String) -> Result<URL, Failure> {
        guard let data = try? Data(contentsOf: archive, options: .mappedIfSafe) else {
            return .failure(Failure(text: "读取安装包失败"))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { return .failure(Failure(text: "安装包校验未通过，已放弃更新")) }
        let unpacked = workFolder.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        do { try ditto.run() } catch { return .failure(Failure(text: "解压安装包失败")) }
        ditto.waitUntilExit()
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard ditto.terminationStatus == 0, let app = apps.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { return .failure(Failure(text: "安装包内容不对，已放弃更新")) }
        try? FileManager.default.removeItem(at: archive)
        return .success(app)
    }

    /// Hands the swap to a small script that waits for this app to quit,
    /// puts the new copy in its place (the old one is deleted, not kept),
    /// and opens it. If the move fails the old copy goes back.
    private func relaunch(into app: URL) {
        let target = Self.installedApp
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        old="$4/old.app"
        /bin/rm -rf "$old"
        if /bin/mv "$2" "$old" && /bin/mv "$3" "$2"; then
          /bin/rm -rf "$old"
        else
          [ -d "$old" ] && [ ! -d "$2" ] && /bin/mv "$old" "$2"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /usr/bin/open "$2"
        /bin/rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             target.path, app.path, Self.workFolder.path]
        do { try process.run() } catch { return fail("无法启动安装，请稍后再试") }
        // macOS refuses to quit while a sheet is up (this panel is one), and
        // the swap waits for the quit: close every sheet first.
        promptShown = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}

/// The offer of a new version: what changed, and the user's choice to
/// update now or later.
/// The offer of a new version, as a panel inside the main window (on the
/// same frosted glass as the app's other panels).
enum UpdatePrompt {
    static func show() {
        NSApp.activate()
        // The main window shows it; it opens with the panel if it was closed.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
        UpdateChecker.shared.promptShown = true
    }

    static func close() {
        UpdateChecker.shared.resetFailure()
        UpdateChecker.shared.promptShown = false
    }
}

struct UpdatePromptView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var mirror = MirrorStore.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(updates.available.map { "幕台 \($0.version) 可用" } ?? "已是最新版本")
                        .font(.title3.weight(.semibold))
                    Text("当前版本 \(UpdateChecker.currentVersion)")
                        .foregroundStyle(.secondary)
                }
            }
            if let release = updates.available {
                Text("更新内容").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(release.changes.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•").foregroundStyle(.secondary)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if release.changes.isEmpty {
                            Text("这个版本没有附带更新说明").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(minHeight: 80, idealHeight: 210, maxHeight: 210)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                footer(release)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .secondaryPanelSize(width: 460)
    }

    @ViewBuilder
    private func footer(_ release: UpdateChecker.Release) -> some View {
        switch updates.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                HStack {
                    Text("正在下载… \(Int(fraction * 100))%").foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { updates.cancel() }
                }
            }
        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text("正在安装，完成后幕台会自动重新打开").foregroundStyle(.secondary)
            }
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                if case .failed(let message) = updates.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mirror.windowCount > 0 {
                    Text("更新时幕台会重新打开，正在进行的投屏会被关闭")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("在 GitHub 查看") { NSWorkspace.shared.open(release.page) }
                    Spacer()
                    Button("稍后") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("立即更新") { updates.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
        }
    }
}
