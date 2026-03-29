import Combine
import Foundation

/// Thin wrapper around AppConfig for dependency injection.
/// Forwards all properties and persistence to the underlying AppConfig instance.
final class ConfigManager: ObservableObject, ConfigManagerProtocol {

    let appConfig: AppConfig

    // MARK: - Forwarded @Published properties

    @Published var triggerKey: String {
        didSet { appConfig.triggerKey = triggerKey }
    }
    @Published var model: String {
        didSet { appConfig.model = model }
    }
    @Published var hotwords: [String] {
        didSet { appConfig.hotwords = hotwords }
    }
    @Published var replacements: [ReplacementRule] {
        didSet { appConfig.replacements = replacements }
    }
    @Published var removeFillers: Bool {
        didSet { appConfig.removeFillers = removeFillers }
    }
    @Published var spaceReposition: Bool {
        didSet { appConfig.spaceReposition = spaceReposition }
    }
    @Published var meetingSavePath: String {
        didSet { appConfig.meetingSavePath = meetingSavePath }
    }
    @Published var preserveClipboard: Bool {
        didSet { appConfig.preserveClipboard = preserveClipboard }
    }
    @Published var onboardingDone: Bool {
        didSet { appConfig.onboardingDone = onboardingDone }
    }

    // MARK: - Init

    init(appConfig: AppConfig? = nil) {
        let config = appConfig ?? AppConfig()
        self.appConfig = config

        // Initialize local properties from AppConfig
        self.triggerKey = config.triggerKey
        self.model = config.model
        self.hotwords = config.hotwords
        self.replacements = config.replacements
        self.removeFillers = config.removeFillers
        self.spaceReposition = config.spaceReposition
        self.meetingSavePath = config.meetingSavePath
        self.preserveClipboard = config.preserveClipboard
        self.onboardingDone = config.onboardingDone
    }

    // MARK: - ConfigManagerProtocol

    func save() {
        // Sync local values to AppConfig, which persists via didSet
        appConfig.triggerKey = triggerKey
        appConfig.model = model
        appConfig.hotwords = hotwords
        appConfig.replacements = replacements
        appConfig.removeFillers = removeFillers
        appConfig.spaceReposition = spaceReposition
        appConfig.meetingSavePath = meetingSavePath
        appConfig.preserveClipboard = preserveClipboard
        appConfig.onboardingDone = onboardingDone
        appConfig.save()
    }

    func isFreshInstall() -> Bool {
        appConfig.isFreshInstall()
    }
}
