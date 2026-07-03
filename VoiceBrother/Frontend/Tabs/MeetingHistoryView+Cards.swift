import SwiftUI

extension MeetingHistoryView {
    func statItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(theme.accentSecondary)
            Text(label).font(.system(size: 12)).foregroundColor(theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.surfaceBackground)
        .cornerRadius(8)
    }

    func dateSectionView(_ group: DateGroup, files: [MarkdownFile]) -> some View {
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
                        Text("打开文档").font(.system(size: 11))
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

    var emptyState: some View {
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

    var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundColor(theme.textTertiary)
            Text("无匹配结果").font(.system(size: 14, weight: .medium)).foregroundColor(theme.textPrimary)
        }
        .padding(28)
        .glassCard(cornerRadius: 14)
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}
