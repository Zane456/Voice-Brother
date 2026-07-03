import SwiftUI

extension VoiceSettingsSection {
    // MARK: - Cloud ASR Model

    var cloudASRContent: some View {
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
            }

        }
    }
}
