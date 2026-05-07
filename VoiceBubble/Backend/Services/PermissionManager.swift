import AVFoundation
import Combine
import Foundation
import ApplicationServices
import AppKit

/// Manages macOS permission checks and triggers for Accessibility, Microphone, Screen Recording.
final class PermissionManager: ObservableObject, PermissionManagerProtocol {

    @Published var status: PermissionStatus = .notDetermined

    /// True once a permission that requires process restart to fully take effect
    /// (Screen Recording) has flipped from denied → granted during this run.
    /// UI layer watches this to show a "重启 Voice Bubble" prompt.
    @Published var needsRelaunch: Bool = false

    /// Snapshot of Screen Recording permission at launch, so we can detect
    /// the deny→grant transition that triggers the relaunch banner.
    private let screenRecordingAtLaunch: Bool

    // MARK: - Init

    init() {
        self.screenRecordingAtLaunch = CGPreflightScreenCaptureAccess()
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

        // Screen Recording: macOS registers the grant immediately but existing
        // process capture streams stay broken until relaunch. Flag it so the UI
        // can prompt; Accessibility/Microphone don't need this.
        let justGotScreenRecording = !screenRecordingAtLaunch && screenRecording

        // Update synchronously if already on main thread, otherwise dispatch
        if Thread.isMainThread {
            self.status = newStatus
            if justGotScreenRecording { self.needsRelaunch = true }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status = newStatus
                if justGotScreenRecording { self?.needsRelaunch = true }
            }
        }
    }

    /// Show system Accessibility trust dialog on first request; if the user has
    /// already denied (no more prompt is possible), open System Settings → Privacy
    /// → Accessibility directly so they can toggle the switch manually.
    func openAccessibilitySettings() {
        // If already trusted, nothing to do.
        guard !AXIsProcessTrusted() else { return }

        // Try the native prompt first. If Accessibility has already been denied
        // for this app, the prompt is a no-op, so we fall back to opening the
        // Privacy pane directly after a short delay.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, !AXIsProcessTrusted() else { return }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            self.recheckAll()
        }
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

    /// Relaunch the app. Used after Screen Recording permission flips from
    /// denied → granted, because the existing process can't create capture
    /// streams even though preflight now returns true.
    func relaunchApp() {
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Private

    private func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        default: return false
        }
    }
}
