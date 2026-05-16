import SwiftUI

/// Codex primary CTA — near-black filled + white text (works in light & dark).
/// Per Codex spec: the primary button uses `textPrimary` as fill (not accent),
/// because in Codex's design language "filled with foreground" is what reads
/// as "primary action", not "filled with brand color".
struct CodexPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.isDark ? .white : .white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .fill(buttonFill(configuration: configuration))
            )
            .animation(.easeOut(duration: theme.durationBasic), value: configuration.isPressed)
    }

    private func buttonFill(configuration: Configuration) -> Color {
        // Codex uses opacity layering for press states (color-mix with transparent).
        let base = theme.isDark ? Color(hex: "0D0D0D") : theme.textPrimary
        return configuration.isPressed ? base.opacity(0.85) : base
    }
}

/// Transparent + hairline border. For 取消 / 设置 / 次要操作.
struct CodexSecondaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.textPrimary.opacity(0.08)
                          : theme.textPrimary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: theme.durationBasic), value: configuration.isPressed)
    }
}

/// Red-outline button for destructive actions (停止录制 / 删除).
struct CodexDestructiveButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.destructive)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.destructive.opacity(0.18)
                          : theme.destructive.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous)
                    .stroke(theme.destructive.opacity(0.5), lineWidth: 1)
            )
            .animation(.easeOut(duration: theme.durationBasic), value: configuration.isPressed)
    }
}
