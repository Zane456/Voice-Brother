import SwiftUI

// MARK: - Voice History View

struct VoiceHistoryView: View {
    @EnvironmentObject var theme: ThemeManager
    let historyStore = HistoryStore()

    @State var records: [TranscriptionRecord] = []
    @State var hasMore = true
    @State var isLoadingMore = false
    @State var copiedId: UUID?
    @State var statistics: HistoryStore.Statistics?
    @State var keywords: [KeywordAnalyzer.Keyword] = []
    @State var showClearConfirm = false
    @State var pendingClearGroup: DateGroup?

    // 自学习纠错：编辑某条历史记录时，改动会被 CorrectionLearningEngine
    // 学成替换规则，下次转写自动套用。
    @State var editingId: UUID?
    @State var editText: String = ""
    @State var learnToast: String?

    static let pageSize = 20

    enum DateGroup: CaseIterable {
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
        .overlay(alignment: .bottom) {
            if let toast = learnToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(theme.accent)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassCard(cornerRadius: 10)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: learnToast)
    }
}
