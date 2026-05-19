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
    var historyRetentionMonths: Int {
        get { appConfig.historyRetentionMonths }
        set { appConfig.historyRetentionMonths = newValue }
    }
    var meetingRetentionMonths: Int {
        get { appConfig.meetingRetentionMonths }
        set { appConfig.meetingRetentionMonths = newValue }
    }
    var onboardingDone: Bool {
        get { appConfig.onboardingDone }
        set { appConfig.onboardingDone = newValue }
    }
    var lastHistoryKind: String {
        get { appConfig.lastHistoryKind }
        set { appConfig.lastHistoryKind = newValue }
    }
    var meetingScreenRecording: Bool {
        get { appConfig.meetingScreenRecording }
        set { appConfig.meetingScreenRecording = newValue }
    }
    /// Screen-recording clarity tier. Stored as a raw string; falls back to
    /// HD (1080p) on unknown values.
    var meetingVideoQuality: MeetingVideoQuality {
        get { MeetingVideoQuality(rawValue: appConfig.meetingVideoQuality) ?? .hd }
        set { appConfig.meetingVideoQuality = newValue.rawValue }
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

    var meetingLLMEnabled: Bool {
        get { appConfig.meetingLLMEnabled }
        set { appConfig.meetingLLMEnabled = newValue }
    }
    /// Selected ASR language for meetings. Stored as raw string but exposed as
    /// the typed enum to consumers; falls back to Chinese on unknown values.
    var meetingLanguage: MeetingLanguage {
        get { MeetingLanguage(rawValue: appConfig.meetingLanguage) ?? .auto }
        set { appConfig.meetingLanguage = newValue.rawValue }
    }

    /// Voice-input transcription language for the Apple Speech engine. Stored
    /// as a raw string; falls back to Chinese on unknown values. The Qwen
    /// engine ignores this and auto-detects.
    var voiceInputLanguage: VoiceInputLanguage {
        get { VoiceInputLanguage(rawValue: appConfig.voiceInputLanguage) ?? .chinese }
        set { appConfig.voiceInputLanguage = newValue.rawValue }
    }

    /// ASR model for meeting transcription, independent of voice input's
    /// `model`. Constrained to local Qwen models — an Apple/cloud value (or
    /// anything unknown) falls back to the 0.6B model.
    var meetingASRModel: ASRModel {
        get {
            guard let m = ASRModel(rawValue: appConfig.meetingASRModel), m.isQwen else { return .small }
            return m
        }
        set { appConfig.meetingASRModel = newValue.rawValue }
    }

    // MARK: - Prompt Presets

    var polishCustomPresets: [String: String] {
        get { appConfig.polishCustomPresets }
        set { appConfig.polishCustomPresets = newValue }
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
