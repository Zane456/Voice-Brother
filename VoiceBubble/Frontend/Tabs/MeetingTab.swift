import SwiftUI

struct MeetingTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var meetingService: MeetingService

    @State private var elapsedTime: String = "00:00:00"
    @State private var timerCancellable: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Service Warning
                if voiceService.state != .ready {
                    serviceWarning
                }

                // MARK: - Save Path
                savePathSection

                // MARK: - Meeting Controls
                meetingControlsSection

                // MARK: - Duration Display
                if meetingService.state == .recording || meetingService.state == .finishing {
                    durationSection
                }

                // MARK: - Shortcut Info
                shortcutInfoSection
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: meetingService.state) { _, newState in
            updateTimer(for: newState)
        }
    }

    // MARK: - Service Warning

    private var serviceWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "FF6B8A"))

            Text("请先启动语音服务加载模型")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "FF6B8A"))

            Spacer()
        }
        .padding(14)
        .background(Color(hex: "FFF0F3"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "FFB3C1"), lineWidth: 1)
        )
    }

    // MARK: - Save Path Section

    private var savePathSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("保存路径")

            HStack(spacing: 8) {
                Text(configManager.meetingSavePath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(hex: "2C3E6B"))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: configManager.meetingSavePath))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.arrow.up.right" )
                            .font(.system(size: 12))
                        Text("打开")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "7B8CF5"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "F2F6FC"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "C8D8EA"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    chooseSavePath()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("选择文件夹")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "7B8CF5"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "F2F6FC"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "C8D8EA"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .glassCard()
        }
    }

    // MARK: - Meeting Controls

    private var meetingControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("会议控制")

            HStack(spacing: 16) {
                // Status
                HStack(spacing: 8) {
                    Circle()
                        .fill(meetingStatusColor)
                        .frame(width: 10, height: 10)

                    Text(meetingService.state.displayText)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "2C3E6B"))
                }

                Spacer()

                // Start / Stop button
                if meetingService.state == .recording || meetingService.state == .finishing {
                    Button {
                        meetingService.stop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 14))
                            Text("停止录制")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3A4E7A"))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "FFB3C1"))
                        .cornerRadius(11)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        meetingService.start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 14))
                            Text("开始录制")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3A4E7A"))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "A8E6CF"))
                        .cornerRadius(11)
                    }
                    .buttonStyle(.plain)
                    .disabled(voiceService.state != .ready)
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    // MARK: - Duration Section

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("录制时长")

            Text(elapsedTime)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "C89828"))
                .padding(20)
                .frame(maxWidth: .infinity)
                .glassCard()
        }
    }

    // MARK: - Shortcut Info

    private var shortcutInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("快捷操作")

            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(
                    icon: "keyboard",
                    title: "同时长按左右 Command 键",
                    description: "按住左右两个 ⌘ 键不放，持续 0.5 秒后自动开始/结束会议录制"
                )

                shortcutRow(
                    icon: "info.circle",
                    title: "说明",
                    description: "语音服务运行期间，同时按住键盘两侧的 Command 键 0.5 秒即可切换会议录制。无需切换到本界面"
                )
            }
            .padding(16)
            .glassCard()
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Color(hex: "2C3E6B"))
    }

    private func shortcutRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "7B8CF5"))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "2C3E6B"))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A7098"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meetingStatusColor: Color {
        switch meetingService.state {
        case .idle:
            return Color(hex: "8AA0BE")
        case .recording:
            return Color(hex: "4ECDC4")
        case .finishing:
            return Color.orange
        case .error:
            return Color(hex: "FF6B8A")
        }
    }

    private func chooseSavePath() {
        let panel = NSOpenPanel()
        panel.title = "选择会议录音保存路径"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.urls.first {
            configManager.meetingSavePath = url.path
            meetingService.savePath = url.path
        }
    }

    // MARK: - Timer Management

    private func updateTimer(for state: MeetingState) {
        timerCancellable?.invalidate()
        timerCancellable = nil

        switch state {
        case .recording:
            startTimer()
        case .finishing:
            // Keep showing the last elapsed time
            break
        case .idle, .error:
            elapsedTime = "00:00:00"
        }
    }

    private func startTimer() {
        let service = meetingService
        timerCancellable = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let seconds = service.elapsedSeconds
            elapsedTime = formatDuration(seconds)
        }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
