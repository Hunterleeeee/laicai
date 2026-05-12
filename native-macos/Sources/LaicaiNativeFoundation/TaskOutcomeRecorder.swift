import Foundation
import LaicaiNativeDomain

#if canImport(SQLite3)
import SQLite3
#endif

/// Records task outcomes for self-evolution analytics.
/// Stores lightweight tuples per task to enable routing drift, prompt A/B, and pattern learning.
public final class TaskOutcomeRecorder {
    public static let shared = TaskOutcomeRecorder()

    private let queue = DispatchQueue(label: "laicai.outcome", qos: .utility)
    private let path: String

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("outcomes.sqlite3")
        migrate()
    }

    private func migrate() {
        withDatabase(()) { db in
            Self.ensureTaskOutcomesTable(on: db)
            Self.ensureToolOutcomesTable(on: db)
            Self.ensureExecutionTracesTable(on: db)
        }
    }

    private func withDatabase<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        queue.sync {
            guard let db = openDatabase(readOnly: false) else { return fallback }
            defer { sqlite3_close(db) }
            return body(db)
        }
    }

    private func withReadOnlyDatabase<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        queue.sync {
            guard let db = openDatabase(readOnly: true) else { return fallback }
            defer { sqlite3_close(db) }
            return body(db)
        }
    }

    private func withDatabaseAsync(_ body: @escaping (OpaquePointer) -> Void) {
        let dbPath = path
        queue.async {
            guard let db = Self.openDatabase(at: dbPath, readOnly: false) else { return }
            defer { sqlite3_close(db) }
            body(db)
        }
    }

    private func openDatabase(readOnly: Bool) -> OpaquePointer? {
        Self.openDatabase(at: path, readOnly: readOnly)
    }

    private static func openDatabase(at path: String, readOnly: Bool) -> OpaquePointer? {
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

    private static func configure(_ db: OpaquePointer, readOnly: Bool) {
        exec("PRAGMA busy_timeout = 5000;", on: db)
        exec("PRAGMA temp_store = MEMORY;", on: db)
        if !readOnly {
            exec("PRAGMA journal_mode = WAL;", on: db)
            exec("PRAGMA synchronous = NORMAL;", on: db)
        }
    }

    @discardableResult
    private static func exec(_ sql: String, on db: OpaquePointer) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func ensureTaskOutcomesTable(on db: OpaquePointer) {
        exec("""
            CREATE TABLE IF NOT EXISTS task_outcomes (
                id TEXT PRIMARY KEY,
                intent TEXT NOT NULL,
                route_label TEXT NOT NULL,
                execution_mode TEXT NOT NULL,
                iterations INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                had_failure INTEGER NOT NULL DEFAULT 0,
                was_cancelled INTEGER NOT NULL DEFAULT 0,
                was_truncated INTEGER NOT NULL DEFAULT 0,
                tool_calls INTEGER NOT NULL DEFAULT 0,
                tool_failures INTEGER NOT NULL DEFAULT 0,
                duration_seconds REAL NOT NULL DEFAULT 0,
                user_followup_count INTEGER NOT NULL DEFAULT 0,
                prompt_tag TEXT NOT NULL DEFAULT '',
                user_rating INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            """, on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_outcome_intent ON task_outcomes(intent);", on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_outcome_status ON task_outcomes(status);", on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_outcome_created ON task_outcomes(created_at);", on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_outcome_prompt ON task_outcomes(prompt_tag);", on: db)
        exec("ALTER TABLE task_outcomes ADD COLUMN prompt_tag TEXT NOT NULL DEFAULT '';", on: db)
        exec("ALTER TABLE task_outcomes ADD COLUMN user_rating INTEGER NOT NULL DEFAULT 0;", on: db)
        exec("ALTER TABLE task_outcomes ADD COLUMN model_name TEXT NOT NULL DEFAULT '';", on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_outcome_model ON task_outcomes(model_name);", on: db)
    }

    private static func ensureToolOutcomesTable(on db: OpaquePointer) {
        exec("""
            CREATE TABLE IF NOT EXISTS tool_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                model_name TEXT NOT NULL DEFAULT '',
                success INTEGER NOT NULL DEFAULT 1,
                duration_seconds REAL NOT NULL DEFAULT 0,
                was_retry INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            """, on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_tool_name ON tool_outcomes(tool_name);", on: db)
        exec("CREATE INDEX IF NOT EXISTS idx_tool_model ON tool_outcomes(model_name);", on: db)
    }

    private static func ensureExecutionTracesTable(on db: OpaquePointer) {
        exec("""
            CREATE TABLE IF NOT EXISTS execution_traces (
                task_id TEXT PRIMARY KEY,
                trace TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """, on: db)
    }

    public func record(
        taskID: String,
        intent: String,
        routeLabel: String,
        executionMode: String,
        iterations: Int,
        status: TaskStatus,
        hadFailure: Bool,
        wasCancelled: Bool,
        wasTruncated: Bool,
        toolCalls: Int,
        toolFailures: Int,
        durationSeconds: Double,
        userFollowupCount: Int,
        promptTag: String = "",
        userRating: Int = 0,
        modelName: String = ""
    ) {
        withDatabaseAsync { db in
            let sql = """
            INSERT OR REPLACE INTO task_outcomes (
                id, intent, route_label, execution_mode, iterations, status,
                had_failure, was_cancelled, was_truncated, tool_calls, tool_failures,
                duration_seconds, user_followup_count, prompt_tag, user_rating, created_at, model_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_text_safe(stmt, 1, taskID)
            sqlite3_bind_text_safe(stmt, 2, intent)
            sqlite3_bind_text_safe(stmt, 3, routeLabel)
            sqlite3_bind_text_safe(stmt, 4, executionMode)
            sqlite3_bind_int(stmt, 5, Int32(iterations))
            sqlite3_bind_text_safe(stmt, 6, status.rawValue)
            sqlite3_bind_int(stmt, 7, hadFailure ? 1 : 0)
            sqlite3_bind_int(stmt, 8, wasCancelled ? 1 : 0)
            sqlite3_bind_int(stmt, 9, wasTruncated ? 1 : 0)
            sqlite3_bind_int(stmt, 10, Int32(toolCalls))
            sqlite3_bind_int(stmt, 11, Int32(toolFailures))
            sqlite3_bind_double(stmt, 12, durationSeconds)
            sqlite3_bind_int(stmt, 13, Int32(userFollowupCount))
            sqlite3_bind_text_safe(stmt, 14, promptTag)
            sqlite3_bind_int(stmt, 15, Int32(userRating))
            sqlite3_bind_double(stmt, 16, now)
            sqlite3_bind_text_safe(stmt, 17, modelName)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Returns outcome stats for the last N days grouped by intent and route label.
    public func stats(days: Int = 7) -> [OutcomeStatsRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
            let sql = """
            SELECT intent, route_label, execution_mode,
                   COUNT(*) as total,
                   SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                   SUM(CASE WHEN was_cancelled = 1 THEN 1 ELSE 0 END) as cancelled,
                   AVG(iterations) as avg_iterations,
                   AVG(tool_failures) as avg_tool_failures,
                   AVG(user_rating) as avg_rating
            FROM task_outcomes
            WHERE created_at > ?
            GROUP BY intent, route_label, execution_mode;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [OutcomeStatsRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(OutcomeStatsRow(
                    intent: Self.columnString(stmt, 0),
                    routeLabel: Self.columnString(stmt, 1),
                    executionMode: Self.columnString(stmt, 2),
                    total: Int(sqlite3_column_int(stmt, 3)),
                    completed: Int(sqlite3_column_int(stmt, 4)),
                    cancelled: Int(sqlite3_column_int(stmt, 5)),
                    avgIterations: sqlite3_column_double(stmt, 6),
                    avgToolFailures: sqlite3_column_double(stmt, 7),
                    avgUserRating: sqlite3_column_double(stmt, 8)
                ))
            }
            return rows
        }
    }

    /// Returns outcome stats grouped by prompt tag for A/B comparison.
    public func promptTagStats(days: Int = 7) -> [PromptTagStatsRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
            let sql = """
            SELECT prompt_tag,
                   COUNT(*) as total,
                   SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                   SUM(CASE WHEN was_cancelled = 1 THEN 1 ELSE 0 END) as cancelled,
                   AVG(iterations) as avg_iterations,
                   AVG(duration_seconds) as avg_duration,
                   AVG(user_rating) as avg_rating
            FROM task_outcomes
            WHERE created_at > ? AND prompt_tag != ''
            GROUP BY prompt_tag
            ORDER BY total DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [PromptTagStatsRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(PromptTagStatsRow(
                    tag: Self.columnString(stmt, 0),
                    total: Int(sqlite3_column_int(stmt, 1)),
                    completed: Int(sqlite3_column_int(stmt, 2)),
                    cancelled: Int(sqlite3_column_int(stmt, 3)),
                    avgIterations: sqlite3_column_double(stmt, 4),
                    avgDuration: sqlite3_column_double(stmt, 5),
                    avgUserRating: sqlite3_column_double(stmt, 6)
                ))
            }
            return rows
        }
    }

    /// Update user rating for a completed task.
    public func rate(taskID: String, rating: Int) {
        withDatabaseAsync { db in
            let sql = "UPDATE task_outcomes SET user_rating = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(rating))
            sqlite3_bind_text_safe(stmt, 2, taskID)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Tool-Level Tracking

    /// Record individual tool call outcomes for per-tool effectiveness analysis.
    public func recordToolOutcome(
        taskID: String,
        toolName: String,
        modelName: String,
        success: Bool,
        durationSeconds: Double,
        wasRetry: Bool = false
    ) {
        withDatabaseAsync { db in
            Self.ensureToolOutcomesTable(on: db)
            let sql = "INSERT INTO tool_outcomes (task_id, tool_name, model_name, success, duration_seconds, was_retry, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text_safe(stmt, 1, taskID)
            sqlite3_bind_text_safe(stmt, 2, toolName)
            sqlite3_bind_text_safe(stmt, 3, modelName)
            sqlite3_bind_int(stmt, 4, success ? 1 : 0)
            sqlite3_bind_double(stmt, 5, durationSeconds)
            sqlite3_bind_int(stmt, 6, wasRetry ? 1 : 0)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Returns per-tool effectiveness stats for the last N days.
    public func toolStats(days: Int = 7) -> [ToolStatsRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
            let sql = """
            SELECT tool_name, model_name,
                   COUNT(*) as total,
                   SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successes,
                   AVG(duration_seconds) as avg_duration,
                   SUM(CASE WHEN was_retry = 1 THEN 1 ELSE 0 END) as retries
            FROM tool_outcomes
            WHERE created_at > ?
            GROUP BY tool_name, model_name
            ORDER BY total DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [ToolStatsRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ToolStatsRow(
                    toolName: Self.columnString(stmt, 0),
                    modelName: Self.columnString(stmt, 1),
                    total: Int(sqlite3_column_int(stmt, 2)),
                    successes: Int(sqlite3_column_int(stmt, 3)),
                    avgDuration: sqlite3_column_double(stmt, 4),
                    retries: Int(sqlite3_column_int(stmt, 5))
                ))
            }
            return rows
        }
    }

    // MARK: - Execution Trace

    /// Store a compact execution trace for a task — enables future GEPA-style offline analysis.
    public func storeTrace(taskID: String, traceJSON: String) {
        withDatabaseAsync { db in
            Self.ensureExecutionTracesTable(on: db)
            let sql = "INSERT OR REPLACE INTO execution_traces (task_id, trace, created_at) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text_safe(stmt, 1, taskID)
            sqlite3_bind_text_safe(stmt, 2, traceJSON)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Returns the average iteration count for completed tasks of a given intent.
    /// Used for dynamic iteration budget learning (A4).
    public func avgIterations(intent: String, days: Int = 14) -> Double? {
        withReadOnlyDatabase(Double?.none) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
            let sql = "SELECT AVG(iterations) FROM task_outcomes WHERE intent = ? AND status = 'completed' AND created_at > ? AND iterations > 0;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text_safe(stmt, 1, intent)
            sqlite3_bind_double(stmt, 2, cutoff)
            if sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                return sqlite3_column_double(stmt, 0)
            }
            return nil
        }
    }

    /// Returns recent failures for a given intent to enable pattern learning.
    public func recentFailures(intent: String, limit: Int = 20) -> [OutcomeRow] {
        withReadOnlyDatabase([]) { db in
            let sql = """
            SELECT id, intent, route_label, execution_mode, iterations, status,
                   had_failure, was_cancelled, was_truncated, tool_calls, tool_failures,
                   duration_seconds, user_followup_count, created_at
            FROM task_outcomes
            WHERE intent = ? AND (status != 'completed' OR was_cancelled = 1 OR had_failure = 1)
            ORDER BY created_at DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text_safe(stmt, 1, intent)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [OutcomeRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(OutcomeRow(
                    id: Self.columnString(stmt, 0),
                    intent: Self.columnString(stmt, 1),
                    routeLabel: Self.columnString(stmt, 2),
                    executionMode: Self.columnString(stmt, 3),
                    iterations: Int(sqlite3_column_int(stmt, 4)),
                    status: Self.columnString(stmt, 5),
                    hadFailure: sqlite3_column_int(stmt, 6) == 1,
                    wasCancelled: sqlite3_column_int(stmt, 7) == 1,
                    wasTruncated: sqlite3_column_int(stmt, 8) == 1,
                    toolCalls: Int(sqlite3_column_int(stmt, 9)),
                    toolFailures: Int(sqlite3_column_int(stmt, 10)),
                    durationSeconds: sqlite3_column_double(stmt, 11),
                    userFollowupCount: Int(sqlite3_column_int(stmt, 12)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
                ))
            }
            return rows
        }
    }

    private static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }
}

public struct OutcomeStatsRow: Sendable {
    public let intent: String
    public let routeLabel: String
    public let executionMode: String
    public let total: Int
    public let completed: Int
    public let cancelled: Int
    public let avgIterations: Double
    public let avgToolFailures: Double
    public let avgUserRating: Double

    public var completionRate: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
    public var cancellationRate: Double {
        guard total > 0 else { return 0 }
        return Double(cancelled) / Double(total)
    }
}

public struct PromptTagStatsRow: Sendable {
    public let tag: String
    public let total: Int
    public let completed: Int
    public let cancelled: Int
    public let avgIterations: Double
    public let avgDuration: Double
    public let avgUserRating: Double

    public var completionRate: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
    public var score: Double {
        guard total > 0 else { return 0 }
        let base = completionRate * 100
        let cancelPenalty = (Double(cancelled) / Double(total)) * 30.0
        let iterPenalty: Double = avgIterations > 8 ? 10.0 : 0.0
        let bonus = avgUserRating > 0 ? avgUserRating * 5.0 : 0.0
        return max(0, base - cancelPenalty - iterPenalty + bonus)
    }
}

public struct ToolStatsRow: Sendable {
    public let toolName: String
    public let modelName: String
    public let total: Int
    public let successes: Int
    public let avgDuration: Double
    public let retries: Int

    public var successRate: Double {
        guard total > 0 else { return 0 }
        return Double(successes) / Double(total)
    }
    public var retryRate: Double {
        guard total > 0 else { return 0 }
        return Double(retries) / Double(total)
    }
}

public struct OutcomeRow: Sendable {
    public let id: String
    public let intent: String
    public let routeLabel: String
    public let executionMode: String
    public let iterations: Int
    public let status: String
    public let hadFailure: Bool
    public let wasCancelled: Bool
    public let wasTruncated: Bool
    public let toolCalls: Int
    public let toolFailures: Int
    public let durationSeconds: Double
    public let userFollowupCount: Int
    public let createdAt: Date
}
