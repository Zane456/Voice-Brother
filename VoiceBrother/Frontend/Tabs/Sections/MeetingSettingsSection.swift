import SwiftUI

struct MeetingSettingsSection: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var meetingService: MeetingService
    @EnvironmentObject private var theme: ThemeManager
    // Meeting LLM shares the voice provider/endpoint, so it reads `voiceService`'s
    // single warm-up state rather than maintaining its own — see the status
    // helpers below.
    @EnvironmentObject private var voiceService: VoiceService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "声音录制设置")

            // ASR Model — read-only mirror of voice input config
            asrModelCard

            // Meeting LLM Config
            meetingLLMView
        }
    }

    private func provenanceBadge(isCloud: Bool) -> some View {
        CodexBadge(text: isCloud ? "云端" : "本地",
                   variant: isCloud ? .cloud : .local)
    }

    // MARK: - ASR Model Card
    //
    // Meetings transcribe with their own local Qwen model, picked here and
    // independent of voice input's model. Apple Speech is intentionally not
    // offered — it can't auto-detect across languages, and meetings are a
    // multilingual, long-form scenario. The model loads when a meeting starts
    // and unloads when it ends, so it costs no memory between meetings.

    private var meetingASRModelBinding: Binding<ASRModel> {
        Binding(
            get: { configManager.meetingASRModel },
            set: { configManager.meetingASRModel = $0 }
        )
    }

    private var asrModelCard: some View {
        let selected = configManager.meetingASRModel
        let isIdle = meetingService.state == .idle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accent)
                Text("语音识别模型")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: false)
            }

            // Segmented picker — identical style to the voice-input ASR card so
            // both screens present model selection the same way.
            Picker("", selection: meetingASRModelBinding) {
                ForEach([ASRModel.small, ASRModel.large]) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(!isIdle)

            HStack(spacing: 8) {
                modelInfoTag(icon: "cpu", text: selected.quantization)
                modelInfoTag(icon: "internaldrive", text: selected.estimatedSize)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Meeting LLM

    /// True when meeting summary LLM is toggled on but no usable API key is
    /// configured. Meeting LLM shares the voice `llmProvider` / `llmCredentials`,
    /// so the check mirrors the voice-input card. Drives an inline warning so a
    /// summary that will silently never run isn't presented as "已启用".
    private var meetingLLMEnabledButUnconfigured: Bool {
        guard configManager.meetingLLMEnabled else { return false }
        guard let provider = LLMProvider(rawValue: configManager.llmProvider),
              provider != .none else { return true }
        let key = configManager.llmCredentials[provider.rawValue]?.apiKey ?? ""
        return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compact LLM enable card. The provider / API Key / model fields moved
    /// to the 通用 settings page — this card keeps only the on/off switch.
    private var meetingLLMView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("AI 大模型（声音内容处理）")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: true)  // Meeting LLM is always cloud — no local option.
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(meetingLLMStatusDotColor)
                    .frame(width: 8, height: 8)
                Text(meetingLLMStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(meetingLLMStatusTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isMeetingLLMWarmupFailed {
                    Button("重试") { voiceService.warmUpLLM() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(theme.accent)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { configManager.meetingLLMEnabled },
                    set: { configManager.meetingLLMEnabled = $0 }
                ))
                .toggleStyle(CustomToggleStyle())
                .labelsHidden()
            }

            Text("录制结束后自动生成录音摘要")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("提供商 / API Key / 模型 在「通用」设置中配置")
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.textTertiary)

            if meetingLLMEnabledButUnconfigured {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("未在「通用」页配置 API Key，录音结束不会生成摘要")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(theme.stop)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Meeting LLM Connection Status
    //
    // Meeting LLM shares the voice `llmProvider` / `llmCredentials` — same
    // endpoint, same pooled TLS connection — so it renders `voiceService`'s
    // single warm-up state. The 连接中/已就绪/连接失败 三态 + retry mirror the
    // voice-input LLM card so both screens read identically.

    private var meetingLLMStatusText: String {
        guard configManager.meetingLLMEnabled else { return "未启用" }
        switch voiceService.llmWarmupState {
        case .idle:       return "已启用"
        case .connecting: return "连接中…"
        case .ready:      return "已就绪"
        case .failed(let msg): return msg.isEmpty ? "连接失败" : "连接失败：\(msg)"
        }
    }

    private var meetingLLMStatusTextColor: Color {
        guard configManager.meetingLLMEnabled else { return theme.textSecondary }
        switch voiceService.llmWarmupState {
        case .idle:       return theme.textSecondary
        case .connecting: return theme.accent
        case .ready:      return theme.statusOK
        case .failed:     return theme.statusFail
        }
    }

    private var meetingLLMStatusDotColor: Color {
        guard configManager.meetingLLMEnabled else { return theme.border }
        switch voiceService.llmWarmupState {
        case .idle:       return theme.border
        case .connecting: return theme.accent
        case .ready:      return theme.statusOK
        case .failed:     return theme.statusFail
        }
    }

    private var isMeetingLLMWarmupFailed: Bool {
        guard configManager.meetingLLMEnabled else { return false }
        if case .failed = voiceService.llmWarmupState { return true }
        return false
    }

    // MARK: - Helpers

    private func modelInfoTag(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundColor(theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.tagBackground.opacity(0.8))
        .cornerRadius(6)
    }
}
