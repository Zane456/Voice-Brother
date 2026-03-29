import SwiftUI

@main
struct VoiceBubbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let configManager: ConfigManager
    let permissionManager: PermissionManager
    let voiceService: VoiceService
    let meetingService: MeetingService

    init() {
        let config = ConfigManager()
        let permissions = PermissionManager()
        let voice = VoiceService(configManager: config)
        let meeting = MeetingService(configManager: config, voiceService: voice)

        self.configManager = config
        self.permissionManager = permissions
        self.voiceService = voice
        self.meetingService = meeting

        // Wire meeting toggle from keyboard shortcut to meeting service
        voice.meetingToggleAction = { [weak meeting] in
            meeting?.toggle()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(configManager)
                .environmentObject(permissionManager)
                .environmentObject(voiceService)
                .environmentObject(meetingService)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Voice Bubble") {
                    NSApp.orderFrontStandardAboutPanel()
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup all services
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}
