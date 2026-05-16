import SwiftUI

/// Unified AI 大模型 API config card, shown in the 通用 settings page.
/// Voice input and meeting summary share one provider / API Key / Base URL;
/// each keeps its own model field. The on/off switches stay on the 语音
/// and 会议 pages — this card is config only, no enable toggle.
struct LLMConfigCard: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var theme: ThemeManager

    /// Result of the most recent 测试连接 tap. Reset whenever the provider or
    /// any credential field changes, so a stale "成功" never lingers.
    @State private var testState: TestState = .idle

    private enum TestState {
        case idle, testing, success
        case failure(String)
    }

    private var isTesting: Bool {
        if case .testing = testState { return true }
        return false
    }

    private var selectedLLM: LLMProvider? {
        let p = LLMProvider(rawValue: configManager.llmProvider)
        return p == LLMProvider.none ? nil : p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "AI 大模型")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentSecondary)
                    Text("API 配置")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    CodexBadge(text: "云端", variant: .cloud)
                }

                configRow(label: "提供商") {
                    Picker("", selection: $configManager.llmProvider) {
                        ForEach(LLMProvider.allCases.filter { $0 != LLMProvider.none }) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: configManager.llmProvider) { _, newProvider in
                        testState = .idle
                        if let provider = LLMProvider(rawValue: newProvider), provider != LLMProvider.none {
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

                if let provider = selectedLLM {
                    if provider.requiresAPIKey {
                        configRow(label: "API Key") {
                            SecureField("输入 API Key", text: credentialBinding(provider: provider.rawValue, keyPath: \.apiKey))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }
                    }

                    configRow(label: "Base URL") {
                        TextField("API 地址", text: credentialBinding(provider: provider.rawValue, keyPath: \.baseURL))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    Divider().padding(.vertical, 2)

                    configRow(label: "语音润色模型") {
                        TextField("官方模型 ID，如 glm-5-turbo", text: credentialBinding(provider: provider.rawValue, keyPath: \.model))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    configRow(label: "声音录制模型") {
                        TextField("留空则与语音润色模型相同", text: credentialBinding(provider: provider.rawValue, keyPath: \.meetingModel))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    configRow(label: "连接测试") {
                        HStack(spacing: 8) {
                            Button {
                                runConnectionTest(provider: provider)
                            } label: {
                                HStack(spacing: 4) {
                                    if isTesting {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "bolt.horizontal.circle")
                                    }
                                    Text(isTesting ? "测试中…" : "测试连接")
                                }
                                .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(theme.accent)
                            .disabled(isTesting)

                            testResultView
                            Spacer()
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("语音输入与声音录制共用此配置，在「语音」「声音录制」页分别开启")
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    // MARK: - Helpers

    private func configRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.textSecondary)
                .fixedSize()
                .frame(width: 84, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func credentialBinding(
        provider: String,
        keyPath: WritableKeyPath<ProviderCredentials, String>
    ) -> Binding<String> {
        Binding(
            get: { configManager.llmCredentials[provider]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var creds = configManager.llmCredentials
                var providerCreds = creds[provider] ?? ProviderCredentials()
                providerCreds[keyPath: keyPath] = newValue
                creds[provider] = providerCreds
                configManager.llmCredentials = creds
                // Editing any field invalidates a prior test result.
                testState = .idle
            }
        )
    }

    // MARK: - Connection Test

    @ViewBuilder private var testResultView: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success:
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.success)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.stop)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Fire a minimal LLM call with the currently-entered credentials so the
    /// user can confirm API Key + Base URL + model ID actually work before
    /// relying on them. A wrong model ID surfaces here as an API error.
    private func runConnectionTest(provider: LLMProvider) {
        let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
        if provider.requiresAPIKey,
           creds.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            testState = .failure("请先填写 API Key")
            return
        }
        testState = .testing
        Task {
            let client = LLMClient(provider: provider, credentials: creds,
                                   userNotes: "", timeout: 20, maxTokens: 32)
            do {
                let reply = try await client.call(
                    systemPrompt: "你是连接测试助手，收到消息后只回复 ok。",
                    userMessage: "ping"
                )
                testState = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .failure("API 响应为空") : .success
            } catch {
                testState = .failure(Self.shortError(error))
            }
        }
    }

    private static func shortError(_ error: Error) -> String {
        let raw = (error as? LLMError)?.errorDescription ?? error.localizedDescription
        return raw.count > 140 ? String(raw.prefix(140)) + "…" : raw
    }
}
