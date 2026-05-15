import SwiftUI

struct MeetingSettingsSection: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var meetingService: MeetingService
    @EnvironmentObject private var theme: ThemeManager

    @State private var showSaveMeetingPresetSheet = false
    @State private var newMeetingPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "会议设置")

            // ASR Model — read-only mirror of voice input config
            asrModelCard

            // Meeting language hint
            languageCard

            // Meeting LLM Config
            meetingLLMView

            // Custom Prompt
            customPromptView

            // Save Path
            savePathView
        }
        .onAppear { migrateMeetingCredentialsIfNeeded() }
    }

    private func provenanceBadge(isCloud: Bool) -> some View {
        CodexBadge(text: isCloud ? "云端" : "本地",
                   variant: isCloud ? .cloud : .local)
    }

    // MARK: - ASR Model Card
    //
    // Read-only display: meetings reuse the engine VoiceService loaded from
    // `configManager.model` / `configManager.asrProviderType`. The previous
    // independent picker was a phantom — config was persisted but never read
    // at runtime. To change the meeting transcription model, the user goes
    // to the 通用 (General) tab.

    private var sharedASRIsCloud: Bool {
        configManager.asrProviderType == "cloud"
    }

    private var sharedASRModel: ASRModel? {
        ASRModel(rawValue: configManager.model)
    }

    private var sharedASRDisplayName: String {
        if sharedASRIsCloud {
            let raw = configManager.cloudASRProvider
            return CloudASRProvider(rawValue: raw)?.displayName ?? raw
        }
        return sharedASRModel?.fullName ?? configManager.model
    }

    private var asrModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accent)
                Text("语音识别模型")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: sharedASRIsCloud)
            }

            HStack(spacing: 8) {
                Image(systemName: sharedASRIsCloud ? "cloud" : "cpu")
                    .font(.system(size: 13))
                    .foregroundColor(theme.textSecondary)
                Text(sharedASRDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                if !sharedASRIsCloud, let model = sharedASRModel {
                    // Same two tags for all three local models — keeps the row
                    // height stable when the user switches engines in the voice tab.
                    modelInfoTag(
                        icon: model.isApple ? "apple.logo" : "cpu",
                        text: model.quantization
                    )
                    modelInfoTag(icon: "internaldrive", text: model.estimatedSize)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Text("会议录制共享语音输入的识别模型与提供商。如需修改，请前往「通用」Tab 调整。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Language hint

    private var meetingLanguageBinding: Binding<MeetingLanguage> {
        Binding(
            get: { configManager.meetingLanguage },
            set: { configManager.meetingLanguage = $0 }
        )
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accent)
                Text("会议语言")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Picker("", selection: meetingLanguageBinding) {
                    ForEach(MeetingLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Text("传给本地语音模型的语言提示。错配会让识别变成同音字噪音（例如把日语会议转成乱码中文）。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Meeting LLM

    private var selectedMeetingLLM: LLMProvider {
        LLMProvider(rawValue: configManager.meetingLLMProvider) ?? .openRouter
    }

    private var meetingLLMView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("AI 大模型（内容处理）")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: true)  // Meeting LLM is always cloud — no local option.
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("提供商")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textSecondary)
                        .frame(width: 60, alignment: .trailing)

                    Picker("", selection: $configManager.meetingLLMProvider) {
                        ForEach(LLMProvider.allCases.filter { $0 != .none }, id: \.self) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .frame(width: 160)
                    .onChange(of: configManager.meetingLLMProvider) { _, newProvider in
                        if configManager.meetingLLMCredentials[newProvider] == nil,
                           let provider = LLMProvider(rawValue: newProvider) {
                            configManager.meetingLLMCredentials[newProvider] = ProviderCredentials(
                                baseURL: provider.defaultBaseURL,
                                model: provider.defaultModel
                            )
                        }
                    }
                }

                if selectedMeetingLLM.requiresAPIKey {
                    HStack {
                        Text("API Key")
                            .font(.system(size: 13))
                            .foregroundColor(theme.textSecondary)
                            .frame(width: 60, alignment: .trailing)

                        SecureField("输入 API Key", text: meetingLLMCredentialBinding(keyPath: \.apiKey))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }
                }

                HStack {
                    Text("Base URL")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textSecondary)
                        .frame(width: 60, alignment: .trailing)

                    TextField("API 地址", text: meetingLLMCredentialBinding(keyPath: \.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                HStack {
                    Text("模型")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textSecondary)
                        .frame(width: 60, alignment: .trailing)

                    TextField("模型名称", text: meetingLLMCredentialBinding(keyPath: \.model))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(configManager.meetingLLMEnabled ? theme.accent : theme.textTertiary)
                            .frame(width: 8, height: 8)
                        Text(configManager.meetingLLMEnabled ? "已启用" : "未启用")
                            .font(.system(size: 13))
                            .foregroundColor(configManager.meetingLLMEnabled ? theme.accent : theme.textSecondary)
                    }

                    Spacer()

                    Button {
                        configManager.meetingLLMEnabled.toggle()
                        if configManager.meetingLLMEnabled
                            && configManager.meetingSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            configManager.meetingSummaryPrompt = MeetingSummarizer.defaultPrompt
                        }
                    } label: {
                        Text(configManager.meetingLLMEnabled ? "停止" : "启动")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(configManager.meetingLLMEnabled ? theme.destructive : theme.accentSecondary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("API Key / Base URL / 模型 与「语音」共享，同提供商无需重复输入")
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.textTertiary)

                Text("录制结束后自动生成会议摘要")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Custom Prompt

    private var customPromptView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("会议摘要提示词")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()

                Menu {
                    Section("内置模板") {
                        ForEach(PromptPreset.builtInMeetingPresets) { preset in
                            Button(preset.name) { configManager.meetingSummaryPrompt = preset.prompt }
                        }
                    }
                    if !configManager.meetingCustomPresets.isEmpty {
                        Section("我的模板") {
                            ForEach(configManager.meetingCustomPresets.sorted(by: { $0.key < $1.key }), id: \.key) { name, prompt in
                                Button(name) { configManager.meetingSummaryPrompt = prompt }
                            }
                            Divider()
                            Menu("删除我的模板…") {
                                ForEach(configManager.meetingCustomPresets.sorted(by: { $0.key < $1.key }), id: \.key) { name, _ in
                                    Button("删除 「\(name)」") {
                                        configManager.meetingCustomPresets.removeValue(forKey: name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack").font(.system(size: 11))
                        Text("应用模板").font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    newMeetingPresetName = ""
                    showSaveMeetingPresetSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                        Text("存为模板").font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                }
                .buttonStyle(.plain)
                .disabled(configManager.meetingSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("启用 AI 模型后生效。录制结束后模型会按下面要求整理录音内容。留空则使用默认风格（识别参会者、修正错别字、按议题整理、提取决议事项）。")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $configManager.meetingSummaryPrompt)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 80)
                    .padding(4)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )

                if configManager.meetingSummaryPrompt.isEmpty {
                    Text("点击「应用模板」选择一个会议类型，或自定义后点「存为模板」保存。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textPlaceholder)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showSaveMeetingPresetSheet) {
            saveMeetingPresetSheet
        }
    }

    private var saveMeetingPresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存为会议摘要模板")
                .font(.system(size: 14, weight: .semibold))
            Text("输入模板名称，下次开会前一键应用。同名将覆盖。")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
            TextField("模板名称（如：每周一产品评审）", text: $newMeetingPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveMeetingPreset() }
            HStack {
                Spacer()
                Button("取消") { showSaveMeetingPresetSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveMeetingPreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newMeetingPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func saveMeetingPreset() {
        let name = newMeetingPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.meetingCustomPresets[name] = configManager.meetingSummaryPrompt
        showSaveMeetingPresetSheet = false
    }

    // MARK: - Save Path

    private var savePathView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("保存路径")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
            }

            HStack(spacing: 8) {
                Text(configManager.meetingSavePath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: configManager.meetingSavePath))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.arrow.up.right")
                            .font(.system(size: 12))
                        Text("打开")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.surfaceBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    chooseSavePath()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("选择文件夹")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.surfaceBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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

    /// Meeting LLM creds share the *same* dictionary as the voice tab's
    /// `llmCredentials` — same provider name = same API key / Base URL / model.
    /// Users no longer have to enter the same OpenRouter key twice.
    private func meetingLLMCredentialBinding(keyPath: WritableKeyPath<ProviderCredentials, String>) -> Binding<String> {
        let provider = configManager.meetingLLMProvider
        return Binding(
            get: {
                configManager.llmCredentials[provider]?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                var creds = configManager.llmCredentials
                var providerCreds = creds[provider] ?? ProviderCredentials()
                providerCreds[keyPath: keyPath] = newValue
                creds[provider] = providerCreds
                configManager.llmCredentials = creds
            }
        )
    }

    /// One-time migration: copy any provider creds from the legacy
    /// `meetingLLMCredentials` storage into the shared `llmCredentials`,
    /// only when the shared dict has no entry for that provider yet.
    private func migrateMeetingCredentialsIfNeeded() {
        guard !configManager.meetingLLMCredentials.isEmpty else { return }
        var shared = configManager.llmCredentials
        var changed = false
        for (provider, creds) in configManager.meetingLLMCredentials {
            if shared[provider] == nil
                && (!creds.apiKey.isEmpty || !creds.baseURL.isEmpty || !creds.model.isEmpty) {
                shared[provider] = creds
                changed = true
            }
        }
        if changed {
            configManager.llmCredentials = shared
        }
    }
}
