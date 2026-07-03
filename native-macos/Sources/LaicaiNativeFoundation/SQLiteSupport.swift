import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SQLite Helpers

/// Safe text binding that copies the string immediately (SQLITE_TRANSIENT).
/// Prevents use-after-free when Swift temporaries are freed before sqlite3_step.
@discardableResult
func sqlite3_bind_text_safe(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) -> Int32 {
    sqlite3_bind_text(stmt, index, value, -1, SQLiteSupport.transientDestructor)
}

enum SQLiteSupport {
    static let transientDestructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    static func withDatabase<T>(
        path: String,
        queue: DispatchQueue,
        readOnly: Bool = false,
        fallback: T,
        _ body: (OpaquePointer) -> T
    ) -> T {
        queue.sync {
            guard let database = openDatabase(at: path, readOnly: readOnly) else { return fallback }
            defer { sqlite3_close(database) }
            return body(database)
        }
    }

    static func withDatabaseAsync(
        path: String,
        queue: DispatchQueue,
        readOnly: Bool = false,
        _ body: @escaping (OpaquePointer) -> Void
    ) {
        queue.async {
            guard let database = openDatabase(at: path, readOnly: readOnly) else { return }
            defer { sqlite3_close(database) }
            body(database)
        }
    }

    static func openDatabase(at path: String, readOnly: Bool) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let opened = database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(opened, 5_000)
        configure(opened, readOnly: readOnly)
        return opened
    }

    @discardableResult
    static func exec(_ sql: String, on database: OpaquePointer) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }

    private static func configure(_ database: OpaquePointer, readOnly: Bool) {
        exec("PRAGMA busy_timeout = 5000;", on: database)
        exec("PRAGMA temp_store = MEMORY;", on: database)
        if !readOnly {
            exec("PRAGMA journal_mode = WAL;", on: database)
            exec("PRAGMA synchronous = NORMAL;", on: database)
        }
    }
}
