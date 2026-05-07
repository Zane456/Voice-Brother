import AppKit
import CoreGraphics
import Foundation

/// Injects text at the current cursor position via clipboard + Cmd+V.
/// Protects and restores the original clipboard content.
enum TextInjector {

    /// changeCount snapshot of our most recent injection write. Used to detect
    /// when our own injection text is still sitting on the clipboard at the
    /// start of the next call — that means the previous restore was skipped
    /// (target app's paste outran our restore timer), and we must NOT treat
    /// that stale text as the user's "original clipboard". Otherwise the
    /// pollution propagates: next paste reads back the previous transcription.
    private static var lastInjectedChangeCount: Int?

    // MARK: - Public API

    /// Type the given text at the current cursor position.
    ///
    /// Flow:
    /// 1. Save the current clipboard contents (if preserving)
    /// 2. Write our text to the clipboard, snapshot the resulting changeCount
    /// 3. Post Cmd+V via CGEvent
    /// 4. Wait long enough for the focused app to actually consume the paste
    /// 5. Restore the original clipboard, but only if no other actor wrote to it
    ///
    /// The restore wait must outlast the focused app's paste handling — too short
    /// and we replace our injected text with the saved clipboard *before* the app
    /// has read it, causing the previously-copied content to be pasted instead of
    /// the transcription.
    static func typeText(_ text: String, preserveClipboard: Bool = true) {
        let pb = NSPasteboard.general

        // 1. Save current clipboard content (only if preserving).
        // Pollution guard: if the clipboard still holds our previous injection
        // (changeCount unchanged since last write), the user's real original
        // is gone — skip the save so we don't restore the previous
        // transcription on top of this one.
        let clipboardIsOurStaleInjection = lastInjectedChangeCount.map { $0 == pb.changeCount } ?? false
        let savedItems: [[NSPasteboard.PasteboardType: Data]]
        if preserveClipboard && !clipboardIsOurStaleInjection {
            savedItems = saveClipboard(pb)
        } else {
            savedItems = []
        }

        // 2. Write text to clipboard, then snapshot changeCount AFTER the write.
        // We compare against this post-write count to detect external clobbers,
        // because the increment from clearContents+setString is not guaranteed to
        // be exactly +1 across macOS versions.
        pb.clearContents()
        pb.setString(text, forType: .string)
        let postWriteChangeCount = pb.changeCount
        lastInjectedChangeCount = postWriteChangeCount

        // 3. Simulate Cmd+V via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09, // V key
            keyDown: true
        ) else {
            sendFallbackNotification()
            return
        }

        guard let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: false
        ) else {
            sendFallbackNotification()
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // 4. Defer clipboard restore so the calling thread (often @MainActor)
        // doesn't block on usleep. Slow apps (browsers, Electron, IME-heavy
        // targets) can take 200ms+ to actually consume the paste; restoring
        // earlier lets them read the restored contents and paste the user's
        // previously-copied text instead of the transcription.
        guard preserveClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            // Only restore if no other actor wrote to the clipboard in the
            // meantime. Comparing against postWriteChangeCount catches both the
            // focused app's own clipboard managers and concurrent app writes.
            guard pb.changeCount == postWriteChangeCount else {
                // Someone else already wrote — clipboard is no longer "our"
                // injection, so the next call shouldn't treat it as stale.
                lastInjectedChangeCount = nil
                return
            }
            restoreClipboard(pb, savedItems: savedItems)
            // Restore advanced changeCount; clear sentinel so the next call's
            // pollution guard doesn't false-positive on the restored content.
            lastInjectedChangeCount = nil
        }
    }

    // MARK: - Clipboard Save / Restore

    /// Saves all pasteboard items with all their data types.
    private static func saveClipboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []

        guard let items = pb.pasteboardItems else { return savedItems }

        for item in items {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for ptype in item.types {
                if let data = item.data(forType: ptype) {
                    itemData[ptype] = data
                }
            }
            if !itemData.isEmpty {
                savedItems.append(itemData)
            }
        }

        return savedItems
    }

    /// Restores saved clipboard data. The caller must already have verified
    /// changeCount has not advanced past our injection write.
    private static func restoreClipboard(
        _ pb: NSPasteboard,
        savedItems: [[NSPasteboard.PasteboardType: Data]]
    ) {
        if savedItems.isEmpty {
            pb.clearContents()
            return
        }

        // Reconstruct pasteboard items
        pb.clearContents()
        var newItems: [NSPasteboardItem] = []
        for itemData in savedItems {
            let item = NSPasteboardItem()
            for (ptype, data) in itemData {
                item.setData(data, forType: ptype)
            }
            newItems.append(item)
        }
        pb.writeObjects(newItems)
    }

    // MARK: - Fallback

    /// Send a macOS notification when CGEvent paste fails.
    private static func sendFallbackNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Voice Bubble"
        content.body = "文字已复制到剪贴板，请手动 Cmd+V 粘贴"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// Import UserNotifications for fallback notification
import UserNotifications
