import SwiftUI

struct VoiceSettingsSection: View {
    @EnvironmentObject var configManager: ConfigManager
    @EnvironmentObject var voiceService: VoiceService
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var theme: ThemeManager

    @State var previousModel: String = ""
    @State var previousTriggerKey: String = ""

    // Cloud switch confirmation (only ASR has local↔cloud toggle now)
    @State var showASRCloudConfirm = false

    /// Whether the Apple engine's model asset for the selected 识别语言 is on the
    /// machine. nil = unknown / not applicable (pre-macOS 26). Refreshed by a
    /// `.task(id:)` on the language picker, because a missing asset makes the
    /// first recording silently fall back to the legacy engine.
    @State var appleLanguageAssetReady: Bool? = nil

    // Prompt preset save dialog
    @State var showSavePolishPresetSheet = false
    @State var newPolishPresetName = ""

    // Vocabulary state
    @State var newHotword = ""
    @State var showNewRuleEditor = false
    @State var newRuleFrom = ""
    @State var newRuleTo = ""
    @State var editingRuleId: UUID? = nil
    @State var editFrom = ""
    @State var editTo = ""
    @State var hasUnsavedChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 输入行为 toggles (语气词过滤/空格重定位/剪贴板保护) all live in
            // the 通用 tab now — gathered in one place.

            // Trigger Key
            triggerKeyCard

            SectionHeader(title: "语音输入模型设置")

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

    // MARK: - Provenance Badge

    func provenanceBadge(isCloud: Bool) -> some View {
        CodexBadge(text: isCloud ? "云端" : "本地",
                   variant: isCloud ? .cloud : .local)
    }

    // MARK: - Helpers

    func modelInfoTag(icon: String, text: String) -> some View {
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

    func configRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func credentialBinding(
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

    func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Actions

    func addHotword() {
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

    func removeHotword(_ word: String) {
        configManager.hotwords.removeAll { $0 == word }
        markChanged()
    }

    func addRule() {
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

    func removeRule(_ rule: ReplacementRule) {
        configManager.replacements.removeAll { $0.id == rule.id }
        markChanged()
    }

    func saveEdit(_ rule: ReplacementRule) {
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
