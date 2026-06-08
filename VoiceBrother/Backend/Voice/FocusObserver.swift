import AppKit
import ApplicationServices
import Foundation

/// Polls the system-wide accessibility focused element. Fires `onEditableFocused`
/// when the user clicks into a text-editable field, and `onEditableUnfocused` when
/// focus leaves one. Used by `VoiceService` to bring the Bluetooth audio engine up
/// while the user is in a context where they're likely to press the voice trigger,
/// so the SCO link is already warm when they actually press.
///
/// Privacy: only the focused element's `role` attribute is read. The element's
/// value (what the user is typing) is never accessed.
final class FocusObserver {
    /// AX roles we treat as "user can type here". AXTextField is single-line,
    /// AXTextArea multi-line, AXComboBox is dropdown-with-text. Web content via
    /// WebKit's AX bridge reports the same roles for `<input>` / `<textarea>`.
    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]

    private var pollTimer: Timer?
    private var lastEditable = false
    private let pollInterval: TimeInterval = 0.5

    var onEditableFocused: (() -> Void)?
    var onEditableUnfocused: (() -> Void)?

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if lastEditable {
            lastEditable = false
            onEditableUnfocused?()
        }
    }

    private func poll() {
        let editable = Self.currentFocusIsEditable()
        if editable, !lastEditable {
            lastEditable = true
            onEditableFocused?()
        } else if !editable, lastEditable {
            lastEditable = false
            onEditableUnfocused?()
        }
    }

    private static func currentFocusIsEditable() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusResult == .success, let focusedAny = focusedRef,
              CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return false }
        // 类型已校验，强转不会 trap。原来直接 as! 在 Accessibility 返回非
        // AXUIElement（少见但可能）时会整个进程崩溃；持续运行的观察器经不起这种崩。
        let focused = focusedAny as! AXUIElement

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleRef
        )
        guard roleResult == .success, let role = roleRef as? String else { return false }
        return editableRoles.contains(role)
    }
}
