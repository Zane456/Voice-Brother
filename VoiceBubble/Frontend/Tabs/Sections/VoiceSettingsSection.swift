import SwiftUI

struct VoiceSettingsSection: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var theme: ThemeManager

    @State private var previousModel: String = ""
    @State private var previousTriggerKey: String = ""

    // Cloud switch confirmation (only ASR has local↔cloud toggle now)
    @State private var showASRCloudConfirm = false

    // Prompt preset save dialog
    @State private var showSavePolishPresetSheet = false
    @State private var newPolishPresetName = ""

    // Vocabulary state
    @State private var newHotword = ""
    @State private var showNewRuleEditor = false
    @State private var newRuleFrom = ""
    @State private var newRuleTo = ""
    @State private var editingRuleId: UUID? = nil
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var hasUnsavedChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Input Behavior toggles (moved from 通用 tab)
            inputBehaviorCard

            SectionHeader(title: "语音设置")

            // Trigger Key
            triggerKeyCard

            // ASR Model Card
            asrModelCard

            // LLM Model Card
            llmModelCard

            // AI Polish Prompt
            llmNotesView

            // Hotwords
            hotwordsView

            // Replacement Rules
            replacementRulesView
        }
        .alert("切换到云端语音识别？", isPresented: $showASRCloudConfirm) {
            Button("取消", role: .cancel) {
                configManager.asrProviderType = "local"
            }
            Button("我已了解，使用云端") {
                if asrModelLoaded { voiceService.stop() }
            }
        } message: {
            Text("音频将通过网络发送至所选云端服务商，受其隐私政策约束。请勿用于敏感对话录入。")
        }
    }

    // MARK: - Input Behavior

    private var inputBehaviorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "输入行为")

            VStack(spacing: 0) {
                toggleRow(title: "语气词过滤",
                          subtitle: "自动删除「嗯」「啊」「那个」等口头禅",
                          isOn: Binding(get: { voiceService.removeFillers }, set: { voiceService.removeFillers = $0 }))

                Divider().padding(.horizontal, 16)

                toggleRow(title: "空格重定位",
                          subtitle: "录音中按空格键在鼠标位置点击，切换输入位置",
                          isOn: Binding(get: { voiceService.spaceReposition }, set: { voiceService.spaceReposition = $0 }))

                Divider().padding(.horizontal, 16)

                toggleRow(title: "剪贴板保护",
                          subtitle: "保留之前复制的内容（图片、文件等），关闭则直接覆盖",
                          isOn: $configManager.preserveClipboard)

                Divider().padding(.horizontal, 16)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("实时预览")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.textPrimary)
                            Text("录音时在悬浮窗旁边实时显示转写文字")
                                .font(.system(size: 11))
                                .foregroundColor(theme.textTertiary)
                        }
                        Spacer()
                        Toggle("", isOn: $configManager.streamingPreview)
                            .toggleStyle(CustomToggleStyle())
                            .labelsHidden()
                    }
                    .padding(16)

                    if configManager.streamingPreview {
                        Divider().padding(.horizontal, 16)

                        HStack {
                            Text("预览字号")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                            Text("\(Int(configManager.previewFontSize))")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundColor(theme.textPrimary)
                                .frame(width: 24)
                            Slider(value: $configManager.previewFontSize, in: 12...28, step: 1)
                                .frame(width: 120)
                        }
                        .padding(16)
                        .transition(.opacity)
                    }
                }
            }
            .glassCard()
        }
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(CustomToggleStyle()).labelsHidden()
        }
        .padding(16)
    }

    // MARK: - Provenance Badge

    private func provenanceBadge(isCloud: Bool) -> some View {
        CodexBadge(text: isCloud ? "云端" : "本地",
                   variant: isCloud ? .cloud : .local)
    }

    // MARK: - Trigger Key

    private var triggerKeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("录音按键")
                    .font(.system(size: 14))
                    .foregroundColor(theme.textPrimary)
                    .frame(width: 80, alignment: .leading)

                Picker("", selection: $configManager.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
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

            Text("长按开始录音，松手后自动录入文字。默认使用右 Option ⌥（避免与中文输入法切换冲突）")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - ASR Model Card

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
                provenanceBadge(isCloud: configManager.asrProviderType == "cloud")
            }

            Picker("", selection: $configManager.asrProviderType) {
                Text("本地模型").tag("local")
                Text("云端模型").tag("cloud")
            }
            .pickerStyle(.segmented)
            .tint(theme.accent)
            .onChange(of: configManager.asrProviderType) { oldValue, newValue in
                if oldValue == "local" && newValue == "cloud" {
                    showASRCloudConfirm = true
                } else if asrModelLoaded {
                    voiceService.stop()
                }
            }

            if configManager.asrProviderType == "local" {
                localASRContent
            } else {
                cloudASRContent
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var localASRContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Three-way segmented picker — all options visible at once instead of
            // hidden behind a menu. Use displayName (含极速/精确/Apple) for clarity.
            Picker("", selection: $configManager.model) {
                ForEach(ASRModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: configManager.model) { _, newValue in
                guard newValue != previousModel else { return }
                let wasLoaded = asrModelLoaded
                previousModel = newValue
                if wasLoaded {
                    // Switch model in place: stop the old engine, then immediately
                    // start the new one so the user doesn't have to click "启动" again.
                    voiceService.stop()
                    voiceService.start()
                }
            }

            // Same metadata layout for ALL three models — prevents the card from
            // shrinking/growing when the user toggles between Apple and Qwen.
            if let currentModel = ASRModel(rawValue: configManager.model) {
                HStack(spacing: 8) {
                    modelInfoTag(
                        icon: currentModel.isApple ? "apple.logo" : "cpu",
                        text: currentModel.quantization
                    )
                    modelInfoTag(icon: "internaldrive", text: currentModel.estimatedSize)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(asrStatusDotColor)
                    .frame(width: 8, height: 8)
                Text(asrStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(asrStatusTextColor)

                Spacer()

                Button(action: {
                    if asrModelLoaded {
                        voiceService.stop()
                    } else {
                        voiceService.start()
                    }
                }) {
                    Text(asrActionLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(asrModelLoaded ? theme.stop : theme.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!permissionManager.status.allGranted && !asrModelLoaded)
            }

            if case .downloading = voiceService.state, let progress = voiceService.downloadProgress {
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.border)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.accent)
                                .frame(width: max(6, geometry.size.width * progress.fraction), height: 6)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(progress.percentageText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("\(byteString(progress.downloaded)) / \(byteString(progress.total))")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                    }
                }
            }

            if case .error(let message) = voiceService.state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.stop)
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(theme.stop)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.stop.opacity(0.08)))
            }

            if let currentModel = ASRModel(rawValue: configManager.model) {
                if currentModel.isApple {
                    Text("无需下载，使用系统内置语音识别引擎。需在「系统设置 → 键盘 → 听写」中启用中文（简体）。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("首次启动需下载模型（\(currentModel.estimatedSize)）。下载由 HuggingFace 提供，国内网络若卡住可点「重试」继续。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var asrStatusDotColor: Color {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return .green
        case .error: return theme.stop
        default: return theme.border
        }
    }

    private var asrStatusTextColor: Color {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return .green
        case .error: return theme.stop
        default: return theme.textSecondary
        }
    }

    private var asrActionLabel: String {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return "停止"
        case .error: return "重试"
        default: return "启动"
        }
    }

    private var asrModelLoaded: Bool {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return true
        default: return false
        }
    }

    private var asrStatusText: String {
        switch voiceService.state {
        case .stopped: return "模型未加载"
        case .downloading: return "下载中…"
        case .loading: return "加载中…"
        case .ready, .recording, .transcribing: return "模型已加载"
        case .error: return "加载失败"
        }
    }

    private var isVolcano: Bool {
        configManager.cloudASRProvider == CloudASRProvider.volcanoASR.rawValue
    }

    private var cloudASRContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            configRow(label: "提供商") {
                Picker("", selection: $configManager.cloudASRProvider) {
                    ForEach(CloudASRProvider.allCases.filter { $0.isImplemented }) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: configManager.cloudASRProvider) { _, newProvider in
                    if let provider = CloudASRProvider(rawValue: newProvider) {
                        var creds = configManager.cloudASRCredentials
                        if creds[newProvider] == nil {
                            creds[newProvider] = ProviderCredentials(
                                baseURL: provider.defaultBaseURL,
                                model: provider.defaultModel
                            )
                            configManager.cloudASRCredentials = creds
                        }
                    }
                    if asrModelLoaded {
                        voiceService.stop()
                    }
                }
            }

            configRow(label: isVolcano ? "App ID" : "API Key") {
                if isVolcano {
                    TextField("应用 ID", text: credentialBinding(
                        credentials: $configManager.cloudASRCredentials,
                        provider: configManager.cloudASRProvider,
                        keyPath: \.apiKey
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                } else {
                    SecureField("输入 API Key", text: credentialBinding(
                        credentials: $configManager.cloudASRCredentials,
                        provider: configManager.cloudASRProvider,
                        keyPath: \.apiKey
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }
            }

            configRow(label: isVolcano ? "Access Token" : "Base URL") {
                if isVolcano {
                    // Volcano's access token is a secret → mask it.
                    SecureField("访问令牌", text: credentialBinding(
                        credentials: $configManager.cloudASRCredentials,
                        provider: configManager.cloudASRProvider,
                        keyPath: \.baseURL
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                } else {
                    // Base URL is not a secret — keep it visible so users can
                    // verify their paste matches the expected endpoint.
                    TextField("API 地址", text: credentialBinding(
                        credentials: $configManager.cloudASRCredentials,
                        provider: configManager.cloudASRProvider,
                        keyPath: \.baseURL
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }
            }

            configRow(label: isVolcano ? "识别模型" : "模型") {
                TextField(isVolcano ? "volc.seedasr.sauc.duration" : "模型名称", text: credentialBinding(
                    credentials: $configManager.cloudASRCredentials,
                    provider: configManager.cloudASRProvider,
                    keyPath: \.model
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(asrModelLoaded ? Color.green : theme.border)
                    .frame(width: 8, height: 8)
                Text(asrStatusText)
                    .font(.system(size: 13))
                    .foregroundColor(asrModelLoaded ? Color.green : theme.textSecondary)

                Spacer()

                Button(action: {
                    if asrModelLoaded {
                        voiceService.stop()
                    } else {
                        voiceService.start()
                    }
                }) {
                    Text(asrModelLoaded ? "停止" : "启动")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(asrModelLoaded ? theme.stop : theme.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Text(isVolcano ? "使用火山引擎豆包语音识别，需要网络连接" : "云端 ASR 需要网络连接，识别结果取决于所选服务商")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
        }
    }

    // MARK: - LLM Model Card

    private var llmModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentSecondary)
                Text("AI 大模型（文本优化）")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                provenanceBadge(isCloud: true)  // LLM polishing is always cloud — local option retired.
            }

            // Local LLM option intentionally removed — text post-processing is
            // a low-frequency operation, no need for the heavy local model.
            cloudLLMContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var cloudLLMContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            configRow(label: "提供商") {
                Picker("", selection: $configManager.llmProvider) {
                    ForEach(LLMProvider.allCases.filter { $0 != .none }) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: configManager.llmProvider) { _, newProvider in
                    if let provider = LLMProvider(rawValue: newProvider), provider != .none {
                        var creds = configManager.llmCredentials
                        if creds[newProvider] == nil {
                            creds[newProvider] = ProviderCredentials(
                                baseURL: provider.defaultBaseURL,
                                model: provider.defaultModel
                            )
                            configManager.llmCredentials = creds
                        }
                    }
                }
            }

            if let selectedLLM = LLMProvider(rawValue: configManager.llmProvider), selectedLLM != .none {
                if selectedLLM.requiresAPIKey {
                    configRow(label: "API Key") {
                        SecureField("输入 API Key", text: credentialBinding(
                            credentials: $configManager.llmCredentials,
                            provider: selectedLLM.rawValue,
                            keyPath: \.apiKey
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    }
                }

                configRow(label: "Base URL") {
                    TextField("API 地址", text: credentialBinding(
                        credentials: $configManager.llmCredentials,
                        provider: selectedLLM.rawValue,
                        keyPath: \.baseURL
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }

                configRow(label: "模型") {
                    TextField("模型名称", text: credentialBinding(
                        credentials: $configManager.llmCredentials,
                        provider: selectedLLM.rawValue,
                        keyPath: \.model
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(configManager.cloudLLMEnabled ? Color.green : theme.border)
                    .frame(width: 8, height: 8)
                Text(configManager.cloudLLMEnabled ? "已启用" : "未启用")
                    .font(.system(size: 13))
                    .foregroundColor(configManager.cloudLLMEnabled ? Color.green : theme.textSecondary)

                Spacer()

                Button(action: {
                    configManager.cloudLLMEnabled.toggle()
                }) {
                    Text(configManager.cloudLLMEnabled ? "停止" : "启动")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(configManager.cloudLLMEnabled ? theme.stop : theme.accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            if let selectedLLM = LLMProvider(rawValue: configManager.llmProvider), selectedLLM.isLocal {
                Text("使用本地 Ollama 服务，无需 API Key，请确保 Ollama 已启动")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
            } else {
                Text("点击「启动」后，语音转写将通过云端 AI 大模型优化")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
            }
        }
    }

    // MARK: - AI Polish Prompt

    private var allPolishPresets: [PromptPreset] {
        let custom = configManager.polishCustomPresets.map { name, prompt in
            PromptPreset(id: "user.\(name)", name: name, prompt: prompt, isBuiltIn: false)
        }.sorted { $0.name < $1.name }
        return PromptPreset.builtInPolishPresets + custom
    }

    private var llmNotesView: some View {
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

            Text("需在上方启动 AI 模型后生效。语音转写完成后，模型会根据以下要求对文本进行润色。留空则使用默认优化（补充标点、修正口语表达）。")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $configManager.localLLMNotes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 80)
                    .padding(4)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )

                if configManager.localLLMNotes.isEmpty {
                    Text("点击「应用预设」选一个开始，或自定义后点「存为预设」保存。")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textPlaceholder)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 13)
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
    }

    private func savePolishPreset() {
        let name = newPolishPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.polishCustomPresets[name] = configManager.localLLMNotes
        showSavePolishPresetSheet = false
    }

    // MARK: - Hotwords

    private var hotwordsView: some View {
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

    // MARK: - Replacement Rules

    private var replacementRulesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "替换规则")

                Spacer()

                Button {
                    withAnimation {
                        showNewRuleEditor = true
                        newRuleFrom = ""
                        newRuleTo = ""
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("添加规则")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.accentSecondary)
                }
                .buttonStyle(.plain)
            }

            Text("识别后自动替换的文字")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

            if showNewRuleEditor {
                newRuleEditorRow
            }

            VStack(spacing: 6) {
                ForEach(configManager.replacements) { rule in
                    if editingRuleId == rule.id {
                        editingRuleRow(rule)
                    } else {
                        ruleRow(rule)
                    }
                }
            }
        }
    }

    private var newRuleEditorRow: some View {
        HStack(spacing: 8) {
            TextField("错误词", text: $newRuleFrom)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            TextField("正确词", text: $newRuleTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )
                .onSubmit {
                    addRule()
                }

            Button {
                addRule()
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.accent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(newRuleFrom.trimmingCharacters(in: .whitespaces).isEmpty || newRuleTo.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                withAnimation {
                    showNewRuleEditor = false
                }
            } label: {
                Text("取消")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: theme.accentSecondary)
    }

    private func ruleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 8) {
            Text(rule.from)
                .font(.system(size: 13))
                .foregroundColor(theme.destructive)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.destructiveBackground)
                .cornerRadius(6)

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            Text(rule.to)
                .font(.system(size: 13))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.successBackground)
                .cornerRadius(6)

            Spacer()

            Button {
                withAnimation {
                    editingRuleId = rule.id
                    editFrom = rule.from
                    editTo = rule.to
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)

            Button {
                removeRule(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(theme.destructive)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10)
    }

    private func editingRuleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 8) {
            TextField("错误词", text: $editFrom)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)

            TextField("正确词", text: $editTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 140)
                .background(theme.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentSecondary, lineWidth: 1)
                )

            Button {
                saveEdit(rule)
            } label: {
                Text("保存")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.accent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation {
                    editingRuleId = nil
                }
            } label: {
                Text("取消")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 10, borderColor: theme.accentSecondary)
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

    private func configRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func credentialBinding(
        credentials: Binding<[String: ProviderCredentials]>,
        provider: String,
        keyPath: WritableKeyPath<ProviderCredentials, String>
    ) -> Binding<String> {
        Binding(
            get: { credentials.wrappedValue[provider]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var creds = credentials.wrappedValue
                var providerCreds = creds[provider] ?? ProviderCredentials()
                providerCreds[keyPath: keyPath] = newValue
                creds[provider] = providerCreds
                credentials.wrappedValue = creds
            }
        )
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Actions

    private func addHotword() {
        let word = newHotword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        guard !configManager.hotwords.contains(word) else {
            newHotword = ""
            return
        }
        configManager.hotwords.append(word)
        newHotword = ""
        markChanged()
    }

    private func removeHotword(_ word: String) {
        configManager.hotwords.removeAll { $0 == word }
        markChanged()
    }

    private func addRule() {
        let from = newRuleFrom.trimmingCharacters(in: .whitespaces)
        let to = newRuleTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty && !to.isEmpty else { return }

        let rule = ReplacementRule(from: from, to: to)
        configManager.replacements.append(rule)

        withAnimation {
            showNewRuleEditor = false
            newRuleFrom = ""
            newRuleTo = ""
        }
        markChanged()
    }

    private func removeRule(_ rule: ReplacementRule) {
        configManager.replacements.removeAll { $0.id == rule.id }
        markChanged()
    }

    private func saveEdit(_ rule: ReplacementRule) {
        let from = editFrom.trimmingCharacters(in: .whitespaces)
        let to = editTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty && !to.isEmpty else { return }

        if let index = configManager.replacements.firstIndex(where: { $0.id == rule.id }) {
            configManager.replacements[index] = ReplacementRule(id: rule.id, from: from, to: to)
        }

        withAnimation {
            editingRuleId = nil
        }
        markChanged()
    }

    private func markChanged() {
        hasUnsavedChanges = true
    }
}
