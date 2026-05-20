import SwiftUI

/// Mini illustration of the macOS System Settings pane the user needs to flip a
/// switch in. Used inside `OnboardingView` so the "Open System Settings" button
/// isn't just a black-box jump — the user knows exactly which row and toggle
/// they're looking for before they leave the app.
///
/// Drawn entirely in SwiftUI with SF Symbols + theme colours, so it tracks the
/// app's appearance and doesn't drift when macOS redesigns System Settings.
struct SystemSettingsIllustration: View {

    enum Pane {
        case accessibility
        case microphone
        case screenRecording

        var title: String {
            switch self {
            case .accessibility:    return "辅助功能"
            case .microphone:       return "麦克风"
            case .screenRecording:  return "屏幕录制"
            }
        }

        var sidebarIcon: String {
            switch self {
            case .accessibility:    return "accessibility"
            case .microphone:       return "mic"
            case .screenRecording:  return "rectangle.on.rectangle.angled"
            }
        }
    }

    let pane: Pane
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        HStack(spacing: 0) {
            // Left "sidebar" — three rows hinting at the System Settings list,
            // with the relevant row highlighted.
            VStack(alignment: .leading, spacing: 6) {
                sidebarRow(icon: "lock", label: "隐私与安全性", highlighted: false)
                sidebarRow(icon: pane.sidebarIcon, label: pane.title, highlighted: true)
                sidebarRow(icon: "person.crop.circle", label: "用户与群组", highlighted: false)
            }
            .padding(8)
            .frame(width: 110, alignment: .leading)
            .background(theme.surfaceBackground)

            Divider()

            // Right pane — one row representing Voice Brother with a green
            // toggle and an arrow pointing at it.
            VStack(alignment: .leading, spacing: 6) {
                Text(pane.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                HStack(spacing: 6) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 10))
                        .foregroundColor(theme.accentSecondary)
                    Text("Voice Brother")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textPrimary)

                    Spacer()

                    // The toggle to flip — drawn as on (green).
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(Color.green.opacity(0.85))
                            .frame(width: 22, height: 13)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 11, height: 11)
                            .padding(.trailing, 1)
                    }
                    // Arrow nudging the eye toward the toggle.
                    Image(systemName: "arrowshape.left.fill")
                        .font(.system(size: 9))
                        .foregroundColor(theme.accent)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.accent.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.accent.opacity(0.35), lineWidth: 1))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 78)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sidebarRow(icon: String, label: String, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(highlighted ? theme.accent : theme.textTertiary)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 10, weight: highlighted ? .semibold : .regular))
                .foregroundColor(highlighted ? theme.textPrimary : theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            highlighted
                ? RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(0.18))
                : RoundedRectangle(cornerRadius: 4).fill(Color.clear)
        )
    }
}
