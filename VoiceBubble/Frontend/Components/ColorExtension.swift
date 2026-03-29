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

// MARK: - Glassmorphism Card Modifier

extension View {
    /// Applies a frosted glass card style matching Voice Aura's glassmorphism design.
    func glassCard(cornerRadius: CGFloat = 14, borderColor: Color? = nil) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(0.55))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor ?? Color.white.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.02), radius: 1, x: 0, y: 1)
            .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
    }
}
