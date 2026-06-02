import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SQLite Helpers

/// Safe text binding that copies the string immediately (SQLITE_TRANSIENT).
/// Prevents use-after-free when Swift temporaries are freed before sqlite3_step.
@discardableResult
func sqlite3_bind_text_safe(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) -> Int32 {
    let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    return sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
}

enum SQLiteSupport {
    static func withDatabase<T>(
        path: String,
        queue: DispatchQueue,
        readOnly: Bool = false,
        fallback: T,
        _ body: (OpaquePointer) -> T
    ) -> T {
        queue.sync {
            guard let db = openDatabase(at: path, readOnly: readOnly) else { return fallback }
            defer { sqlite3_close(db) }
            return body(db)
        }
    }

    static func withDatabaseAsync(
        path: String,
        queue: DispatchQueue,
        readOnly: Bool = false,
        _ body: @escaping (OpaquePointer) -> Void
    ) {
        queue.async {
            guard let db = openDatabase(at: path, readOnly: readOnly) else { return }
            defer { sqlite3_close(db) }
            body(db)
        }
    }

    static func openDatabase(at path: String, readOnly: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(opened, 5_000)
        configure(opened, readOnly: readOnly)
        return opened
    }

    @discardableResult
    static func exec(_ sql: String, on db: OpaquePointer) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }

    private static func configure(_ db: OpaquePointer, readOnly: Bool) {
        exec("PRAGMA busy_timeout = 5000;", on: db)
        exec("PRAGMA temp_store = MEMORY;", on: db)
        if !readOnly {
            exec("PRAGMA journal_mode = WAL;", on: db)
            exec("PRAGMA synchronous = NORMAL;", on: db)
        }
    }
}
