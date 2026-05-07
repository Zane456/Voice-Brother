import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem (menu bar icon) and a popup menu.
/// Icon reflects voiceService + meetingService state at a glance.
/// Menu provides quick actions: 启动/停止语音、开始/结束会议、显示主窗口、退出。
@MainActor
final class MenuBarController: NSObject {

    private let voiceService: VoiceService
    private let meetingService: MeetingService
    private let configManager: ConfigManager

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var meetingTimer: Timer?

    init(voiceService: VoiceService, meetingService: MeetingService, configManager: ConfigManager) {
        self.voiceService = voiceService
        self.meetingService = meetingService
        self.configManager = configManager
        super.init()
        setupStatusItem()
        observeState()
    }

    // MARK: - Setup

    /// Fixed footprint that matches the visual width of system-supplied
    /// status items (Wi-Fi, Bluetooth, battery). Both `variableLength` and
    /// `squareLength` end up wider for us because the "waveform" SF Symbol
    /// has a wide alignment rect with built-in horizontal padding — the
    /// status bar honours that padding and inflates the item. Hard-coding
    /// the length sidesteps the alignment rect entirely.
    private static let iconOnlyLength: CGFloat = 24

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: Self.iconOnlyLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Bubble")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            img?.size = NSSize(width: 18, height: 18)
            button.image = img
            button.imagePosition = .imageOnly
        }
        rebuildMenu()
    }

    private func observeState() {
        voiceService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAppearance() }
            .store(in: &cancellables)

        meetingService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.refreshAppearance()
                self?.handleMeetingTimer(for: state)
            }
            .store(in: &cancellables)

        // ConfigManager forwards AppConfig's objectWillChange — subscribe to it
        // for any config-driven refresh. We just refresh appearance on every
        // change since the work is cheap.
        configManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAppearance() }
            .store(in: &cancellables)
    }

    // MARK: - Appearance

    private func refreshAppearance() {
        guard let button = statusItem.button else { return }
        let (symbol, tint, label) = currentIconState()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        // Constrain to a fixed 18×18 footprint so the menu-bar item width
        // doesn't expand for symbols whose glyphs have wide intrinsic bounds
        // (e.g. "waveform" — without this it leaves a visibly larger gap
        // between us and neighbouring status items).
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
        button.toolTip = label

        // Meeting still gets an inline timer because users actively rely on
        // knowing how long the recording has run. Voice (push-to-talk) is
        // ephemeral and macOS already shows the orange microphone indicator
        // in the menu bar — adding "录音中" here just made the bar wider for
        // no extra information.
        //
        // Length toggle: square when icon-only (matches neighbour width),
        // variable when we need to fit "REC 00:42" text.
        if case .recording = meetingService.state {
            button.title = " REC \(formatElapsed(meetingService.elapsedSeconds))"
            button.imagePosition = .imageLeading
            statusItem.length = NSStatusItem.variableLength
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = Self.iconOnlyLength
        }
        rebuildMenu()
    }

    /// Returns (sf-symbol, tint color or nil for template, accessibility label).
    ///
    /// Meeting recording is the only state that overrides the menu-bar icon
    /// (red dot + REC timer). Voice states reuse the same "waveform" glyph so
    /// the icon doesn't visibly shrink/grow when the push-to-talk flow cycles
    /// through recording → transcribing → ready. State is still surfaced via
    /// tooltip and menu text.
    private func currentIconState() -> (String, NSColor?, String) {
        if case .recording = meetingService.state {
            return ("record.circle.fill", .systemRed, "会议录制中")
        }
        return ("waveform", nil, voiceService.state.displayText)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        // Status header (disabled, informational)
        let statusItem = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Voice service start/stop
        let voiceTitle: String
        switch voiceService.state {
        case .stopped, .error: voiceTitle = "启动语音输入"
        case .ready, .recording, .transcribing: voiceTitle = "停止语音输入"
        case .downloading, .loading: voiceTitle = "正在加载模型…"
        }
        let voiceItem = NSMenuItem(title: voiceTitle, action: #selector(toggleVoice), keyEquivalent: "")
        voiceItem.target = self
        if case .downloading = voiceService.state { voiceItem.isEnabled = false }
        if case .loading = voiceService.state { voiceItem.isEnabled = false }
        menu.addItem(voiceItem)

        // Meeting toggle
        let meetingTitle: String
        switch meetingService.state {
        case .idle, .error: meetingTitle = "开始会议录制"
        case .recording: meetingTitle = "停止会议录制（\(formatElapsed(meetingService.elapsedSeconds))）"
        case .finishing: meetingTitle = "正在保存…"
        case .summarizing: meetingTitle = "正在生成摘要…"
        }
        let meetingItem = NSMenuItem(title: meetingTitle, action: #selector(toggleMeeting), keyEquivalent: "")
        meetingItem.target = self
        if case .finishing = meetingService.state { meetingItem.isEnabled = false }
        if case .summarizing = meetingService.state { meetingItem.isEnabled = false }
        menu.addItem(meetingItem)

        menu.addItem(NSMenuItem.separator())

        // Show main window
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        // Open meeting folder
        let openFolderItem = NSMenuItem(title: "打开会议文件夹", action: #selector(openMeetingFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Voice Bubble", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    private func statusLine() -> String {
        let isCloud = configManager.asrProviderType == "cloud"
        let provenance = isCloud ? "☁️ 云端" : "🔒 本地"
        let privacyTag = configManager.privacyMode ? " · 🛡 隐私模式" : ""
        return "Voice Bubble · \(provenance)\(privacyTag) · \(voiceService.state.displayText)"
    }

    private func handleMeetingTimer(for state: MeetingState) {
        meetingTimer?.invalidate()
        meetingTimer = nil
        if case .recording = state {
            meetingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshAppearance() }
            }
        }
    }

    private func formatElapsed(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600, m = (totalSeconds % 3600) / 60, s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Actions

    @objc private func toggleVoice() {
        switch voiceService.state {
        case .stopped, .error: voiceService.start()
        case .ready, .recording, .transcribing: voiceService.stop()
        default: break
        }
    }

    @objc private func toggleMeeting() {
        meetingService.toggle()
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openMeetingFolder() {
        let url = URL(fileURLWithPath: configManager.meetingSavePath)
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
