import SwiftUI

extension MeetingHistoryView {
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in scanFiles() }
        }
    }

    /// Filename prefixes this app uses for meeting artifacts. Two generations:
    /// current ("声音录制_/录音_/录屏_") and legacy ("会议纪要_/会议录音_") from
    /// before the dialogue rename. `.mov` has no legacy entry — screen recording
    /// is newer than the rename. Pruning matches these and nothing else.
    private static let meetingFilePrefixes: [String: [String]] = [
        "md":  ["声音录制_", "会议纪要_"],
        "wav": ["录音_", "会议录音_"],
        "mov": ["录屏_"],
    ]

    /// True only for files this app itself created — a known prefix for the
    /// file's extension. `meetingSavePath` is a user-chosen directory that may
    /// hold unrelated `.md`/`.wav`/`.mov` files (Documents, Desktop, a synced
    /// folder); retention must never delete those.
    ///
    /// Deliberate tradeoff: a meeting file the user manually *renamed* no longer
    /// matches, so it's exempt from auto-pruning (it still shows in history via
    /// `scanFiles`, which intentionally lists every `.md`). We cannot tell a
    /// renamed app file apart from a user's own file, so we fail safe — letting
    /// one stale file linger beats deleting someone's unrelated documents.
    private static func isAppMeetingFile(_ url: URL) -> Bool {
        guard let prefixes = meetingFilePrefixes[url.pathExtension.lowercased()] else { return false }
        let name = url.lastPathComponent
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Delete meeting markdown + audio files older than the user-configured
    /// retention window (通用 设置 → 历史记录 → 会议记录缓存). Only files this
    /// app created are eligible — see `isAppMeetingFile`.
    func pruneOldFiles() {
        let months = max(1, UserDefaults.standard.object(forKey: "meetingRetentionMonths") as? Int ?? 2)
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) else { return }
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: savePath)
        guard let contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents {
            guard Self.isAppMeetingFile(url) else { continue }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modDate < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    func scanFiles() {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: savePath)
        guard let contents = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { files = []; return }

        files = contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> MarkdownFile? in
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modDate = attrs?.contentModificationDate ?? Date.distantPast
                let size = Int64(attrs?.fileSize ?? 0)
                let preview = loadPreview(url: url)
                let name = url.deletingPathExtension().lastPathComponent
                return MarkdownFile(url: url, name: name, modifiedDate: modDate, fileSize: size, preview: preview)
            }
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }

    private func loadPreview(url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8) else { return "" }
        let lines = content.components(separatedBy: .newlines)
        let previewLines = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
            .prefix(3)
        return previewLines.joined(separator: "\n")
    }

    func deleteFile(_ file: MarkdownFile) {
        try? FileManager.default.removeItem(at: file.url)
        files.removeAll { $0.url == file.url }
    }

    var totalSizeString: String {
        let total = files.reduce(Int64(0)) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(date) { formatter.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(date) { formatter.dateFormat = "昨天 HH:mm" }
        else { formatter.dateFormat = "MM/dd HH:mm" }
        return formatter.string(from: date)
    }

    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
