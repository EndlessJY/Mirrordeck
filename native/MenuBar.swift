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
    static let toggleCaptureHistory = Notification.Name("uk.agpt.lanadbmanager.toggleCaptureHistory")
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
/// instead of opening another. Each time it opens it is fitted to the main
/// window — never wider or taller — and placed over it; pages that do not
/// fit scroll.
enum SettingsWindow {
    final class Layout: ObservableObject {
        @Published var width: CGFloat = 540
        /// Room for a page under the title and the tab icons.
        @Published var maxPageHeight: CGFloat = 560

        func pageHeight(_ natural: CGFloat) -> CGFloat { max(260, min(natural, maxPageHeight)) }
    }

    static let layout = Layout()
    /// Title bar and the row of tab icons above a page.
    private static let chrome: CGFloat = 110

    static func show(_ open: OpenSettingsAction) {
        let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        let bounds = main?.frame ?? (NSScreen.main?.visibleFrame.insetBy(dx: 80, dy: 60) ?? .zero)
        layout.width = min(540, max(420, bounds.width - 40))
        layout.maxPageHeight = max(260, bounds.height - chrome - 24)

        NSApp.activate()
        let existing = NSApp.windows.first { window in
            window.isVisible && (window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true)
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { place(existing, over: bounds) }
        } else {
            open()
            // The window exists once SwiftUI has laid it out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
                }) {
                    place(window, over: bounds)
                }
            }
        }
    }

    /// Centred horizontally over the main window, just below its top.
    private static func place(_ window: NSWindow, over bounds: NSRect) {
        guard bounds.width > 0 else { return }
        let size = window.frame.size
        var origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 12)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        window.setFrameOrigin(origin)
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

/// Overlay scroll bars everywhere in the app: thin, shown only while
/// scrolling, never taking width from the content. With a mouse connected
/// macOS would otherwise use permanent bars, which also squeezed the device
/// page under its right edge.
enum OverlayScrollers {
    static func install() {
        // The app-wide answer AppKit asks when it lays out any scroll view.
        if let original = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
           let replacement = class_getClassMethod(NSScroller.self, #selector(NSScroller.lanadb_preferredScrollerStyle)) {
            method_exchangeImplementations(original, replacement)
        }
        // And on each scroll view, for those that ask for themselves.
        if let original = class_getInstanceMethod(NSScrollView.self, #selector(getter: NSScrollView.scrollerStyle)),
           let replacement = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.lanadb_scrollerStyle)) {
            method_exchangeImplementations(original, replacement)
        }
    }
}

extension NSScroller {
    @objc class func lanadb_preferredScrollerStyle() -> NSScroller.Style { .overlay }
}

extension NSScrollView {
    @objc func lanadb_scrollerStyle() -> NSScroller.Style { .overlay }
}

/// Glass icon buttons drawn by the app in the title bar row, outside the
/// system toolbar: the toolbar re-lays itself out while the sidebar slides
/// (its buttons fade, shift, and a » overflow button can appear), these do not.
struct TitleBarIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .regular))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                           value: spinning)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.75))
        .help(help)
    }
}

/// One glass capsule around a few title bar icons (macOS 26 Liquid Glass,
/// a frosted capsule before that).
struct TitleBarGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let row = HStack(spacing: 2) { content }.padding(.horizontal, 3)
        if #available(macOS 26.0, *) {
            row.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            row.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

/// Recent captures and Settings, pinned to the right end of the main
/// window's title bar as an AppKit title bar accessory. Kept out of the
/// SwiftUI toolbar on purpose: toolbar items are re-laid out on every frame
/// of the sidebar animation (they drift, fade and collapse into a » menu),
/// while an accessory stays put and still takes clicks.
struct TitleBarTrailingButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.titlebarAccessoryViewControllers.contains(where: {
                $0.identifier == TitleBarTrailingButtons.id
            }) else { return }
            let host = NSHostingView(rootView: TitleBarTrailingContent())
            host.frame.size = host.fittingSize
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: host.fittingSize.width + 10, height: 40))
            host.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                host.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = TitleBarTrailingButtons.id
            accessory.layoutAttribute = .trailing
            accessory.view = holder
            window.addTitlebarAccessoryViewController(accessory)
        }
    }

    static let id = NSUserInterfaceItemIdentifier("uk.agpt.lanadbmanager.titlebarTrailing")
}

private struct TitleBarTrailingContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TitleBarGlassGroup {
            TitleBarIconButton(symbol: "photo.stack", help: "最近捕获：最近的截图、录屏和动图，可直接拖进聊天窗口") {
                NotificationCenter.default.post(name: .toggleCaptureHistory, object: nil)
            }
            .accessibilityLabel("最近捕获")
            TitleBarIconButton(symbol: "gearshape", help: "设置（⌘,）") {
                SettingsWindow.show(openSettings)
            }
            .accessibilityLabel("设置")
        }
        .padding(.vertical, 4)
    }
}
