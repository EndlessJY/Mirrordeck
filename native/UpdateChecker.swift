import AppKit
import Foundation

/// Looks for a newer release on GitHub (each push to main publishes one).
/// Only reads the public "latest release" record; nothing is downloaded or
/// installed by itself.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let autoKey = "update.autoCheck"
    private static let lastCheckKey = "update.lastCheck"
    private static let api = URL(string: "https://api.github.com/repos/EndlessJY/Mirrordeck/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/EndlessJY/Mirrordeck/releases")!

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// A release newer than this app, once found.
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var status: String?

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
        check()
    }

    func check() {
        guard !checking else { return }
        checking = true
        status = nil
        var request = URLRequest(url: Self.api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mirrordeck", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { json -> Release? in
                    guard let tag = json["tag_name"] as? String,
                          let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                    return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
                }
            DispatchQueue.main.async {
                self.checking = false
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let release else {
                    self.status = error == nil ? "没有读到最新版本信息" : "无法连接 GitHub，请稍后再试"
                    return
                }
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    self.available = release
                    self.status = "有新版本 \(release.version)"
                } else {
                    self.available = nil
                    self.status = "已是最新版本（\(release.version)）"
                }
            }
        }.resume()
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
}
