#if os(macOS)
import SwiftUI

// MARK: - Theme

enum Theme {
    static let cornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let sidebarWidth: CGFloat = 220

    // MARK: Status colors

    static func color(for status: String) -> Color {
        switch status.lowercased() {
        case "active", "working": return .cyan
        case "completed":         return Color(red: 0.1, green: 0.82, blue: 0.48)
        case "error":             return Color(red: 1, green: 0.3, blue: 0.3)
        case "abandoned":         return Color(red: 0.9, green: 0.55, blue: 0.1)
        case "waiting":           return Color(red: 0.85, green: 0.78, blue: 0.1)
        default:                  return .secondary
        }
    }

    static func color(session status: Session.SessionStatus) -> Color { color(for: status.rawValue) }
    static func color(agent status: Agent.AgentStatus) -> Color { color(for: status.rawValue) }

    // MARK: Background gradients

    // Deep navy — the gold comes from accents, not the background.
    static let darkBackgroundGradient = LinearGradient(
        colors: [
            Color(red: 10/255, green: 12/255, blue: 20/255),
            Color(red: 13/255, green: 16/255, blue: 26/255),
            Color(red: 17/255, green: 20/255, blue: 32/255)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Soft white → blue/indigo.
    static let lightBackgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.95, green: 0.96, blue: 1.0),
            Color(red: 0.93, green: 0.95, blue: 1.0),
            Color(red: 0.96, green: 0.94, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Brand accent — WP Media gold (#FED23A)

    static let accent = Color(red: 254/255, green: 210/255, blue: 58/255)        // #FED23A
    static let accentHover = Color(red: 255/255, green: 223/255, blue: 90/255)   // #FFDF5A

    // Gold for *text/glyphs*: the brand gold has ~1.3:1 contrast on light glass,
    // so text usages get a darkened gold in light appearance while fills and
    // gradients keep the true brand color in both.
    static let accentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 254/255, green: 210/255, blue: 58/255, alpha: 1)  // #FED23A
            : NSColor(red: 0.58, green: 0.44, blue: 0.02, alpha: 1)          // #947005
    })

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 1, green: 0.886, blue: 0.478),   // #FFE27A
            accent,                                       // #FED23A
            Color(red: 0.788, green: 0.635, blue: 0.153) // #C9A227
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Gold gradient for chart bars.
    static let chartGradient = LinearGradient(
        colors: [accent, Color(red: 0.788, green: 0.635, blue: 0.153)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Formatting

    static func formatCost(_ value: Double) -> String {
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    static func formatTokens(_ n: Int) -> String {
        let m = Double(n) / 1_000_000
        if m >= 1 { return String(format: "%.2fM", m) }
        let k = Double(n) / 1_000
        if k >= 1 { return String(format: "%.1fK", k) }
        return "\(n)"
    }

    static func shortDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func projectName(from cwd: String?) -> String {
        guard let cwd else { return "Unknown" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

// MARK: - Adaptive background view
// The window-level NSVisualEffectView (see AppDelegate.applyVibrancy) provides
// the full .behindWindow frosted glass. On top of that this view paints the
// "Aurora Glass" ambient orbs (TASK 2.0b) — the same effect the web dashboard
// has: two large, soft, static radial glows the ultraThinMaterial glass cards
// pick up as a colour bleed. Gold on dark, blue→indigo on light, matching the
// brand palette. Static (no animation) for battery, non-interactive, and it
// falls back to nothing under the Reduce Transparency accessibility setting.
struct ThemeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Dark: gold #FED23A top-left, warm gold #FFDF5A bottom-right.
    // Light: blue #2563EB top-left, indigo #6366F1 bottom-right.
    // A RadialGradient (bright core → clear) is the orb: it produces its own
    // soft falloff, unlike a solid disc that a heavy blur would flatten into
    // nothing. Core opacity is high because the gradient fades it to zero.
    private var topCore: Color {
        colorScheme == .dark
            ? Color(red: 254/255, green: 210/255, blue: 58/255).opacity(0.55)
            : Color(red: 37/255, green: 99/255, blue: 235/255).opacity(0.38)
    }
    private var bottomCore: Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 223/255, blue: 90/255).opacity(0.38)
            : Color(red: 99/255, green: 102/255, blue: 241/255).opacity(0.32)
    }

    private func orb(_ core: Color, at point: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(
            gradient: Gradient(colors: [core, core.opacity(0)]),
            center: point,
            startRadius: 0,
            endRadius: radius
        )
        .ignoresSafeArea()
    }

    var body: some View {
        if reduceTransparency {
            Color.clear.ignoresSafeArea()
        } else {
            GeometryReader { geo in
                // Tighter radius = a concentrated glow in each corner that
                // reads through the window's .behindWindow vibrancy, rather
                // than a whole-screen wash that the wallpaper overpowers.
                let r = max(geo.size.width, geo.size.height) * 0.55
                ZStack {
                    orb(topCore, at: UnitPoint(x: 0.0, y: -0.05), radius: r)
                    orb(bottomCore, at: UnitPoint(x: 1.0, y: 1.05), radius: r)
                }
                .blur(radius: 20)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Liquid glass card modifier
// Uses ultraThinMaterial so the navy-purple gradient behind bleeds through as a
// purple-tinted frost — real depth without losing colour identity.

struct GlassCardModifier: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(colorScheme == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white.opacity(0.22), .white.opacity(0.05)]
                                : [.black.opacity(0.10), .black.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 14, x: 0, y: 5)
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }

    // glassSurface()/glassEffect() (macOS 26 API, zero callers) removed:
    // @available can't guard a symbol absent from older SDKs — CI's
    // macos-latest SDK failed to compile it even though local Xcode has it.
}

#endif
