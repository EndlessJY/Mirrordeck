import AppKit
import SwiftUI

/// Visual style of the app. `.classic` remains the default so existing users
/// keep the familiar indigo palette until they switch in Settings.
enum AppThemeStyle: String, CaseIterable, Identifiable {
    case classic = "classic"
    case appleNative = "native"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典靛蓝（默认）"
        case .appleNative: return "Apple 原生通透"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "蓝紫渐变设备图标与经典紧凑卡片布局"
        case .appleNative: return "真实设备窄边框轮廓、通透材质表面与系统蓝点缀"
        }
    }
}

/// Optional light / dark override applied live across all app & mirror windows.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Reactive theme controller shared by all SwiftUI views, AppKit windows, and
/// helper `scrcpy` processes (via DistributedNotificationCenter).
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let styleKey = "ui.themeStyle"
    static let appearanceKey = "ui.appearanceMode"
    static let notificationName = Notification.Name("uk.agpt.lanadbmanager.theme")

    @Published var style: AppThemeStyle {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            broadcastToMirrors()
        }
    }

    @Published var appearanceMode: AppAppearanceMode {
        didSet {
            guard appearanceMode != oldValue else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
            broadcastToMirrors()
        }
    }

    var isAppleNative: Bool { style == .appleNative }

    private init() {
        let rawStyle = UserDefaults.standard.string(forKey: Self.styleKey) ?? ""
        self.style = AppThemeStyle(rawValue: rawStyle) ?? .classic
        let rawAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? ""
        self.appearanceMode = AppAppearanceMode(rawValue: rawAppearance) ?? .system
    }

    func applyAppearance() {
        let target = appearanceMode.nsAppearance
        let applyBlock = {
            NSApp?.appearance = target
            for window in NSApp?.windows ?? [] {
                window.appearance = target
            }
        }
        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    func broadcastToMirrors() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName,
            object: nil,
            userInfo: [
                "style": style.rawValue,
                "appearance": appearanceMode.rawValue,
            ],
            deliverImmediately: true
        )
    }
}

/// 幕台 Mirrordeck design tokens. System colours keep light and dark mode,
/// contrast settings and accessibility in step with macOS.
enum Theme {
    static var isAppleNative: Bool { ThemeStore.shared.isAppleNative }

    /// Brand accent: indigo in Classic, standard Apple System Blue in Apple Native.
    static var accent: Color {
        isAppleNative ? Color(nsColor: .systemBlue) : Color(nsColor: .systemIndigo)
    }
    static var accentSecondary: Color {
        isAppleNative ? Color(nsColor: .systemCyan) : Color(nsColor: .systemPurple)
    }
    static let online = Color(nsColor: .systemGreen)
    static let attention = Color(nsColor: .systemOrange)
    static let recording = Color(nsColor: .systemRed)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Cards sit one step above the page, like grouped settings.
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static var subtleFill: Color { Color.primary.opacity(0.04) }
    static var cardStroke: Color {
        Color(nsColor: .separatorColor).opacity(isAppleNative ? 0.45 : 0.55)
    }
    static var cardRadius: CGFloat { isAppleNative ? 13 : 12 }
    static let pagePadding: CGFloat = 28

    static let quick = Animation.snappy(duration: 0.22)
}

/// A rounded square holding an SF Symbol: the gradient style marks the device
/// itself, the tinted style marks secondary objects (connections, issues).
struct IconTile: View {
    enum Style { case gradient, tinted(Color), plain }
    let symbol: String
    var size: CGFloat = 28
    var style: Style = .tinted(Theme.accent)
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background(shape))
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .gradient:
            return theme.isAppleNative ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white)
        case .tinted(let color):
            return AnyShapeStyle(color)
        case .plain:
            return AnyShapeStyle(Color.white)
        }
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .gradient:
            if theme.isAppleNative {
                shape.fill(Theme.cardFill)
                    .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.05), radius: size * 0.08, y: size * 0.03)
            } else {
                shape.fill(Theme.brandGradient)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: Theme.accent.opacity(0.28), radius: size * 0.12, y: size * 0.05)
            }
        case .tinted(let color):
            shape.fill(color.opacity(theme.isAppleNative ? 0.11 : 0.13))
        case .plain:
            shape.fill(Color.white.opacity(theme.isAppleNative ? 0.20 : 0.22))
        }
    }
}

/// Narrow-bezel hardware silhouette badge for sidebar rows in Apple Native mode,
/// falling back to the tinted SF Symbol tile in Classic mode.
struct DeviceSidebarIcon: View {
    let device: ADBDevice
    @Environment(\.sidebarRowHighlighted) private var highlighted
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        if !theme.isAppleNative {
            IconTile(symbol: device.symbol, size: 30,
                     style: highlighted ? .plain : .tinted(Theme.accent))
        } else {
            let box = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let stroke = highlighted ? Color.white : Color.primary.opacity(0.82)
            let screenFill = highlighted ? Color.white.opacity(0.22) : Color.primary.opacity(0.06)
            ZStack {
                if device.emulator {
                    VStack(spacing: 0) {
                        HStack(spacing: 1.5) {
                            Circle().fill(stroke.opacity(0.6)).frame(width: 2, height: 2)
                            Circle().fill(stroke.opacity(0.6)).frame(width: 2, height: 2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 2.5)
                        .frame(height: 4.5)
                        Rectangle().fill(stroke.opacity(0.45)).frame(height: 0.8)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 1.1)
                            .frame(width: 6.5, height: 7)
                            .padding(.bottom, 1.5)
                    }
                    .frame(width: 18, height: 14)
                    .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(screenFill))
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1.35))
                } else if device.tv == true {
                    VStack(spacing: 1.5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(screenFill)
                            .frame(width: 18, height: 11.5)
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(stroke, lineWidth: 1.35))
                        Capsule().fill(stroke).frame(width: 8, height: 1.3)
                    }
                } else if device.isApple && device.deviceClass == "iPad" {
                    RoundedRectangle(cornerRadius: 2.8, style: .continuous)
                        .fill(screenFill)
                        .frame(width: 14, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 2.8, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 1.4))
                } else {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 2.8, style: .continuous)
                            .fill(screenFill)
                            .overlay(RoundedRectangle(cornerRadius: 2.8, style: .continuous)
                                .strokeBorder(stroke, lineWidth: 1.4))
                        if device.isApple {
                            Capsule()
                                .fill(stroke)
                                .frame(width: 4.2, height: 1.4)
                                .padding(.top, 2.4)
                        } else {
                            Circle()
                                .fill(stroke)
                                .frame(width: 1.7, height: 1.7)
                                .padding(.top, 2.4)
                        }
                    }
                    .frame(width: 11, height: 18.5)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                box.fill(highlighted ? Color.white.opacity(0.16) : Theme.cardFill)
            )
            .overlay(
                box.strokeBorder(
                    highlighted ? Color.white.opacity(0.24) : Theme.cardStroke,
                    lineWidth: 0.5
                )
            )
        }
    }
}

/// Realistic Xcode Devices / Apple Configurator hardware illustration for the
/// main device header card in Apple Native mode, falling back to the 64pt
/// gradient IconTile in Classic mode.
struct DeviceHeroIllustration: View {
    let device: ADBDevice
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !theme.isAppleNative {
            IconTile(symbol: device.symbol, size: 64, style: .gradient)
        } else if device.emulator {
            VStack(spacing: 0) {
                HStack(spacing: 3.5) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5.5, height: 5.5)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 5.5, height: 5.5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 15)
                Divider()
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.accent.opacity(colorScheme == .dark ? 0.20 : 0.11))
                    Text("AVD")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }
                .padding(6)
            }
            .frame(width: 60, height: 70)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 2)
        } else if device.tv == true {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(screenGradient)
                    .frame(width: 72, height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(bezelGradient, lineWidth: 2.5)
                    )
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 26, height: 3)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
        } else {
            let isPad = device.isApple && device.deviceClass == "iPad"
            let frameWidth: CGFloat = isPad ? 56 : 44
            let frameHeight: CGFloat = isPad ? 74 : 78
            let outerRadius: CGFloat = isPad ? 10 : 10.5
            let innerRadius: CGFloat = isPad ? 7.5 : 8
            ZStack {
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(bezelGradient)
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .fill(screenGradient)
                    .padding(2.4)
                    .overlay(alignment: .top) {
                        if !isPad {
                            if device.isApple {
                                Capsule()
                                    .fill(Color.black.opacity(0.82))
                                    .frame(width: 13, height: 3.6)
                                    .padding(.top, 6)
                            } else {
                                Circle()
                                    .fill(Color.black.opacity(0.82))
                                    .frame(width: 3.6, height: 3.6)
                                    .padding(.top, 6)
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 15, height: 1.6)
                            .padding(.bottom, 5.5)
                    }
            }
            .frame(width: frameWidth, height: frameHeight)
            .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
        }
    }

    private var bezelGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color(white: 0.42), Color(white: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(white: 0.84), Color(white: 0.63)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var screenGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.22, blue: 0.38),
                    Color(red: 0.09, green: 0.12, blue: 0.19),
                    Color(red: 0.07, green: 0.08, blue: 0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.85, green: 0.92, blue: 1.0),
                Color(red: 0.94, green: 0.97, blue: 1.0),
                Color.white,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Small capsule for facts such as "Android 16" or "79%".
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color?
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, theme.isAppleNative ? 9 : 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((tint ?? Color.secondary).opacity(theme.isAppleNative ? 0.11 : 0.12))
        )
        .overlay {
            if theme.isAppleNative && tint == nil {
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            }
        }
    }
}

/// Online indicator; a live mirror pulses gently.
struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        ZStack {
            if pulsing {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - (1 - phase) * (1 - phase)
                    let size = 7 + 8 * eased
                    Circle()
                        .stroke(color.opacity(0.55 * (1 - eased)), lineWidth: 1.5)
                        .frame(width: size, height: size)
                }
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
    }
}

/// A titled group of rows on a card, like System Settings.
struct Card<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder let content: Content
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    accessory
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
                .shadow(
                    color: theme.isAppleNative ? Color.black.opacity(0.03) : .clear,
                    radius: 5,
                    y: 1.5
                )
        }
    }
}

/// Divider inset to the text column of a card row.
struct CardDivider: View {
    var inset: CGFloat = 14
    var body: some View { Divider().padding(.leading, inset) }
}

/// Inline notice for a mirror error or progress message.
struct Banner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint = Theme.attention
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.1)))
        .overlay {
            if theme.isAppleNative {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
            }
        }
    }
}
