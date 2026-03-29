import Foundation
import Combine

/// Configuration model - all user settings are persisted here.
final class AppConfig: ObservableObject {
    // MARK: - Published settings
    @Published var triggerKey: String {
        didSet { save() }
    }
    @Published var model: String {
        didSet { save() }
    }
    @Published var hotwords: [String] {
        didSet { save() }
    }
    @Published var replacements: [ReplacementRule] {
        didSet { save() }
    }
    @Published var removeFillers: Bool {
        didSet { save() }
    }
    @Published var spaceReposition: Bool {
        didSet { save() }
    }
    @Published var meetingSavePath: String {
        didSet { save() }
    }
    @Published var preserveClipboard: Bool {
        didSet { save() }
    }
    @Published var onboardingDone: Bool {
        didSet { save() }
    }
    @Published var migratedFromVoiceAura: Bool {
        didSet { save() }
    }

    // MARK: - Defaults

    static let defaultTriggerKey = "cmd_r"
    static let defaultModel = "Qwen/Qwen3-ASR-1.7B"
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
    static let defaultMeetingSavePath: String = {
        let path = NSHomeDirectory() + "/Documents/VoiceAura/"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()
    static let defaultOnboardingDone = false
    static let defaultMigrated = false

    // MARK: - Persistence

    private let storage = UserDefaults.standard
    private static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VoiceBubble", isDirectory: true)
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
        self.onboardingDone = Self.load("onboardingDone", default: Self.defaultOnboardingDone)
        self.migratedFromVoiceAura = Self.load("migratedFromVoiceAura", default: Self.defaultMigrated)

        // Load complex types from JSON
        let (hotwords, replacements) = Self.loadComplexTypes()
        self.hotwords = hotwords
        self.replacements = replacements

        // Migrate from Voice Aura on first launch
        if !migratedFromVoiceAura {
            migrateFromVoiceAura()
            migratedFromVoiceAura = true
        }
    }

    // MARK: - Save

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(triggerKey, forKey: "triggerKey")
        defaults.set(model, forKey: "model")
        defaults.set(removeFillers, forKey: "removeFillers")
        defaults.set(spaceReposition, forKey: "spaceReposition")
        defaults.set(meetingSavePath, forKey: "meetingSavePath")
        defaults.set(preserveClipboard, forKey: "preserveClipboard")
        defaults.set(onboardingDone, forKey: "onboardingDone")
        defaults.set(migratedFromVoiceAura, forKey: "migratedFromVoiceAura")

        // Save complex types as JSON
        if let hwData = try? JSONEncoder().encode(hotwords) {
            defaults.set(hwData, forKey: "hotwords")
        }
        if let rpData = try? JSONEncoder().encode(replacements) {
            defaults.set(rpData, forKey: "replacements")
        }
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

    private static func loadComplexTypes() -> ([String], [ReplacementRule]) {
        let defaults = UserDefaults.standard

        // Hotwords
        let hotwords: [String]
        if let data = defaults.data(forKey: "hotwords"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            hotwords = decoded
        } else {
            hotwords = defaultHotwords
        }

        // Replacements
        let replacements: [ReplacementRule]
        if let data = defaults.data(forKey: "replacements"),
           let decoded = try? JSONDecoder().decode([ReplacementRule].self, from: data) {
            replacements = decoded
        } else {
            replacements = defaultReplacements
        }

        return (hotwords, replacements)
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
