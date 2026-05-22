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

            Text("macOS 原生语音输入工具\n按住说话，松开输入")
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
            VStack(spacing: 0) {
                instrRow(icon: "waveform", title: "语音输入",
                         desc: "设置录音触发按键、识别模型与转写润色规则",
                         tab: "语音")
                Divider().padding(.horizontal, 16)
                instrRow(icon: "person.2.wave.2", title: "声音录制",
                         desc: "配置长时录音识别模型、屏幕录制与内容摘要",
                         tab: "声音录制")
                Divider().padding(.horizontal, 16)
                instrRow(icon: "clock.arrow.circlepath", title: "历史记录",
                         desc: "按日期查看、搜索与管理语音转写与录音记录",
                         tab: "历史")
                Divider().padding(.horizontal, 16)
                instrRow(icon: "gearshape", title: "通用设置",
                         desc: "调整输入行为、历史记录开关与文件保存路径",
                         tab: "通用")
            }
            .glassCard()
        }
    }

    private func instrRow(icon: String, title: String, desc: String, tab: String) -> some View {
        // The row is a plain button: same visual as before, but the whole
        // padded area is a click target that jumps to the page it describes.
        Button {
            onNavigate(tab)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Without this Spacer each HStack hugs its content; the parent
                // VStack's default centring then leaves every row indented by a
                // different amount. Mirror the dataFlowRow / permRow layout so
                // every section in this tab is left-anchored.
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
