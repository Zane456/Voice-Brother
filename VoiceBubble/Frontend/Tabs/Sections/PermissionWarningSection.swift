import SwiftUI

struct PermissionWarningSection: View {
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.warning)

                Text("需要授权以下权限才能使用")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
            }

            VStack(spacing: 8) {
                permissionRow(
                    icon: "universalaccess",
                    title: "辅助功能",
                    granted: permissionManager.status.accessibility,
                    action: { permissionManager.openAccessibilitySettings() }
                )

                permissionRow(
                    icon: "mic",
                    title: "麦克风",
                    granted: permissionManager.status.microphone,
                    action: { permissionManager.openMicrophoneSettings() }
                )

                permissionRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "屏幕录制",
                    granted: permissionManager.status.screenRecording,
                    action: { permissionManager.openScreenRecordingSettings() }
                )
            }
        }
        .padding(16)
        .background(theme.warningBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.warningBorder, lineWidth: 1)
        )
    }

    private func permissionRow(
        icon: String,
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14))
                .foregroundColor(granted ? theme.accent : theme.textTertiary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(granted ? theme.accent : theme.textPrimary)

            Spacer()

            if granted {
                Text("已授权")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accent)
            } else {
                Button {
                    action()
                } label: {
                    Text("授权")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(theme.accentSecondary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
