import SwiftUI

extension VoiceHistoryView {
    /// Persist an edited transcription and feed the change to the self-learning
    /// correction engine. A failure in the learning engine cannot affect the
    /// history update — they are independent steps.
    ///
    /// Diff source: `record.rawText` (raw ASR) ↔ user's edit. Diffing the
    /// already-processed `record.text` would teach rules that chase LLM polish
    /// artefacts instead of real ASR mistakes. For pre-migration records
    /// (rawText == nil) the edit is still saved and still routed to the engine,
    /// which logs the skip — so the journal has an entry for every attempt.
    func saveEdit(_ record: TranscriptionRecord) {
        let displayed = record.text
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingId = nil
        guard !newText.isEmpty, newText != displayed else { return }
        Task {
            let updated = TranscriptionRecord(
                id: record.id, timestamp: record.timestamp,
                text: newText, duration: record.duration,
                rawText: record.rawText, model: record.model
            )
            await historyStore.insert(updated)

            // Pre-migration records (rawText == nil) still go to the engine —
            // it logs the skip, so the journal has an entry for every attempt.
            let result = CorrectionLearningEngine.shared.learn(
                originalText: record.rawText ?? "", correctedText: newText
            )
            if !result.message.isEmpty {
                learnToast = result.message
                let shown = result.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    if learnToast == shown { learnToast = nil }
                }
            }
            await loadRecords()
            await loadStatistics()
            await loadKeywords()
        }
    }

    func loadRecords() async {
        let fetched = await historyStore.fetchAll(limit: Self.pageSize)
        records = fetched
        hasMore = fetched.count >= Self.pageSize
    }

    func loadStatistics() async {
        statistics = await historyStore.getStatistics()
    }

    /// Fetches the full corpus and computes high-frequency keywords off the
    /// main thread — segmentation over all history can be sizable.
    func loadKeywords() async {
        let texts = await historyStore.fetchAll().map(\.text)
        keywords = await Task.detached(priority: .utility) {
            KeywordAnalyzer.analyze(texts: texts)
        }.value
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        let page = await historyStore.fetchAll(limit: Self.pageSize, offset: records.count)
        let existingIds = Set(records.map(\.id))
        let newRecords = page.filter { !existingIds.contains($0.id) }
        records.append(contentsOf: newRecords)
        hasMore = page.count >= Self.pageSize
        isLoadingMore = false
    }

    func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)秒" }
        return "\(s / 60)分\(s % 60)秒"
    }

    func formatTotalDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(minutes)分钟"
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
