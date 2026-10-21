import SwiftUI

// Solid, white, no materials. Every color here is opaque on purpose.
enum Theme {
    static let bg = Color.white
    static let subtle = Color(hex: 0xF5F5F7)
    static let hover = Color(hex: 0xF3F4F6)
    static let line = Color(hex: 0xECECEF)
    static let lineStrong = Color(hex: 0xDEDEE3)
    static let text = Color(hex: 0x111827)
    static let text2 = Color(hex: 0x6B7280)
    static let text3 = Color(hex: 0x9CA3AF)
    static let accent = Color(hex: 0x2563EB)
    static let accentSoft = Color(hex: 0xEEF3FF)

    static let green = Color(hex: 0x15803D), greenSoft = Color(hex: 0xEAF7EE)
    static let amber = Color(hex: 0xB45309), amberSoft = Color(hex: 0xFFF4E0)
    static let red = Color(hex: 0xDC2626), redSoft = Color(hex: 0xFEF0F0)

    static let barApp = Color(hex: 0x3B82F6)
    static let barWired = Color(hex: 0xF59E0B)
    static let barCompressed = Color(hex: 0x8B5CF6)
    static let barCache = Color(hex: 0x5EEAD4)
    static let barFree = Color(hex: 0xEDEEF1)

    static let radius: CGFloat = 10
    static let pagePadding: CGFloat = 24
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension Safety {
    var fg: Color { switch self { case .safe: Theme.green; case .caution: Theme.amber; case .danger: Theme.red } }
    var soft: Color { switch self { case .safe: Theme.greenSoft; case .caution: Theme.amberSoft; case .danger: Theme.redSoft } }
}

extension ProcCategory {
    var fg: Color {
        switch self {
        case .dev: Color(hex: 0x6D28D9)
        case .ai: Color(hex: 0xBE185D)
        case .browser: Color(hex: 0x1D4ED8)
        case .apps: Color(hex: 0x0F766E)
        case .system: Color(hex: 0x4B5563)
        }
    }

    var soft: Color {
        switch self {
        case .dev: Color(hex: 0xF3EFFE)
        case .ai: Color(hex: 0xFDF0F6)
        case .browser: Color(hex: 0xEEF3FF)
        case .apps: Color(hex: 0xEAF7F5)
        case .system: Color(hex: 0xF3F4F6)
        }
    }
}

// MARK: - Buttons

struct AppButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger, dangerSoft, quiet }
    var kind: Kind = .normal
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, large: large)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let (fg, fill, stroke): (Color, Color, Color) = {
                switch kind {
                case .normal: (Theme.text, hovering ? Theme.hover : Theme.bg, Theme.lineStrong)
                case .primary: (.white, Theme.accent, Theme.accent)
                case .danger: (.white, Theme.red, Theme.red)
                case .dangerSoft: (Theme.red, hovering ? Color(hex: 0xFDE3E3) : Theme.redSoft, Theme.redSoft)
                case .quiet: (Theme.text2, hovering ? Theme.hover : .clear, .clear)
                }
            }()
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, large ? 16 : 11)
                .frame(height: large ? 34 : 26)
                .foregroundStyle(fg)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 1))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var app: AppButtonStyle { AppButtonStyle() }
    static var primary: AppButtonStyle { AppButtonStyle(kind: .primary, large: true) }
    static var danger: AppButtonStyle { AppButtonStyle(kind: .danger) }
    static var dangerSoft: AppButtonStyle { AppButtonStyle(kind: .dangerSoft) }
    static var quiet: AppButtonStyle { AppButtonStyle(kind: .quiet) }
}

/// Small square icon button (reveal in Finder, expand, kill one process).
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = Theme.text2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Chips, tags, badges

struct Chip: View {
    let title: String
    var value: String? = nil
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let value { Text(value).font(.system(size: 12.5)).foregroundStyle(selected ? Theme.accent.opacity(0.75) : Theme.text3).monospacedDigit() }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(selected ? Theme.accentSoft : hovering ? Theme.hover : Theme.bg))
            .overlay(Capsule().strokeBorder(selected ? Theme.accentSoft : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Tag: View {
    let text: String
    var fg: Color = Theme.text2
    var bg: Color = Theme.subtle

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
            .fixedSize()
    }
}

// MARK: - Layout helpers

/// Wraps children onto new lines instead of squeezing them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bounds.width { y += lineH + lineSpacing; x = 0; lineH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/// Page intro: title line, explanation, optional controls on the right (they wrap below on narrow windows).
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) { texts; Spacer(minLength: 12); trailing() }
            VStack(alignment: .leading, spacing: 14) { texts; HStack(spacing: 10) { trailing() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Bottom action bar with a hairline on top.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 12) { content() }
                .padding(.horizontal, Theme.pagePadding)
                .frame(minHeight: 60)
        }
        .background(Theme.bg)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius + 2).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Solid "working..." pill used while scanning.
struct BusyPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().fill(Theme.bg))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

/// Empty state with a single call to action.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(Theme.text3)
                .frame(width: 64, height: 64).background(Circle().fill(Theme.subtle))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) { actions() }.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

extension View {
    /// White list, no vibrancy, roomy rows.
    func cleanList() -> some View {
        self.listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .environment(\.defaultMinListRowHeight, 52)
    }

    func cleanRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 10, leading: Theme.pagePadding, bottom: 10, trailing: Theme.pagePadding))
            .listRowSeparatorTint(Theme.line)
            .listRowBackground(Theme.bg)
    }
}

struct SectionTitle: View {
    let title: String
    var symbol: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4)
            Spacer()
            if let value { Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit() }
        }
        .foregroundStyle(Theme.text2)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
