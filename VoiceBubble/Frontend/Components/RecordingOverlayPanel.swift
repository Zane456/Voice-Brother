import SwiftUI
import AppKit

// MARK: - Streaming Text State

enum OverlayMode {
    case voice    // Hold-to-talk voice input
    case meeting  // Long meeting recording
}

class StreamingTextState: ObservableObject {
    @Published var text: String = ""
    @Published var isEnabled: Bool = false
    @Published var fontSize: CGFloat = 16
    @Published var maxTextWidth: CGFloat = 300
    @Published var mode: OverlayMode = .voice
    @Published var meetingElapsed: Int = 0  // seconds, for REC label
    /// True between key release and final text injection — drives the
    /// "识别中" hint so the user gets a clear "I'm working" signal instead
    /// of the panel disappearing silently.
    @Published var isFinalizing: Bool = false

    // Audio-driven waveform state
    @Published var audioLevel: CGFloat = 0
    @Published var barHeights: [CGFloat] = Array(repeating: 0.15, count: 5)

    private static let barWeights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private static let minBarFraction: CGFloat = 0.15

    /// Set new text from ASR — displayed instantly for responsiveness.
    func setTarget(_ newText: String) {
        text = newText
    }

    /// Update audio level from RMS. Applies attack/release envelope and per-bar jitter.
    func updateAudioLevel(_ raw: CGFloat) {
        let attack: CGFloat = 0.4
        let release: CGFloat = 0.15
        let factor = raw > audioLevel ? attack : release
        audioLevel += (raw - audioLevel) * factor

        barHeights = Self.barWeights.map { weight in
            let fraction = Self.minBarFraction + (1 - Self.minBarFraction) * audioLevel * weight
            let jitter = CGFloat.random(in: -0.04...0.04)
            return min(max(fraction + jitter, Self.minBarFraction), 1.0)
        }
    }

    /// Reset all state (called on hide).
    func reset() {
        text = ""
        audioLevel = 0
        barHeights = Array(repeating: Self.minBarFraction, count: 5)
    }

}

// MARK: - Overlay Content View

struct RecordingOverlayContentView: View {
    @ObservedObject var streamingState: StreamingTextState
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Plain waveform in both modes — the menu bar carries the
            // "REC 00:42" text for meetings, so the overlay doesn't need
            // its own indicator dot. Earlier a small red pulse lived in
            // the top-left corner for meeting mode, but it read as a stray
            // orange speck against the warm-themed waveform bars.
            RecordingWaveformView(streamingState: streamingState)
                .frame(width: 44, height: 44)
                .opacity(streamingState.isFinalizing && streamingState.mode == .voice ? 0.55 : 1.0)

            if streamingState.isEnabled && !streamingState.text.isEmpty {
                Text(streamingState.text)
                    .font(.system(size: streamingState.fontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: streamingState.maxTextWidth, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.trailing, 16)
            }
        }
        .frame(minHeight: 44, alignment: .center)
        .animation(.easeInOut(duration: 0.18), value: streamingState.isFinalizing)
    }

    private func formatElapsed(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Recording Overlay Panel

final class RecordingOverlayPanel: NSPanel {

    // MARK: Singleton

    static let shared = RecordingOverlayPanel()

    // MARK: Constants

    private let compactSize: CGFloat = 44
    private let topPadding: CGFloat = 20
    private let cornerRadius: CGFloat = 22
    /// Waveform area + trailing padding
    private let horizontalOverhead: CGFloat = 60

    // MARK: Streaming State

    let streamingState = StreamingTextState()

    private var hostingView: NSHostingView<AnyView>?

    /// Bumped on every `show()`. `hide()`'s completion handler bails out if the
    /// token has changed in the meantime — i.e. a new `show()` superseded this
    /// hide while its animation was still in flight. Without this, the stale
    /// completion would reset the new recording's text and collapse the panel.
    private var showToken: Int = 0

    /// Must be called once after app creates ThemeManager, before showing the panel.
    func configure(themeManager: ThemeManager) {
        let rootView = AnyView(
            RecordingOverlayContentView(streamingState: streamingState)
                .environmentObject(themeManager)
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        // contentView is now the NSVisualEffectView directly — re-host SwiftUI content into it.
        if let visualEffect = contentView as? NSVisualEffectView {
            visualEffect.subviews.forEach { $0.removeFromSuperview() }
            visualEffect.addSubview(hosting)
        }
    }

    // MARK: Init

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
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
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Build content hierarchy: NSVisualEffectView > NSHostingView.
        // No outer container, no custom CALayer shadow, no breathing glow:
        // those additions caused a visible rectangular silhouette around the
        // rounded panel (especially on light-themed backgrounds where the
        // soft drop-shadow's bounding box read as a square halo). The system
        // popover material gives a clean rounded shape with no halo.
        let contentViewSwift = RecordingOverlayContentView(streamingState: streamingState)
        let hosting = NSHostingView(rootView: AnyView(contentViewSwift))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        self.hostingView = hosting

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover         // adaptive light/dark, no harsh tint
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        visualEffect.autoresizingMask = [.width, .height]

        // Shape layer mask — more reliable clipping than cornerRadius alone
        let shapeMask = CAShapeLayer()
        shapeMask.path = CGPath(roundedRect: visualEffect.bounds,
                                 cornerWidth: cornerRadius,
                                 cornerHeight: cornerRadius,
                                 transform: nil)
        visualEffect.layer?.mask = shapeMask

        // Clip hosting view to rounded corners
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        visualEffect.addSubview(hosting)
        self.contentView = visualEffect

        // Start hidden (keep in window hierarchy for .canJoinAllSpaces)
        alphaValue = 0
    }

    /// No-op kept so existing call sites don't have to change. Previously this
    /// updated a custom CALayer drop-shadow path; that shadow was removed
    /// because it created a visible rectangular halo on light-themed
    /// backgrounds. The visualEffect's mask handles all clipping now.
    private func updateShadowPath(size: CGSize, radius: CGFloat) { }

    /// Stubs — breathing-glow shadow was removed (see init comment).
    private func startBreathing() { }
    private func stopBreathing() { }

    // MARK: Public API

    func show(streamingEnabled: Bool = false, fontSize: CGFloat = 16, mode: OverlayMode = .voice) {
        showToken &+= 1

        // Calculate max text width for this screen
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let maxTextWidth = screenWidth / 2 - horizontalOverhead

        // Update streaming state
        streamingState.isEnabled = streamingEnabled
        streamingState.fontSize = fontSize
        streamingState.maxTextWidth = maxTextWidth
        streamingState.mode = mode
        streamingState.meetingElapsed = 0
        streamingState.isFinalizing = false
        streamingState.reset()
        // Always start at compact circular size — meeting mode no longer
        // shows REC + time inline (the menu bar carries that), so we can
        // keep the floating bubble as a single 44×44 circle in both modes.
        setContentSize(NSSize(width: compactSize, height: compactSize))

        positionAtScreenTopCenter()

        // Spring entry: start 10px below final position, spring up into place
        let finalOrigin = frame.origin
        setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y - 10))
        alphaValue = 0
        orderFrontRegardless()
        startBreathing()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            // Spring-like curve: overshoots slightly then settles
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.175, 0.885, 0.32, 1.1)
            self.animator().alphaValue = 1.0
            self.animator().setFrameOrigin(finalOrigin)
        }
    }

    /// Dim the waveform during the gap between key release and final text
    /// injection, so the user has a visual cue that we're working on it.
    func markFinalizing() {
        streamingState.isFinalizing = true
    }

    /// Last brief message + when it was shown. Used to suppress repeat toasts
    /// when the underlying failure is sticky (e.g. mic occupied gives the same
    /// error every key press — showing it every time turns into spam).
    private var lastBriefMessage: String = ""
    private var lastBriefMessageAt: Date = .distantPast

    /// Show a transient text message (error/warning) and auto-hide after `duration`.
    /// Used for silent-failure cases (mic occupied, no audio captured, ASR hallucinated
    /// silence) so the user always gets visible feedback instead of the overlay
    /// disappearing without explanation.
    ///
    /// Same message within 10s is suppressed (just hides the existing overlay) —
    /// prevents error spam when the user keeps pressing through a sticky failure.
    func showBriefMessage(_ message: String, fontSize: CGFloat = 14, duration: TimeInterval = 2.5) {
        // Dedup: same message within 10s → just hide any existing overlay silently.
        if message == lastBriefMessage,
           Date().timeIntervalSince(lastBriefMessageAt) < 10 {
            hide()
            return
        }
        lastBriefMessage = message
        lastBriefMessageAt = Date()

        showToken &+= 1
        let myToken = showToken

        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let maxTextWidth = screenWidth / 2 - horizontalOverhead

        streamingState.isEnabled = true
        streamingState.isFinalizing = false
        streamingState.fontSize = fontSize
        streamingState.maxTextWidth = maxTextWidth
        streamingState.mode = .voice
        streamingState.setTarget(message)
        resizePanelToFitContent()

        if alphaValue < 0.99 {
            positionAtScreenTopCenter()
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 1.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.showToken == myToken else { return }
            self.hide()
        }
    }

    func hide() {
        let myToken = showToken
        let originalY = frame.origin.y

        // No frame-size animation — only fade alpha + small upward nudge.
        // Scaling width/height during hide caused the shadow path and the
        // visualEffect mask radius to fall out of sync, leaving a visible
        // rectangular silhouette at the end of the animation. Keeping the
        // dimensions constant means the rounded shape stays a clean circle/
        // capsule from start to finish.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
            self.animator().setFrameOrigin(NSPoint(x: self.frame.origin.x,
                                                    y: originalY + 6))
        }, completionHandler: { [weak self] in
            guard let self, self.showToken == myToken else { return }
            self.streamingState.reset()
            self.streamingState.isEnabled = false
            self.streamingState.isFinalizing = false
            self.setContentSize(NSSize(width: self.compactSize, height: self.compactSize))
        })
    }

    func updateAudioLevel(_ level: Float) {
        streamingState.updateAudioLevel(CGFloat(level))
    }

    /// Meeting timer tick — updates the REC label without disturbing audio level.
    func updateMeetingElapsed(_ seconds: Int) {
        streamingState.meetingElapsed = seconds
    }

    func updateStreamingText(_ text: String) {
        streamingState.setTarget(text)
        resizePanelToFitContent()
    }

    // MARK: Dynamic Sizing

    private func resizePanelToFitContent() {
        guard streamingState.isEnabled, !streamingState.text.isEmpty else { return }
        guard let screen = NSScreen.main else { return }

        let maxPanelWidth = screen.frame.width / 2
        let fontSize = streamingState.fontSize
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        // Max text width must match SwiftUI view's constraint
        let maxTextWidth = maxPanelWidth - horizontalOverhead

        // Calculate text bounds with wrapping at maxTextWidth
        let textRect = (streamingState.text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        // Panel dimensions
        let verticalPadding: CGFloat = 24
        let panelWidth = min(horizontalOverhead + ceil(textRect.width), maxPanelWidth)
        let panelHeight = max(compactSize, ceil(textRect.height) + verticalPadding)

        // Keep current top edge fixed, grow downward
        let screenFrame = screen.frame
        let currentTopEdge = frame.origin.y + frame.height
        let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
        let y = currentTopEdge - panelHeight

        let newFrame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        // Set frame directly — no animation during streaming to prevent text "jumping"
        setFrame(newFrame, display: true)

        // Update corner radius and mask for new size
        let radius = min(panelHeight / 2, cornerRadius)
        if let visualEffect = contentView as? NSVisualEffectView {
            visualEffect.layer?.cornerRadius = radius
            if let shapeMask = visualEffect.layer?.mask as? CAShapeLayer {
                shapeMask.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                                         cornerWidth: radius,
                                         cornerHeight: radius,
                                         transform: nil)
            }
        }
        hostingView?.layer?.cornerRadius = radius
    }

    // MARK: Positioning

    private func positionAtScreenTopCenter() {
        // Anchor to the screen under the mouse cursor rather than NSScreen.main,
        // which is whichever screen has keyboard focus — on multi-monitor setups
        // that's often a different display than where the user is actually
        // working. The cursor location is the most reliable proxy for "where
        // the user is looking right now".
        let screen = screenForActiveContext() ?? NSScreen.main
        guard let screen else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let screenTop = visibleFrame.origin.y + visibleFrame.height
        let currentWidth = frame.width
        let currentHeight = frame.height
        let x = screenFrame.origin.x + (screenFrame.width - currentWidth) / 2.0
        let y = screenTop - currentHeight - topPadding
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenForActiveContext() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}
