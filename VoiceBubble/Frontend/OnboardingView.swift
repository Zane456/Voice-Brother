import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var permissionManager: PermissionManager

    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var refreshTimer: Timer?

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            header

            // MARK: - Step Content
            VStack(spacing: 16) {
                stepView(
                    step: 0,
                    icon: "universalaccess",
                    title: "第 1 步：辅助功能权限",
                    description: "Voice Bubble 需要辅助功能权限来监听全局按键事件。\n\n点击下方按钮，在弹出的系统对话框中勾选 Voice Bubble。",
                    granted: permissionManager.status.accessibility,
                    isCurrent: currentStep == 0,
                    action: { permissionManager.openAccessibilitySettings() }
                )

                stepView(
                    step: 1,
                    icon: "mic",
                    title: "第 2 步：麦克风权限",
                    description: "需要麦克风权限来录制您的语音并进行文字识别。\n\n点击下方按钮，在弹出的对话框中选择「好」。",
                    granted: permissionManager.status.microphone,
                    isCurrent: currentStep == 1,
                    action: { permissionManager.openMicrophoneSettings() }
                )

                stepView(
                    step: 2,
                    icon: "rectangle.on.rectangle.angled",
                    title: "第 3 步：屏幕录制权限",
                    description: "需要屏幕录制权限来获取系统音频（会议纪要功能）和输入焦点位置。\n\n点击下方按钮，在弹出的对话框中选择「打开系统设置」。",
                    granted: permissionManager.status.screenRecording,
                    isCurrent: currentStep == 2,
                    action: { permissionManager.openScreenRecordingSettings() }
                )
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)

            Spacer()

            // MARK: - Progress & Footer
            footer
        }
        .frame(width: 520, height: 580)
        .background(Color(hex: "F2F6FC"))
        .onAppear {
            permissionManager.recheckAll()
            startRefreshTimer()

            // If all permissions already granted, auto-dismiss
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

            // All permissions granted → auto dismiss after a brief moment
            if newStatus.allGranted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    configManager.onboardingDone = true
                    isPresented = false
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "7B8CF5"), Color(hex: "4ECDC4")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
            }
            .padding(.top, 28)

            Text("欢迎使用 Voice Bubble")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(hex: "2C3E6B"))

            Text("首次使用需要授予以下权限，请按顺序完成设置")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "5A7098"))
        }
    }

    // MARK: - Step View

    private func stepView(
        step: Int,
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Step indicator
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        granted ? Color(hex: "4ECDC4").opacity(0.15) :
                        isCurrent ? Color(hex: "7B8CF5").opacity(0.1) :
                        Color(hex: "F2F6FC")
                    )
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                granted ? Color(hex: "4ECDC4").opacity(0.3) :
                                isCurrent ? Color(hex: "7B8CF5").opacity(0.5) :
                                Color(hex: "C8D8EA"),
                                lineWidth: isCurrent ? 2 : 1
                            )
                    )

                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(hex: "4ECDC4"))
                } else {
                    Text("\(step + 1)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isCurrent ? Color(hex: "7B8CF5") : Color(hex: "8AA0BE"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        granted ? Color(hex: "4ECDC4") :
                        isCurrent ? Color(hex: "2C3E6B") :
                        Color(hex: "8AA0BE")
                    )

                if isCurrent || granted {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "5A7098"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if !granted {
                if isCurrent {
                    Button {
                        action()
                    } label: {
                        Text("授权")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: "7B8CF5"))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("待完成")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "C8D8EA"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            } else {
                Text("已完成")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "4ECDC4"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    granted ? Color(hex: "4ECDC4").opacity(0.3) :
                    isCurrent ? Color(hex: "7B8CF5").opacity(0.4) :
                    Color(hex: "C8D8EA"),
                    lineWidth: isCurrent ? 2 : 1
                )
        )
        .opacity(granted ? 0.7 : (isCurrent ? 1.0 : 0.5))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(
                            permissionManager.status.allGranted ? Color(hex: "4ECDC4") :
                            step <= currentStep ? Color(hex: "7B8CF5") :
                            Color(hex: "C8D8EA")
                        )
                        .frame(width: 8, height: 8)
                }
            }

            // Start button
            Button {
                configManager.onboardingDone = true
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    Text(permissionManager.status.allGranted ? "全部完成，开始使用" : "跳过，稍后设置")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(permissionManager.status.allGranted ? .white : Color(hex: "8AA0BE"))

                    if permissionManager.status.allGranted {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(
                            permissionManager.status.allGranted ? Color(hex: "7B8CF5") : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color(hex: "C8D8EA"), lineWidth: permissionManager.status.allGranted ? 0 : 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    // MARK: - Helpers

    private func updateCurrentStep() {
        let s = permissionManager.status
        if !s.accessibility {
            currentStep = 0
        } else if !s.microphone {
            currentStep = 1
        } else if !s.screenRecording {
            currentStep = 2
        } else {
            currentStep = 2
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}
