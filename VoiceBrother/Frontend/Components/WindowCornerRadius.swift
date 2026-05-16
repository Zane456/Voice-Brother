import SwiftUI
import AppKit

/// Bumps the host NSWindow's corner radius beyond the macOS default so the
/// window reads as more "rounded" — matching the visual softness of macOS
/// System Settings on Sequoia/Tahoe. The default is ~10pt; we go to ~16pt
/// with continuous corner curve.
///
/// Apply with `.modifier(WindowCornerRadius(radius: 16))` on the root view
/// once the window is in the hierarchy.
struct WindowCornerRadius: ViewModifier {
    let radius: CGFloat

    /// Codex content width. The window is normalized to this once per launch.
    private static let targetWidth: CGFloat = 672
    private static var didNormalizeWidth = false

    func body(content: Content) -> some View {
        content.background(WindowAccessor { window in
            apply(to: window)
        })
    }

    private func apply(to window: NSWindow) {
        // Make the window background transparent so the rounded corners are
        // actually visible (otherwise the system draws a square backing).
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Keep only the close (red) button. Zoom enlarges the UI — not a
        // feature this settings window needs — and closing the window
        // doesn't quit the app, so minimize is redundant too.
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        // Narrow the window to the Codex content width once per launch (a
        // persisted frame can otherwise restore an over-wide window). Left
        // edge stays put; the user can still widen it within the session.
        if !Self.didNormalizeWidth {
            Self.didNormalizeWidth = true
            if window.frame.width - Self.targetWidth > 1 {
                var f = window.frame
                f.size.width = Self.targetWidth
                window.setFrame(f, display: true)
            }
        }

        // Round the contentView's layer with continuous (Apple) curve.
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

/// One-shot SwiftUI ↔︎ NSWindow bridge. Calls `onWindow` when the host
/// window first becomes available, then again only if it changes.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
