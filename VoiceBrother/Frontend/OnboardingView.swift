import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var theme: ThemeManager

    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var refreshTimer: Timer?
    @State private var isRelaunching = false

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 32)

                Text("欢迎使用 Voice Brother")
                    .font(.system(size: 20, weight: .bold))

                Text("首次使用需要授予以下权限")
                    .font(.system(size: 13))
                    .foregroundColor(theme.textSecondary)
            }

            // Defaults & privacy card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(theme.accent)
                    Text("默认全部本地处理")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("语音识别使用本地 Qwen3-ASR 模型（首次启动约需下载 400MB）。转写历史、学习数据都保存在你的 Mac 上，不上传任何服务器。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(theme.accent)
                    Text("AI 云端润色 / 录音摘要（可选）")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("如需更强的文本润色或录音摘要，可在「语音 → AI 大模型」或「声音录制 → 摘要」中填入你自己的 API Key（推荐 OpenRouter，一个 key 通用多家模型）。API Key 保存在系统 Keychain，不会随应用分发。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.25), lineWidth: 1)
            )
            .padding(.horizontal, 32)
            .padding(.top, 16)

            // Steps
            VStack(spacing: 8) {
                stepCard(0, icon: "universalaccess", title: "辅助功能",
                         desc: "监听全局按键事件。在系统对话框中勾选 Voice Brother。",
                         granted: permissionManager.status.accessibility,
                         action: { permissionManager.openAccessibilitySettings() })

                stepCard(1, icon: "mic", title: "麦克风",
                         desc: "录制语音并进行文字识别。在对话框中选择「好」。",
                         granted: permissionManager.status.microphone,
                         action: { permissionManager.openMicrophoneSettings() })

                stepCard(2, icon: "rectangle.on.rectangle.angled", title: "屏幕录制",
                         desc: "获取系统音频和输入焦点位置。在对话框中选择「打开系统设置」。",
                         granted: permissionManager.status.screenRecording,
                         action: { permissionManager.openScreenRecordingSettings() })
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Spacer(minLength: 28)

            // Footer
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(stepIndicatorColor(step))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 12)

            Button {
                if permissionManager.needsRelaunch {
                    permissionManager.relaunchApp()
                } else {
                    configManager.onboardingDone = true
                    isPresented = false
                }
            } label: {
                let isPrimary = permissionManager.status.allGranted || permissionManager.needsRelaunch
                Text(primaryButtonLabel)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isPrimary ? theme.accent : Color.clear)
                    )
                    .overlay(
                        // Secondary-style border makes the "skip" button read
                        // as clickable rather than disabled-gray.
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isPrimary ? Color.clear : theme.accent.opacity(0.6), lineWidth: 1)
                    )
                    .foregroundColor(isPrimary ? .white : theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        // Width is fixed; height is left intrinsic so the sheet grows to fit
        // its content. A hard-coded height clipped the footer button whenever
        // the step cards expanded their descriptions.
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            permissionManager.recheckAll()
            startRefreshTimer()
            if permissionManager.status.allGranted {
                configManager.onboardingDone = true
                isPresented = false
                return
            }
            updateCurrentStep()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: permissionManager.status) { newStatus in
            updateCurrentStep()
            if permissionManager.needsRelaunch {
                // Screen Recording just flipped denied → granted. The running
                // process still can't open capture streams until relaunch, so
                // do it automatically instead of waiting for a button click.
                guard !isRelaunching else { return }
                isRelaunching = true
                if newStatus.allGranted { configManager.onboardingDone = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    permissionManager.relaunchApp()
                }
            } else if newStatus.allGranted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    configManager.onboardingDone = true
                    isPresented = false
                }
            }
        }
    }

    private func stepCard(_ step: Int, icon: String, title: String, desc: String,
                          granted: Bool, action: @escaping () -> Void) -> some View {
        let isCurrent = currentStep == step

        return HStack(spacing: 14) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(granted ? theme.accent.opacity(0.12) : theme.surfaceBackground)
                    .frame(width: 40, height: 40)

                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(granted ? theme.accent : (isCurrent ? theme.accent : theme.textTertiary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(granted || isCurrent ? theme.textPrimary : theme.textTertiary)

                if isCurrent || granted {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if !granted && isCurrent {
                Button {
                    action()
                } label: {
                    Text("授权")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(granted ? 0.6 : (isCurrent ? 1.0 : 0.5))
    }

    private var primaryButtonLabel: String {
        if permissionManager.needsRelaunch { return "立即重启以启用屏幕录制" }
        if permissionManager.status.allGranted { return "开始使用" }
        return "跳过，稍后设置"
    }

    private func stepIndicatorColor(_ step: Int) -> Color {
        if permissionManager.status.allGranted { return theme.accent }
        return step <= currentStep ? theme.accent : theme.border
    }

    private func updateCurrentStep() {
        let s = permissionManager.status
        if !s.accessibility { currentStep = 0 }
        else if !s.microphone { currentStep = 1 }
        else { currentStep = 2 }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}
