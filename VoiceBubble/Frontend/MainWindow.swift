import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var permissionManager: PermissionManager

    @State private var selectedTab: AppTab = .general
    @State private var showOnboarding = false

    private enum AppTab: String, CaseIterable {
        case general = "通用"
        case vocabulary = "词汇"
        case history = "历史"
        case meeting = "会议"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .vocabulary: return "text.bubble"
            case .history: return "clock.arrow.circlepath"
            case .meeting: return "mic.badge.plus"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            sidebar
                .frame(width: 180)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1)

            // MARK: - Content
            Group {
                switch selectedTab {
                case .general:
                    GeneralTab()
                case .vocabulary:
                    VocabularyTab()
                case .history:
                    HistoryTab()
                case .meeting:
                    MeetingTab()
                case .about:
                    AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GlassmorphismBackground().ignoresSafeArea())
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            // Always show onboarding when permissions aren't all granted
            if !permissionManager.status.allGranted {
                showOnboarding = true
            } else if configManager.isFreshInstall() && !configManager.onboardingDone {
                showOnboarding = true
            }
        }
        .onChange(of: permissionManager.status) { newStatus in
            // Re-show onboarding if permissions were revoked
            if !newStatus.allGranted && !showOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }

    // MARK: - Sidebar View

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App title with logo
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                Text("Voice Bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "2C3E6B"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 28)

            // Navigation items
            VStack(spacing: 2) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    navItem(for: tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()
        }
        .background(.ultraThinMaterial)
    }

    private func navItem(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))

                Spacer()
            }
            .foregroundColor(isSelected ? Color(hex: "7B8CF5") : Color(hex: "3A4F6B"))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(hex: "D8E4F8") : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

