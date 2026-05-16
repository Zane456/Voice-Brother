import SwiftUI

@main
struct VoiceBubbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let configManager: ConfigManager
    let permissionManager: PermissionManager
    let voiceService: VoiceService
    let meetingService: MeetingService
    let themeManager: ThemeManager

    init() {
        // Hidden launch path: re-transcribe an existing meeting WAV in a
        // chosen language and write a fresh markdown alongside. Used to
        // recover meetings that were captured under the wrong language hint.
        // Usage:
        //   VoiceBubble --retranscribe <wav> <language> <output_md> [model_id]
        if let opts = MeetingRetranscribeLauncher.parseArgs(CommandLine.arguments) {
            MeetingRetranscribeLauncher.runAndExit(options: opts)
        }

        // Bound MLX's GPU buffer cache before any model loads. Without this,
        // variable-length transcription intermediates accumulate in MLX's
        // recycle pool and process RSS grows to tens of GB after long use.
        MLXMemoryGovernor.configure()

        let config = ConfigManager()
        let permissions = PermissionManager()
        let voice = VoiceService(configManager: config)
        let meeting = MeetingService(configManager: config, voiceService: voice)
        let theme = ThemeManager()

        self.configManager = config
        self.permissionManager = permissions
        self.voiceService = voice
        self.meetingService = meeting
        self.themeManager = theme

        // Inject theme into overlay panel (separate NSPanel window hierarchy)
        RecordingOverlayPanel.shared.configure(themeManager: theme)

        // Wire meeting toggle from keyboard shortcut to meeting service
        voice.meetingToggleAction = { [weak meeting] in
            meeting?.toggle()
        }

        // Menu bar status item — created on main thread after services exist.
        appDelegate.installMenuBar(voiceService: voice,
                                   meetingService: meeting,
                                   configManager: config)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(configManager)
                .environmentObject(permissionManager)
                .environmentObject(voiceService)
                .environmentObject(meetingService)
                .environmentObject(themeManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 672, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Voice Bubble") {
                    NSApp.orderFrontStandardAboutPanel()
                }
            }
            // Standard ⌘, preferences entry — brings the main settings window
            // to front (and unhides if minimized) so users get the macOS-native
            // muscle memory for "open preferences".
            CommandGroup(after: .appSettings) {
                Button("偏好设置…") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.contentView?.subviews.first is NSHostingView<AnyView> || !$0.title.isEmpty })
                        ?? NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-load the bundle's AppIcon at launch. Without this, both
        // `NSApp.applicationIconImage` (used in the sidebar avatar, About
        // hero, and onboarding) and the Dock badge can serve a Launch
        // Services-cached version of the previous icon — even after the
        // .icns inside the bundle has been replaced. Reading the .icns
        // straight from `Bundle.main` and re-asserting it here forces the
        // running NSApp instance to use the freshest art.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

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

    @MainActor
    func installMenuBar(voiceService: VoiceService,
                        meetingService: MeetingService,
                        configManager: ConfigManager) {
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(
            voiceService: voiceService,
            meetingService: meetingService,
            configManager: configManager
        )
    }
}
