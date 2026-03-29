import AVFoundation
import Combine
import Foundation
import ApplicationServices
import AppKit

/// Manages macOS permission checks and triggers for Accessibility, Microphone, Screen Recording.
final class PermissionManager: ObservableObject, PermissionManagerProtocol {

    @Published var status: PermissionStatus = .notDetermined

    // MARK: - Init

    init() {
        recheckAll()
    }

    // MARK: - PermissionManagerProtocol

    func recheckAll() {
        let accessibility = AXIsProcessTrusted()
        let microphone = checkMicrophone()
        let screenRecording = CGPreflightScreenCaptureAccess()

        let newStatus = PermissionStatus(
            accessibility: accessibility,
            microphone: microphone,
            screenRecording: screenRecording
        )

        // Update synchronously if already on main thread, otherwise dispatch
        if Thread.isMainThread {
            self.status = newStatus
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status = newStatus
            }
        }
    }

    /// Show system Accessibility trust dialog.
    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Request Microphone access via system dialog, /// Falls back to System Settings if denied.
    func openMicrophoneSettings() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.recheckAll()
                }
            }
        } else if authStatus == .denied {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Show system Screen Recording dialog.
    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Private

    private func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        default: return false
        }
    }
}
