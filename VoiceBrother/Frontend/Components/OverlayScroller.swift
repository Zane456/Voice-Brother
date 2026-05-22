import SwiftUI
import AppKit

/// A thin, auto-hiding scroller with a soft light-gray capsule knob.
///
/// macOS shows the *legacy* scroller — opaque, always visible, layout-occupying
/// — whenever a mouse is connected. At a window's rounded corner the legacy
/// knob's rounded head/tail get clipped, and it never fades out even when idle.
///
/// This subclass is paired with `scrollerStyle = .overlay` so it:
///   • auto-hides when not scrolling (overlay behaviour),
///   • floats over content, inset from the edge — caps no longer clipped,
///   • paints its own knob, a deliberately faint gray capsule.
final class SoftOverlayScroller: NSScroller {

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// Overlay style — no visible track behind the knob.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        // Inset the knob rect so the capsule never reaches the window edge;
        // this is what stops the rounded head/tail from being clipped.
        let r = rect(for: .knob).insetBy(dx: 2.5, dy: 2.5)
        guard r.width > 0, r.height > 0 else { return }
        // Faint mid-gray — softer and lighter than the system knob.
        NSColor(white: 0.6, alpha: 0.32).setFill()
        let radius = r.width / 2
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}

/// Zero-size helper: walks up to the enclosing `NSScrollView` and swaps in the
/// soft overlay scroller. Applied via `.installOverlayScroller()` on a
/// `ScrollView`'s content (it must live *inside* the scroll view so that
/// `enclosingScrollView` resolves).
private struct OverlayScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { install(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(from: nsView) }
    }

    private func install(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        if !(scrollView.verticalScroller is SoftOverlayScroller) {
            let scroller = SoftOverlayScroller()
            scroller.scrollerStyle = .overlay
            scrollView.verticalScroller = scroller
        }
    }
}

extension View {
    /// Apply to a `ScrollView`'s **content** to replace the backing
    /// `NSScrollView`'s scroller with the soft, auto-hiding overlay style.
    func installOverlayScroller() -> some View {
        background(
            OverlayScrollerInstaller()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
