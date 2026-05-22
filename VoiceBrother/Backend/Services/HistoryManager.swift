import Foundation
import SQLite3

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("VoiceBrother.historyStoreDidChange")
    static let meetingFilesDidChange = Notification.Name("VoiceBrother.meetingFilesDidChange")
}

/// SQLite-backed store for voice transcription history. Thread-safe via actor isolation.
actor HistoryStore {

    private var db: OpaquePointer?
    private let iso = ISO8601DateFormatter()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceBrother", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("history.db").path

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA busy_timeout=2000;", nil, nil, nil)
            let sql = """
            CREATE TABLE IF NOT EXISTS transcription_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                text TEXT NOT NULL,
                character_count INTEGER,
                raw_text TEXT,
                model TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_created_at ON transcription_history(created_at DESC);
            """
            sqlite3_exec(db, sql, nil, nil, nil)
            // Migrations for DBs created before these columns existed. ALTER
            // TABLE errors if the column already exists — sqlite3_exec swallows
            // it, which is exactly what we want here. Both columns are appended
            // last, so fetchAll's positional indices stay stable: raw_text=5,
            // model=6, regardless of whether the DB is fresh or migrated.
            sqlite3_exec(db, "ALTER TABLE transcription_history ADD COLUMN raw_text TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE transcription_history ADD COLUMN model TEXT;", nil, nil, nil)
            pruneOldRecords()
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - CRUD

    func insert(_ record: TranscriptionRecord) {
        let sql = """
        INSERT OR REPLACE INTO transcription_history
        (id, created_at, duration_seconds, text, character_count, raw_text, model)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, record.id.uuidString)
        bind(stmt, 2, iso.string(from: record.timestamp))
        sqlite3_bind_double(stmt, 3, record.duration)
        bind(stmt, 4, record.text)
        sqlite3_bind_int(stmt, 5, Int32(record.text.count))
        if let raw = record.rawText {
            bind(stmt, 6, raw)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let model = record.model {
            bind(stmt, 7, model)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    func fetchAll(limit: Int? = nil, offset: Int = 0) -> [TranscriptionRecord] {
        let sql: String
        if let limit {
            sql = "SELECT * FROM transcription_history ORDER BY created_at DESC LIMIT \(limit) OFFSET \(offset);"
        } else {
            sql = "SELECT * FROM transcription_history ORDER BY created_at DESC;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var records: [TranscriptionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // raw_text / model are nullable — sqlite3_column_text returns NULL
            // for them, which String(cString:) cannot take, so map the pointer.
            let rawPtr = sqlite3_column_text(stmt, 5)
            let rawText: String? = rawPtr.map { String(cString: $0) }
            let modelPtr = sqlite3_column_text(stmt, 6)
            let model: String? = modelPtr.map { String(cString: $0) }
            records.append(TranscriptionRecord(
                id: UUID(uuidString: column(stmt, 0)) ?? UUID(),
                timestamp: iso.date(from: column(stmt, 1)) ?? Date(),
                text: column(stmt, 3),
                duration: sqlite3_column_double(stmt, 2),
                rawText: rawText,
                model: model
            ))
        }
        return records
    }

    func count() -> Int {
        let sql = "SELECT COUNT(*) FROM transcription_history;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func delete(id: String) {
        let sql = "DELETE FROM transcription_history WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    func deleteAll() {
        if sqlite3_exec(db, "DELETE FROM transcription_history;", nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        }
    }

    /// Delete records in [start, end). Half-open interval.
    func deleteRange(from start: Date, to end: Date) {
        let sql = "DELETE FROM transcription_history WHERE created_at >= ? AND created_at < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, iso.string(from: start))
        bind(stmt, 2, iso.string(from: end))
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    // MARK: - Statistics

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let recordCount: Int

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalCharacters) / totalDuration * 60  // 字/分钟
        }
    }

    func getStatistics() -> Statistics {
        let sql = """
        SELECT
            COALESCE(SUM(duration_seconds), 0),
            COALESCE(SUM(character_count), 0),
            COUNT(*)
        FROM transcription_history;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Statistics(
                totalDuration: sqlite3_column_double(stmt, 0),
                totalCharacters: Int(sqlite3_column_int(stmt, 1)),
                recordCount: Int(sqlite3_column_int(stmt, 2))
            )
        }
        return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
    }

    // MARK: - Pruning

    /// Delete records older than the user-configured retention window
    /// (通用 设置 → 历史记录 → 语音记录缓存). Called once on init.
    private func pruneOldRecords() {
        let months = max(1, UserDefaults.standard.object(forKey: "historyRetentionMonths") as? Int ?? 2)
        guard let cutoffDate = Calendar.current.date(byAdding: .month, value: -months, to: Date()) else { return }
        let cutoff = iso.string(from: cutoffDate)
        let sql = "DELETE FROM transcription_history WHERE created_at < ?;"
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
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }
}
