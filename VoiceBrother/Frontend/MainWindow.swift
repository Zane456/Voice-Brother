import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var theme: ThemeManager

    @State private var selectedTab: AppTab = .voice
    @State private var showOnboarding = false

    /// Tab order: voice-first matches the new-user mental model — the first thing
    /// users want is to configure the trigger key and ASR engine, not generic
    /// settings. About stays last as the reference / help anchor.
    private enum AppTab: String, CaseIterable {
        case voice = "语音"
        case meeting = "声音录制"
        case history = "历史"
        case general = "通用"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .voice: return "waveform"
            case .meeting: return "person.2.wave.2"
            case .history: return "clock.arrow.circlepath"
            case .about: return "info.circle"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .voice: return "语音输入设置"
            case .meeting: return "声音录制"
            case .history: return "历史记录"
            case .general: return "通用设置"
            case .about: return "关于"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    // Screen Recording just got granted — macOS needs a relaunch
                    // before the process can actually start capturing, so show an
                    // explicit banner with a one-click restart.
                    if permissionManager.needsRelaunch {
                        relaunchBanner
                            .padding(.leading, 56)
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Persistent banner: any missing permission renders this above
                    // every tab so the user can never get stuck on a non-General
                    // page wondering why nothing works.
                    if !permissionManager.status.allGranted {
                        permissionBanner
                            .padding(.leading, 56)
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Group {
                        switch selectedTab {
                        case .general:
                            GeneralTab()
                        case .voice:
                            VoiceTab()
                        case .meeting:
                            MeetingTab()
                        case .history:
                            HistoryTab()
                        case .about:
                            AboutTab()
                        }
                    }
                    // Silky page swap: `.id` gives each tab its own identity so
                    // SwiftUI runs a transition on switch. The incoming page
                    // fades in while gently settling up 6pt; the outgoing one
                    // just fades — short (0.22s) so it never feels sluggish.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity
                    ))
                    .id(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 56)
                    // The content surface is its own rounded "card" tucked
                    // next to the sidebar — left edge rounded, right edge
                    // straight (it inherits rounding from the window's outer
                    // corner). Without this, the inner sidebar/content seam
                    // is a hard 90° edge that fights the soft outer corners.
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 16,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                        .fill(theme.contentBackground)
                        .padding(.leading, 56)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                sidebar
                    .frame(width: 56, height: geometry.size.height)
                    // The sidebar uses the macOS `.sidebar` vibrancy material;
                    // a 20% white wash lightens it without losing the blur.
                    .background(
                        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                            .overlay(Color.white.opacity(0.2))
                    )
                    .overlay(alignment: .trailing) {
                        // Codex sidebar: flat full-height panel + 1pt vertical
                        // hairline divider on the inside edge. No rounded corners,
                        // no shadow — sidebar is structure, not a floating card.
                        Rectangle()
                            .fill(theme.border)
                            .frame(width: 1)
                    }
            }
            .animation(.easeInOut(duration: 0.25), value: permissionManager.status.allGranted)
        }
        .background(theme.windowBackground.ignoresSafeArea())
        .ignoresSafeArea()
        // Round the window's outer corners more aggressively than the macOS
        // default — matches System Settings' visual softness. macOS Sequoia
        // ships ~10pt; bumping to 16pt + continuous curve reads as the
        // "rounded panel" the design references call out.
        .modifier(WindowCornerRadius(radius: 16))
        // Each theme picks its own typeface design (serif for paper themes,
        // monospaced for the technical theme, rounded for Material). Setting
        // it at the root lets every Font.system(...) call inherit automatically.
        .fontDesign(theme.fontDesign)
        // Force every native control (segmented picker, menus, fields) onto the
        // app's blue — without this they inherit the macOS system accent, which
        // renders purple/pink/etc. on users who changed it.
        .tint(theme.accent)
        .frame(minWidth: 560, minHeight: 600)
        .onAppear {
            // Only open onboarding when the user hasn't finished it yet.
            // After the user dismisses once (skip or complete), we switch to
            // the in-window permission banner instead of re-popping the sheet
            // on every status change.
            if !configManager.onboardingDone {
                showOnboarding = true
            } else if permissionManager.status.allGranted {
                voiceService.start()
            }
        }
        .onChange(of: permissionManager.status) { newStatus in
            if newStatus.allGranted {
                if voiceService.state == .stopped {
                    voiceService.start()
                }
            }
            // Do NOT re-open onboarding here — once the user has dismissed it,
            // the permission banner is the path back to the system settings.
        }
        .onChange(of: showOnboarding) { isShowing in
            if !isShowing && voiceService.state == .stopped {
                voiceService.start()
            }
        }
        .sheet(isPresented: $showOnboarding) {
            // A sheet is hosted in its own window — re-apply the app tint so its
            // controls don't fall back to the macOS system accent (purple/pink).
            OnboardingView(isPresented: $showOnboarding)
                .tint(theme.accent)
        }
    }

    // MARK: - Permission Banner (persistent, all tabs)

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.warning)
            Text(missingPermissionsText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button("去授权") { showOnboarding = true }
                .buttonStyle(CodexPrimaryButtonStyle(minHeight: 26))
                .accessibilityLabel("打开权限设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.warningBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.warningBorder, lineWidth: 1)
        )
    }

    private var relaunchBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accent)
            Text("屏幕录制权限已授予，需要重启 Voice Brother 才能生效")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button("立即重启") { permissionManager.relaunchApp() }
                .buttonStyle(CodexPrimaryButtonStyle(minHeight: 26))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private var missingPermissionsText: String {
        var missing: [String] = []
        if !permissionManager.status.accessibility { missing.append("辅助功能") }
        if !permissionManager.status.microphone { missing.append("麦克风") }
        if !permissionManager.status.screenRecording { missing.append("屏幕录制") }
        return "缺少权限：\(missing.joined(separator: " · ")) — 语音功能不可用"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .center, spacing: 0) {
            Spacer()
                .frame(height: 52) // clear traffic light buttons

            // Vector mark (no white tile / no rounded square frame) so the
            // brand glyph reads in line with the SF Symbol nav items below
            // instead of looking like a transplanted Dock icon.
            AppLogoView(size: 26)
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    navItem(for: tab)
                }
            }

            Spacer()
        }
    }

    private func navItem(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            // Codex motion language: ease-out, no spring bounce. 0.22s drives
            // both the sidebar chip and the page-swap transition — long enough
            // to read as silky, short enough to never feel sluggish.
            withAnimation(.easeOut(duration: 0.22)) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .frame(width: 40, height: 40)
                .foregroundColor(isSelected ? theme.accent : theme.sidebarText)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.sidebarSelectedBg : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.accessibilityLabel)
    }
}
