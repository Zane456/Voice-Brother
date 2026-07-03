import SwiftUI

extension VoiceSettingsSection {
    // MARK: - ASR Model Card

    var asrModelCard: some View {
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
            .labelsHidden()
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
            // Apple (on-device, instant) and 0.6B 极速 first, heavier 1.7B 精确 last.
            Picker("", selection: $configManager.model) {
                ForEach([ASRModel.apple, ASRModel.small, ASRModel.large]) { model in
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

                Toggle("", isOn: Binding(
                    get: { asrModelLoaded },
                    set: { isOn in
                        if isOn { voiceService.start() } else { voiceService.stop() }
                    }
                ))
                .toggleStyle(CustomToggleStyle())
                .labelsHidden()
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("无需下载，使用系统内置语音识别引擎。")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Image(systemName: "globe").font(.system(size: 11))
                            Text("识别语言").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.textSecondary)

                        Picker("", selection: $configManager.voiceInputLanguage) {
                            ForEach(VoiceInputLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Text("Apple 引擎无法自动检测语言，请先选定语言。需在「系统设置 → 键盘 → 听写」中启用对应语言。")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    var asrStatusDotColor: Color {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return theme.statusOK
        case .error: return theme.statusFail
        default: return theme.border
        }
    }

    var asrStatusTextColor: Color {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return theme.statusOK
        case .error: return theme.statusFail
        default: return theme.textSecondary
        }
    }

    var asrModelLoaded: Bool {
        switch voiceService.state {
        case .ready, .recording, .transcribing: return true
        default: return false
        }
    }

    var asrStatusText: String {
        switch voiceService.state {
        case .stopped: return "模型未加载"
        case .downloading: return "下载中…"
        case .loading: return "加载中…"
        case .ready, .recording, .transcribing: return "模型已加载"
        case .error: return "加载失败"
        }
    }

    var isVolcano: Bool {
        configManager.cloudASRProvider == CloudASRProvider.volcanoASR.rawValue
    }
}
