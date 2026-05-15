import SwiftUI

extension Text {
    /// Codex mono text — for "machine output": timers, model IDs, file paths,
    /// keybind labels, error codes. NOT for prose. See spec §4.4.
    func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    /// Apply mono digit style to numeric labels (timers, sliders).
    func monoDigits(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced).monospacedDigit())
    }
}
