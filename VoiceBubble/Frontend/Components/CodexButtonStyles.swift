import SwiftUI

/// Solid green primary CTA — "Stage all" / "Send" / 启动服务. Spec §6.4.
struct CodexPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(buttonFill(configuration: configuration))
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func buttonFill(configuration: Configuration) -> Color {
        configuration.isPressed
            ? theme.accent.opacity(0.85)
            : theme.accent
    }
}

/// Transparent + hairline border. For 取消 / 设置 / 次要操作. Spec §6.4.
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? theme.tagBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Red-outline button for destructive actions (停止录制 / 删除). Spec §6.4.
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.destructive.opacity(0.18)
                          : theme.destructive.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.destructive.opacity(0.5), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
