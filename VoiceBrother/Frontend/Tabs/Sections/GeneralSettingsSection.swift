import SwiftUI

/// Global settings. All 输入行为 toggles (语气词过滤/空格重定位/剪贴板保护)
/// live here — 语气词过滤 affects 语音输入 + 会议记录; the other two are
/// voice-recording specifics, gathered here so the user finds them in one place.
/// Appearance picker removed in Codex redesign (single theme).
struct GeneralSettingsSection: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var meetingService: MeetingService
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // AI 大模型 — shared API config for voice polish + meeting summary.
            // The on/off switches live on the 语音 / 会议 pages.
            LLMConfigCard()

            // 输入行为 — 语气词过滤 affects 语音输入 + 会议记录;
            // 空格重定位/剪贴板保护 are voice-recording specifics.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "输入行为")

                VStack(spacing: 0) {
                    toggleRow(title: "语气词过滤",
                              subtitle: "自动删除「嗯」「啊」「那个」等口头禅 · 语音输入与声音录制同时生效",
                              isOn: $configManager.removeFillers)

                    Divider().padding(.horizontal, 16)

                    toggleRow(title: "空格重定位",
                              subtitle: "录音中按空格键在鼠标位置点击，切换输入位置",
                              isOn: Binding(get: { voiceService.spaceReposition },
                                            set: { voiceService.spaceReposition = $0 }))

                    Divider().padding(.horizontal, 16)

                    toggleRow(title: "剪贴板保护",
                              subtitle: "保留之前复制的内容（图片、文件等），关闭则直接覆盖",
                              isOn: $configManager.preserveClipboard)

                    Divider().padding(.horizontal, 16)

                    toggleRow(title: "句尾标点",
                              subtitle: "保留转写结果的句末标点符号；关闭则替换为空格",
                              isOn: $configManager.trailingPunctuation)

                    Divider().padding(.horizontal, 16)

                    toggleRow(title: "渐进上屏",
                              subtitle: "目标 App 内按打字机节奏逐字键入（浮窗只显示波形）；关闭则现有整段一次性粘贴",
                              isOn: $configManager.typewriterMode)
                }
                .glassCard()
            }

            // 历史记录缓存 — records / meeting files past the chosen window
            // are pruned automatically. Voice & meeting have separate periods.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "历史记录")

                VStack(spacing: 0) {
                    retentionRow(title: "语音记录缓存",
                                 subtitle: "超过该时长的语音转写历史会自动清理",
                                 selection: $configManager.historyRetentionMonths)

                    Divider().padding(.horizontal, 16)

                    retentionRow(title: "声音录制缓存",
                                 subtitle: "超过该时长的录音记录与录音文件会自动清理",
                                 selection: $configManager.meetingRetentionMonths)
                }
                .glassCard()
            }

            // 会议保存路径 — long-term setting, so it lives here. The
            // 打开文件夹 action sits in the 会议 tab next to recording.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "声音录制保存路径")

                HStack(spacing: 8) {
                    Text(configManager.meetingSavePath)
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        chooseSavePath()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 12))
                            Text("选择文件夹").font(.system(size: 12))
                        }
                        .foregroundColor(theme.accentSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.surfaceBackground)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
    }

    private func chooseSavePath() {
        let panel = NSOpenPanel()
        panel.title = "选择录音保存路径"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.urls.first {
            configManager.meetingSavePath = url.path
            meetingService.savePath = url.path
        }
    }

    /// Retention dropdown options, in months. 12 = 一年 (the cap).
    private static let retentionOptions = [1, 2, 3, 4, 5, 6, 12]

    private static func retentionLabel(_ months: Int) -> String {
        months >= 12 ? "一年" : "\(months) 个月"
    }

    private func retentionRow(title: String, subtitle: String, selection: Binding<Int>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: selection) {
                ForEach(Self.retentionOptions, id: \.self) { months in
                    Text(Self.retentionLabel(months)).tag(months)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(16)
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(CustomToggleStyle())
                .labelsHidden()
        }
        .padding(16)
    }
}
