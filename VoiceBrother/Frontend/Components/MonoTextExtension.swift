import SwiftUI

extension Text {
    /// True mono — for actual code blocks, terminal output, diff views.
    /// Per Codex spec: UI chrome stays sans; mono is reserved for code-like content.
    func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    /// Sans typeface with tabular-numerics — for timers, percentages, version
    /// strings where digits need to align without switching to a mono typeface.
    /// SwiftUI equivalent of CSS `font-variant-numeric: tabular-nums`.
    func monoDigits(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight).monospacedDigit())
    }
}
