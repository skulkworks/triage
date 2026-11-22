import AppKit
import SwiftUI

/// GitHub's state colors (Primer), light and dark.
enum GHColor {
    static let open = dynamic(light: 0x1A7F37, dark: 0x3FB950)
    static let done = dynamic(light: 0x8250DF, dark: 0xA371F7)
    static let closed = dynamic(light: 0xCF222E, dark: 0xF85149)
    static let muted = dynamic(light: 0x59636E, dark: 0x9198A1)
    static let attention = dynamic(light: 0x9A6700, dark: 0xD29922)
    static let accent = dynamic(light: 0x0969DA, dark: 0x4493F8)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hexString: String) {
        let v = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(nsColor: NSColor(hex: v))
    }
}

/// The icon and tint GitHub uses for a subject in a given state.
struct SubjectGlyph {
    var symbol: String
    var color: Color

    init(kind: SubjectKind, state: SubjectState?) {
        switch kind {
        case .issue:
            switch state {
            case .closed: symbol = "checkmark.circle"; color = GHColor.done
            case .notPlanned, .duplicate: symbol = "nosign"; color = GHColor.muted
            case .open: symbol = "smallcircle.filled.circle"; color = GHColor.open
            default: symbol = "smallcircle.filled.circle"; color = GHColor.muted
            }
        case .pullRequest:
            switch state {
            case .merged: symbol = "arrow.triangle.merge"; color = GHColor.done
            case .closed: symbol = "arrow.triangle.pull"; color = GHColor.closed
            case .draft: symbol = "arrow.triangle.pull"; color = GHColor.muted
            case .open: symbol = "arrow.triangle.pull"; color = GHColor.open
            default: symbol = "arrow.triangle.pull"; color = GHColor.muted
            }
        case .discussion:
            switch state {
            case .answered: symbol = "checkmark.bubble"; color = GHColor.open
            case .closed: symbol = "bubble.left.and.bubble.right"; color = GHColor.done
            default: symbol = "bubble.left.and.bubble.right"; color = GHColor.muted
            }
        case .release: symbol = "tag"; color = GHColor.open
        case .commit: symbol = "point.topleft.down.to.point.bottomright.curvepath"; color = GHColor.muted
        case .checkSuite, .workflowRun: symbol = "gearshape.2"; color = GHColor.attention
        case .advisory: symbol = "shield.lefthalf.filled"; color = GHColor.closed
        case .vulnerability, .dependabot: symbol = "exclamationmark.shield"; color = GHColor.attention
        case .other: symbol = "bell"; color = GHColor.muted
        }
    }
}

struct LabelChip: View {
    var name: String
    var color: String

    var body: some View {
        let c = Color(hexString: color)
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(c.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(c.opacity(0.55), lineWidth: 0.5))
            .foregroundStyle(.primary)
    }
}

struct StatePill: View {
    var kind: SubjectKind
    var state: SubjectState

    var body: some View {
        let glyph = SubjectGlyph(kind: kind, state: state)
        if !state.label.isEmpty {
            Label(state.label, systemImage: glyph.symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(glyph.color, in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

struct Avatar: View {
    var url: String?
    var size: CGFloat = 16

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0.contains("?") ? "\($0)&s=\(Int(size * 2))" : "\($0)?s=\(Int(size * 2))") }) { image in
            image.resizable().interpolation(.high)
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

extension Date {
    /// "3m", "2h", "5d", "Nov 3" — the inbox's compact time.
    var shortAgo: String {
        let s = -timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
