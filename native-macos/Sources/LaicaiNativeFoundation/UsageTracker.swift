import Foundation
import LaicaiNativeDomain

#if canImport(SQLite3)
import SQLite3
#endif

/// Tracks per-request LLM usage for accurate token/cost analytics.
/// Each API call (streaming or non-streaming) records a row with exact token counts.
public final class UsageTracker {
    public static let shared = UsageTracker()

    private let queue = DispatchQueue(label: "laicai.usage-tracker", qos: .utility)
    private let path: String

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("usage.sqlite3")
        migrate()
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

    private func migrate() {
        withDatabase(()) { db in
            Self.exec("""
            CREATE TABLE IF NOT EXISTS usage_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                date_key TEXT NOT NULL,
                model_name TEXT NOT NULL DEFAULT '',
                connector_name TEXT NOT NULL DEFAULT '',
                project_name TEXT NOT NULL DEFAULT '',
                thread_id TEXT NOT NULL DEFAULT '',
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                duration_seconds REAL NOT NULL DEFAULT 0,
                tokens_per_second REAL NOT NULL DEFAULT 0,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                intent TEXT NOT NULL DEFAULT ''
            );
            """, on: db)
            Self.exec("CREATE INDEX IF NOT EXISTS idx_usage_date ON usage_records(date_key);", on: db)
            Self.exec("CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_records(model_name);", on: db)
            Self.exec("CREATE INDEX IF NOT EXISTS idx_usage_project ON usage_records(project_name);", on: db)
            Self.exec("CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_records(timestamp);", on: db)
            Self.exec("CREATE INDEX IF NOT EXISTS idx_usage_thread ON usage_records(thread_id);", on: db)
        }
    }

    // MARK: - Record

    public func record(
        modelName: String,
        connectorName: String = "",
        projectName: String = "",
        threadID: String = "",
        inputTokens: Int,
        outputTokens: Int,
        durationSeconds: Double,
        tokensPerSecond: Double = 0,
        isStreaming: Bool = false,
        intent: String = ""
    ) {
        withDatabaseAsync { db in
            let now = Date()
            let dateKey = Self.dateKey(from: now)
            let sql = """
            INSERT INTO usage_records (
                timestamp, date_key, model_name, connector_name, project_name,
                thread_id, input_tokens, output_tokens, duration_seconds,
                tokens_per_second, is_streaming, intent
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            Self.bindText(stmt, 2, dateKey)
            Self.bindText(stmt, 3, modelName)
            Self.bindText(stmt, 4, connectorName)
            Self.bindText(stmt, 5, projectName)
            Self.bindText(stmt, 6, threadID)
            sqlite3_bind_int(stmt, 7, Int32(inputTokens))
            sqlite3_bind_int(stmt, 8, Int32(outputTokens))
            sqlite3_bind_double(stmt, 9, durationSeconds)
            sqlite3_bind_double(stmt, 10, tokensPerSecond)
            sqlite3_bind_int(stmt, 11, isStreaming ? 1 : 0)
            Self.bindText(stmt, 12, intent)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Queries

    /// Daily usage for the last N days
    public func dailyUsage(days: Int = 30) -> [DailyUsageRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT date_key,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count,
                   AVG(duration_seconds) as avg_duration,
                   AVG(tokens_per_second) as avg_speed
            FROM usage_records
            WHERE timestamp > ?
            GROUP BY date_key
            ORDER BY date_key ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [DailyUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(DailyUsageRow(
                    dateKey: Self.columnString(stmt, 0),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3)),
                    avgDuration: sqlite3_column_double(stmt, 4),
                    avgSpeed: sqlite3_column_double(stmt, 5)
                ))
            }
            return rows
        }
    }

    /// Per-model usage breakdown
    public func modelBreakdown(days: Int = 30) -> [ModelUsageRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT model_name,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count,
                   AVG(tokens_per_second) as avg_speed
            FROM usage_records
            WHERE timestamp > ?
            GROUP BY model_name
            ORDER BY (total_input + total_output) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [ModelUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ModelUsageRow(
                    modelName: Self.columnString(stmt, 0),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3)),
                    avgSpeed: sqlite3_column_double(stmt, 4)
                ))
            }
            return rows
        }
    }

    /// Per-project usage breakdown
    public func projectBreakdown(days: Int = 30) -> [ProjectUsageRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT project_name,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count
            FROM usage_records
            WHERE timestamp > ? AND project_name != ''
            GROUP BY project_name
            ORDER BY (total_input + total_output) DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [ProjectUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ProjectUsageRow(
                    projectName: Self.columnString(stmt, 0),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3))
                ))
            }
            return rows
        }
    }

    /// Totals for a period
    public func totals(days: Int = 30) -> UsageTotals {
        withReadOnlyDatabase(UsageTotals()) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT SUM(input_tokens), SUM(output_tokens), COUNT(*),
                   AVG(duration_seconds), AVG(tokens_per_second)
            FROM usage_records WHERE timestamp > ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return UsageTotals() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var result = UsageTotals()
            if sqlite3_step(stmt) == SQLITE_ROW {
                result.inputTokens = Int(sqlite3_column_int64(stmt, 0))
                result.outputTokens = Int(sqlite3_column_int64(stmt, 1))
                result.requestCount = Int(sqlite3_column_int(stmt, 2))
                result.avgDuration = sqlite3_column_double(stmt, 3)
                result.avgSpeed = sqlite3_column_double(stmt, 4)
            }
            return result
        }
    }

    /// Hourly pattern for today
    public func hourlyToday() -> [HourlyUsageRow] {
        withReadOnlyDatabase([]) { db in
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let sql = """
            SELECT CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) as hour,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count
            FROM usage_records
            WHERE timestamp > ?
            GROUP BY hour
            ORDER BY hour;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, startOfDay)
            var rows: [HourlyUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(HourlyUsageRow(
                    hour: Int(sqlite3_column_int(stmt, 0)),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3))
                ))
            }
            return rows
        }
    }

    /// Top threads by token usage (for session ranking)
    public func topThreads(days: Int = 30, limit: Int = 10) -> [ThreadUsageRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT thread_id,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count,
                   AVG(duration_seconds) as avg_duration,
                   SUM(input_tokens + output_tokens) as total_tokens
            FROM usage_records
            WHERE timestamp > ? AND thread_id != ''
            GROUP BY thread_id
            ORDER BY total_tokens DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [ThreadUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ThreadUsageRow(
                    threadID: Self.columnString(stmt, 0),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3)),
                    avgDuration: sqlite3_column_double(stmt, 4)
                ))
            }
            return rows
        }
    }

    /// Intent breakdown (chat vs task vs research)
    public func intentBreakdown(days: Int = 30) -> [IntentUsageRow] {
        withReadOnlyDatabase([]) { db in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT CASE WHEN intent = '' THEN 'chat' ELSE intent END as intent_label,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   COUNT(*) as request_count,
                   AVG(duration_seconds) as avg_duration
            FROM usage_records
            WHERE timestamp > ?
            GROUP BY intent_label
            ORDER BY request_count DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [IntentUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(IntentUsageRow(
                    intent: Self.columnString(stmt, 0),
                    inputTokens: Int(sqlite3_column_int64(stmt, 1)),
                    outputTokens: Int(sqlite3_column_int64(stmt, 2)),
                    requestCount: Int(sqlite3_column_int(stmt, 3)),
                    avgDuration: sqlite3_column_double(stmt, 4)
                ))
            }
            return rows
        }
    }

    /// Quick lookup: total tokens + cost for a single thread
    public func threadUsage(threadID: String) -> (inputTokens: Int, outputTokens: Int, requestCount: Int, estimatedCost: Double) {
        guard !threadID.isEmpty else { return (0, 0, 0, 0) }
        return withReadOnlyDatabase((0, 0, 0, 0)) { db in
            let sql = "SELECT SUM(input_tokens), SUM(output_tokens), COUNT(*) FROM usage_records WHERE thread_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0) }
            defer { sqlite3_finalize(stmt) }
            Self.bindText(stmt, 1, threadID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0) }
            let input = Int(sqlite3_column_int64(stmt, 0))
            let output = Int(sqlite3_column_int64(stmt, 1))
            let count = Int(sqlite3_column_int(stmt, 2))
            let cost = (Double(input) * 3.0 / 1_000_000.0) + (Double(output) * 15.0 / 1_000_000.0)
            return (input, output, count, cost)
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dateKey(from date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }
}

// MARK: - Data Models

public struct DailyUsageRow: Sendable, Identifiable {
    public var id: String { dateKey }
    public let dateKey: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let avgDuration: Double
    public let avgSpeed: Double
    public var totalTokens: Int { inputTokens + outputTokens }

    /// Estimate cost: $3/M input, $15/M output (frontier model pricing)
    public var estimatedCost: Double {
        (Double(inputTokens) * 3.0 / 1_000_000.0) + (Double(outputTokens) * 15.0 / 1_000_000.0)
    }
}

public struct ModelUsageRow: Sendable, Identifiable {
    public var id: String { modelName }
    public let modelName: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let avgSpeed: Double
    public var totalTokens: Int { inputTokens + outputTokens }

    public var estimatedCost: Double {
        let pricing = ModelPricing.lookup(modelName)
        return (Double(inputTokens) * pricing.inputPerMillion / 1_000_000.0) + (Double(outputTokens) * pricing.outputPerMillion / 1_000_000.0)
    }
}

public struct ProjectUsageRow: Sendable, Identifiable {
    public var id: String { projectName }
    public let projectName: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct UsageTotals: Sendable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var requestCount: Int = 0
    public var avgDuration: Double = 0
    public var avgSpeed: Double = 0
    public var totalTokens: Int { inputTokens + outputTokens }
    public var estimatedCost: Double {
        (Double(inputTokens) * 3.0 / 1_000_000.0) + (Double(outputTokens) * 15.0 / 1_000_000.0)
    }
}

public struct HourlyUsageRow: Sendable, Identifiable {
    public var id: Int { hour }
    public let hour: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct ThreadUsageRow: Sendable, Identifiable {
    public var id: String { threadID }
    public let threadID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let avgDuration: Double
    public var totalTokens: Int { inputTokens + outputTokens }
    public var estimatedCost: Double {
        (Double(inputTokens) * 3.0 / 1_000_000.0) + (Double(outputTokens) * 15.0 / 1_000_000.0)
    }
}

public struct IntentUsageRow: Sendable, Identifiable {
    public var id: String { intent }
    public let intent: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let avgDuration: Double
    public var totalTokens: Int { inputTokens + outputTokens }

    public var displayName: String {
        switch intent {
        case "chat": return "聊天"
        case "task": return "任务"
        case "research": return "研究"
        default: return intent
        }
    }
}

// MARK: - Model Pricing (per million tokens)

public enum ModelPricing {
    public struct Price {
        public let inputPerMillion: Double
        public let outputPerMillion: Double
    }

    public static func lookup(_ model: String) -> Price {
        let m = model.lowercased()
        // GPT-5 / GPT-4.1
        if m.contains("gpt-5") || m.contains("gpt5") { return Price(inputPerMillion: 10.0, outputPerMillion: 30.0) }
        if m.contains("gpt-4.1") { return Price(inputPerMillion: 2.0, outputPerMillion: 8.0) }
        if m.contains("gpt-4o") { return Price(inputPerMillion: 2.5, outputPerMillion: 10.0) }
        if m.contains("o3") || m.contains("o4") { return Price(inputPerMillion: 10.0, outputPerMillion: 40.0) }
        if m.contains("o1") { return Price(inputPerMillion: 15.0, outputPerMillion: 60.0) }
        // Claude
        if m.contains("claude-4") || m.contains("claude-3.7") { return Price(inputPerMillion: 3.0, outputPerMillion: 15.0) }
        if m.contains("claude-3.5") { return Price(inputPerMillion: 3.0, outputPerMillion: 15.0) }
        if m.contains("claude") { return Price(inputPerMillion: 3.0, outputPerMillion: 15.0) }
        // DeepSeek
        if m.contains("deepseek") { return Price(inputPerMillion: 0.27, outputPerMillion: 1.10) }
        // Gemini
        if m.contains("gemini") { return Price(inputPerMillion: 1.25, outputPerMillion: 5.0) }
        // Local models — free
        if m.contains("llama") || m.contains("qwen") || m.contains("mistral") || m.contains("phi") {
            return Price(inputPerMillion: 0, outputPerMillion: 0)
        }
        // Default frontier pricing
        return Price(inputPerMillion: 3.0, outputPerMillion: 15.0)
    }
}
