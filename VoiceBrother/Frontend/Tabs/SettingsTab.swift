import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var permissionManager: PermissionManager

    @State private var permissionRefreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Permission Warning
                if !permissionManager.status.allGranted {
                    PermissionWarningSection()
                }

                // General Settings
                GeneralSettingsSection()
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startPermissionRefreshTimer()
        }
        .onDisappear {
            permissionRefreshTimer?.invalidate()
            permissionRefreshTimer = nil
        }
        .onChange(of: permissionManager.status) { _, newStatus in
            if newStatus.allGranted, case .error = voiceService.state {
                voiceService.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
            }
        }
    }

    private func startPermissionRefreshTimer() {
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}
