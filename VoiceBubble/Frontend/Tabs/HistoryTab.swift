import SwiftUI

struct HistoryTab: View {

    private let historyStore = HistoryStore()

    @State private var records: [TranscriptionRecord] = []
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var searchText = ""
    @State private var copiedId: UUID?
    @State private var statistics: HistoryStore.Statistics?
    @State private var showClearConfirm = false
    @State private var showExportPopover = false

    private static let pageSize = 20

    private var filtered: [TranscriptionRecord] {
        if searchText.isEmpty { return records }
        return records.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Date Grouping

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
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()), date > weekAgo {
            return .thisWeek
        }
        return .earlier
    }

    private var groupedRecords: [(DateGroup, [TranscriptionRecord])] {
        let grouped = Dictionary(grouping: filtered) { dateGroup(for: $0.timestamp) }
        return DateGroup.allCases.compactMap { group in
            guard let records = grouped[group], !records.isEmpty else { return nil }
            return (group, records)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            // Statistics
            if let stats = statistics, stats.recordCount > 0 {
                statisticsSection(stats: stats)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }

            // Search + Export
            HStack(spacing: 8) {
                searchBar

                Button {
                    showExportPopover = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text("导出")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "7B8CF5"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "F2F6FC"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "C8D8EA"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(records.isEmpty)
                .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                    exportPopover
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            // Content
            if records.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                noSearchResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groupedRecords, id: \.0) { group, groupRecords in
                            dateSectionView(group, records: groupRecords)
                        }

                        if hasMore && searchText.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    Task { await loadMore() }
                                }

                            if isLoadingMore {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            Task {
                await loadRecords()
                await loadStatistics()
            }
        }
        .alert("确认清空", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task {
                    await historyStore.deleteAll()
                    records.removeAll()
                    statistics = nil
                }
            }
        } message: {
            Text("将清空所有历史记录，此操作不可撤销。")
        }
    }

    // MARK: - Data Loading

    private func loadRecords() async {
        let fetched = await historyStore.fetchAll(limit: Self.pageSize)
        records = fetched
        hasMore = fetched.count >= Self.pageSize
    }

    private func loadStatistics() async {
        statistics = await historyStore.getStatistics()
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("历史记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: "2C3E6B"))

            Spacer()

            if !records.isEmpty {
                Button {
                    showClearConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("清空")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "FF6B8A"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "FFF0F3"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "FFB3C1"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "8AA0BE"))

            TextField("搜索历史记录...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "2C3E6B"))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "8AA0BE"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .glassCard()
    }

    // MARK: - Statistics Section

    private func statisticsSection(stats: HistoryStore.Statistics) -> some View {
        HStack(spacing: 12) {
            statCard(
                icon: "clock.fill",
                label: "累计时长",
                value: formatTotalDuration(stats.totalDuration),
                color: Color(hex: "C89828")
            )

            statCard(
                icon: "doc.text",
                label: "累计字数",
                value: formatNumber(stats.totalCharacters),
                color: Color(hex: "4ECDC4")
            )

            statCard(
                icon: "speedometer",
                label: "平均速度",
                value: String(format: "%.0f 字/分", stats.averageSpeed),
                color: Color(hex: "7B8CF5")
            )
        }
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "8AA0BE"))
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "2C3E6B"))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
    }

    // MARK: - Date Section

    private func dateSectionView(_ group: DateGroup, records: [TranscriptionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "8AA0BE"))

            ForEach(records) { record in
                recordCard(record, showDate: group == .thisWeek || group == .earlier)
            }
        }
    }

    // MARK: - Record Card

    private func recordCard(_ record: TranscriptionRecord, showDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Metadata row
            HStack(spacing: 10) {
                let timeFormat: Date.FormatStyle = showDate
                    ? .dateTime.month().day().hour().minute()
                    : .dateTime.hour().minute()
                Label(record.timestamp.formatted(timeFormat), systemImage: "clock")
                Label(formatDuration(record.duration), systemImage: "waveform")
                Label("\(record.text.count) 字", systemImage: "doc.text")
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundColor(Color(hex: "8AA0BE"))

            // Text content
            Text(record.text)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "2C3E6B"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Actions
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
                    Label(
                        copiedId == record.id ? "已复制" : "复制",
                        systemImage: copiedId == record.id ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(copiedId == record.id ? Color(hex: "4ECDC4") : Color(hex: "7B8CF5"))
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await historyStore.delete(id: record.id.uuidString)
                        records.removeAll { $0.id == record.id }
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "FF6B8A").opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .glassCard()
    }

    // MARK: - Export Popover

    private var exportPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出识别记录")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "2C3E6B"))

            HStack {
                Spacer()
                Button("取消") { showExportPopover = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A7098"))

                Button("导出 CSV") { exportCSV() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "7B8CF5")))
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func exportCSV() {
        Task {
            let allRecords = await historyStore.fetchAll()
            await MainActor.run {
                let header = "时间,时长(秒),文本,字数"
                let iso = ISO8601DateFormatter()
                let rows = allRecords.map { r in
                    let time = iso.string(from: r.timestamp)
                    let duration = String(format: "%.1f", r.duration)
                    return [time, duration, r.text, "\(r.text.count)"]
                        .map { csvEscape($0) }
                        .joined(separator: ",")
                }
                let csv = ([header] + rows).joined(separator: "\n")

                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "voice-bubble-history.csv"
                panel.canCreateDirectories = true

                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? csv.write(to: url, atomically: true, encoding: .utf8)
                showExportPopover = false
            }
        }
    }

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "C8D8EA"))

            Text("暂无历史记录")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "8AA0BE"))

            Text("语音输入的内容会自动记录在这里")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "A8BCD0"))
        }
    }

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "C8D8EA"))

            Text("没有找到匹配的记录")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "8AA0BE"))
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)秒" }
        return "\(s / 60)分\(s % 60)秒"
    }

    private func formatTotalDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分"
        }
        return "\(minutes)分钟"
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
