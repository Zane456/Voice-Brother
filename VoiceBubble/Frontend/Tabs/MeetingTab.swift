import SwiftUI

/// Meeting (long recording + AI summary) tab. Top section is the prominent
/// 开始/停止 control — this is the user's main action, not a setting.
/// Detail config moved into MeetingSettingsSection below.
struct MeetingTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var meetingService: MeetingService
    @EnvironmentObject private var theme: ThemeManager

    @State private var elapsedTime: String = "00:00:00"
    @State private var timerCancellable: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会议")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    recordingControlCard
                    if let err = meetingService.summaryError {
                        summaryErrorCard(err)
                    }
                    MeetingSettingsSection()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: meetingService.state) { _, newState in
            updateTimer(for: newState)
        }
        .onDisappear {
            timerCancellable?.invalidate()
            timerCancellable = nil
        }
    }

    // MARK: - Main Recording Control

    private var recordingControlCard: some View {
        let isRecording: Bool = {
            if case .recording = meetingService.state { return true }
            return false
        }()
        let isBusy: Bool = {
            switch meetingService.state {
            case .finishing, .summarizing: return true
            default: return false
            }
        }()

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isRecording ? theme.destructive.opacity(0.15) : theme.accent.opacity(0.12))
                    .frame(width: 56, height: 56)
                if isRecording {
                    Circle()
                        .stroke(theme.destructive, lineWidth: 2)
                        .frame(width: 56, height: 56)
                        .opacity(0.7)
                }
                Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isRecording ? theme.destructive : theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText(isRecording: isRecording, isBusy: isBusy))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                if isRecording {
                    Text(elapsedTime)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced).monospacedDigit())
                        .foregroundColor(theme.destructive)
                } else {
                    Text(subtitle())
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }
            }

            Spacer()

            Button {
                meetingService.toggle()
            } label: {
                Text(isRecording ? "停止会议" : "开始会议")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isRecording ? theme.destructive : theme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.6 : 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func headlineText(isRecording: Bool, isBusy: Bool) -> String {
        if isRecording { return "正在录制" }
        switch meetingService.state {
        case .finishing: return "正在保存音频…"
        case .summarizing: return "正在生成摘要…"
        case .error(let msg): return "出错：\(msg)"
        default: return "准备录制会议"
        }
    }

    private func subtitle() -> String {
        // Meetings share the voice input engine, so the provenance comes from
        // `asrProviderType` rather than a (now removed) meeting-specific field.
        let isCloud = configManager.asrProviderType == "cloud"
        let provenance = isCloud ? "云端转写" : "本地转写"
        return "\(provenance) · 双击 ⌘ 也可启动"
    }

    private func summaryErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.destructive)
            VStack(alignment: .leading, spacing: 4) {
                Text("摘要生成失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                meetingService.summaryError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.destructive.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Timer

    private func updateTimer(for state: MeetingState) {
        timerCancellable?.invalidate()
        timerCancellable = nil
        switch state {
        case .recording:
            startTimer()
        case .finishing, .summarizing:
            break
        case .idle, .error:
            elapsedTime = "00:00:00"
        }
    }

    private func startTimer() {
        let service = meetingService
        timerCancellable = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedTime = formatDuration(service.elapsedSeconds)
        }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
