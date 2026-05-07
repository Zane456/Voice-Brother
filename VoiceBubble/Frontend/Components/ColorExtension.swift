import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r: Double
        let g: Double
        let b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 1.0
            g = 1.0
            b = 1.0
        }
        self.init(red: r, green: g, blue: b)
    }

    init(red8: UInt8, green8: UInt8, blue8: UInt8) {
        self.init(
            red: Double(red8) / 255.0,
            green: Double(green8) / 255.0,
            blue: Double(blue8) / 255.0
        )
    }
}

// MARK: - Card Modifier

extension View {
    /// Glass / paper / Material card surface. Pass `cornerRadius` to override
    /// the theme's default radius; pass `borderColor` to override the theme
    /// border. Material, border width and shadow profile are always pulled
    /// from the active `ThemeManager` so each theme has a distinct surface
    /// personality (Apple thin frost, Claude paper, Material elevation, etc.).
    func glassCard(cornerRadius: CGFloat? = nil, borderColor: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }
}

private struct GlassCardModifier: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let cornerRadius: CGFloat?
    let borderColor: Color?

    func body(content: Content) -> some View {
        let r = cornerRadius ?? theme.cardBaseCornerRadius
        // Drop-shadow profile is user-controlled, not theme-controlled.
        // Lets you keep e.g. the minimalist Claude look but bump cards to
        // "深" / "悬浮" if you prefer more separation between sections.
        let depth = theme.cardDepth

        // Border width is theme-defined, then scaled by cardDepth.borderScale.
        // depth.bare zeroes the scale so the border disappears entirely
        // even on themes whose default border width is non-zero.
        let baseBorderWidth: CGFloat = (theme.decoration == .minimal) ? 0.5 : theme.cardBorderWidth
        let effectiveBorderWidth = baseBorderWidth * CGFloat(depth.borderScale)

        switch theme.decoration {
        case .minimal:
            return AnyView(
                content
                    .background(
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .fill(theme.cardOverlayColor.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .stroke(borderColor ?? theme.border.opacity(0.5),
                                    lineWidth: effectiveBorderWidth)
                    )
                    .shadow(color: Color.black.opacity(depth.shadowOpacity),
                            radius: depth.shadowRadius,
                            x: 0,
                            y: max(depth.shadowRadius / 3, 0))
            )

        case .material, .expressive:
            return AnyView(
                content
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: r, style: .continuous)
                                .fill(theme.cardMaterial)
                            RoundedRectangle(cornerRadius: r, style: .continuous)
                                .fill(theme.cardOverlayColor.opacity(theme.cardFillOpacity))
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .stroke(borderColor ?? theme.cardBorderColor,
                                    lineWidth: effectiveBorderWidth)
                    )
                    .shadow(color: Color.black.opacity(depth.shadowOpacity),
                            radius: depth.shadowRadius,
                            x: 0,
                            y: max(depth.shadowRadius / 3, 0))
            )
        }
    }
}
