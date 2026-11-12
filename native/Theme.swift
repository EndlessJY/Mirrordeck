import AppKit
import SwiftUI

/// 幕台 Mirrordeck design tokens. System colours keep light and dark mode,
/// contrast settings and accessibility in step with macOS.
enum Theme {
    /// Brand accent: indigo, shared with the mirror window's title bar.
    static let accent = Color(nsColor: .systemIndigo)
    static let accentSecondary = Color(nsColor: .systemPurple)
    static let online = Color(nsColor: .systemGreen)
    static let attention = Color(nsColor: .systemOrange)
    static let recording = Color(nsColor: .systemRed)

    static let brandGradient = LinearGradient(
        colors: [accent, accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Cards sit one step above the page, like grouped settings.
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color(nsColor: .separatorColor).opacity(0.55)
    static let cardRadius: CGFloat = 12
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
        case .gradient: return AnyShapeStyle(Color.white)
        case .tinted(let color): return AnyShapeStyle(color)
        case .plain: return AnyShapeStyle(Color.white)
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
        .background(Capsule().fill((tint ?? Color.secondary).opacity(0.12)))
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
