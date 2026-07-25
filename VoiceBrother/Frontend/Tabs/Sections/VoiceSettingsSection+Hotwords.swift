import SwiftUI

extension VoiceSettingsSection {
    // MARK: - Hotwords

    /// The old copy ("传递给识别模型") is only true on the Qwen path. Apple's engine
    /// takes no hotword bias at all — `AnalysisContext.contextualStrings` is a
    /// measured no-op on macOS 26.5.1 — so there the list only feeds
    /// HotwordSnapper's post-transcription pass. Name whichever is actually in
    /// effect instead of promising biasing the selected engine can't do.
    var hotwordScopeHint: String {
        let usingApple = configManager.asrProviderType == "local"
            && (ASRModel(rawValue: configManager.model)?.isApple ?? false)
        return usingApple
            ? "当前 Apple 档不接受热词——这些词只用于转写完成后的文本纠正。换到 Qwen 档才会真正传给识别模型。"
            : "传递给识别模型，帮助识别专有名词"
    }

    var hotwordsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "热词")

            Text(hotwordScopeHint)
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 8) {
                ForEach(configManager.hotwords, id: \.self) { word in
                    hotwordTag(word)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            HStack(spacing: 8) {
                TextField("输入新热词，按 Enter 添加", text: $newHotword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.borderLight, lineWidth: 1)
                    )
                    .onSubmit {
                        addHotword()
                    }

                Button {
                    addHotword()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(theme.accentSecondary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(newHotword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func hotwordTag(_ word: String) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 13))
                .foregroundColor(theme.textPrimary)

            Button {
                removeHotword(word)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.surfaceBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
