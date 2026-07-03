import Foundation
import CoreGraphics

// MARK: - Overlay Presenting

/// Backend-facing abstraction over the recording overlay HUD. Lets the
/// services and their collaborators drive the floating panel through the
/// Shared layer instead of reaching into the concrete Frontend singleton
/// `RecordingOverlayPanel.shared`.
///
/// `@MainActor` mirrors `RecordingOverlayPanel`'s isolation — the panel is an
/// `NSPanel` subclass, so main-actor isolation is inferred from inheritance.
/// The concrete panel already implements every requirement below.
@MainActor
protocol OverlayPresenting {
    func show(mode: OverlayMode, preparing: Bool)
    func beginRecording()
    func hide()
    func showBriefMessage(_ message: String, fontSize: CGFloat, duration: TimeInterval)
    func updateAudioLevel(_ level: Float)
    func updateMeetingElapsed(_ seconds: Int)
}

// Convenience overloads reproduce `RecordingOverlayPanel`'s default arguments,
// which protocol requirements can't carry. Distinct arities keep them separate
// from the requirements above (no recursion).
extension OverlayPresenting {
    func show() { show(mode: .voice, preparing: false) }
    func showBriefMessage(_ message: String) {
        showBriefMessage(message, fontSize: 14, duration: 2.5)
    }
}
