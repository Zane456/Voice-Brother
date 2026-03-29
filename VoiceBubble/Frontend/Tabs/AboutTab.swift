import SwiftUI

struct AboutTab: View {
    @EnvironmentObject private var permissionManager: PermissionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // MARK: - App Info
                appInfoSection

                // MARK: - Permissions
                permissionsSection

                // MARK: - Refresh Button
                refreshButton
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        VStack(spacing: 16) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 4) {
                Text("Voice Bubble")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "2C3E6B"))

                Text("版本 1.0.0")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "5A7098"))
            }

            Text("macOS 原生语音输入工具\n按住说话，松开输入")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "8AA0BE"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 32)
        .glassCard()
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("系统权限")

            VStack(spacing: 8) {
                permissionRow(
                    icon: "universalaccess",
                    title: "辅助功能",
                    subtitle: "用于监听全局按键事件",
                    granted: permissionManager.status.accessibility,
                    action: { permissionManager.openAccessibilitySettings() }
                )

                permissionRow(
                    icon: "mic",
                    title: "麦克风",
                    subtitle: "用于录制语音输入",
                    granted: permissionManager.status.microphone,
                    action: { permissionManager.openMicrophoneSettings() }
                )

                permissionRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "屏幕录制",
                    subtitle: "用于获取当前输入焦点位置",
                    granted: permissionManager.status.screenRecording,
                    action: { permissionManager.openScreenRecordingSettings() }
                )
            }
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(granted ? Color(hex: "4ECDC4").opacity(0.15) : Color(hex: "FF6B8A").opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: granted ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(granted ? Color(hex: "4ECDC4") : Color(hex: "FF6B8A"))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "2C3E6B"))

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A7098"))
            }

            Spacer()

            if !granted {
                Button {
                    action()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.system(size: 11))
                        Text("打开系统设置")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "7B8CF5"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "F2F6FC"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "C8D8EA"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Text("已授权")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "4ECDC4"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "4ECDC4").opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button {
            permissionManager.recheckAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                Text("刷新权限状态")
                    .font(.system(size: 13))
            }
            .foregroundColor(Color(hex: "5A7098"))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 11)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: "2C3E6B"))
    }
}
