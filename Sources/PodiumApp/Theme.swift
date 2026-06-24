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

    static let darkBackgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.04, blue: 0.13),
            Color(red: 0.07, green: 0.03, blue: 0.17),
            Color(red: 0.02, green: 0.07, blue: 0.14)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let lightBackgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.85, green: 0.82, blue: 0.98),
            Color(red: 0.88, green: 0.78, blue: 0.96),
            Color(red: 0.82, green: 0.88, blue: 0.98)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Accent gradient

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.15, green: 0.4, blue: 0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
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
// the full .behindWindow frosted glass for the whole window. This view is kept
// as a transparent placeholder so ZStack structure in views remains valid.
struct ThemeBackground: View {
    var body: some View {
        Color.clear.ignoresSafeArea()
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

    func glassSurface() -> some View {
        glassEffect()
    }
}
