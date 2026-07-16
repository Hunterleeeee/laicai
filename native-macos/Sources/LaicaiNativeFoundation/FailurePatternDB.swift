import Foundation

#if canImport(SQLite3)
    import SQLite3
#endif

/// Stores and matches failure patterns for proactive strategy learning.
/// When a new task looks similar to a known failure, injects a preemptive instruction.
public final class FailurePatternDB {
    public static let shared = FailurePatternDB()

    private static let queueKey = DispatchSpecificKey<Void>()

    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "laicai.patterns", qos: .utility)
    private let path: String

    public init(path: String? = nil) {
        let directory = LaicaiStoragePaths.appDirectory(basePath: path)
        self.path = directory.appendingPathComponent("patterns.sqlite3").path
        queue.setSpecific(key: Self.queueKey, value: ())
        open()
        migrate()
        pruneStalePatterns()
    }

    deinit {
        sqlite3_close(database)
    }

    private func open() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &database, flags, nil) != SQLITE_OK {
            database = nil
            return
        }
        sqlite3_busy_timeout(database, 2500)
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA foreign_keys = ON;")
    }

    private func exec(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func migrate() {
        exec(
            """
            CREATE TABLE IF NOT EXISTS failure_patterns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_hash TEXT NOT NULL UNIQUE,
                intent TEXT NOT NULL,
                trigger_tools TEXT NOT NULL DEFAULT '',
                trigger_keywords TEXT NOT NULL DEFAULT '',
                root_cause TEXT NOT NULL DEFAULT '',
                preemptive_instruction TEXT NOT NULL DEFAULT '',
                frequency INTEGER NOT NULL DEFAULT 1,
                success_after_fix INTEGER NOT NULL DEFAULT 0,
                last_seen REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        exec(
            """
            CREATE INDEX IF NOT EXISTS idx_pattern_intent ON failure_patterns(intent);
            """)
        exec(
            """
            CREATE INDEX IF NOT EXISTS idx_pattern_hash ON failure_patterns(pattern_hash);
            """)
        exec("ALTER TABLE failure_patterns ADD COLUMN model_name TEXT NOT NULL DEFAULT '';")
        exec("CREATE INDEX IF NOT EXISTS idx_pattern_model ON failure_patterns(model_name);")
    }

    /// Record a potential failure pattern from a task outcome.
    public func record(
        intent: String,
        triggerTools: [String],
        triggerKeywords: [String],
        rootCause: String,
        preemptiveInstruction: String,
        modelName: String = ""
    ) {
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let hash = Self.hash(intent: intent, tools: triggerTools, keywords: triggerKeywords, modelName: modelName)
            let tools = triggerTools.joined(separator: ",")
            let keywords = triggerKeywords.joined(separator: ",")
            let now = Date().timeIntervalSince1970

            // Try update first
            let updateSQL = """
                UPDATE failure_patterns SET
                    frequency = frequency + 1,
                    last_seen = ?
                WHERE pattern_hash = ?;
                """
            var updateStmt: OpaquePointer?
            if sqlite3_prepare_v2(database, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(updateStmt) }
                sqlite3_bind_double(updateStmt, 1, now)
                sqlite3BindTextSafe(updateStmt, 2, hash)
                sqlite3_step(updateStmt)
                let rowsChanged = sqlite3_changes(database)
                if rowsChanged > 0 { return }
            }

            // Insert new
            let insertSQL = """
                INSERT INTO failure_patterns (
                    pattern_hash, intent, trigger_tools, trigger_keywords,
                    root_cause, preemptive_instruction, frequency, last_seen, created_at, model_name
                ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?);
                """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(insertStmt) }
            sqlite3BindTextSafe(insertStmt, 1, hash)
            sqlite3BindTextSafe(insertStmt, 2, intent)
            sqlite3BindTextSafe(insertStmt, 3, tools)
            sqlite3BindTextSafe(insertStmt, 4, keywords)
            sqlite3BindTextSafe(insertStmt, 5, rootCause)
            sqlite3BindTextSafe(insertStmt, 6, preemptiveInstruction)
            sqlite3_bind_double(insertStmt, 7, now)
            sqlite3_bind_double(insertStmt, 8, now)
            sqlite3BindTextSafe(insertStmt, 9, modelName)
            sqlite3_step(insertStmt)
        }
    }

    /// Find matching patterns for a given intent and tool sequence.
    /// Applies time-based decay: patterns older than 30 days are skipped,
    /// patterns older than 14 days are deprioritized.
    /// Patterns that have been fixed (high successAfterFix) are also skipped.
    public func matches(intent: String, recentTools: [String], message: String, modelName: String = "") -> [FailurePattern] {
        syncOnQueue {
            guard let database else { return [] }
            let maxAgeDays: Double = 30
            let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400).timeIntervalSince1970
            // Prefer model-specific patterns; also include model-agnostic ones
            let sql = """
                SELECT id, pattern_hash, intent, trigger_tools, trigger_keywords,
                       root_cause, preemptive_instruction, frequency, success_after_fix, last_seen, model_name
                FROM failure_patterns
                WHERE intent = ? AND frequency >= 2 AND last_seen > ? AND (model_name = '' OR model_name = ?)
                ORDER BY CASE WHEN model_name = ? THEN 0 ELSE 1 END, frequency DESC, last_seen DESC
                LIMIT 10;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3BindTextSafe(stmt, 1, intent)
            sqlite3_bind_double(stmt, 2, cutoff)
            sqlite3BindTextSafe(stmt, 3, modelName)
            sqlite3BindTextSafe(stmt, 4, modelName)
            let now = Date()
            let decayThreshold: TimeInterval = 14 * 86400
            var results: [FailurePattern] = []
            let messageTokens = Self.tokenize(message)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let successCount = Int(sqlite3_column_int(stmt, 8))
                let freq = Int(sqlite3_column_int(stmt, 7))
                // Skip patterns already confirmed as fixed (success rate > 60%)
                if successCount > 0 && freq > 0 && Double(successCount) / Double(freq) > 0.6 {
                    continue
                }
                let triggerToolsString = SQLiteSupport.columnString(stmt, 3)
                let triggerKeywordsString = SQLiteSupport.columnString(stmt, 4)
                let tools = triggerToolsString.isEmpty ? [] : triggerToolsString.components(separatedBy: ",")
                let keywords = triggerKeywordsString.isEmpty ? [] : triggerKeywordsString.components(separatedBy: ",")
                let toolOverlap = !tools.isEmpty && tools.contains(where: { recentTools.contains($0) })
                // Use token similarity for keyword matching (P2: better than pure substring)
                let keywordTokens = keywords.reduce(into: Set<String>()) { $0.formUnion(Self.tokenize($1)) }
                let sim = Self.similarity(messageTokens, keywordTokens)
                let keywordMatch =
                    sim > 0.15 || (!keywords.isEmpty && keywords.contains(where: { message.localizedCaseInsensitiveContains($0) }))
                if toolOverlap || keywordMatch {
                    let lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                    let age = now.timeIntervalSince(lastSeen)
                    // Deprioritize stale patterns (>14 days) — only include if frequency is high
                    if age > decayThreshold && freq < 4 { continue }
                    results.append(
                        FailurePattern(
                            id: Int(sqlite3_column_int(stmt, 0)),
                            patternHash: SQLiteSupport.columnString(stmt, 1),
                            intent: SQLiteSupport.columnString(stmt, 2),
                            triggerTools: tools,
                            triggerKeywords: keywords,
                            rootCause: SQLiteSupport.columnString(stmt, 5),
                            preemptiveInstruction: SQLiteSupport.columnString(stmt, 6),
                            frequency: freq,
                            successAfterFix: successCount > 0,
                            lastSeen: lastSeen
                        ))
                }
            }
            return results
        }
    }

    /// Mark a pattern as having led to success after its preemptive instruction was applied.
    public func markSuccess(patternHash: String) {
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let sql = "UPDATE failure_patterns SET success_after_fix = success_after_fix + 1 WHERE pattern_hash = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3BindTextSafe(stmt, 1, patternHash)
            sqlite3_step(stmt)
        }
    }

    private static func hash(intent: String, tools: [String], keywords: [String], modelName: String = "") -> String {
        let base = "\(intent):\(tools.sorted().joined()):\(keywords.sorted().joined()):\(modelName)"
        return base.data(using: .utf8)?.base64EncodedString() ?? base
    }

    /// Tokenize text into meaningful keywords for similarity matching.
    /// Lightweight alternative to embedding vectors — segments Chinese and splits ASCII words.
    static func tokenize(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        let lower = text.lowercased()
        // Split ASCII words
        let ascii = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        tokens.formUnion(ascii)
        // Extract Chinese bigrams (2-char sliding window)
        let chars = Array(lower.unicodeScalars)
        var index = 0
        while index < chars.count - 1 {
            if chars[index].value >= 0x4E00 && chars[index].value <= 0x9FFF {
                let bigram = String(chars[index]) + String(chars[index + 1])
                tokens.insert(bigram)
                index += 1
            }
            index += 1
        }
        return tokens
    }

    /// Compute Jaccard similarity between two token sets.
    static func similarity(_ firstSet: Set<String>, _ secondSet: Set<String>) -> Double {
        guard !firstSet.isEmpty && !secondSet.isEmpty else { return 0 }
        let intersection = firstSet.intersection(secondSet).count
        let union = firstSet.union(secondSet).count
        return Double(intersection) / Double(union)
    }

    /// Prune patterns that are outdated (>60 days), low-frequency and fixed.
    /// Call periodically (e.g. on app launch) to keep the DB lean.
    public func pruneStalePatterns() {
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            let cutoff60 = Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970
            // Delete: >60 days old AND (low frequency OR confirmed fixed)
            let sql = """
                DELETE FROM failure_patterns
                WHERE last_seen < ?
                  AND (frequency < 3 OR (success_after_fix > 0 AND success_after_fix * 2 > frequency));
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff60)
            sqlite3_step(stmt)
        }
    }

    /// Return top failure patterns by frequency for self-improvement analysis.
    public func topPatterns(limit: Int = 5) -> [PatternSummary] {
        syncOnQueue {
            guard let database else { return [] }
            let sql = """
                SELECT intent, trigger_tools, root_cause, preemptive_instruction,
                       frequency, success_after_fix
                FROM failure_patterns
                ORDER BY frequency DESC LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [PatternSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(
                    PatternSummary(
                        intent: SQLiteSupport.columnString(stmt, 0),
                        triggerTools: SQLiteSupport.columnString(stmt, 1),
                        rootCause: SQLiteSupport.columnString(stmt, 2),
                        preemptiveInstruction: SQLiteSupport.columnString(stmt, 3),
                        frequency: Int(sqlite3_column_int(stmt, 4)),
                        successAfterFix: Int(sqlite3_column_int(stmt, 5))
                    ))
            }
            return results
        }
    }
}

// MARK: - Behavior Signal Tracker

/// Automatically captures implicit user behavior signals and writes failure patterns.
/// Signals: cancel (user stops a running task), retry (user retries a failed task),
/// frustration (user expresses annoyance/correction).
public struct BehaviorSignalTracker {
    public enum Signal: String {
        case cancel = "user_cancel"
        case retry = "user_retry"
        case frustration = "user_frustration"
    }

    /// Record a behavior signal from a thread.
    /// Extracts tools, keywords, and generates a preemptive instruction automatically.
    public static func record(signal: Signal, thread: Thread) {
        let intentString = inferIntent(from: thread)
        let recentTools = thread.steps
            .filter { $0.kind == .toolCall }
            .compactMap { $0.toolName }
        let triggerKeywords = extractKeywords(from: thread)
        let rootCause = rootCause(for: signal, thread: thread)
        let instruction = generatePreemptiveInstruction(signal: signal, thread: thread)

        FailurePatternDB.shared.record(
            intent: intentString,
            triggerTools: Array(Set(recentTools)),
            triggerKeywords: triggerKeywords,
            rootCause: rootCause,
            preemptiveInstruction: instruction,
            modelName: thread.modelName
        )
    }

    private static func inferIntent(from thread: Thread) -> String {
        if let workflowName = thread.workflowName { return "workflow:\(workflowName)" }
        let hasTools = thread.steps.contains { $0.kind == .toolCall }
        return hasTools ? "task" : "chat"
    }

    private static func extractKeywords(from thread: Thread) -> [String] {
        // Use first user input and title as keywords for pattern matching
        var keywords: [String] = []
        if !Thread.isPlaceholderTitle(thread.title) {
            keywords.append(thread.title)
        }
        if let firstInput = thread.steps.first(where: { $0.kind == .userInput })?.text {
            let cleaned = firstInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { keywords.append(String(cleaned.prefix(60))) }
        }
        return keywords
    }

    private static func rootCause(for signal: Signal, thread: Thread) -> String {
        switch signal {
        case .cancel:
            let iterations = thread.steps.filter { $0.kind == .toolCall }.count
            let lastTool = thread.steps.reversed().first(where: { $0.kind == .toolCall })?.toolName ?? "无"
            if iterations <= 1 { return "用户在第一轮工具调用后就取消，可能是路由错误或bootstrap选择失误" }
            if iterations > 6 { return "用户在\(iterations)次工具调用后取消，可能是任务陷入循环或效率低" }
            return "用户取消，最后工具：\(lastTool)，已执行\(iterations)次调用"
        case .retry:
            let lastError = thread.steps.reversed().first(where: { $0.isFailure })?.text ?? "未知"
            return "用户重试，上次失败原因：\(String(lastError.prefix(100)))"
        case .frustration:
            let lastUserMsg = thread.steps.reversed().first(where: { $0.kind == .userInput })?.text ?? ""
            return "用户表达不满：\(String(lastUserMsg.prefix(100)))"
        }
    }

    private static func generatePreemptiveInstruction(signal: Signal, thread: Thread) -> String {
        let toolNames = Set(thread.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName })
        let iterations = thread.steps.filter { $0.kind == .toolCall }.count

        switch signal {
        case .cancel:
            if iterations <= 1 {
                return "历史信号：类似请求用户曾在首轮就取消。请先确认是否需要工具调用，简单问题直接回答。"
            }
            if toolNames.contains("code.search") && iterations > 3 {
                return "历史信号：类似请求用户因搜索过多而取消。请精准搜索，不超过2次，找不到就告知用户。"
            }
            if iterations > 6 {
                return "历史信号：类似请求用户因迭代过多而取消。请控制在5轮内完成，不要循环尝试。"
            }
            return "历史信号：类似请求曾被用户取消。请更高效地完成，避免不必要的工具调用。"
        case .retry:
            let failedTools = thread.steps.filter { $0.kind == .toolResult && $0.isFailure }.compactMap { $0.toolName }
            if !failedTools.isEmpty {
                // Deduplicate and count occurrences
                var counts: [String: Int] = [:]
                for toolName in failedTools { counts[toolName, default: 0] += 1 }
                let summary = counts.sorted(by: { $0.value > $1.value })
                    .prefix(5)
                    .map { $0.value > 1 ? "\($0.key)(\($0.value)次)" : $0.key }
                    .joined(separator: "、")
                return "历史信号：类似请求中\(summary)曾失败导致重试。请预先检查参数有效性，或使用替代方案。"
            }
            return "历史信号：类似请求曾失败被重试。请确保输出完整且准确。"
        case .frustration:
            return "历史信号：类似请求曾引起用户不满。请更谨慎地回应，基于真实证据，不要编造或重复无效操作。"
        }
    }
}

public struct FailurePattern: Sendable {
    public let id: Int
    public let patternHash: String
    public let intent: String
    public let triggerTools: [String]
    public let triggerKeywords: [String]
    public let rootCause: String
    public let preemptiveInstruction: String
    public let frequency: Int
    public let successAfterFix: Bool
    public let lastSeen: Date
}
