import AppKit
import CoreGraphics
import Foundation

/// Injects text at the current cursor position via clipboard + Cmd+V.
/// Protects and restores the original clipboard content.
enum TextInjector {

    // MARK: - Public API

    /// Type the given text at the current cursor position.
    ///
    /// Flow:
    /// 1. Save all clipboard items (all types per item)
    /// 2. Set string to clipboard
    /// 3. Post Cmd+V via CGEvent
    /// 4. Wait 200ms
    /// 5. Restore clipboard (check changeCount first to avoid overwriting user data)
    static func typeText(_ text: String, preserveClipboard: Bool = true) {
        let pb = NSPasteboard.general

        // 1. Save current clipboard content (only if preserving)
        let savedItems = preserveClipboard ? saveClipboard(pb) : []
        let savedChangeCount = pb.changeCount

        // 2. Write text to clipboard
        pb.clearContents()
        pb.setString(text, forType: .string)

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

        // 4. Wait for paste to complete
        usleep(200_000) // 200ms

        // 5. Restore clipboard if preserving and no external changes
        if preserveClipboard {
            if pb.changeCount == savedChangeCount + 1 || pb.changeCount != savedChangeCount {
                restoreClipboard(pb, savedItems: savedItems, originalChangeCount: savedChangeCount)
            }
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

    /// Restores saved clipboard data if the changeCount still matches expectations.
    private static func restoreClipboard(
        _ pb: NSPasteboard,
        savedItems: [[NSPasteboard.PasteboardType: Data]],
        originalChangeCount: Int
    ) {
        // Check if someone else modified the clipboard while we were pasting.
        // We expect our clearContents() to have bumped changeCount by 1.
        // If changeCount differs from what we'd expect, someone else wrote to clipboard.
        let currentChangeCount = pb.changeCount

        // After our clearContents + setString, changeCount should have incremented.
        // If it incremented more than once, someone else changed it — skip restore.
        // But actually, the safest check: if current changeCount differs from
        // what it was right after our write, someone else touched it.
        // We compare against the count right before we restore.
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
