import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var permissionManager: PermissionManager

    @State private var pendingRestart = false
    @State private var previousTriggerKey: String = ""
    @State private var previousModel: String = ""
    @State private var permissionRefreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Permission Warning (if needed)
                if !permissionManager.status.allGranted {
                    permissionWarningSection
                }

                // MARK: - Service Status
                serviceStatusSection

                // MARK: - Download Progress
                if case .downloading = voiceService.state {
                    downloadProgressSection
                }

                // MARK: - Trigger Key
                triggerKeySection

                // MARK: - Model Picker
                modelSection

                // MARK: - Toggles
                togglesSection

                // MARK: - Restart Notice
                if pendingRestart {
                    restartNotice
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            previousTriggerKey = configManager.triggerKey
            previousModel = configManager.model
            startPermissionRefreshTimer()
        }
        .onDisappear {
            permissionRefreshTimer?.invalidate()
            permissionRefreshTimer = nil
        }
        .onChange(of: permissionManager.status) { newStatus in
            // Auto-retry: permissions just became all granted but service stuck in error
            if newStatus.allGranted, case .error = voiceService.state {
                voiceService.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
            }
        }
    }

    // MARK: - Service Status

    private var serviceStatusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("服务状态")

            HStack(spacing: 16) {
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(for: voiceService.state))
                        .frame(width: 10, height: 10)

                    Text(voiceService.state.displayText)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "2C3E6B"))
                }

                Spacer()

                // Start/Stop buttons
                if voiceService.state.isIdle {
                    Button {
                        voiceService.start()
                    } label: {
                        Text("启动服务")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(permissionManager.status.allGranted ? Color(hex: "4ECDC4") : Color(hex: "C8D8EA"))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!permissionManager.status.allGranted)
                } else if voiceService.state == .ready {
                    Button {
                        voiceService.stop()
                    } label: {
                        Text("停止服务")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "3A4E7A"))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 7)
                            .background(Color(hex: "FFB3C1"))
                            .cornerRadius(11)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    // MARK: - Download Progress

    private var downloadProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("下载进度")

            if let progress = voiceService.downloadProgress {
                VStack(spacing: 8) {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background track
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(hex: "C8D8EA"))
                                .frame(height: 10)

                            // Fill
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(hex: "4ECDC4"))
                                .frame(
                                    width: max(10, geometry.size.width * progress.fraction),
                                    height: 10
                                )
                        }
                    }
                    .frame(height: 10)

                    // Progress text
                    HStack {
                        Text(progress.percentageText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "2C3E6B"))

                        Spacer()

                        Text("\(byteString(progress.downloaded)) / \(byteString(progress.total))")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "5A7098"))
                    }
                }
                .padding(16)
                .glassCard()
            }
        }
    }

    // MARK: - Trigger Key

    private var triggerKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("触发按键")

            HStack {
                Text("触发按键")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2C3E6B"))
                    .frame(width: 80, alignment: .leading)

                Picker("", selection: $configManager.triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .onChange(of: configManager.triggerKey) { _, newValue in
                if newValue != previousTriggerKey {
                    previousTriggerKey = newValue
                    checkPendingRestart()
                }
            }
        }
    }

    // MARK: - Model Picker

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("识别模型")

            HStack {
                Text("识别模型")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2C3E6B"))
                    .frame(width: 80, alignment: .leading)

                Picker("", selection: $configManager.model) {
                    ForEach(ASRModel.allCases) { model in
                        Text("\(model.displayName) (\(model.estimatedSize))").tag(model.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .onChange(of: configManager.model) { _, newValue in
                if newValue != previousModel {
                    previousModel = newValue
                    checkPendingRestart()
                }
            }
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("识别选项")

            VStack(spacing: 12) {
                toggleRow(
                    title: "语气词过滤",
                    subtitle: "说话时的「嗯」「啊」「那个」等口头禅会被自动删除，让输出的文字更干净",
                    isOn: Binding(
                        get: { voiceService.removeFillers },
                        set: { voiceService.removeFillers = $0 }
                    )
                )

                toggleRow(
                    title: "空格重定位",
                    subtitle: "录音过程中按空格键，会在鼠标当前位置点击一下，让你换个地方继续输入",
                    isOn: Binding(
                        get: { voiceService.spaceReposition },
                        set: { voiceService.spaceReposition = $0 }
                    )
                )

                toggleRow(
                    title: "剪贴板保护",
                    subtitle: "语音输入通过剪贴板粘贴文字。开启后会保留你之前复制的内容（图片、文件等），关闭则直接覆盖",
                    isOn: $configManager.preserveClipboard
                )
            }
        }
    }

    // MARK: - Restart Notice

    private var restartNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(hex: "C89828"))

            Text("需要重启服务生效")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "5A7098"))

            Spacer()

            Button {
                voiceService.stop()
                // Short delay to allow cleanup, then start
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
                pendingRestart = false
            } label: {
                Text("立即重启")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(hex: "7B8CF5"))
                    .cornerRadius(11)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - Permission Warning

    private var permissionWarningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "C89828"))

                Text("需要授权以下权限才能使用")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "2C3E6B"))
            }

            VStack(spacing: 8) {
                permissionWarningRow(
                    icon: "universalaccess",
                    title: "辅助功能",
                    granted: permissionManager.status.accessibility,
                    action: { permissionManager.openAccessibilitySettings() }
                )

                permissionWarningRow(
                    icon: "mic",
                    title: "麦克风",
                    granted: permissionManager.status.microphone,
                    action: { permissionManager.openMicrophoneSettings() }
                )

                permissionWarningRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "屏幕录制",
                    granted: permissionManager.status.screenRecording,
                    action: { permissionManager.openScreenRecordingSettings() }
                )
            }
        }
        .padding(16)
        .background(Color(hex: "FFF8E7"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "E8D08C"), lineWidth: 1)
        )
    }

    private func permissionWarningRow(
        icon: String,
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14))
                .foregroundColor(granted ? Color(hex: "4ECDC4") : Color(hex: "8AA0BE"))
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(granted ? Color(hex: "4ECDC4") : Color(hex: "2C3E6B"))

            Spacer()

            if granted {
                Text("已授权")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "4ECDC4"))
            } else {
                Button {
                    action()
                } label: {
                    Text("授权")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color(hex: "7B8CF5"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: "2C3E6B"))
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2C3E6B"))

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "8AA0BE"))
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(CustomToggleStyle())
                .labelsHidden()
        }
        .padding(16)
        .glassCard()
    }

    private func statusColor(for state: ServiceState) -> Color {
        switch state {
        case .stopped:
            return Color(hex: "8AA0BE")
        case .downloading, .loading:
            return Color(hex: "7B8CF5")
        case .ready:
            return Color(hex: "4ECDC4")
        case .recording, .transcribing:
            return Color.orange
        case .error:
            return Color(hex: "FF6B8A")
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func checkPendingRestart() {
        // Only show restart notice if the service is currently running
        if voiceService.state == .ready || voiceService.state == .recording || voiceService.state == .transcribing {
            pendingRestart = true
        }
    }

    private func startPermissionRefreshTimer() {
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}

// MARK: - Custom Toggle Style

struct CustomToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                // Track
                RoundedRectangle(cornerRadius: 12)
                    .fill(isOn ? Color(hex: "4ECDC4") : Color(hex: "C8D8EA"))
                    .frame(width: 44, height: 24)

                // Knob
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
