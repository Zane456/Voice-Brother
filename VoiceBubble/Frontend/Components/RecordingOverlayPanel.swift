import SwiftUI
import AppKit

final class RecordingOverlayPanel: NSPanel {

    // MARK: Singleton

    static let shared = RecordingOverlayPanel()

    // MARK: Constants

    private let panelWidth: CGFloat = 44
    private let panelHeight: CGFloat = 44
    private let topPadding: CGFloat = 12

    private var hostingView: NSHostingView<RecordingWaveformView>?

    // MARK: Init

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        // Window configuration
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Build content hierarchy: NSVisualEffectView > NSHostingView
        let waveform = RecordingWaveformView()
        let hosting = NSHostingView(rootView: waveform)
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        self.hostingView = hosting

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 22
        visualEffect.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        // Clip hosting view to rounded corners
        hosting.layer?.cornerRadius = 22
        hosting.layer?.masksToBounds = true

        visualEffect.addSubview(hosting)
        self.contentView = visualEffect

        // Start hidden
        alphaValue = 0
        orderOut(nil)
    }

    // MARK: Public API

    func show() {
        positionAtScreenTopCenter()
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    // MARK: Positioning

    /// Places the panel at the top-center of the main screen, `topPadding` points
    /// below the visible area top edge.
    private func positionAtScreenTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let screenTop = visibleFrame.origin.y + visibleFrame.height
        // Horizontal: center on full screen width (ignoring dock position)
        let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2.0
        // Vertical: below menu bar
        let y = screenTop - panelHeight - topPadding
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
