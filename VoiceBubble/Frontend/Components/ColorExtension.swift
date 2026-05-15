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
    /// Codex card surface — flat fill, hairline border, sharp corners, no shadow.
    /// `cornerRadius` overrides the theme default; `borderColor` overrides the
    /// theme border. Spec §6.3.
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

        return content
            .background(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(theme.cardOverlayColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .stroke(borderColor ?? theme.cardBorderColor,
                            lineWidth: theme.cardBorderWidth)
            )
    }
}
