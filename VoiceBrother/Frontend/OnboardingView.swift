import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var theme: ThemeManager

    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var refreshTimer: Timer?
    @State private var isRelaunching = false
    /// User's test transcription. Driven by the regular voice-input pipeline
    /// — the TextEditor below is just a frontmost editable target, so when
    /// the user presses & holds the trigger key, TextInjector pastes here.
    @State private var testText: String = ""

    private let totalSteps = 5

    /// True once all three system permissions are granted. Drives the "show
    /// step 4 + 5" transition (we don't immediately close the sheet anymore —
    /// onboarding now also walks the user through trigger key + a test).
    private var allPermissionsGranted: Bool {
        permissionManager.status.allGranted
    }

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

                Text(allPermissionsGranted ? "再两步就完成,试一下你的语音输入" : "首次使用需要授予以下权限")
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
                Text("语音识别使用本地 Qwen3-ASR 模型(首次启动约需下载 400MB)。转写历史、学习数据都保存在你的 Mac 上,不上传任何服务器。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(theme.accent)
                    Text("AI 云端润色 / 录音摘要(可选)")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("如需更强的文本润色或录音摘要,可在「语音 → AI 大模型」或「声音录制 → 摘要」中填入你自己的 API Key(推荐 OpenRouter,一个 key 通用多家模型)。API Key 保存在系统 Keychain,不会随应用分发。")
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

            // Steps — permission cards (steps 0-2) collapse to compact "✓"
            // rows once granted, freeing vertical space for steps 3-4.
            VStack(spacing: 8) {
                permissionCard(0, pane: .accessibility, title: "辅助功能",
                               desc: "监听全局按键事件。在系统对话框中勾选 Voice Brother。",
                               granted: permissionManager.status.accessibility,
                               action: { permissionManager.openAccessibilitySettings() })

                permissionCard(1, pane: .microphone, title: "麦克风",
                               desc: "录制语音并进行文字识别。在对话框中选择「好」。",
                               granted: permissionManager.status.microphone,
                               action: { permissionManager.openMicrophoneSettings() })

                permissionCard(2, pane: .screenRecording, title: "屏幕录制",
                               desc: "获取系统音频和输入焦点位置。在对话框中选择「打开系统设置」。",
                               granted: permissionManager.status.screenRecording,
                               action: { permissionManager.openScreenRecordingSettings() })

                if allPermissionsGranted && !permissionManager.needsRelaunch {
                    triggerKeyCard()
                    testRecordingCard()
                }
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
                let isPrimary = allPermissionsGranted || permissionManager.needsRelaunch
                Text(primaryButtonLabel)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isPrimary ? theme.accent : Color.clear)
                    )
                    .overlay(
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
        // Width fixed; height intrinsic so the sheet grows to fit content
        // (steps 4 + 5 only appear once permissions are done, so the initial
        // sheet stays compact).
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            permissionManager.recheckAll()
            startRefreshTimer()
            updateCurrentStep()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: permissionManager.status) { newStatus in
            updateCurrentStep()
            if permissionManager.needsRelaunch {
                // Screen Recording just flipped denied → granted. Process must
                // relaunch before it can open capture streams; auto-trigger
                // rather than waiting for a click.
                guard !isRelaunching else { return }
                isRelaunching = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    permissionManager.relaunchApp()
                }
            }
            // No auto-close anymore — the user finishes by clicking
            // "开始使用" after seeing trigger key + test cards.
        }
    }

    // MARK: - Permission card

    /// Permission step with an inline System Settings illustration shown only
    /// while the step is current and the permission is still denied — once
    /// granted the card collapses to a compact "✓" row.
    private func permissionCard(_ step: Int,
                                pane: SystemSettingsIllustration.Pane,
                                title: String,
                                desc: String,
                                granted: Bool,
                                action: @escaping () -> Void) -> some View {
        let isCurrent = currentStep == step

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(granted ? theme.accent.opacity(0.12) : theme.surfaceBackground)
                        .frame(width: 40, height: 40)
                    Image(systemName: granted ? "checkmark" : pane.sidebarIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(granted ? theme.accent : (isCurrent ? theme.accent : theme.textTertiary))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(granted || isCurrent ? theme.textPrimary : theme.textTertiary)
                    if isCurrent && !granted {
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
                        Text("打开系统设置")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isCurrent && !granted {
                SystemSettingsIllustration(pane: pane)
                    .padding(.leading, 54)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(granted ? 0.7 : (isCurrent ? 1.0 : 0.5))
    }

    // MARK: - Step 4: Trigger key

    private func triggerKeyCard() -> some View {
        let isCurrent = currentStep == 3
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isCurrent ? theme.accent : theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("选择录音快捷键")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text("按住所选键开始录音,松手输入文字。后续可在「语音」设置中随时更改。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Picker("", selection: $configManager.triggerKey) {
                ForEach(TriggerKey.allCases) { key in
                    Text(key.displayName).tag(key.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(isCurrent ? 1.0 : 0.7)
    }

    // MARK: - Step 5: Test recording

    /// Test card — the TextEditor is just a frontmost editable target, so
    /// when the user presses & holds their trigger key, TextInjector pastes
    /// the transcription right here. No special "preview mode" needed.
    private func testRecordingCard() -> some View {
        let isCurrent = currentStep == 4
        let triggerName = TriggerKey(rawValue: configManager.triggerKey)?.displayName ?? "录音键"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: testText.isEmpty ? "mic.fill" : "checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(testText.isEmpty ? "试一下" : "看起来工作正常 ✓")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    (Text("按住 ")
                        + Text(triggerName).font(.system(size: 12, weight: .bold)).foregroundColor(theme.textPrimary)
                        + Text(" 说一句话,例如「小明,明天去看电影吧」,松手后文字会出现在下方。"))
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            TextEditor(text: $testText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 90)
                .padding(8)
                .background(theme.surfaceBackground)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                .padding(.leading, 54)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(isCurrent ? 1.0 : 0.7)
    }

    // MARK: - Footer helpers

    private var primaryButtonLabel: String {
        if permissionManager.needsRelaunch { return "立即重启以启用屏幕录制" }
        if allPermissionsGranted { return "开始使用" }
        return "跳过,稍后设置"
    }

    private func stepIndicatorColor(_ step: Int) -> Color {
        if step < currentStep || (allPermissionsGranted && step <= 2) {
            return theme.accent
        }
        return step == currentStep ? theme.accent : theme.border
    }

    private func updateCurrentStep() {
        let s = permissionManager.status
        if !s.accessibility { currentStep = 0 }
        else if !s.microphone { currentStep = 1 }
        else if !s.screenRecording { currentStep = 2 }
        else if !testText.isEmpty { currentStep = 4 }
        else { currentStep = 3 }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}
