import SwiftUI

extension VoiceSettingsSection {
    // MARK: - Hotwords

    var hotwordsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "热词")

            Text("传递给识别模型，帮助识别专有名词")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

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
