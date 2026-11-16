import AppKit
import SwiftUI

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
    static let notificationName = Notification.Name("uk.agpt.mirrordeck.theme")

    @Published var appearanceMode: AppAppearanceMode {
        didSet {
            guard appearanceMode != oldValue else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
            broadcastToMirrors()
        }
    }

    private init() {
        // The removed second theme ("Apple 原生通透") leaves no setting behind.
        UserDefaults.standard.removeObject(forKey: Self.styleKey)
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
                "style": "classic",
                "appearance": appearanceMode.rawValue,
            ],
            deliverImmediately: true
        )
    }
}

/// 幕台 Mirrordeck design tokens. System colours keep light and dark mode,
/// contrast settings and accessibility in step with macOS.
enum Theme {
    /// Brand accent: indigo.
    static var accent: Color { Color(nsColor: .systemIndigo) }
    static var accentSecondary: Color { Color(nsColor: .systemPurple) }
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
        Color(nsColor: .separatorColor).opacity(0.55)
    }
    static var cardRadius: CGFloat { 12 }
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
            return AnyShapeStyle(Color.white)
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
            shape.fill(Theme.brandGradient)
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: Theme.accent.opacity(0.28), radius: size * 0.12, y: size * 0.05)
        case .tinted(let color):
            shape.fill(color.opacity(0.13))
        case .plain:
            shape.fill(Color.white.opacity(0.22))
        }
    }
}

/// Small capsule for facts such as "Android 16" or "79%".
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((tint ?? Color.secondary).opacity(0.12))
        )
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
    /// A top-level title (like “设备信息”) instead of a group's.
    var prominent = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        if prominent {
                            Text(title).font(.headline)
                        } else {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    accessory
                }
                .padding(.horizontal, prominent ? 0 : 4)
                .padding(.bottom, prominent ? 4 : 0)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5))

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
    }
}

/// A grey placeholder with a light sweeping across it: shown where content
/// is still being read, instead of a spinner or "读取中".
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
            .modifier(Shimmer())
            .accessibilityLabel("正在读取")
    }
}

/// The sweep of a skeleton: a soft highlight crossing it every 1.4 s.
struct Shimmer: ViewModifier {
    @State private var moving = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.45), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: moving ? proxy.size.width : -proxy.size.width * 0.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { moving = true }
            }
    }
}

/// Rows of skeleton lines in a card, for a list still being read.
struct SkeletonCard: View {
    var title: Bool = true
    var rows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title { SkeletonBlock(width: 56, height: 11).padding(.horizontal, 4) }
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    if index > 0 { CardDivider() }
                    HStack {
                        SkeletonBlock(width: 54, height: 11)
                        Spacer()
                        SkeletonBlock(width: CGFloat([120, 90, 140, 70, 110][index % 5]), height: 11)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        }
    }
}
