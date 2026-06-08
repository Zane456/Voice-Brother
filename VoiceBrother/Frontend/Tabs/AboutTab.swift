import SwiftUI

struct AboutTab: View {
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var theme: ThemeManager

    /// Jump to a sidebar page by its raw value — wired by MainWindow so each
    /// 使用说明 row works as a shortcut to the page it describes.
    var onNavigate: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                appInfoSection
                usageSection
                dataFlowSection
                permissionsSection
                refreshButton
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Flow (privacy assurance)

    private var dataFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "数据流向")

            VStack(spacing: 0) {
                dataFlowRow(label: "语音识别（短录入）", state: shortASRState)
                Divider().padding(.horizontal, 16)
                dataFlowRow(label: "AI 润色（短录入）", state: shortPolishState)
                Divider().padding(.horizontal, 16)
                dataFlowRow(label: "语音识别（声音录制）", state: meetingASRState)
                Divider().padding(.horizontal, 16)
                dataFlowRow(label: "AI 摘要（声音录制）", state: meetingSummaryState)
                Divider().padding(.horizontal, 16)
                dataStateRow(label: "转写历史",
                             enabled: true,
                             onText: "本地保存中",
                             offText: "已暂停")
            }
            .glassCard()
        }
    }

    // MARK: Data flow state resolution
    //
    // Each row reports one of three honest states:
    //   .local       — processed on this Mac, no network
    //   .cloud(p)    — sent to provider `p` over the network
    //   .disabled    — not used at all (silently skipped by the pipeline)
    //
    // Meeting summary has no local LLM path in the current code, so
    // `meetingLLMEnabled == false` means "no AI summary at all", not "local".

    private enum DataFlowState {
        case local
        case cloud(String)
        case disabled
    }

    private var shortASRState: DataFlowState {
        configManager.asrProviderType == "cloud"
            ? .cloud(configManager.cloudASRProvider)
            : .local
    }

    private var shortPolishState: DataFlowState {
        if configManager.cloudLLMEnabled {
            return .cloud(configManager.llmProvider)
        }
        return .disabled
    }

    // Meetings share the voice input ASR engine — mirror shortASRState.
    private var meetingASRState: DataFlowState {
        configManager.asrProviderType == "cloud"
            ? .cloud(configManager.cloudASRProvider)
            : .local
    }

    private var meetingSummaryState: DataFlowState {
        configManager.meetingLLMEnabled
            ? .cloud(configManager.llmProvider)
            : .disabled
    }

    private func dataFlowRow(label: String, state: DataFlowState) -> some View {
        let iconName: String
        let subtitle: String
        let badgeText: String
        let badgeColor: Color

        switch state {
        case .local:
            iconName = "lock.shield.fill"
            subtitle = "本地处理"
            badgeText = "本地"
            badgeColor = theme.accent
        case .cloud(let provider):
            iconName = "cloud.fill"
            subtitle = "云端 · \(provider)"
            badgeText = "云端"
            badgeColor = theme.accent
        case .disabled:
            iconName = "pause.circle"
            subtitle = "未启用"
            badgeText = "未启用"
            badgeColor = theme.textTertiary
        }

        return HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(badgeColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
            }
            Spacer()
            Text(badgeText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(badgeColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(badgeColor.opacity(0.15))
                )
        }
        .padding(16)
    }

    private func dataStateRow(label: String, enabled: Bool, onText: String, offText: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "internaldrive.fill" : "pause.circle")
                .font(.system(size: 14))
                .foregroundColor(enabled ? theme.accent : theme.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text(enabled ? onText : offText)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - App Info

    private var appInfoSection: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Layered soft shadows lift the icon off the card: a tight
                // contact shadow plus a wider ambient one read as real depth.
                .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 1)
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 7)

            Text("Voice Brother")
                .font(.system(size: 22, weight: .bold))
                // Subtle drop shadow gives the wordmark a slight raised emboss.
                .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)

            Text("版本 \(AboutTab.currentVersion)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(theme.textSecondary)

            Text("就是要成为最好用的语音输入软件")
                .font(.system(size: 12))
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .glassCard()
    }

    /// Minor version auto-increments by 1 every 7 days since the baseline,
    /// patch is derived from the day-within-week, so rebuilding the same day
    /// keeps the version stable but consecutive weeks tick up automatically.
    /// Baseline: 2026-04-22 is 1.0.0.
    private static let currentVersion: String = {
        let calendar = Calendar(identifier: .gregorian)
        let baseline = DateComponents(calendar: calendar,
                                      year: 2026, month: 4, day: 22).date!
        let days = calendar.dateComponents([.day], from: baseline, to: Date()).day ?? 0
        let clamped = max(0, days)
        let weeks = clamped / 7
        let dayInWeek = clamped % 7
        return "1.\(weeks).\(dayInWeek)"
    }()

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "使用说明")

            // One row per *other* sidebar page, in sidebar order — the page
            // hosting this section (关于) is omitted. The leading icon of each
            // row is the exact SF Symbol used by that page's nav item (see
            // MainWindow.AppTab.icon) so this section reads as a sidebar legend.
            // All four desc strings are kept to exactly 20 full-width glyphs
            // (CJK + 、 only, no Latin / spaces) so every row's secondary line
            // is the same visual length.
            // 每条做成独立的卡片式按钮（而非一张卡里的扁平行）——独立边框 +
            // hover 高亮 + 按下回弹 + 尾部 › 箭头，一眼看出"这是能按的"。
            // 保持 Codex 扁平风：无阴影、发丝边框、蓝色 accent。
            VStack(spacing: 8) {
                InstructionButton(icon: "waveform", title: "语音输入",
                                  desc: "设置录音触发按键、识别模型与转写润色规则",
                                  tab: "语音", onNavigate: onNavigate)
                InstructionButton(icon: "person.2.wave.2", title: "声音录制",
                                  desc: "配置长时录音识别模型、屏幕录制与内容摘要",
                                  tab: "声音录制", onNavigate: onNavigate)
                InstructionButton(icon: "clock.arrow.circlepath", title: "历史记录",
                                  desc: "按日期查看、搜索与管理语音转写与录音记录",
                                  tab: "历史", onNavigate: onNavigate)
                InstructionButton(icon: "gearshape", title: "通用设置",
                                  desc: "调整输入行为、历史记录开关与文件保存路径",
                                  tab: "通用", onNavigate: onNavigate)
            }
        }
    }

    /// 单条"使用说明"——独立的卡片式按钮。拥有自己的 hover 状态：hover 时边框
    /// 转蓝 + 淡蓝填充、尾部箭头转蓝，按下时轻微缩放回弹。让它一眼是个能按的按钮。
    private struct InstructionButton: View {
        @EnvironmentObject private var theme: ThemeManager
        let icon: String
        let title: String
        let desc: String
        let tab: String
        let onNavigate: (String) -> Void
        @State private var isHovering = false

        var body: some View {
            let radius = theme.cardBaseCornerRadius
            return Button {
                onNavigate(tab)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.textPrimary)
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    // 导航暗示——hover 时随边框一起转蓝。
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isHovering ? theme.accent : theme.textTertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.surfaceBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.accent.opacity(isHovering ? 0.06 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(isHovering ? theme.accent.opacity(0.55) : theme.cardBorderColor,
                                lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .buttonStyle(PressableCardButtonStyle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    /// 卡片按钮的按下反馈——轻微缩放 + 压暗，给"按下去了"的触感。
    private struct PressableCardButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .opacity(configuration.isPressed ? 0.9 : 1.0)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "系统权限")

            VStack(spacing: 0) {
                permRow(icon: "universalaccess", title: "辅助功能", subtitle: "监听全局按键事件",
                        granted: permissionManager.status.accessibility,
                        action: { permissionManager.openAccessibilitySettings() })
                Divider().padding(.horizontal, 16)
                permRow(icon: "mic", title: "麦克风", subtitle: "录制语音输入",
                        granted: permissionManager.status.microphone,
                        action: { permissionManager.openMicrophoneSettings() })
                Divider().padding(.horizontal, 16)
                permRow(icon: "rectangle.on.rectangle.angled", title: "屏幕录制", subtitle: "获取输入焦点位置",
                        granted: permissionManager.status.screenRecording,
                        action: { permissionManager.openScreenRecordingSettings() })
            }
            .glassCard()
        }
    }

    private func permRow(icon: String, title: String, subtitle: String,
                         granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(granted ? theme.accent : theme.destructive)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundColor(theme.textSecondary)
            }

            Spacer()

            if !granted {
                Button {
                    action()
                } label: {
                    Text("设置")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(theme.accent.opacity(0.08))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Text("已授权")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accent)
            }
        }
        .padding(16)
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            permissionManager.recheckAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                Text("刷新权限状态").font(.system(size: 13))
            }
            .foregroundColor(theme.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
