import SwiftUI

extension VoiceHistoryView {
    func statisticsSection(stats: HistoryStore.Statistics) -> some View {
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

    func dateSectionView(_ group: DateGroup, records: [TranscriptionRecord]) -> some View {
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

            if editingId == record.id {
                TextEditor(text: $editText)
                    .font(.system(size: 13))
                    .foregroundColor(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64)
                    .padding(8)
                    .background(theme.inputBackground)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderLight, lineWidth: 1))

                HStack(spacing: 8) {
                    Text("改对后会自动学成替换规则，下次转写自动套用")
                        .font(.system(size: 10)).foregroundColor(theme.textTertiary)
                    Spacer()
                    Button("取消") { editingId = nil }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                    Button("保存") { saveEdit(record) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            } else {
                Text(record.text)
                    .font(.system(size: 13)).foregroundColor(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        editText = record.text
                        editingId = record.id
                    } label: {
                        Label("修正", systemImage: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentSecondary)
                    }.buttonStyle(.plain)

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
        }
        .padding(12)
        .glassCard()
    }

    var emptyState: some View {
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
}
