import SwiftUI

/// Small rectangular badge — used for hotword tags, status pills, provenance
/// chips. Codex shape language: small radius rectangles, mono label, neutral
/// fill, optional leading SF Symbol. Spec §6.7.
struct CodexBadge: View {
    enum Variant {
        case neutral       // hotword / generic tag
        case running       // amber
        case success       // green (ready/online)
        case error         // red
        case cloud         // neutral grey + cloud icon
        case local         // neutral grey + lock.shield icon
    }

    let text: String
    var variant: Variant = .neutral
    var icon: String? = nil
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        HStack(spacing: 4) {
            if let icon = effectiveIcon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(fg)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(fg)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(fg.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(bg)
        )
    }

    private var effectiveIcon: String? {
        if let icon { return icon }
        switch variant {
        case .cloud: return "cloud.fill"
        case .local: return "lock.shield.fill"
        default: return nil
        }
    }

    private var fg: Color {
        switch variant {
        case .neutral, .cloud, .local: return theme.textSecondary
        case .running: return theme.warning
        case .success: return theme.accent
        case .error:   return theme.destructive
        }
    }

    private var bg: Color {
        switch variant {
        case .neutral, .cloud, .local: return theme.tagBackground
        case .running: return theme.warning.opacity(0.15)
        case .success: return theme.accent.opacity(0.15)
        case .error:   return theme.destructive.opacity(0.15)
        }
    }
}
