import SwiftUI
import AppKit

/// Dark, minimal "future-retro" console palette: near-black blue panels,
/// warm amber and peach accents, cool periwinkle and lilac secondaries,
/// rounded pill shapes and condensed uppercase labels.
enum Palette {
    static let background = NSColor(hex: 0x05070D)
    static let panel = NSColor(hex: 0x0A0F1C)
    static let panelRaised = NSColor(hex: 0x111A2E)
    static let rule = NSColor(hex: 0x1C2742)
    static let lane = NSColor(hex: 0x080C17)

    /// Selection and focus only ("you are here"). Never a timing status.
    static let amber = NSColor(hex: 0xFF9D4A)
    /// Timing status "near the limit": a pale LCARS gold, kept well apart from amber.
    static let gold = NSColor(hex: 0xFFCC66)
    static let peach = NSColor(hex: 0xFFC994)
    static let lilac = NSColor(hex: 0xC49BDB)
    static let periwinkle = NSColor(hex: 0x8EA1FF)
    static let red = NSColor(hex: 0xE8665A)
    static let teal = NSColor(hex: 0x5FCFC0)

    static let text = NSColor(hex: 0xE6EAF4)
    static let textDim = NSColor(hex: 0x7A86A5)
    static let textFaint = NSColor(hex: 0x465170)

    static func status(_ s: TimingStatus) -> NSColor {
        switch s {
        case .ok: return periwinkle
        case .warn: return gold
        case .bad: return red
        }
    }
}

enum Theme {
    static let background = Color(nsColor: Palette.background)
    static let panel = Color(nsColor: Palette.panel)
    static let panelRaised = Color(nsColor: Palette.panelRaised)
    static let rule = Color(nsColor: Palette.rule)
    static let amber = Color(nsColor: Palette.amber)
    static let gold = Color(nsColor: Palette.gold)
    static let peach = Color(nsColor: Palette.peach)
    static let lilac = Color(nsColor: Palette.lilac)
    static let periwinkle = Color(nsColor: Palette.periwinkle)
    static let red = Color(nsColor: Palette.red)
    static let teal = Color(nsColor: Palette.teal)
    static let text = Color(nsColor: Palette.text)
    static let textDim = Color(nsColor: Palette.textDim)
    static let textFaint = Color(nsColor: Palette.textFaint)

    static func status(_ s: TimingStatus) -> Color { Color(nsColor: Palette.status(s)) }

    /// Condensed rounded label face used for headings and readouts.
    static func label(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).width(.condensed)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Uppercase, letter-spaced label.
struct ConsoleLabel: View {
    let text: String
    var color: Color = Theme.textDim
    var size: CGFloat = 10

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(size, .bold))
            .tracking(1.6)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A pane header: a rounded colour cap, a label, and a thin rule.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var color: Color = Theme.amber
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(color).frame(width: 22, height: 10)
            ConsoleLabel(text: title, color: color, size: 10)
            Rectangle().fill(Theme.rule).frame(height: 1)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, color: Color = Theme.amber) {
        self.title = title
        self.color = color
        self.trailing = { EmptyView() }
    }
}

/// A small pill readout, e.g. "14.2 CPS".
struct Chip: View {
    let text: String
    var color: Color = Theme.textDim
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.label(10, .bold))
            .tracking(0.6)
            .foregroundStyle(filled ? Theme.background : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.12))
            )
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.35), lineWidth: 1))
    }
}

/// Pill-shaped console button.
/// A console capsule. The primary one is filled; `secondary` (Cancel and the like) is
/// the same shape and type, outlined.
struct ConsoleButtonStyle: ButtonStyle {
    var color: Color = Theme.amber
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(11, .bold))
            .tracking(1.2)
            .foregroundStyle(secondary ? color : Theme.background)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(Capsule().fill(secondary
                ? color.opacity(configuration.isPressed ? 0.25 : 0.08)
                : color.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(Capsule().stroke(secondary ? color.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Capsule())
    }
}

extension SpotTimerStatus {
    var nsColor: NSColor {
        switch self {
        case .short, .near: return Palette.gold
        case .ok: return Palette.periwinkle
        case .over: return Palette.red
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

/// The spotting timer: a small console readout, filled with its status colour.
struct SpotTimerPill: View {
    let text: String
    let status: SpotTimerStatus
    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(Theme.background.opacity(0.55)).frame(width: 6, height: 8)
            Text(text).font(Theme.mono(11, .bold)).tracking(0.5)
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 7)
        .frame(height: 16)
        .background(Capsule().fill(status.color))
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: status)
    }
}
