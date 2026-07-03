import Foundation
import Combine

// MARK: - Voice Service Protocol

protocol VoiceServiceProtocol: ObservableObject {
    var state: ServiceState { get }
    var downloadProgress: DownloadProgress? { get }
    var spaceReposition: Bool { get set }

    func start()
    func stop()
    func setMeetingActive(_ active: Bool)
}

// MARK: - Meeting Service Protocol

protocol MeetingServiceProtocol: ObservableObject {
    var state: MeetingState { get }
    var elapsedSeconds: Int { get }
    var savePath: String { get set }
    var summaryError: String? { get }

    func start()
    func stop()
    func toggle()
}

// MARK: - Config Manager Protocol

protocol ConfigManagerProtocol: ObservableObject {
    var triggerKey: String { get set }
    var model: String { get set }
    var hotwords: [String] { get set }
    var replacements: [ReplacementRule] { get set }
    var removeFillers: Bool { get set }
    var spaceReposition: Bool { get set }
    var meetingSavePath: String { get set }
    var preserveClipboard: Bool { get set }
    var onboardingDone: Bool { get set }

    // Model management
    var asrProviderType: String { get set }
    var cloudASRProvider: String { get set }
    var cloudASRCredentials: [String: ProviderCredentials] { get set }
    var llmProvider: String { get set }
    var llmCredentials: [String: ProviderCredentials] { get set }
    var localLLMNotes: String { get set }
    var cloudLLMEnabled: Bool { get set }

    // Meeting ASR — shares engine with voice input (configManager.model).
    // No separate meeting ASR config; the meeting LLM (summary) is independent below.

    // Meeting LLM — provider and credentials shared with voice
    // (`llmProvider` / `llmCredentials`); the meeting-specific model lives in
    // `ProviderCredentials.meetingModel`.
    var meetingLLMEnabled: Bool { get set }

    // Prompt presets
    var polishCustomPresets: [String: String] { get set }

    func save()
    func isFreshInstall() -> Bool
}

// MARK: - Permission Manager Protocol

protocol PermissionManagerProtocol: ObservableObject {
    var status: PermissionStatus { get }

    func recheckAll()
    func openAccessibilitySettings()
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
}

// MARK: - ASR Engine Protocol

protocol ASREngineProtocol: AnyObject {
    /// Returns transcribed text, or empty string on failure. Non-throwing — wrappers handle errors internally.
    /// `language` is a hint for engines that support it (Qwen3-ASR, Volcano).
    /// Pass `nil` for auto-detect: Qwen3-ASR drops the language token from its
    /// prompt template, freeing the decoder across CJK/Latin scripts; Volcano
    /// falls back to its server-side default.
    func transcribe(audio: [Float], sampleRate: Int, language: String?, context: String?) -> String
    func unload()
}
