import AppKit
import SwiftUI

/// The menu bar icon: each connected device with mirror, screenshot and log,
/// recent captures, arranging windows, and the main window — without opening
/// the main window first.
struct MenuBarContent: View {
    @ObservedObject private var store = DeviceStore.shared
    @ObservedObject private var mirror = MirrorStore.shared
    @ObservedObject private var iosMirror = IOSMirrorStore.shared
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var prefs = DevicePrefsStore.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var devices: [ADBDevice] { store.report?.devices.filter(\.connected) ?? [] }

    var body: some View {
        if devices.isEmpty {
            Text(store.report == nil ? "正在发现设备…" : "没有已连接的设备")
        }
        ForEach(devices) { device in
            Menu {
                deviceMenu(device)
            } label: {
                Label(isLive(device) ? "\(device.title)（投屏中）" : device.title,
                      systemImage: device.symbol)
            }
        }
        Divider()
        if !history.items.isEmpty {
            Menu("最近捕获") {
                ForEach(history.items.prefix(8), id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { CaptureHistory.reveal(url) }
                }
                Divider()
                Button("全部捕获…") {
                    showMainWindow()
                    NotificationCenter.default.post(name: .showCaptureHistory, object: nil)
                }
            }
        }
        Button("并排排列投屏窗口") { mirror.arrangeAllWindows() }
            .disabled(mirror.windowCount < 1)
        Divider()
        if let release = updates.available {
            Button("下载新版本 \(release.version)…") { NSWorkspace.shared.open(release.page) }
            Divider()
        }
        Button("打开幕台") { showMainWindow() }
        Button("设置…") { SettingsWindow.show(openSettings) }
        Divider()
        Button("退出幕台") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private func deviceMenu(_ device: ADBDevice) -> some View {
        if isLive(device) {
            Button("结束投屏") {
                device.isApple ? iosMirror.stop(deviceID: device.id) : mirror.stop(deviceID: device.id)
            }
        } else {
            Button("开始投屏") { MenuBarActions.mirror(device) }
        }
        if !device.isApple {
            Button("截图") { MenuBarActions.screenshot(device) }
        }
        Button("日志") {
            NSApp.activate()
            DeviceLogWindows.show(device)
        }
        Divider()
        Toggle("连接后自动投屏", isOn: Binding(
            get: { prefs.prefs(for: device.identity).autoMirror },
            set: { value in prefs.update(device.identity) { $0.autoMirror = value } }))
    }

    private func isLive(_ device: ADBDevice) -> Bool {
        device.isApple ? iosMirror.open.contains(device.id) : mirror.sessions[device.id] != nil
    }

    private func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

extension Notification.Name {
    static let showCaptureHistory = Notification.Name("uk.agpt.lanadbmanager.showCaptureHistory")
}

enum MenuBarActions {
    static func mirror(_ device: ADBDevice) {
        if device.isApple {
            IOSMirrorStore.shared.start(device: device)
        } else {
            MirrorStore.shared.start(device: device, options: .current(for: device))
        }
    }

    /// A screenshot without a mirror window: saved, copied as set in
    /// Settings, and confirmed by a small notice at the top of the screen.
    static func screenshot(_ device: ADBDevice) {
        DeviceActions.saveScreenshot(of: device) { url, error in
            guard let url else {
                QuickNotice.show(error ?? "截图失败", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
                return
            }
            CaptureHistory.shared.add(url)
            let copy = UserDefaults.standard.object(forKey: MirrorStore.copyToClipboardKey) as? Bool ?? true
            let copied = copy && MirrorStore.copyToClipboard(url)
            QuickNotice.show(copied ? "\(device.title) 已截图，已复制到剪贴板" : "\(device.title) 已截图",
                             symbol: "checkmark.circle.fill", tint: .systemGreen)
        }
    }
}

/// A short notice near the top of the screen, for actions taken from the
/// menu bar when no window of this app is in front.
enum QuickNotice {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, symbol: String, tint: NSColor) {
        hide?.cancel()
        panel?.orderOut(nil)
        let view = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Color(nsColor: tint))
                Text(text).foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .fixedSize())
        let size = view.fittingSize
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let window = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 14,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
        panel = window
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; window.animator().alphaValue = 0 },
                                                 completionHandler: { window.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

/// The menu bar icon (on by default). With it, closing the main window
/// leaves the app running there. Published only when this one setting
/// changes, not on every defaults write.
final class MenuBarSettings: ObservableObject {
    static let shared = MenuBarSettings()
    static let showKey = "menubar.show"
    static var show: Bool { UserDefaults.standard.object(forKey: showKey) as? Bool ?? true }

    @Published var shown: Bool {
        didSet {
            guard shown != oldValue else { return }
            UserDefaults.standard.set(shown, forKey: Self.showKey)
        }
    }
    private var observer: NSObjectProtocol?

    private init() {
        shown = Self.show
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.shown != Self.show else { return }
            self.shown = Self.show
        }
    }
}

/// One settings window: clicking “设置” again brings the open one forward
/// instead of opening another.
enum SettingsWindow {
    static func show(_ open: OpenSettingsAction) {
        NSApp.activate()
        let existing = NSApp.windows.first { window in
            window.isVisible && (window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true)
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
    }
}

/// macOS frosted glass (the material of sidebars and popovers): what is
/// behind the window shows through, blurred, and follows light / dark mode.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// A sheet on light, see-through frosted glass (the iOS look) instead of
    /// the opaque window colour.
    func glassPanel() -> some View {
        presentationBackground(.ultraThinMaterial)
    }

    /// The whole window on that glass: macOS 15 and later draw it as the
    /// window's own background; macOS 14 falls back to a frosted view.
    @ViewBuilder
    func glassWindow() -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(.ultraThinMaterial, for: .window)
        } else {
            background(GlassBackground(material: .popover).ignoresSafeArea())
        }
    }
}

/// Switches in the brand colour while everything else in the view keeps the
/// normal text colour (a view-wide tint also colours picker values).
struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Theme.accent)
    }
}
