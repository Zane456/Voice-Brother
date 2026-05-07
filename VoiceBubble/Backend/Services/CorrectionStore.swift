import Foundation
import SQLite3

extension Notification.Name {
    static let correctionStoreDidChange = Notification.Name("VoiceBubble.correctionStoreDidChange")
}

/// SQLite-backed store for voice correction history. Thread-safe via actor isolation.
/// Shares the same database file as HistoryStore but uses a separate table.
actor CorrectionStore {

    private var db: OpaquePointer?

    /// Process-level flag — multiple `CorrectionStore` instances share the same DB,
    /// so the one-time garbage cleanup only needs to run once per launch.
    nonisolated(unsafe) private static var didPruneGarbage = false

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceBubble", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("history.db").path

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let sql = """
            CREATE TABLE IF NOT EXISTS correction_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                injected_text TEXT NOT NULL,
                corrected_text TEXT NOT NULL,
                diff_from TEXT NOT NULL,
                diff_to TEXT NOT NULL,
                bundle_id TEXT NOT NULL,
                applied INTEGER DEFAULT 0
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_correction_lookup ON correction_history(diff_from, diff_to, applied);", nil, nil, nil)
            if !Self.didPruneGarbage {
                Self.didPruneGarbage = true
                let maxLen = CorrectionAnalyzer.maxSubstitutionLength
                let sql = "DELETE FROM correction_history WHERE diff_from = diff_to OR length(diff_from) > \(maxLen) OR length(diff_to) > \(maxLen);"
                sqlite3_exec(db, sql, nil, nil, nil)
                // Re-audit existing pending candidates against the current
                // similarity / length-ratio rules. Older records were admitted
                // under a looser 0.3 threshold and left garbage like
                // "AK平"→"。哥" sitting in the learning list forever.
                pruneLowQualityPending()
            }
            pruneOldRecords()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Insert

    func insert(_ record: CorrectionRecord) {
        let sql = """
        INSERT OR REPLACE INTO correction_history
        (id, created_at, injected_text, corrected_text, diff_from, diff_to, bundle_id, applied)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id.uuidString)
        bind(stmt, 2, iso.string(from: record.timestamp))
        bind(stmt, 3, record.injectedText)
        bind(stmt, 4, record.correctedText)
        bind(stmt, 5, record.diffFrom)
        bind(stmt, 6, record.diffTo)
        bind(stmt, 7, record.bundleID)

        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    // MARK: - Query

    /// Count how many times the same (from → to) correction has occurred.
    func countMatching(from: String, to: String) -> Int {
        let sql = "SELECT COUNT(*) FROM correction_history WHERE diff_from = ? AND diff_to = ? AND applied = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Mark all corrections with the given (from → to) as applied (rule was created).
    func markAsApplied(from: String, to: String) {
        let sql = "UPDATE correction_history SET applied = 1 WHERE diff_from = ? AND diff_to = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        sqlite3_step(stmt)
    }

    /// Delete all pending records matching (from → to). Use when the user dismisses a learning candidate.
    func deletePending(from: String, to: String) {
        let sql = "DELETE FROM correction_history WHERE diff_from = ? AND diff_to = ? AND applied = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, from)
        bind(stmt, 2, to)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    /// Fetch recent correction records.
    func fetchRecent(limit: Int = 20) -> [CorrectionRecord] {
        let sql = "SELECT * FROM correction_history ORDER BY created_at DESC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        var records: [CorrectionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(CorrectionRecord(
                id: UUID(uuidString: column(stmt, 0)) ?? UUID(),
                timestamp: iso.date(from: column(stmt, 1)) ?? Date(),
                injectedText: column(stmt, 2),
                correctedText: column(stmt, 3),
                diffFrom: column(stmt, 4),
                diffTo: column(stmt, 5),
                bundleID: column(stmt, 6)
            ))
        }
        return records
    }

    /// Get all pending learnings: (from, to) pairs that appear >= threshold times.
    func fetchPendingLearnings(threshold: Int) -> [(from: String, to: String, count: Int)] {
        let sql = """
        SELECT diff_from, diff_to, COUNT(*) as cnt
        FROM correction_history
        WHERE applied = 0
        GROUP BY diff_from, diff_to
        HAVING cnt >= ?
        ORDER BY cnt DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(threshold))

        var results: [(from: String, to: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                from: column(stmt, 0),
                to: column(stmt, 1),
                count: Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return results
    }

    func deleteAll() {
        if sqlite3_exec(db, "DELETE FROM correction_history;", nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        }
    }

    // MARK: - Pruning

    /// Re-audit existing pending candidates against the current similarity /
    /// length-ratio rules in CorrectionAnalyzer. SQL can't compute LCS, so we
    /// fetch distinct (from, to) pairs and evaluate each in Swift. Called once
    /// per process on init, before `pruneOldRecords`.
    private func pruneLowQualityPending() {
        let selectSQL = "SELECT DISTINCT diff_from, diff_to FROM correction_history WHERE applied = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else { return }

        var garbage: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let from = String(cString: sqlite3_column_text(stmt, 0))
            let to = String(cString: sqlite3_column_text(stmt, 1))

            let sim = FeedbackCollector.similarity(from, to)
            let shorter = min(from.count, to.count)
            let longer = max(from.count, to.count)
            let ratioBad = shorter == 0 || Double(longer) / Double(shorter) > 2.5
            // Case-only differences are not real corrections for a voice app.
            let caseOnly = from.lowercased() == to.lowercased()

            if sim < CorrectionAnalyzer.minSimilarity || ratioBad || caseOnly {
                garbage.append((from, to))
            }
        }
        sqlite3_finalize(stmt)

        guard !garbage.isEmpty else { return }

        let deleteSQL = "DELETE FROM correction_history WHERE diff_from = ? AND diff_to = ? AND applied = 0;"
        for (from, to) in garbage {
            var dstmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &dstmt, nil) == SQLITE_OK else { continue }
            bind(dstmt, 1, from)
            bind(dstmt, 2, to)
            sqlite3_step(dstmt)
            sqlite3_finalize(dstmt)
        }
        NSLog("[CorrectionStore] Pruned %d low-quality learning candidates: %@", garbage.count, garbage.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))
    }

    /// Delete applied records older than 90 days. Called once on init.
    private func pruneOldRecords() {
        let iso = ISO8601DateFormatter()
        let cutoff = iso.string(from: Date().addingTimeInterval(-90 * 24 * 3600))
        let sql = "DELETE FROM correction_history WHERE created_at < ? AND applied = 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    // MARK: - SQLite Helpers

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, index))
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .correctionStoreDidChange, object: nil)
        }
    }
}
