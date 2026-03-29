import Foundation
import SQLite3

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("VoiceBubble.historyStoreDidChange")
}

/// SQLite-backed store for voice transcription history. Thread-safe via actor isolation.
actor HistoryStore {

    private var db: OpaquePointer?

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceBubble", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("history.db").path

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let sql = """
            CREATE TABLE IF NOT EXISTS transcription_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                text TEXT NOT NULL,
                character_count INTEGER
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - CRUD

    func insert(_ record: TranscriptionRecord) {
        let sql = """
        INSERT OR REPLACE INTO transcription_history
        (id, created_at, duration_seconds, text, character_count)
        VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id.uuidString)
        bind(stmt, 2, iso.string(from: record.timestamp))
        sqlite3_bind_double(stmt, 3, record.duration)
        bind(stmt, 4, record.text)
        sqlite3_bind_int(stmt, 5, Int32(record.text.count))

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

        let iso = ISO8601DateFormatter()
        var records: [TranscriptionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(TranscriptionRecord(
                id: UUID(uuidString: column(stmt, 0)) ?? UUID(),
                timestamp: iso.date(from: column(stmt, 1)) ?? Date(),
                text: column(stmt, 3),
                duration: sqlite3_column_double(stmt, 2)
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
