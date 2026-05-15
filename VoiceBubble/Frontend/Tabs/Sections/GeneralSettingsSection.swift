import SwiftUI

/// Global settings only. Voice-specific input toggles
/// (语气词过滤、空格重定位、剪贴板保护、实时预览) live under the 语音 tab now.
/// Appearance picker removed in Codex redesign (single theme).
struct GeneralSettingsSection: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Privacy Mode (highest-priority setting — for咨询师/律师/敏感场景)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "隐私模式")

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: configManager.privacyMode ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 22))
                        .foregroundColor(configManager.privacyMode ? theme.accent : theme.textTertiary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(configManager.privacyMode ? "隐私模式 · 已开启" : "隐私模式 · 关闭")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.textPrimary)
                        Text("开启后：不保存语音转写历史、不进行智能学习记录、切换云端服务商时强制二次确认。适合处理保密对话、客户访谈、内部会议。")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle("", isOn: $configManager.privacyMode)
                        .toggleStyle(CustomToggleStyle())
                        .labelsHidden()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(configManager.privacyMode ? theme.accent.opacity(0.08) : Color.clear)
                )
                .glassCard()
            }

            // Hint card pointing user to the Voice tab for input behavior
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "输入行为")

                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accent)
                    Text("语气词过滤、空格重定位、剪贴板保护、实时预览等输入相关开关已移至「语音」标签。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
    }
}
