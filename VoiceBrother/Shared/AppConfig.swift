import AppKit
import Combine
import Foundation

/// Configuration model - all user settings are persisted here.
final class AppConfig: ObservableObject {

    // MARK: - Debounced save

    /// Coalesces rapid-fire `didSet`s (slider drags, batch edits) into a single
    /// disk write. Without this, dragging a slider once can fire 60+ saves per
    /// second, each writing 30+ UserDefaults keys plus 6 JSON encodes.
    private var pendingSaveWorkItem: DispatchWorkItem?
    private static let saveDebounceInterval: TimeInterval = 0.25
    private var willTerminateObserver: NSObjectProtocol?

    // MARK: - Published settings
    @Published var triggerKey: String {
        didSet { scheduleSave() }
    }
    @Published var model: String {
        didSet { scheduleSave() }
    }
    @Published var hotwords: [String] {
        didSet { scheduleSave() }
    }
    @Published var replacements: [ReplacementRule] {
        didSet { scheduleSave() }
    }
    @Published var removeFillers: Bool {
        didSet { scheduleSave() }
    }
    @Published var spaceReposition: Bool {
        didSet { scheduleSave() }
    }
    @Published var meetingSavePath: String {
        didSet { scheduleSave() }
    }
    @Published var preserveClipboard: Bool {
        didSet { scheduleSave() }
    }
    /// Retention window (months) for voice transcription history.
    @Published var historyRetentionMonths: Int {
        didSet { scheduleSave() }
    }
    /// Retention window (months) for meeting markdown + audio files.
    @Published var meetingRetentionMonths: Int {
        didSet { scheduleSave() }
    }
    @Published var onboardingDone: Bool {
        didSet { scheduleSave() }
    }
    @Published var migratedFromVoiceAura: Bool {
        didSet { scheduleSave() }
    }
    /// Which History tab segment to show on open — tracks the most recently
    /// completed task. "voice" or "meeting".
    @Published var lastHistoryKind: String {
        didSet { scheduleSave() }
    }
    /// When true, meetings additionally record the main display to a .mov
    /// video file (with mixed mic + system audio). Off by default.
    @Published var meetingScreenRecording: Bool {
        didSet { scheduleSave() }
    }
    /// Screen-recording clarity tier. Stored as a `MeetingVideoQuality` rawValue.
    @Published var meetingVideoQuality: String {
        didSet { scheduleSave() }
    }

    // MARK: - Model Management

    @Published var asrProviderType: String {
        didSet { scheduleSave() }
    }
    @Published var cloudASRProvider: String {
        didSet { scheduleSave() }
    }
    @Published var cloudASRCredentials: [String: ProviderCredentials] {
        didSet { scheduleSave() }
    }
    @Published var llmProvider: String {
        didSet { scheduleSave() }
    }
    @Published var llmCredentials: [String: ProviderCredentials] {
        didSet { scheduleSave() }
    }
    @Published var localLLMNotes: String {
        didSet { scheduleSave() }
    }
    @Published var cloudLLMEnabled: Bool {
        didSet { scheduleSave() }
    }

    // MARK: - Meeting ASR

    /// ASR model used for meeting transcription, independent of voice input's
    /// `model`. Always a local Qwen model (the UI never offers Apple Speech
    /// here) — stored as an `ASRModel` rawValue. Meetings load this model on
    /// start and unload it on stop, so it occupies no memory between meetings.
    @Published var meetingASRModel: String {
        didSet { scheduleSave() }
    }

    // MARK: - Meeting LLM
    //
    // Meeting shares the voice LLM provider (`llmProvider`) — there is no
    // separate meeting provider. The meeting-specific model is stored per
    // provider in `ProviderCredentials.meetingModel`.

    @Published var meetingLLMCredentials: [String: ProviderCredentials] {
        didSet { scheduleSave() }
    }
    @Published var meetingLLMEnabled: Bool {
        didSet { scheduleSave() }
    }
    /// Language hint sent to the ASR when transcribing meeting audio.
    /// Stored as the raw `MeetingLanguage` value (e.g. "Chinese", "Japanese").
    /// Decouples meetings from the historical hardcoded "Chinese" hint so a
    /// Japanese meeting no longer comes back as Mandarin homophones.
    @Published var meetingLanguage: String {
        didSet { scheduleSave() }
    }
    /// Language for voice-input transcription on the Apple Speech engine.
    /// Stored as the raw `VoiceInputLanguage` value ("Chinese" / "English" /
    /// "Japanese"). Apple's on-device recognizer is locale-bound and cannot
    /// auto-detect; Qwen ignores this and auto-detects.
    @Published var voiceInputLanguage: String {
        didSet { scheduleSave() }
    }

    // MARK: - Prompt Presets (user-defined templates)

    /// User-saved 润色 presets, name → prompt body.
    @Published var polishCustomPresets: [String: String] {
        didSet { scheduleSave() }
    }

    // MARK: - Defaults

    static let defaultTriggerKey = "alt_r"
    // Ship the 0.6B "fast" ASR model as default — it's what `package-for-friend.sh`
    // preloads into the package. Defaulting to 1.7B would trigger a 2.5GB
    // download on first launch for any fresh install.
    static let defaultModel = "Qwen/Qwen3-ASR-0.6B"
    static let defaultHotwords = ["Claude Code", "OpenRouter", "n8n", "智谱", "GLM", "Sonnet", "Opus"]
    static let defaultReplacements: [ReplacementRule] = [
        ReplacementRule(from: "cloud code", to: "Claude Code"),
        ReplacementRule(from: "cloud cold", to: "Claude Code"),
        ReplacementRule(from: "克劳德", to: "Claude"),
        ReplacementRule(from: "n八n", to: "n8n"),
        ReplacementRule(from: "N八n", to: "n8n"),
        ReplacementRule(from: "质朴", to: "智谱"),
        ReplacementRule(from: "G L M", to: "GLM"),
        ReplacementRule(from: "open router", to: "OpenRouter"),
        ReplacementRule(from: "openrouter", to: "OpenRouter"),
        ReplacementRule(from: "code x", to: "CodeX"),
        ReplacementRule(from: "sonnet", to: "Sonnet"),
        ReplacementRule(from: "opus", to: "Opus"),
    ]
    static let defaultRemoveFillers = true
    static let defaultSpaceReposition = true
    static let defaultPreserveClipboard = true
    static let defaultHistoryRetentionMonths = 2
    static let defaultMeetingRetentionMonths = 2
    static let defaultMeetingSavePath: String = {
        let path = NSHomeDirectory() + "/Documents/Voice Brother/"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()
    static let defaultOnboardingDone = false
    static let defaultMigrated = false
    static let defaultLastHistoryKind = "voice"
    static let defaultMeetingScreenRecording = false
    static let defaultMeetingVideoQuality = MeetingVideoQuality.hd.rawValue

    // Model management defaults
    static let defaultASRProviderType = "local"
    // Default to the only currently-implemented cloud ASR provider so new
    // users don't land on a disabled option (openaiWhisper/deepgram are
    // filtered out of the picker via isImplemented=false).
    static let defaultCloudASRProvider = CloudASRProvider.volcanoASR.rawValue
    static let defaultCloudASRCredentials: [String: ProviderCredentials] = [:]
    static let defaultLLMProvider = LLMProvider.openRouter.rawValue
    static let defaultLLMCredentials: [String: ProviderCredentials] = [:]
    static let defaultLocalLLMNotes = ""
    static let defaultCloudLLMEnabled = false

    // Meeting ASR default — 0.6B for the same reason as `defaultModel`: it's
    // the model preloaded by `package-for-friend.sh`, so a fresh install can
    // record a meeting without a 2.5GB download first.
    static let defaultMeetingASRModel = ASRModel.small.rawValue

    // Meeting LLM defaults
    static let defaultMeetingLLMCredentials: [String: ProviderCredentials] = [:]
    static let defaultMeetingLLMEnabled = false
    static let defaultMeetingLanguage = MeetingLanguage.auto.rawValue
    static let defaultVoiceInputLanguage = VoiceInputLanguage.chinese.rawValue

    // Prompt presets defaults
    static let defaultPolishCustomPresets: [String: String] = [:]

    // MARK: - Persistence
    private static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VoiceBrother", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    // MARK: - Init

    init() {
        // Load from UserDefaults first (simple key-value), then JSON file for complex types
        self.triggerKey = Self.load("triggerKey", default: Self.defaultTriggerKey)
        self.model = Self.load("model", default: Self.defaultModel)
        self.removeFillers = Self.load("removeFillers", default: Self.defaultRemoveFillers)
        self.spaceReposition = Self.load("spaceReposition", default: Self.defaultSpaceReposition)
        self.meetingSavePath = Self.load("meetingSavePath", default: Self.defaultMeetingSavePath)
        self.preserveClipboard = Self.load("preserveClipboard", default: Self.defaultPreserveClipboard)
        self.historyRetentionMonths = Self.load("historyRetentionMonths", default: Self.defaultHistoryRetentionMonths)
        self.meetingRetentionMonths = Self.load("meetingRetentionMonths", default: Self.defaultMeetingRetentionMonths)
        self.onboardingDone = Self.load("onboardingDone", default: Self.defaultOnboardingDone)
        self.migratedFromVoiceAura = Self.load("migratedFromVoiceAura", default: Self.defaultMigrated)
        self.lastHistoryKind = Self.load("lastHistoryKind", default: Self.defaultLastHistoryKind)
        self.meetingScreenRecording = Self.load("meetingScreenRecording", default: Self.defaultMeetingScreenRecording)
        self.meetingVideoQuality = Self.load("meetingVideoQuality", default: Self.defaultMeetingVideoQuality)

        // Model management
        self.asrProviderType = Self.load("asrProviderType", default: Self.defaultASRProviderType)
        let loadedCloudASR: String = Self.load("cloudASRProvider", default: Self.defaultCloudASRProvider)
        // Auto-heal: openaiWhisper / deepgram are not implemented yet but some
        // older builds stored them as defaults. Map to the one working provider
        // so users don't land on a disabled option.
        self.cloudASRProvider = (loadedCloudASR == "openai_whisper" || loadedCloudASR == "deepgram")
            ? CloudASRProvider.volcanoASR.rawValue
            : loadedCloudASR
        self.llmProvider = Self.load("llmProvider", default: Self.defaultLLMProvider)
        self.localLLMNotes = Self.load("localLLMNotes", default: Self.defaultLocalLLMNotes)
        self.cloudLLMEnabled = Self.load("cloudLLMEnabled", default: Self.defaultCloudLLMEnabled)

        // Meeting ASR
        self.meetingASRModel = Self.load("meetingASRModel", default: Self.defaultMeetingASRModel)

        // Meeting LLM
        self.meetingLLMEnabled = Self.load("meetingLLMEnabled", default: Self.defaultMeetingLLMEnabled)
        self.meetingLanguage = Self.load("meetingLanguage", default: Self.defaultMeetingLanguage)
        self.voiceInputLanguage = Self.load("voiceInputLanguage", default: Self.defaultVoiceInputLanguage)

        // Prompt presets (custom user-defined)
        self.polishCustomPresets = Self.loadDict("polishCustomPresets", default: Self.defaultPolishCustomPresets)

        // Load complex types from JSON
        let (hotwords, replacements, cloudASRCreds, llmCreds, meetingLLMCreds, keychainMigrated) = Self.loadComplexTypes()
        self.hotwords = hotwords
        self.replacements = replacements
        self.cloudASRCredentials = cloudASRCreds
        self.llmCredentials = llmCreds
        self.meetingLLMCredentials = meetingLLMCreds

        // Migrate from Voice Aura on first launch
        if !migratedFromVoiceAura {
            migrateFromVoiceAura()
            migratedFromVoiceAura = true
        }

        // If we just migrated plaintext API keys from UserDefaults into the
        // Keychain, force a disk re-save immediately so the scrubbed copy
        // (without apiKey) replaces the plaintext blob. Do NOT wait for the
        // user to change a setting — the whole point is to stop leaking secrets.
        if keychainMigrated {
            performSave()
        }

        // Make sure any debounced save is flushed before the process exits.
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.save()
        }
    }

    deinit {
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingSaveWorkItem?.cancel()
        // Best-effort flush so dropped instances don't lose unsaved changes.
        performSave()
    }

    // MARK: - Save

    /// Schedule a debounced save. Multiple calls within `saveDebounceInterval`
    /// coalesce into a single write — the right shape for slider drags and
    /// batch edits.
    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSave()
        }
        pendingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceInterval, execute: work)
    }

    /// Public entrypoint — flushes any pending debounced save AND writes
    /// immediately. Use this when you need a guaranteed on-disk write right now
    /// (app exit, explicit "save" actions).
    func save() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        performSave()
    }

    private func performSave() {
        let defaults = UserDefaults.standard
        defaults.set(triggerKey, forKey: "triggerKey")
        defaults.set(model, forKey: "model")
        defaults.set(removeFillers, forKey: "removeFillers")
        defaults.set(spaceReposition, forKey: "spaceReposition")
        defaults.set(meetingSavePath, forKey: "meetingSavePath")
        defaults.set(preserveClipboard, forKey: "preserveClipboard")
        defaults.set(historyRetentionMonths, forKey: "historyRetentionMonths")
        defaults.set(meetingRetentionMonths, forKey: "meetingRetentionMonths")
        defaults.set(onboardingDone, forKey: "onboardingDone")
        defaults.set(migratedFromVoiceAura, forKey: "migratedFromVoiceAura")
        defaults.set(lastHistoryKind, forKey: "lastHistoryKind")
        defaults.set(meetingScreenRecording, forKey: "meetingScreenRecording")
        defaults.set(meetingVideoQuality, forKey: "meetingVideoQuality")

        // Model management
        defaults.set(asrProviderType, forKey: "asrProviderType")
        defaults.set(cloudASRProvider, forKey: "cloudASRProvider")
        defaults.set(llmProvider, forKey: "llmProvider")
        defaults.set(localLLMNotes, forKey: "localLLMNotes")
        defaults.set(cloudLLMEnabled, forKey: "cloudLLMEnabled")

        // Meeting ASR
        defaults.set(meetingASRModel, forKey: "meetingASRModel")

        // Meeting LLM
        defaults.set(meetingLLMEnabled, forKey: "meetingLLMEnabled")
        defaults.set(meetingLanguage, forKey: "meetingLanguage")

        // Save complex types as JSON
        if let hwData = try? JSONEncoder().encode(hotwords) {
            defaults.set(hwData, forKey: "hotwords")
        }
        if let rpData = try? JSONEncoder().encode(replacements) {
            defaults.set(rpData, forKey: "replacements")
        }
        // Credentials: API keys go to Keychain; everything else (baseURL/model)
        // still persists in UserDefaults so the JSON stays portable/inspectable.
        if let asrCredsData = try? JSONEncoder().encode(Self.scrubKeysForDisk(cloudASRCredentials, bucket: "cloudASR")) {
            defaults.set(asrCredsData, forKey: "cloudASRCredentials")
        }
        if let llmCredsData = try? JSONEncoder().encode(Self.scrubKeysForDisk(llmCredentials, bucket: "llm")) {
            defaults.set(llmCredsData, forKey: "llmCredentials")
        }
        if let meetingLLMCredsData = try? JSONEncoder().encode(Self.scrubKeysForDisk(meetingLLMCredentials, bucket: "meetingLLM")) {
            defaults.set(meetingLLMCredsData, forKey: "meetingLLMCredentials")
        }

        // Prompt presets
        if let data = try? JSONEncoder().encode(polishCustomPresets) {
            defaults.set(data, forKey: "polishCustomPresets")
        }
    }

    private static func loadDict(_ key: String, default: [String: String]) -> [String: String] {
        decodeOrDefault([String: String].self, key: key,
                        data: UserDefaults.standard.data(forKey: key), default: `default`)
    }

    /// Decode JSON-backed UserDefaults data, distinguishing "key never set"
    /// (silent, expected — falls back to default) from "stored data exists but
    /// won't decode" (corruption — logged). Without the log, a corrupt blob
    /// silently resets the user's hotwords / replacement rules / credentials
    /// to defaults with no trace.
    private static func decodeOrDefault<T: Decodable>(
        _ type: T.Type, key: String, data: Data?, default def: T
    ) -> T {
        guard let data else { return def }
        if let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        DebugLog.write("[AppConfig] '\(key)' stored data failed to decode — corrupt, falling back to default")
        return def
    }

    // MARK: - Fresh install detection

    func isFreshInstall() -> Bool {
        // If no config file and no UserDefaults keys exist, it's a fresh install
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "triggerKey") == nil
            && defaults.object(forKey: "onboardingDone") == nil
            && !FileManager.default.fileExists(atPath: Self.configURL.path)
    }

    // MARK: - Private helpers

    private static func load<T>(_ key: String, default: T) -> T {
        guard let value = UserDefaults.standard.object(forKey: key) as? T else {
            return `default`
        }
        return value
    }

    // MARK: - Keychain helpers

    /// Write each provider's API key to the Keychain and return a copy of the
    /// credentials map with `apiKey` blanked out, so only baseURL/model end up
    /// in UserDefaults. This stops `defaults read com.voicebrother.app` from
    /// leaking live API keys via screen recordings or backups.
    private static func scrubKeysForDisk(
        _ creds: [String: ProviderCredentials],
        bucket: String
    ) -> [String: ProviderCredentials] {
        var scrubbed = creds
        var anyNonEmpty = false
        for (provider, value) in creds {
            KeychainStore.set(value.apiKey, for: "\(bucket).\(provider)")
            scrubbed[provider]?.apiKey = ""
            if !value.apiKey.isEmpty { anyNonEmpty = true }
        }
        if anyNonEmpty {
            UserDefaults.standard.set(true, forKey: "keychain.\(bucket).hasData")
        }
        return scrubbed
    }

    /// Read API keys back from Keychain into the in-memory credential map.
    ///
    /// Skipped entirely when the bucket has no Keychain-backed entries on
    /// record (`bucket.hasKeychainData` flag in UserDefaults). This is what
    /// avoids the "enter your system password" prompt every launch — without
    /// the flag we'd call SecItemCopyMatching for every provider in the map,
    /// and macOS prompts on each call when the app's code signature changes
    /// across rebuilds. The flag is set the moment we actually write a
    /// non-empty key for that bucket.
    ///
    /// If the decoded map still has a non-empty `apiKey` (a pre-Keychain
    /// install), we migrate it to Keychain on the fly and report back so the
    /// caller can force a disk re-save that scrubs the plaintext.
    @discardableResult
    private static func hydrateKeysFromKeychain(
        _ creds: inout [String: ProviderCredentials],
        bucket: String
    ) -> Bool {
        let defaults = UserDefaults.standard
        let flagKey = "keychain.\(bucket).hasData"
        let bucketHasKeychainData = defaults.bool(forKey: flagKey)

        var migrated = false
        for (provider, var cred) in creds {
            let account = "\(bucket).\(provider)"
            if bucketHasKeychainData {
                let stored = KeychainStore.get(account)
                if !stored.isEmpty {
                    cred.apiKey = stored
                    creds[provider] = cred
                    continue
                }
            }
            if !cred.apiKey.isEmpty {
                // One-time migration from plaintext UserDefaults → Keychain.
                KeychainStore.set(cred.apiKey, for: account)
                defaults.set(true, forKey: flagKey)
                migrated = true
            }
        }
        return migrated
    }

    private static func loadComplexTypes() -> ([String], [ReplacementRule], [String: ProviderCredentials], [String: ProviderCredentials], [String: ProviderCredentials], Bool) {
        let defaults = UserDefaults.standard

        // Hotwords
        let hotwords = decodeOrDefault([String].self, key: "hotwords",
            data: defaults.data(forKey: "hotwords"), default: defaultHotwords)

        // Replacements
        let replacements = decodeOrDefault([ReplacementRule].self, key: "replacements",
            data: defaults.data(forKey: "replacements"), default: defaultReplacements)

        // Cloud ASR Credentials
        var cloudASRCreds = decodeOrDefault([String: ProviderCredentials].self, key: "cloudASRCredentials",
            data: defaults.data(forKey: "cloudASRCredentials"), default: defaultCloudASRCredentials)
        var migrated = hydrateKeysFromKeychain(&cloudASRCreds, bucket: "cloudASR")

        // LLM Credentials
        var llmCreds = decodeOrDefault([String: ProviderCredentials].self, key: "llmCredentials",
            data: defaults.data(forKey: "llmCredentials"), default: defaultLLMCredentials)
        migrated = hydrateKeysFromKeychain(&llmCreds, bucket: "llm") || migrated

        // (Meeting Cloud ASR creds removed — meetings share the voice input engine.)

        // Meeting LLM Credentials
        var meetingLLMCreds = decodeOrDefault([String: ProviderCredentials].self, key: "meetingLLMCredentials",
            data: defaults.data(forKey: "meetingLLMCredentials"), default: defaultMeetingLLMCredentials)
        migrated = hydrateKeysFromKeychain(&meetingLLMCreds, bucket: "meetingLLM") || migrated

        return (hotwords, replacements, cloudASRCreds, llmCreds, meetingLLMCreds, migrated)
    }

    private func migrateFromVoiceAura() {
        let voiceAuraConfig = NSHomeDirectory() + "/.voice_config.json"
        guard FileManager.default.fileExists(atPath: voiceAuraConfig),
              let data = try? Data(contentsOf: URL(fileURLWithPath: voiceAuraConfig)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Import trigger key
        if let key = json["trigger_key"] as? String {
            triggerKey = key
        }

        // Import model
        if let modelName = json["model"] as? String {
            model = modelName
        }

        // Import hotwords
        if let words = json["hotwords"] as? [String] {
            hotwords = words
        }

        // Import replacements (dict → ordered array)
        if let dict = json["replacements"] as? [String: String] {
            replacements = dict.map { ReplacementRule(from: $0.key, to: $0.value) }
        }

        // Import meeting save path
        if let path = json["meeting_save_path"] as? String {
            meetingSavePath = path
        }

        save()
    }
}
