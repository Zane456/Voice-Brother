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
        case meeting = "会议"
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
            case .meeting: return "会议纪要"
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
                            .padding(.leading, 76)
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Persistent banner: any missing permission renders this above
                    // every tab so the user can never get stuck on a non-General
                    // page wondering why nothing works.
                    if !permissionManager.status.allGranted {
                        permissionBanner
                            .padding(.leading, 76)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 76)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.contentBackground)

                sidebar
                    .frame(width: 76, height: geometry.size.height)
                    .background(theme.sidebarBackground)
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
        // Each theme picks its own typeface design (serif for paper themes,
        // monospaced for the technical theme, rounded for Material). Setting
        // it at the root lets every Font.system(...) call inherit automatically.
        .fontDesign(theme.fontDesign)
        .frame(minWidth: 800, minHeight: 600)
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
            OnboardingView(isPresented: $showOnboarding)
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
            Button {
                showOnboarding = true
            } label: {
                Text("去授权")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accentSecondary))
            }
            .buttonStyle(.plain)
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
            Text("屏幕录制权限已授予，需要重启 Voice Bubble 才能生效")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button {
                permissionManager.relaunchApp()
            } label: {
                Text("立即重启")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
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

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .padding(.bottom, 20)

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
            // Codex motion language: ease-out, no spring bounce.
            withAnimation(.easeOut(duration: 0.15)) {
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
