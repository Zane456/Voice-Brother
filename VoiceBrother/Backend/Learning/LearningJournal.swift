import Foundation

/// One day's tally in the "is the learning actually working?" ledger.
struct DayStat: Codable, Identifiable {
    let date: String              // yyyy-MM-dd
    var correctionsCaptured: Int  // user corrections diffed into a usable pair
    var rulesLearned: Int         // new/updated learned rules
    var ruleHits: Int             // learned rules that fired on real transcripts

    var id: String { date }
}

/// On-disk record-keeping for the correction-learning subsystem.
///
/// Everything lives under `~/Library/Application Support/VoiceBrother/learning/`,
/// kept apart from the rest of the app's storage:
///   • `learned_rules.json` — rules promoted from user corrections
///   • `corrections.json`   — raw (original→corrected) captures, newest first, capped
///   • `stats.json`         — per-day aggregates, the effectiveness ledger
///   • `learning.log`       — human-readable event stream, size-capped
///
/// All disk I/O runs on one private serial queue and every operation is
/// best-effort (`try?`), so a failure here can never propagate into the
/// recording / transcription path.
final class LearningJournal {

    private let queue = DispatchQueue(label: "com.voicebrother.learning.journal")
    private let dir: URL
    private let rulesURL: URL
    private let correctionsURL: URL
    private let statsURL: URL
    private let logURL: URL
    private let logMaxSize: UInt64 = 512_000  // 0.5 MB, then rotated

    /// Per-day stats cache. Only ever touched on `queue`.
    private var dayStats: [String: DayStat] = [:]

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceBrother/learning", isDirectory: true)
        self.dir = base
        self.rulesURL = base.appendingPathComponent("learned_rules.json")
        self.correctionsURL = base.appendingPathComponent("corrections.json")
        self.statsURL = base.appendingPathComponent("stats.json")
        self.logURL = base.appendingPathComponent("learning.log")

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Prime the stats cache from disk.
        if let data = try? Data(contentsOf: statsURL),
           let list = try? JSONDecoder().decode([DayStat].self, from: data) {
            for stat in list { dayStats[stat.date] = stat }
        }
    }

    var directoryPath: String { dir.path }

    // MARK: - Learned rules

    func loadRules() -> [ReplacementRule] {
        queue.sync {
            guard let data = try? Data(contentsOf: rulesURL),
                  let rules = try? JSONDecoder().decode([ReplacementRule].self, from: data)
            else { return [] }
            return rules
        }
    }

    /// Synchronous write: a learn/forget call returns success to the UI only
    /// after the rule has actually landed on disk. The old async version could
    /// surface "已学会" to the user, then lose the rule if the app crashed or
    /// quit before the queued write ran. stats/log writes stay async because
    /// dropping a stats tick under crash is fine; dropping a rule is not.
    func persistRules(_ rules: [ReplacementRule]) {
        queue.sync { [self] in
            guard let data = try? JSONEncoder().encode(rules) else { return }
            try? data.write(to: rulesURL, options: .atomic)
        }
    }

    // MARK: - Raw corrections

    func appendCorrection(_ record: CorrectionRecord, cap: Int = 500) {
        queue.async { [self] in
            var list: [CorrectionRecord] = []
            if let data = try? Data(contentsOf: correctionsURL) {
                list = (try? JSONDecoder().decode([CorrectionRecord].self, from: data)) ?? []
            }
            list.insert(record, at: 0)
            if list.count > cap { list = Array(list.prefix(cap)) }
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: correctionsURL, options: .atomic)
            }
        }
    }

    func loadCorrections() -> [CorrectionRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: correctionsURL),
                  let list = try? JSONDecoder().decode([CorrectionRecord].self, from: data)
            else { return [] }
            return list
        }
    }

    // MARK: - Daily effectiveness ledger

    func bump(capturedDelta: Int = 0, learnedDelta: Int = 0, hitsDelta: Int = 0) {
        guard capturedDelta != 0 || learnedDelta != 0 || hitsDelta != 0 else { return }
        queue.async { [self] in
            let key = Self.dayKey(Date())
            var stat = dayStats[key]
                ?? DayStat(date: key, correctionsCaptured: 0, rulesLearned: 0, ruleHits: 0)
            stat.correctionsCaptured += capturedDelta
            stat.rulesLearned += learnedDelta
            stat.ruleHits += hitsDelta
            dayStats[key] = stat

            let sorted = dayStats.values.sorted { $0.date > $1.date }
            if let data = try? JSONEncoder().encode(sorted) {
                try? data.write(to: statsURL, options: .atomic)
            }
        }
    }

    func loadStats() -> [DayStat] {
        queue.sync { dayStats.values.sorted { $0.date > $1.date } }
    }

    // MARK: - Human-readable log

    func log(_ message: String) {
        queue.async { [self] in
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default

            // Rotate when the log outgrows its cap.
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? UInt64, size > logMaxSize {
                try? fm.removeItem(at: logURL)
            }

            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    // MARK: - Helpers

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
