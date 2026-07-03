import SwiftUI
import AppKit
import Combine

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
    /// True while a meeting's ASR model is still loading. Drives a pulsing
    /// "loading" waveform so the overlay reads as alive — not frozen —
    /// during the model-load wait that precedes actual recording.
    @Published var isPreparing: Bool = false
    /// True when the overlay is showing a transient error/tip (showBriefMessage).
    /// In this mode the content view drops the waveform — an error has nothing
    /// to do with audio level — and centers the text.
    @Published var isBriefMessage: Bool = false

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
        isPreparing = false
        isBriefMessage = false
    }

}

// MARK: - Overlay Content View

struct RecordingOverlayContentView: View {
    @ObservedObject var streamingState: StreamingTextState
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Group {
            if streamingState.isBriefMessage {
                // Brief error/tip — text only, centered. No waveform: an error
                // message ("没识别到内容") has nothing to do with audio level.
                Text(streamingState.text)
                    .font(.system(size: streamingState.fontSize, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: streamingState.maxTextWidth)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
            } else {
                // Recording — the waveform, fill+centered so the bubble's blue
                // waveform lands dead-center in the (screen-centered) panel.
                HStack(alignment: .center, spacing: 0) {
                    RecordingWaveformView(streamingState: streamingState)
                        .frame(width: 36, height: 36)

                    if streamingState.isEnabled && !streamingState.text.isEmpty {
                        Text(streamingState.text)
                            .font(.system(size: streamingState.fontSize, weight: .medium))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: streamingState.maxTextWidth, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.trailing, 16)
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(theme.surfaceBackground)
    }
}

// MARK: - Recording Overlay Panel

final class RecordingOverlayPanel: NSPanel, OverlayPresenting {

    // MARK: Singleton

    static let shared = RecordingOverlayPanel()

    // MARK: Constants

    private let compactSize: CGFloat = 44
    private let topPadding: CGFloat = 20
    /// Codex HUD radius — slightly larger than card radius (8) to read as a
    /// pill, but not full circle. Spec §6.8.
    private let cornerRadius: CGFloat = 12
    /// REC label + waveform + trailing padding
    private let horizontalOverhead: CGFloat = 110
    /// Symmetric horizontal padding for a brief message (text only, no waveform).
    private let briefHorizontalPadding: CGFloat = 32

    // MARK: Streaming State

    let streamingState = StreamingTextState()

    private var hostingView: NSHostingView<AnyView>?
    private weak var themeRef: ThemeManager?
    private var themeCancellable: AnyCancellable?

    /// Bumped on every `show()`. `hide()`'s completion handler bails out if the
    /// token has changed in the meantime — i.e. a new `show()` superseded this
    /// hide while its animation was still in flight. Without this, the stale
    /// completion would reset the new recording's text and collapse the panel.
    private var showToken: Int = 0

    /// Must be called once after app creates ThemeManager, before showing the panel.
    func configure(themeManager: ThemeManager) {
        self.themeRef = themeManager

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

        if let backdrop = contentView {
            backdrop.subviews.forEach { $0.removeFromSuperview() }
            backdrop.addSubview(hosting)
        }

        applyThemeColors()
        // Repaint the AppKit backdrop whenever the theme flips light/dark.
        // SwiftUI subviews already react via @EnvironmentObject; the CALayer
        // border/background needs an explicit refresh.
        themeCancellable = themeManager.$isDark
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyThemeColors() }
    }

    /// Pull current theme colors into the AppKit backdrop layer. The SwiftUI
    /// view inside paints `theme.surfaceBackground` over the entire content
    /// area, so the backdrop's only visible job is the 1px hairline border.
    private func applyThemeColors() {
        guard let backdrop = contentView else { return }
        let isDark = themeRef?.isDark ?? false
        // Border: 8% of foreground in both modes. NSColor matches the
        // SwiftUI `.opacity(0.08)` on `theme.textPrimary`.
        let borderNS = isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)
        // Backdrop layer color is a fallback only — SwiftUI paints over it.
        // Match the surface color so any clipping rounding artifact reads as
        // continuous with the SwiftUI content.
        let bgNS: NSColor = isDark
            ? NSColor(red: 0x28/255.0, green: 0x28/255.0, blue: 0x28/255.0, alpha: 1.0)
            : NSColor.white
        backdrop.layer?.backgroundColor = bgNS.cgColor
        backdrop.layer?.borderColor = borderNS.cgColor
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
        // Codex HUD: window-level shadow gives the bubble visible weight
        // against bright wallpapers without any custom CALayer halo.
        hasShadow = true
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Codex HUD: flat dark surface, hairline border, no vibrancy/material.
        // Replaces the previous NSVisualEffectView popover material — Codex
        // doesn't use vibrancy anywhere in its UI; it paints flat colors.
        let contentViewSwift = RecordingOverlayContentView(streamingState: streamingState)
        let hosting = NSHostingView(rootView: AnyView(contentViewSwift))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        self.hostingView = hosting

        // Backdrop colors are set in `applyThemeColors()` after `configure()`
        // injects the ThemeManager. Defaults here are a placeholder that gets
        // overwritten before the panel is ever shown.
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.white.cgColor
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.masksToBounds = true
        backdrop.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        backdrop.autoresizingMask = [.width, .height]

        // Shape mask for crisp clipping on resize
        let shapeMask = CAShapeLayer()
        shapeMask.path = CGPath(roundedRect: backdrop.bounds,
                                 cornerWidth: cornerRadius,
                                 cornerHeight: cornerRadius,
                                 transform: nil)
        backdrop.layer?.mask = shapeMask

        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        backdrop.addSubview(hosting)
        self.contentView = backdrop

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

    func show(mode: OverlayMode = .voice, preparing: Bool = false) {
        showToken &+= 1

        // Recording overlay shows only the waveform — no live transcript.
        streamingState.isEnabled = false
        streamingState.mode = mode
        streamingState.meetingElapsed = 0
        streamingState.reset()
        // Set after reset() — reset() clears isPreparing back to false.
        streamingState.isPreparing = preparing
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

    /// Transition an already-visible preparing overlay into the live
    /// recording state. No re-entry animation — the bubble is already on
    /// screen; only the waveform switches from "loading pulse" to live audio.
    func beginRecording() {
        streamingState.isPreparing = false
    }

    /// Show streaming ASR text alongside the waveform — the 渐进上屏 mode's
    /// "in-flight transcription" preview. The first call expands the panel
    /// from waveform-only to waveform + text; subsequent calls just update
    /// the text in place. Pass an empty string to hide the preview again.
    func setStreamingText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            streamingState.isEnabled = false
            streamingState.text = ""
            return
        }
        let wasEnabled = streamingState.isEnabled
        if !wasEnabled {
            let screenWidth = NSScreen.main?.frame.width ?? 1440
            streamingState.maxTextWidth = screenWidth / 2 - horizontalOverhead
            streamingState.fontSize = 14
            streamingState.isEnabled = true
        }
        streamingState.setTarget(trimmed)
        resizePanelToFitContent()
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
        let maxTextWidth = screenWidth / 2 - briefHorizontalPadding

        streamingState.isBriefMessage = true
        streamingState.isEnabled = true
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

        // Fast fade only — no positional slide. The bubble's hide is meant
        // to feel "instant" on key release; a directional slide makes the
        // 80 ms read as slower than it is, and the slide direction was
        // arbitrary (the bubble doesn't live at a panel edge).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self, self.showToken == myToken else { return }
            self.streamingState.reset()
            self.streamingState.isEnabled = false
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


    // MARK: Dynamic Sizing

    private func resizePanelToFitContent() {
        guard streamingState.isEnabled, !streamingState.text.isEmpty else { return }
        guard let screen = NSScreen.main else { return }

        let maxPanelWidth = screen.frame.width / 2
        let fontSize = streamingState.fontSize
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        // Horizontal chrome around the text: a brief message is text-only with
        // symmetric padding; a recording overlay also reserves the waveform.
        let horizontalChrome = streamingState.isBriefMessage ? briefHorizontalPadding : horizontalOverhead

        // Max text width must match SwiftUI view's constraint
        let maxTextWidth = maxPanelWidth - horizontalChrome

        // Calculate text bounds with wrapping at maxTextWidth
        let textRect = (streamingState.text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        // Panel dimensions
        let verticalPadding: CGFloat = 24
        let panelWidth = min(horizontalChrome + ceil(textRect.width), maxPanelWidth)
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
        if let backdrop = contentView {
            backdrop.layer?.cornerRadius = radius
            if let shapeMask = backdrop.layer?.mask as? CAShapeLayer {
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
