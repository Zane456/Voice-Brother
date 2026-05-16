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
            button.image = StatusBarIcon.idle()
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
        let (image, tint, label) = currentIconState()
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
            // Codex-style: monospace digits so the seconds counter doesn't
            // jitter as digit widths change. NSStatusItem.button rejects
            // attributedTitle font hints unless we set both attributedTitle
            // and an empty title — so we use NSAttributedString throughout.
            let titleString = " REC \(formatElapsed(meetingService.elapsedSeconds))"
            let monoFont = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .semibold
            )
            let attrTitle = NSMutableAttributedString(
                string: titleString,
                attributes: [.font: monoFont]
            )
            button.attributedTitle = attrTitle
            button.imagePosition = .imageLeading
            statusItem.length = NSStatusItem.variableLength
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = Self.iconOnlyLength
        }
        rebuildMenu()
    }

    /// Returns (image, tint color or nil for template tinting, accessibility label).
    ///
    /// Meeting recording overrides the icon to a "recording" variant where
    /// the centre waveform bar becomes a solid dot, and tints it red. Voice
    /// states reuse the idle bubble — push-to-talk cycles fast enough that
    /// flicking the icon mid-transcription would just look noisy.
    private func currentIconState() -> (NSImage, NSColor?, String) {
        if case .recording = meetingService.state {
            return (StatusBarIcon.recording(), .systemRed, "录制中")
        }
        return (StatusBarIcon.idle(), nil, voiceService.state.displayText)
    }

    // MARK: - Menu

    /// Fixed width for the custom header view. View-based menu items render
    /// edge-to-edge, so this also sets the menu's minimum width — chosen to sit
    /// comfortably alongside the text rows below.
    private static let headerWidth: CGFloat = 256

    private func rebuildMenu() {
        let menu = NSMenu()

        // Status header — a custom view-based item: brand mark, app name, a
        // live status line, and an SF Symbol provenance chip. Disabled so it
        // never highlights; it's purely informational.
        let headerItem = NSMenuItem()
        headerItem.isEnabled = false
        let header = MenuBarHeaderView(
            voiceState: voiceService.state,
            meetingState: meetingService.state,
            isCloud: configManager.asrProviderType == "cloud",
            width: Self.headerWidth
        )
        let hosting = NSHostingView(rootView: header)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        headerItem.view = hosting
        menu.addItem(headerItem)

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
        case .idle, .error: meetingTitle = "开始录制"
        case .preparing: meetingTitle = "正在准备…"
        case .recording: meetingTitle = "停止录制（\(formatElapsed(meetingService.elapsedSeconds))）"
        case .finishing: meetingTitle = "正在保存…"
        case .summarizing: meetingTitle = "正在生成摘要…"
        }
        let meetingItem = NSMenuItem(title: meetingTitle, action: #selector(toggleMeeting), keyEquivalent: "")
        meetingItem.target = self
        if case .preparing = meetingService.state { meetingItem.isEnabled = false }
        if case .finishing = meetingService.state { meetingItem.isEnabled = false }
        if case .summarizing = meetingService.state { meetingItem.isEnabled = false }
        menu.addItem(meetingItem)

        menu.addItem(NSMenuItem.separator())

        // Show main window
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        // Open meeting folder
        let openFolderItem = NSMenuItem(title: "打开录音文件夹", action: #selector(openMeetingFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Voice Bubble", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
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

// MARK: - Menu Header

/// Informational header at the top of the menu-bar dropdown.
///
/// Three elements on one row: the brand mark, a name + live-status stack, and
/// a provenance chip. Uses only semantic colours (`.primary` / `.secondary`)
/// and a fixed brand blue — never `ThemeManager`, because the menu's NSWindow
/// always renders in the *system* appearance, which may differ from the app's
/// own light/dark override.
private struct MenuBarHeaderView: View {

    let voiceState: ServiceState
    let meetingState: MeetingState
    let isCloud: Bool
    let width: CGFloat

    /// Codex brand blue (#339CFF) — the only accent in the palette. Hard-coded
    /// rather than themed so it reads identically in light and dark menus.
    private let brandBlue = Color(red: 0x33 / 255, green: 0x9C / 255, blue: 0xFF / 255)

    var body: some View {
        HStack(spacing: 10) {
            Image("AppLogoMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            provenanceChip
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: width, alignment: .leading)
    }

    /// "本地" / "云端" pill — SF Symbol + label, small-radius rectangle to match
    /// the Codex badge shape language (replaces the old 🔒 / ☁️ emoji).
    private var provenanceChip: some View {
        HStack(spacing: 3) {
            Image(systemName: isCloud ? "cloud.fill" : "lock.shield.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(isCloud ? "云端" : "本地")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    /// Meeting activity outranks voice state — when a meeting is in progress
    /// that's what the user wants reflected here.
    private var statusText: String {
        switch meetingState {
        case .preparing:   return "会议准备中…"
        case .recording:   return "会议录制中"
        case .finishing:   return "会议处理中…"
        case .summarizing: return "生成摘要中…"
        case .idle, .error: break
        }
        return voiceState.displayText
    }

    /// Brand blue when something is live or ready, dim grey when idle.
    private var statusColor: Color {
        if case .idle = meetingState {} else { return brandBlue }
        switch voiceState {
        case .ready, .recording, .transcribing: return brandBlue
        case .downloading, .loading:             return .secondary
        case .stopped, .error:                   return Color.secondary.opacity(0.55)
        }
    }
}
