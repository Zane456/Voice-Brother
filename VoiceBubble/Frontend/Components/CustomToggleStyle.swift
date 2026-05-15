import SwiftUI

/// Codex toggle: green track when on, hairline-grey when off, white knob,
/// ease-out motion (no spring bounce). Spec §6.5.
struct CustomToggleStyle: ToggleStyle {
    @EnvironmentObject private var theme: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        return ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? theme.accent : theme.toggleInactive)
                .frame(width: 44, height: 24)

            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .padding(3)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        }
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isButton)
    }
}
