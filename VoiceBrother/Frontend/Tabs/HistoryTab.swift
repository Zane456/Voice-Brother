import SwiftUI

/// Unified history center. Internal segmented switch toggles between
/// voice transcription history (SQLite) and meeting markdown files.
struct HistoryTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var theme: ThemeManager

    @State private var selectedKind: Kind = .voice
    /// Guards the one-time `selectedKind` sync from `lastHistoryKind` so a
    /// manual segment switch isn't overridden on every re-appear.
    @State private var didInitKind = false

    private enum Kind: String, CaseIterable {
        case voice = "语音输入"
        case meeting = "声音录制"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Picker("", selection: $selectedKind) {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .tint(theme.accent)
                .frame(width: 220)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)

            Group {
                switch selectedKind {
                case .voice:
                    VoiceHistoryView()
                case .meeting:
                    MeetingHistoryView(savePath: configManager.meetingSavePath)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // One-time sync: open on whichever segment the most recently
            // completed task belongs to. Manual switches afterwards stand.
            guard !didInitKind else { return }
            selectedKind = configManager.lastHistoryKind == "meeting" ? .meeting : .voice
            didInitKind = true
        }
    }
}
