import Combine
import Foundation

/// Thin wrapper around AppConfig for dependency injection.
///
/// Forwards every property directly to the underlying AppConfig via computed
/// accessors so there's a single source of truth. Any external mutation of
/// AppConfig (e.g. the Voice Aura migration path) is immediately visible to
/// SwiftUI because `objectWillChange` is bridged from AppConfig's publisher.
final class ConfigManager: ObservableObject, ConfigManagerProtocol {

    let appConfig: AppConfig
    private var cancellable: AnyCancellable?

    init(appConfig: AppConfig? = nil) {
        let config = appConfig ?? AppConfig()
        self.appConfig = config
        // Re-emit AppConfig's objectWillChange so any SwiftUI view observing
        // ConfigManager re-renders when AppConfig itself is mutated outside
        // the wrapper (migrations, external saves, etc.).
        self.cancellable = config.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Forwarded properties (read/write via appConfig)

    var triggerKey: String {
        get { appConfig.triggerKey }
        set { appConfig.triggerKey = newValue }
    }
    var model: String {
        get { appConfig.model }
        set { appConfig.model = newValue }
    }
    var hotwords: [String] {
        get { appConfig.hotwords }
        set { appConfig.hotwords = newValue }
    }
    var replacements: [ReplacementRule] {
        get { appConfig.replacements }
        set { appConfig.replacements = newValue }
    }
    var removeFillers: Bool {
        get { appConfig.removeFillers }
        set { appConfig.removeFillers = newValue }
    }
    var spaceReposition: Bool {
        get { appConfig.spaceReposition }
        set { appConfig.spaceReposition = newValue }
    }
    var meetingSavePath: String {
        get { appConfig.meetingSavePath }
        set { appConfig.meetingSavePath = newValue }
    }
    var preserveClipboard: Bool {
        get { appConfig.preserveClipboard }
        set { appConfig.preserveClipboard = newValue }
    }
    var streamingPreview: Bool {
        get { appConfig.streamingPreview }
        set { appConfig.streamingPreview = newValue }
    }
    var previewFontSize: Double {
        get { appConfig.previewFontSize }
        set { appConfig.previewFontSize = newValue }
    }
    var onboardingDone: Bool {
        get { appConfig.onboardingDone }
        set { appConfig.onboardingDone = newValue }
    }

    // MARK: - Model Management

    var asrProviderType: String {
        get { appConfig.asrProviderType }
        set { appConfig.asrProviderType = newValue }
    }
    var cloudASRProvider: String {
        get { appConfig.cloudASRProvider }
        set { appConfig.cloudASRProvider = newValue }
    }
    var cloudASRCredentials: [String: ProviderCredentials] {
        get { appConfig.cloudASRCredentials }
        set { appConfig.cloudASRCredentials = newValue }
    }
    var llmProviderType: String {
        get { appConfig.llmProviderType }
        set { appConfig.llmProviderType = newValue }
    }
    var polishModel: String {
        get { appConfig.polishModel }
        set { appConfig.polishModel = newValue }
    }
    var llmProvider: String {
        get { appConfig.llmProvider }
        set { appConfig.llmProvider = newValue }
    }
    var llmCredentials: [String: ProviderCredentials] {
        get { appConfig.llmCredentials }
        set { appConfig.llmCredentials = newValue }
    }
    var localLLMNotes: String {
        get { appConfig.localLLMNotes }
        set { appConfig.localLLMNotes = newValue }
    }
    var cloudLLMEnabled: Bool {
        get { appConfig.cloudLLMEnabled }
        set { appConfig.cloudLLMEnabled = newValue }
    }

    // MARK: - Meeting ASR
    //
    // Removed in v1.x — the meeting ASR config (provider type, model, cloud
    // creds) was a phantom: persisted by the UI but never read by
    // MeetingService at runtime. Meetings borrow the engine that VoiceService
    // already loaded from `configManager.model`. Old UserDefaults keys
    // (`meetingASRProviderType`, `meetingModel`, `meetingCloudASRProvider`,
    // `meetingCloudASRCredentials`) become harmless dead keys after this change.

    // MARK: - Meeting LLM

    var meetingLLMProvider: String {
        get { appConfig.meetingLLMProvider }
        set { appConfig.meetingLLMProvider = newValue }
    }
    var meetingLLMCredentials: [String: ProviderCredentials] {
        get { appConfig.meetingLLMCredentials }
        set { appConfig.meetingLLMCredentials = newValue }
    }
    var meetingLLMEnabled: Bool {
        get { appConfig.meetingLLMEnabled }
        set { appConfig.meetingLLMEnabled = newValue }
    }
    var meetingSummaryPrompt: String {
        get { appConfig.meetingSummaryPrompt }
        set { appConfig.meetingSummaryPrompt = newValue }
    }
    /// Selected ASR language for meetings. Stored as raw string but exposed as
    /// the typed enum to consumers; falls back to Chinese on unknown values.
    var meetingLanguage: MeetingLanguage {
        get { MeetingLanguage(rawValue: appConfig.meetingLanguage) ?? .auto }
        set { appConfig.meetingLanguage = newValue.rawValue }
    }

    // MARK: - Prompt Presets

    var polishCustomPresets: [String: String] {
        get { appConfig.polishCustomPresets }
        set { appConfig.polishCustomPresets = newValue }
    }
    var meetingCustomPresets: [String: String] {
        get { appConfig.meetingCustomPresets }
        set { appConfig.meetingCustomPresets = newValue }
    }

    // MARK: - Privacy

    var privacyMode: Bool {
        get { appConfig.privacyMode }
        set { appConfig.privacyMode = newValue }
    }

    // MARK: - Self-Learning

    var selfLearningEnabled: Bool {
        get { appConfig.selfLearningEnabled }
        set { appConfig.selfLearningEnabled = newValue }
    }
    var selfLearningThreshold: Int {
        get { appConfig.selfLearningThreshold }
        set { appConfig.selfLearningThreshold = newValue }
    }

    // MARK: - ConfigManagerProtocol

    /// Forces an immediate disk flush. AppConfig persists automatically on
    /// every mutation via debounced didSet, so explicit callers are rare — this
    /// mainly exists so app-termination paths can guarantee pending changes
    /// are written before exit.
    func save() {
        appConfig.save()
    }

    func isFreshInstall() -> Bool {
        appConfig.isFreshInstall()
    }
}
