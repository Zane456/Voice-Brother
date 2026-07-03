import SwiftUI

extension VoiceSettingsSection {
    // MARK: - Trigger Key

    /// Mirrors `MeetingTab.recordingControlCard`'s layout (56pt badge + text +
    /// trailing control) so the 语音输入 card matches the 对话记录 card in size
    /// and style. The trailing control here is the trigger-key Picker.
    var triggerKeyCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.12))
                    .frame(width: 56, height: 56)
                BrandGlyph(color: theme.accent, size: 26)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("录音按键")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                (Text("长按 ")
                    + Text(triggerKeyName).font(.system(size: 13, weight: .bold)).foregroundColor(theme.textPrimary)
                    + Text(" 录音 · 松手自动输入文字"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Picker("", selection: $configManager.triggerKey) {
                ForEach(TriggerKey.allCases) { key in
                    Text(key.displayName).tag(key.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: configManager.triggerKey) { _, newValue in
                guard newValue != previousTriggerKey else { return }
                previousTriggerKey = newValue
                // Hot-reload silently — no user-visible "restart service" prompt.
                if asrModelLoaded {
                    voiceService.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        voiceService.start()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Display name of the currently selected trigger key, for the caption.
    private var triggerKeyName: String {
        TriggerKey(rawValue: configManager.triggerKey)?.displayName ?? "录音键"
    }
}
