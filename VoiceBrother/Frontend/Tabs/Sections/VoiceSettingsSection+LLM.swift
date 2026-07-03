import SwiftUI

extension VoiceSettingsSection {
    // MARK: - LLM Model Card

    /// True when LLM polish is toggled on but no usable API key is configured —
    /// the card reads "已启用" yet every polish call silently falls back to the
    /// raw transcription. Drives an inline warning so this isn't silent.
    private var llmEnabledButUnconfigured: Bool {
        guard configManager.cloudLLMEnabled else { return false }
        guard let provider = LLMProvider(rawValue: configManager.llmProvider),
              provider != .none else { return true }
        let key = configManager.llmCredentials[provider.rawValue]?.apiKey ?? ""
        return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compact LLM enable card. The provider / API Key / model fields moved
    /// to the 通用 settings page — this card keeps only the on/off switch.
    var llmModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("AI 大模型（语音文本优化）")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: true)  // LLM polishing is always cloud — local option retired.
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(llmStatusDotColor)
                    .frame(width: 8, height: 8)
                Text(llmStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(llmStatusTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isLLMWarmupFailed {
                    Button("重试") { voiceService.warmUpLLM() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(theme.accent)
                }

                Spacer()

                Toggle("", isOn: $configManager.cloudLLMEnabled)
                    .toggleStyle(CustomToggleStyle())
                    .labelsHidden()
            }

            Text("启用后，语音转写将通过云端 AI 大模型优化")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("提供商 / API Key / 模型 在「通用」设置中配置")
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.textTertiary)

            if llmEnabledButUnconfigured {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("未在「通用」页配置 API Key，润色不会生效")
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

    // MARK: - LLM Connection Status

    private var llmStatusText: String {
        guard configManager.cloudLLMEnabled else { return "未启用" }
        switch voiceService.llmWarmupState {
        case .idle:       return "已启用"
        case .connecting: return "连接中…"
        case .ready:      return "已就绪"
        case .failed(let msg): return msg.isEmpty ? "连接失败" : "连接失败：\(msg)"
        }
    }

    private var llmStatusTextColor: Color {
        guard configManager.cloudLLMEnabled else { return theme.textSecondary }
        switch voiceService.llmWarmupState {
        case .idle:       return theme.textSecondary
        case .connecting: return theme.accent
        case .ready:      return theme.statusOK
        case .failed:     return theme.statusFail
        }
    }

    private var llmStatusDotColor: Color {
        guard configManager.cloudLLMEnabled else { return theme.border }
        switch voiceService.llmWarmupState {
        case .idle:       return theme.border
        case .connecting: return theme.accent
        case .ready:      return theme.statusOK
        case .failed:     return theme.statusFail
        }
    }

    private var isLLMWarmupFailed: Bool {
        if case .failed = voiceService.llmWarmupState { return true }
        return false
    }

    // MARK: - AI Polish Prompt

    private var allPolishPresets: [PromptPreset] {
        let custom = configManager.polishCustomPresets.map { name, prompt in
            PromptPreset(id: "user.\(name)", name: name, prompt: prompt, isBuiltIn: false)
        }.sorted { $0.name < $1.name }
        return PromptPreset.builtInPolishPresets + custom
    }

    var llmNotesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "AI 转写润色提示词")
                Spacer()

                Menu {
                    Section("内置预设") {
                        ForEach(PromptPreset.builtInPolishPresets) { preset in
                            Button(preset.name) { configManager.localLLMNotes = preset.prompt }
                        }
                    }
                    if !configManager.polishCustomPresets.isEmpty {
                        Section("我的预设") {
                            ForEach(configManager.polishCustomPresets.sorted(by: { $0.key < $1.key }), id: \.key) { name, prompt in
                                Button(name) { configManager.localLLMNotes = prompt }
                            }
                            Divider()
                            Menu("删除我的预设…") {
                                ForEach(configManager.polishCustomPresets.sorted(by: { $0.key < $1.key }), id: \.key) { name, _ in
                                    Button("删除 「\(name)」") {
                                        configManager.polishCustomPresets.removeValue(forKey: name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11))
                        Text("应用预设").font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    newPolishPresetName = ""
                    showSavePolishPresetSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                        Text("存为预设").font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                }
                .buttonStyle(.plain)
                .disabled(configManager.localLLMNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $configManager.localLLMNotes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 110)
                    .padding(4)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )

                // Placeholder 即说明——输入框留空时显示完整 hint，开始输入后自动消失。
                // 把"功能介绍"和"使用提示"合并到 placeholder，避免上方再多一段静态说明文字
                // 浪费视觉空间（用户大概率留空，所以 placeholder 总能看到）。
                if configManager.localLLMNotes.isEmpty {
                    Text("留空即可（推荐）——已自动做同音字纠正、标点断句、删口吃、中英大小写规范。\n仅当你想改变文本风格（如改写为公众号 / 小红书 / 正式邮件）时再填，或点右上「应用预设」选一个。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textPlaceholder)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 13)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showSavePolishPresetSheet) {
            savePolishPresetSheet
        }
    }

    private var savePolishPresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存为润色预设")
                .font(.system(size: 14, weight: .semibold))
            Text("输入预设名称，下次可一键应用。同名将覆盖。")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
            TextField("预设名称（如：公众号-长文）", text: $newPolishPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { savePolishPreset() }
            HStack {
                Spacer()
                Button("取消") { showSavePolishPresetSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { savePolishPreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPolishPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        // Sheet runs in its own window — pin the tint so the default "保存"
        // button and the text-field focus ring stay app-blue, not system accent.
        .tint(theme.accent)
    }

    private func savePolishPreset() {
        let name = newPolishPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.polishCustomPresets[name] = configManager.localLLMNotes
        showSavePolishPresetSheet = false
    }
}
