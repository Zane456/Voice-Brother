import SwiftUI

struct CustomToggleStyle: ToggleStyle {
    @EnvironmentObject private var theme: ThemeManager
    @State private var isPressed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        return ZStack(alignment: isOn ? .trailing : .leading) {
            // Track
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? theme.accent : theme.toggleInactive)
                .frame(width: 44, height: 24)

            // Knob — slightly stretches horizontally while pressed for a
            // tactile feel that matches the spring track animation.
            Capsule()
                .fill(.white)
                .frame(width: isPressed ? 22 : 18, height: 18)
                .padding(3)
                .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
        }
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                configuration.isOn.toggle()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isPressed = false }
                }
        )
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isButton)
    }
}
