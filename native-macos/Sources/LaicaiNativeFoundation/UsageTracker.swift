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
    private let cacheLock = NSLock()
    private var threadUsageCache: [String: CachedThreadUsage] = [:]
    private let threadUsageCacheTTL: TimeInterval = 20

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("usage.sqlite3")
        migrate()
    }

    private func withDatabase<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        SQLiteSupport.withDatabase(path: path, queue: queue, fallback: fallback, body)
    }

    private func withReadOnlyDatabase<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        SQLiteSupport.withDatabase(path: path, queue: queue, readOnly: true, fallback: fallback, body)
    }

    private func withDatabaseAsync(_ body: @escaping (OpaquePointer) -> Void) {
        SQLiteSupport.withDatabaseAsync(path: path, queue: queue, body)
    }

    private func migrate() {
        withDatabase(()) { database in
            SQLiteSupport.exec("""
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
                intent TEXT NOT NULL DEFAULT '',
                phase TEXT NOT NULL DEFAULT '',
                tool_call_count INTEGER NOT NULL DEFAULT 0,
                error_count INTEGER NOT NULL DEFAULT 0
            );
            """, on: database)
            SQLiteSupport.exec("CREATE INDEX IF NOT EXISTS idx_usage_date ON usage_records(date_key);", on: database)
            SQLiteSupport.exec("CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_records(model_name);", on: database)
            SQLiteSupport.exec("CREATE INDEX IF NOT EXISTS idx_usage_project ON usage_records(project_name);", on: database)
            SQLiteSupport.exec("CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_records(timestamp);", on: database)
            SQLiteSupport.exec("CREATE INDEX IF NOT EXISTS idx_usage_thread ON usage_records(thread_id);", on: database)

            // Migration: add columns if they don't exist
            SQLiteSupport.exec("ALTER TABLE usage_records ADD COLUMN phase TEXT NOT NULL DEFAULT '';", on: database)
            SQLiteSupport.exec("ALTER TABLE usage_records ADD COLUMN tool_call_count INTEGER NOT NULL DEFAULT 0;", on: database)
            SQLiteSupport.exec("ALTER TABLE usage_records ADD COLUMN error_count INTEGER NOT NULL DEFAULT 0;", on: database)
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
        intent: String = "",
        phase: String = "",
        toolCallCount: Int = 0,
        errorCount: Int = 0
    ) {
        invalidateThreadUsageCache(threadID: threadID)
        withDatabaseAsync { database in
            let now = Date()
            let dateKey = Self.dateKey(from: now)
            let sql = """
            INSERT INTO usage_records (
                timestamp, date_key, model_name, connector_name, project_name,
                thread_id, input_tokens, output_tokens, duration_seconds,
                tokens_per_second, is_streaming, intent, phase, tool_call_count, error_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text_safe(stmt, 2, dateKey)
            sqlite3_bind_text_safe(stmt, 3, modelName)
            sqlite3_bind_text_safe(stmt, 4, connectorName)
            sqlite3_bind_text_safe(stmt, 5, projectName)
            sqlite3_bind_text_safe(stmt, 6, threadID)
            sqlite3_bind_int(stmt, 7, Int32(inputTokens))
            sqlite3_bind_int(stmt, 8, Int32(outputTokens))
            sqlite3_bind_double(stmt, 9, durationSeconds)
            sqlite3_bind_double(stmt, 10, tokensPerSecond)
            sqlite3_bind_int(stmt, 11, isStreaming ? 1 : 0)
            sqlite3_bind_text_safe(stmt, 12, intent)
            sqlite3_bind_text_safe(stmt, 13, phase)
            sqlite3_bind_int(stmt, 14, Int32(toolCallCount))
            sqlite3_bind_int(stmt, 15, Int32(errorCount))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            self.invalidateThreadUsageCache(threadID: threadID)
        }
    }

    // MARK: - Queries

    /// Daily usage for the last N days
    public func dailyUsage(days: Int = 30) -> [DailyUsageRow] {
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [DailyUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(DailyUsageRow(
                    dateKey: SQLiteSupport.columnString(stmt, 0),
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
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [ModelUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ModelUsageRow(
                    modelName: SQLiteSupport.columnString(stmt, 0),
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
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [ProjectUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ProjectUsageRow(
                    projectName: SQLiteSupport.columnString(stmt, 0),
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
        withReadOnlyDatabase(UsageTotals()) { database in
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = """
            SELECT SUM(input_tokens), SUM(output_tokens), COUNT(*),
                   AVG(duration_seconds), AVG(tokens_per_second)
            FROM usage_records WHERE timestamp > ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return UsageTotals() }
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
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [ThreadUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(ThreadUsageRow(
                    threadID: SQLiteSupport.columnString(stmt, 0),
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
        withReadOnlyDatabase([]) { database in
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
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            var rows: [IntentUsageRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(IntentUsageRow(
                    intent: SQLiteSupport.columnString(stmt, 0),
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
    public func threadUsage(threadID: String) -> UsageTotals {
        guard !threadID.isEmpty else { return UsageTotals() }
        if let cached = cachedThreadUsage(threadID: threadID) {
            return cached
        }
        let usage = withReadOnlyDatabase(UsageTotals()) { database in
            let sql = "SELECT SUM(input_tokens), SUM(output_tokens), COUNT(*) FROM usage_records WHERE thread_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return UsageTotals() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text_safe(stmt, 1, threadID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return UsageTotals() }
            let input = Int(sqlite3_column_int64(stmt, 0))
            let output = Int(sqlite3_column_int64(stmt, 1))
            let count = Int(sqlite3_column_int(stmt, 2))
            return UsageTotals(inputTokens: input, outputTokens: output, requestCount: count)
        }
        cacheThreadUsage(usage, for: threadID)
        return usage
    }

    // MARK: - Helpers

    private struct CachedThreadUsage {
        let value: UsageTotals
        let storedAt: Date
    }

    private func cachedThreadUsage(threadID: String) -> UsageTotals? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = threadUsageCache[threadID] else { return nil }
        if Date().timeIntervalSince(cached.storedAt) <= threadUsageCacheTTL {
            return cached.value
        }
        threadUsageCache.removeValue(forKey: threadID)
        return nil
    }

    private func cacheThreadUsage(
        _ value: UsageTotals,
        for threadID: String
    ) {
        cacheLock.lock()
        threadUsageCache[threadID] = CachedThreadUsage(value: value, storedAt: Date())
        cacheLock.unlock()
    }

    private func invalidateThreadUsageCache(threadID: String) {
        guard !threadID.isEmpty else { return }
        cacheLock.lock()
        threadUsageCache.removeValue(forKey: threadID)
        cacheLock.unlock()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dateKey(from date: Date) -> String {
        dateFormatter.string(from: date)
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

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        requestCount: Int = 0,
        avgDuration: Double = 0,
        avgSpeed: Double = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.avgDuration = avgDuration
        self.avgSpeed = avgSpeed
    }
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
        case "chat": return "会话 问答"
        case "task": return "会话 执行"
        case "research": return "会话 研究"
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

    private struct PricingRule {
        let patterns: [String]
        let price: Price
    }

    private static let pricingRules: [PricingRule] = [
        PricingRule(patterns: ["gpt-5", "gpt5"], price: Price(inputPerMillion: 10.0, outputPerMillion: 30.0)),
        PricingRule(patterns: ["gpt-4.1"], price: Price(inputPerMillion: 2.0, outputPerMillion: 8.0)),
        PricingRule(patterns: ["gpt-4o"], price: Price(inputPerMillion: 2.5, outputPerMillion: 10.0)),
        PricingRule(patterns: ["o3", "o4"], price: Price(inputPerMillion: 10.0, outputPerMillion: 40.0)),
        PricingRule(patterns: ["o1"], price: Price(inputPerMillion: 15.0, outputPerMillion: 60.0)),
        PricingRule(patterns: ["claude-4", "claude-3.7"], price: Price(inputPerMillion: 3.0, outputPerMillion: 15.0)),
        PricingRule(patterns: ["claude-3.5"], price: Price(inputPerMillion: 3.0, outputPerMillion: 15.0)),
        PricingRule(patterns: ["claude"], price: Price(inputPerMillion: 3.0, outputPerMillion: 15.0)),
        PricingRule(patterns: ["deepseek"], price: Price(inputPerMillion: 0.27, outputPerMillion: 1.10)),
        PricingRule(patterns: ["gemini"], price: Price(inputPerMillion: 1.25, outputPerMillion: 5.0)),
        PricingRule(patterns: ["llama", "qwen", "mistral", "phi"], price: Price(inputPerMillion: 0, outputPerMillion: 0))
    ]

    public static func lookup(_ model: String) -> Price {
        let normalizedModel = model.lowercased()
        if let match = pricingRules.first(where: { rule in
            rule.patterns.contains { normalizedModel.contains($0) }
        }) {
            return match.price
        }
        return Price(inputPerMillion: 3.0, outputPerMillion: 15.0)
    }
}
