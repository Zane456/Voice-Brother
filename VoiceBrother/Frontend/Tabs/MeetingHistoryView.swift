import SwiftUI

// MARK: - Meeting History View

struct MeetingHistoryView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var meetingService: MeetingService
    let savePath: String

    @State var files: [MarkdownFile] = []
    @State private var searchText = ""
    @State var deleteTarget: MarkdownFile?
    @State var showDeleteConfirm = false
    @State var refreshTimer: Timer?

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
}
