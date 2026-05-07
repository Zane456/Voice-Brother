import SwiftUI

/// Global / appearance settings only. Voice-specific input toggles
/// (语气词过滤、空格重定位、剪贴板保护、实时预览) live under the 语音 tab now.
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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(configManager.privacyMode ? theme.accent.opacity(0.08) : Color.clear)
                )
                .glassCard()
            }

            // Theme Picker — wraps so 7 themes never overflow the card width.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "外观")

                FlowLayout(spacing: 16) {
                    ForEach(AppTheme.selectableCases) { t in
                        themeButton(t)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }

            // Card depth — independent of theme. 5-step segmented control
            // so users can dial cards from totally flat (Claude-like) up
            // to floating (Material-like) regardless of which theme is on.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "卡片深度")

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(CardDepth.allCases) { depth in
                            depthButton(depth)
                        }
                    }
                    Text("控制所有卡片的投影强度，叠加在主题样式之上")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textTertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Theme Button

    /// Uniform-shape picker — every theme renders the same 44pt circle.
    /// The eight options differentiate by colour only; mixing in squares
    /// or 4-dot quadrants made the row look inconsistent and asymmetric.
    private func themeButton(_ t: AppTheme) -> some View {
        let isSelected = theme.current == t
        let swatch = t.pickerSwatch

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                theme.current = t
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    // Solid swatch matching the theme's *name* (so 雾银灰
                    // reads as gray, 泡泡蓝 reads as blue, etc.) — not the
                    // accent colour, which is the interactive UI tint.
                    Circle()
                        .fill(swatch)
                        .frame(width: 44, height: 44)
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                        .frame(width: 44, height: 44)

                    if isSelected {
                        Circle()
                            .stroke(swatch, lineWidth: 2.5)
                            .frame(width: 50, height: 50)
                    }
                }
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)

                Text(t.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? swatch : theme.textPrimary)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(t.displayName)
    }

    /// One segment of the card-depth selector. The swatch stays pure white
    /// regardless of depth — only the cast shadow grows. Earlier this scaled
    /// the real shadow radius down by 0.45, but on a 38×26 swatch even a
    /// 10pt blur makes the whole tile read as a gray smudge. Use small
    /// absolute values that read as a visible shadow without darkening the
    /// card itself.
    private func depthButton(_ depth: CardDepth) -> some View {
        let isSelected = theme.cardDepth == depth
        let swatchRadius: CGFloat
        let swatchOpacity: Double
        switch depth {
        case .bare:    swatchRadius = 0;   swatchOpacity = 0
        case .flat:    swatchRadius = 0;   swatchOpacity = 0
        case .whisper: swatchRadius = 1.5; swatchOpacity = 0.10
        case .soft:    swatchRadius = 2.5; swatchOpacity = 0.16
        }

        // bare → no resting border on the swatch (selected ring still drawn)
        let restingBorderWidth: CGFloat = (depth == .bare) ? 0 : 0.5
        let restingBorderColor: Color = theme.border.opacity(0.4)

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                theme.cardDepth = depth
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 38, height: 26)
                        .shadow(color: .black.opacity(swatchOpacity),
                                radius: swatchRadius,
                                x: 0,
                                y: swatchRadius * 0.4)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? theme.accent : restingBorderColor,
                                lineWidth: isSelected ? 1.5 : restingBorderWidth)
                        .frame(width: 38, height: 26)
                }
                .frame(width: 50, height: 38)

                Text(depth.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.accent : theme.textSecondary)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(depth.displayName)
    }

    /// Accent colour for each theme — used both for the selected-ring and
    /// the selected label colour. Kept as a free function so we can read it
    /// without mutating the live ThemeManager.
    private func tAccent(_ t: AppTheme) -> Color {
        switch t {
        case .bubbleBlue:    return Color(hex: "4ECDC4")
        case .midnight:      return Color(hex: "7C6AFF")
        case .sakura:        return Color(hex: "EC4899")
        case .mint:          return Color(hex: "10B981")
        case .pureWhite:     return Color(hex: "007AFF")
        case .caramelBrown:  return Color(hex: "D97757")
        case .mistSilver:    return Color(hex: "007AFF")
        case .clearSky:      return Color(hex: "4285F4")
        case .inkPine:       return Color(hex: "10A37F")
        }
    }
}
