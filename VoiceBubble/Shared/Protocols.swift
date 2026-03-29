import Foundation
import Combine

// MARK: - Voice Service Protocol

protocol VoiceServiceProtocol: ObservableObject {
    var state: ServiceState { get }
    var downloadProgress: DownloadProgress? { get }
    var removeFillers: Bool { get set }
    var spaceReposition: Bool { get set }

    func start()
    func stop()
}

// MARK: - Meeting Service Protocol

protocol MeetingServiceProtocol: ObservableObject {
    var state: MeetingState { get }
    var elapsedSeconds: Int { get }
    var savePath: String { get set }

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
