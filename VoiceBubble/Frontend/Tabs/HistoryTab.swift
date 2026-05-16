import SwiftUI

/// Unified history center. Internal segmented switch toggles between
/// voice transcription history (SQLite) and meeting markdown files.
struct HistoryTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var theme: ThemeManager

    @State private var selectedKind: Kind = .voice
    /// Guards the one-time `selectedKind` sync from `lastHistoryKind` so a
    /// manual segment switch isn't overridden on every re-appear.
    @State private var didInitKind = false

    private enum Kind: String, CaseIterable {
        case voice = "语音输入"
        case meeting = "声音录制"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)

                Spacer()

                Picker("", selection: $selectedKind) {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .tint(theme.accent)
                .frame(width: 220)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)

            Group {
                switch selectedKind {
                case .voice:
                    VoiceHistoryView()
                case .meeting:
                    MeetingHistoryView(savePath: configManager.meetingSavePath)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // One-time sync: open on whichever segment the most recently
            // completed task belongs to. Manual switches afterwards stand.
            guard !didInitKind else { return }
            selectedKind = configManager.lastHistoryKind == "meeting" ? .meeting : .voice
            didInitKind = true
        }
    }
}

// MARK: - Voice History View

struct VoiceHistoryView: View {
    @EnvironmentObject private var theme: ThemeManager
    private let historyStore = HistoryStore()

    @State private var records: [TranscriptionRecord] = []
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var copiedId: UUID?
    @State private var statistics: HistoryStore.Statistics?
    @State private var keywords: [KeywordAnalyzer.Keyword] = []
    @State private var showClearConfirm = false
    @State private var pendingClearGroup: DateGroup?

    private static let pageSize = 20

    private enum DateGroup: CaseIterable {
        case today, yesterday, thisWeek, earlier
        var title: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .thisWeek: return "本周"
            case .earlier: return "更早"
            }
        }
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date > weekAgo { return .thisWeek }
        return .earlier
    }

    /// Returns half-open date range [start, end) covering the given group.
    private func dateRange(for group: DateGroup) -> (start: Date, end: Date)? {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        switch group {
        case .today:
            guard let end = cal.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
            return (todayStart, end)
        case .yesterday:
            guard let start = cal.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
            return (start, todayStart)
        case .thisWeek:
            guard let start = cal.date(byAdding: .day, value: -7, to: todayStart) else { return nil }
            return (start, todayStart)
        case .earlier:
            guard let end = cal.date(byAdding: .day, value: -7, to: todayStart) else { return nil }
            return (.distantPast, end)
        }
    }

    private var groupedRecords: [(DateGroup, [TranscriptionRecord])] {
        let grouped = Dictionary(grouping: records) { dateGroup(for: $0.timestamp) }
        return DateGroup.allCases.compactMap { group in
            guard let records = grouped[group], !records.isEmpty else { return nil }
            return (group, records)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stats = statistics, stats.recordCount > 0 {
                statisticsSection(stats: stats)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }

            // Always render the word-cloud card so the box is present from the
            // first frame — only the words inside fade in once keywords load.
            WordCloudView(keywords: keywords)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            if records.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedRecords, id: \.0) { group, groupRecords in
                            dateSectionView(group, records: groupRecords)
                        }
                        if hasMore {
                            Color.clear.frame(height: 1).onAppear { Task { await loadMore() } }
                            if isLoadingMore {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadRecords()
            await loadStatistics()
            await loadKeywords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            Task {
                await loadRecords()
                await loadStatistics()
                await loadKeywords()
            }
        }
        .alert("确认清空", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { pendingClearGroup = nil }
            Button("清空", role: .destructive) {
                let group = pendingClearGroup
                pendingClearGroup = nil
                Task {
                    if let group, let range = dateRange(for: group) {
                        await historyStore.deleteRange(from: range.start, to: range.end)
                    } else {
                        await historyStore.deleteAll()
                    }
                    await loadRecords()
                    await loadStatistics()
                }
            }
        } message: {
            if let group = pendingClearGroup {
                Text("将清空「\(group.title)」分组内的记录，此操作不可撤销。")
            } else {
                Text("将清空所有历史记录，此操作不可撤销。")
            }
        }
    }

    private func loadRecords() async {
        let fetched = await historyStore.fetchAll(limit: Self.pageSize)
        records = fetched
        hasMore = fetched.count >= Self.pageSize
    }

    private func loadStatistics() async {
        statistics = await historyStore.getStatistics()
    }

    /// Fetches the full corpus and computes high-frequency keywords off the
    /// main thread — segmentation over all history can be sizable.
    private func loadKeywords() async {
        let texts = await historyStore.fetchAll().map(\.text)
        keywords = await Task.detached(priority: .utility) {
            KeywordAnalyzer.analyze(texts: texts)
        }.value
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        let page = await historyStore.fetchAll(limit: Self.pageSize, offset: records.count)
        let existingIds = Set(records.map(\.id))
        let newRecords = page.filter { !existingIds.contains($0.id) }
        records.append(contentsOf: newRecords)
        hasMore = page.count >= Self.pageSize
        isLoadingMore = false
    }

    private func statisticsSection(stats: HistoryStore.Statistics) -> some View {
        HStack(spacing: 12) {
            statCard(icon: "clock.fill", label: "累计时长", value: formatTotalDuration(stats.totalDuration), color: theme.warning)
            statCard(icon: "doc.text", label: "累计字数", value: formatNumber(stats.totalCharacters), color: theme.accent)
            statCard(icon: "speedometer", label: "平均速度", value: String(format: "%.0f 字/分", stats.averageSpeed), color: theme.accentSecondary)
        }
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
                Text(label).font(.system(size: 10)).foregroundColor(theme.textTertiary)
            }
            Text(value).font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.textPrimary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
    }

    private func dateSectionView(_ group: DateGroup, records: [TranscriptionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textTertiary)
                Spacer()
                if group == .today || records.count > 3 {
                    Button {
                        pendingClearGroup = group
                        showClearConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("清空本组").font(.system(size: 10))
                        }.foregroundColor(theme.destructive)
                    }.buttonStyle(.plain)
                }
            }
            ForEach(records) { record in
                recordCard(record, showDate: group == .thisWeek || group == .earlier)
            }
        }
    }

    private func recordCard(_ record: TranscriptionRecord, showDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                let timeFormat: Date.FormatStyle = showDate
                    ? .dateTime.month().day().hour().minute()
                    : .dateTime.hour().minute()
                Label(record.timestamp.formatted(timeFormat), systemImage: "clock")
                Label(formatDuration(record.duration), systemImage: "waveform")
                Label("\(record.text.count) 字", systemImage: "doc.text")
                Spacer()
            }
            .font(.system(size: 10)).foregroundColor(theme.textTertiary)

            Text(record.text)
                .font(.system(size: 13)).foregroundColor(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                    copiedId = record.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedId == record.id { copiedId = nil }
                    }
                } label: {
                    Label(copiedId == record.id ? "已复制" : "复制",
                          systemImage: copiedId == record.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(copiedId == record.id ? theme.accent : theme.accentSecondary)
                }.buttonStyle(.plain)

                Button {
                    Task {
                        await historyStore.delete(id: record.id.uuidString)
                        records.removeAll { $0.id == record.id }
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.destructive.opacity(0.7))
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .glassCard()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.08))
                    .frame(width: 96, height: 96)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(theme.accent.opacity(0.7))
            }
            VStack(spacing: 6) {
                Text("还没有任何记录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text("按住触发键说话，转写后会自动出现在这里")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(36)
        .frame(maxWidth: 360)
        .glassCard(cornerRadius: 16)
        .padding(.bottom, 48)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)秒" }
        return "\(s / 60)分\(s % 60)秒"
    }

    private func formatTotalDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(minutes)分钟"
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}

// MARK: - Meeting History View

struct MeetingHistoryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var meetingService: MeetingService
    let savePath: String

    @State private var files: [MarkdownFile] = []
    @State private var searchText = ""
    @State private var deleteTarget: MarkdownFile?
    @State private var showDeleteConfirm = false
    @State private var refreshTimer: Timer?

    struct MarkdownFile: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let modifiedDate: Date
        let fileSize: Int64
        let preview: String
    }

    private var filtered: [MarkdownFile] {
        if searchText.isEmpty { return files }
        return files.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    private enum DateGroup: CaseIterable {
        case today, yesterday, thisWeek, earlier
        var title: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .thisWeek: return "本周"
            case .earlier: return "更早"
            }
        }
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date > weekAgo { return .thisWeek }
        return .earlier
    }

    private var groupedFiles: [(DateGroup, [MarkdownFile])] {
        let grouped = Dictionary(grouping: filtered) { dateGroup(for: $0.modifiedDate) }
        return DateGroup.allCases.compactMap { group in
            guard let files = grouped[group], !files.isEmpty else { return nil }
            return (group, files)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !files.isEmpty {
                HStack(spacing: 16) {
                    statItem(icon: "doc.text", label: "文件数", value: "\(files.count)")
                    statItem(icon: "internaldrive", label: "总大小", value: totalSizeString)
                }
                .padding(.horizontal, 32).padding(.bottom, 16)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13)).foregroundColor(theme.textTertiary)
                TextField("搜索录音文件...", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .foregroundColor(theme.textPrimary)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12)).foregroundColor(theme.textTertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.inputBackground)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.borderLight, lineWidth: 1))
            .padding(.horizontal, 32).padding(.bottom, 16)

            if files.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                noSearchResults.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedFiles, id: \.0) { group, groupFiles in
                            dateSectionView(group, files: groupFiles)
                        }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pruneOldFiles()
            scanFiles()
            startRefreshTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: savePath) { _, _ in scanFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingFilesDidChange)) { _ in
            scanFiles()
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    deleteFile(target)
                    deleteTarget = nil
                }
            }
        } message: {
            if let target = deleteTarget { Text("将删除「\(target.name)」，此操作不可撤销。") }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in scanFiles() }
        }
    }

    /// Delete meeting markdown + audio files older than the user-configured
    /// retention window (通用 设置 → 历史记录 → 会议记录缓存).
    private func pruneOldFiles() {
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
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "wav" || ext == "mov" else { continue }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modDate < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func scanFiles() {
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

    private func deleteFile(_ file: MarkdownFile) {
        try? FileManager.default.removeItem(at: file.url)
        files.removeAll { $0.url == file.url }
    }

    private var totalSizeString: String {
        let total = files.reduce(Int64(0)) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(theme.accentSecondary)
            Text(label).font(.system(size: 12)).foregroundColor(theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.surfaceBackground)
        .cornerRadius(8)
    }

    private func dateSectionView(_ group: DateGroup, files: [MarkdownFile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.textSecondary).padding(.leading, 4)
            ForEach(files) { file in fileCard(file) }
        }
    }

    /// True when `file` is the markdown of the meeting currently being
    /// finalized — i.e. MeetingService is in `.finishing` / `.summarizing`
    /// and its processing file matches this card. Matched by filename
    /// (timestamped, unique per directory) to avoid path-normalization gaps.
    private func isProcessing(_ file: MarkdownFile) -> Bool {
        guard let activePath = meetingService.processingMarkdownPath else { return false }
        switch meetingService.state {
        case .finishing, .summarizing:
            return URL(fileURLWithPath: activePath).lastPathComponent
                == file.url.lastPathComponent
        default:
            return false
        }
    }

    /// Stage-specific badge text. Empty when not processing.
    private var processingBadgeText: String {
        switch meetingService.state {
        case .finishing: return "整理中"
        case .summarizing: return "生成摘要中"
        default: return ""
        }
    }

    private var processingBadge: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(theme.accent)
            Text(processingBadgeText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.accent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.accent.opacity(0.12)))
    }

    private func fileCard(_ file: MarkdownFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundColor(theme.accentSecondary)
                Text(file.name).font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary).lineLimit(1)
                if isProcessing(file) {
                    processingBadge
                }
                Spacer()
                Text(formatDate(file.modifiedDate)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
                Text(formatFileSize(file.fileSize)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
            }
            if !file.preview.isEmpty {
                Text(file.preview).font(.system(size: 12))
                    .foregroundColor(theme.textSecondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Spacer()
                Button { NSWorkspace.shared.open(file.url) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye").font(.system(size: 11))
                        Text("打开").font(.system(size: 11))
                    }.foregroundColor(theme.accentSecondary)
                }.buttonStyle(.plain)

                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text("在 Finder 中显示").font(.system(size: 11))
                    }.foregroundColor(theme.accentSecondary)
                }.buttonStyle(.plain)

                Button { deleteTarget = file; showDeleteConfirm = true } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(theme.destructive)
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.accentSecondary.opacity(0.08))
                    .frame(width: 96, height: 96)
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(theme.accentSecondary.opacity(0.7))
            }
            VStack(spacing: 6) {
                Text("还没有录音记录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text("同时按住左右 ⌘ 0.5 秒开始录制\n结束后将自动保存为 Markdown")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(36)
        .frame(maxWidth: 360)
        .glassCard(cornerRadius: 16)
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundColor(theme.textTertiary)
            Text("无匹配结果").font(.system(size: 14, weight: .medium)).foregroundColor(theme.textPrimary)
        }
        .padding(28)
        .glassCard(cornerRadius: 14)
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(date) { formatter.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(date) { formatter.dateFormat = "昨天 HH:mm" }
        else { formatter.dateFormat = "MM/dd HH:mm" }
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

