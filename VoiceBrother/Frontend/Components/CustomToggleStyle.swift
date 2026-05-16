import SwiftUI

/// Codex toggle: near-black track when on, muted-gray track when off, white
/// knob, ease-out motion (no spring). On-state matches the primary-button
/// fill so toggles read as "same family" as primary actions.
struct CustomToggleStyle: ToggleStyle {
    @EnvironmentObject private var theme: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        return ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? theme.toggleActive : theme.toggleInactive)
                .frame(width: 44, height: 24)

            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .padding(3)
                .shadow(color: .black.opacity(theme.isDark ? 0 : 0.15),
                        radius: 1, x: 0, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(theme.easeEnter) {
                configuration.isOn.toggle()
            }
        }
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isButton)
    }
}
