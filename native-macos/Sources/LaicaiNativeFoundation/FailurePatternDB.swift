import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Stores and matches failure patterns for proactive strategy learning.
/// When a new task looks similar to a known failure, injects a preemptive instruction.
public final class FailurePatternDB {
    public static let shared = FailurePatternDB()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "laicai.patterns", qos: .utility)
    private let path: String

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("patterns.sqlite3")
        open()
        migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func open() {
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrate() {
        exec("""
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
        exec("""
        CREATE INDEX IF NOT EXISTS idx_pattern_intent ON failure_patterns(intent);
        """)
        exec("""
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
            guard let self, let db else { return }
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
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(updateStmt, 1, now)
                sqlite3_bind_text(updateStmt, 2, (hash as NSString).utf8String, -1, nil)
                sqlite3_step(updateStmt)
                let rowsChanged = sqlite3_changes(db)
                sqlite3_finalize(updateStmt)
                if rowsChanged > 0 { return }
            }

            // Insert new
            let insertSQL = """
            INSERT INTO failure_patterns (
                pattern_hash, intent, trigger_tools, trigger_keywords,
                root_cause, preemptive_instruction, frequency, last_seen, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?);
            """
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(insertStmt, 1, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (intent as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 3, (tools as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 4, (keywords as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 5, (rootCause as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 6, (preemptiveInstruction as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStmt, 7, now)
            sqlite3_bind_double(insertStmt, 8, now)
            sqlite3_step(insertStmt)
            sqlite3_finalize(insertStmt)
        }
    }

    /// Find matching patterns for a given intent and tool sequence.
    /// Applies time-based decay: patterns older than 30 days are skipped,
    /// patterns older than 14 days are deprioritized.
    /// Patterns that have been fixed (high successAfterFix) are also skipped.
    public func matches(intent: String, recentTools: [String], message: String, modelName: String = "") -> [FailurePattern] {
        guard let db else { return [] }
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (intent as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, cutoff)
        sqlite3_bind_text(stmt, 3, (modelName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (modelName as NSString).utf8String, -1, nil)
        let now = Date()
        let decayThreshold: TimeInterval = 14 * 86400
        var results: [FailurePattern] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let successCount = Int(sqlite3_column_int(stmt, 8))
            let freq = Int(sqlite3_column_int(stmt, 7))
            // Skip patterns already confirmed as fixed (success rate > 60%)
            if successCount > 0 && freq > 0 && Double(successCount) / Double(freq) > 0.6 {
                continue
            }
            let pt = String(cString: sqlite3_column_text(stmt, 3))
            let pk = String(cString: sqlite3_column_text(stmt, 4))
            let tools = pt.isEmpty ? [] : pt.components(separatedBy: ",")
            let keywords = pk.isEmpty ? [] : pk.components(separatedBy: ",")
            let toolOverlap = !tools.isEmpty && tools.contains(where: { recentTools.contains($0) })
            // Use token similarity for keyword matching (P2: better than pure substring)
            let messageTokens = Self.tokenize(message)
            let keywordTokens = keywords.reduce(into: Set<String>()) { $0.formUnion(Self.tokenize($1)) }
            let sim = Self.similarity(messageTokens, keywordTokens)
            let keywordMatch = sim > 0.15 || (!keywords.isEmpty && keywords.contains(where: { message.localizedCaseInsensitiveContains($0) }))
            if toolOverlap || keywordMatch {
                let lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                let age = now.timeIntervalSince(lastSeen)
                // Deprioritize stale patterns (>14 days) — only include if frequency is high
                if age > decayThreshold && freq < 4 { continue }
                results.append(FailurePattern(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    patternHash: String(cString: sqlite3_column_text(stmt, 1)),
                    intent: String(cString: sqlite3_column_text(stmt, 2)),
                    triggerTools: tools,
                    triggerKeywords: keywords,
                    rootCause: String(cString: sqlite3_column_text(stmt, 5)),
                    preemptiveInstruction: String(cString: sqlite3_column_text(stmt, 6)),
                    frequency: freq,
                    successAfterFix: successCount > 0,
                    lastSeen: lastSeen
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Mark a pattern as having led to success after its preemptive instruction was applied.
    public func markSuccess(patternHash: String) {
        queue.async { [weak self] in
            guard let self, let db else { return }
            let sql = "UPDATE failure_patterns SET success_after_fix = success_after_fix + 1 WHERE pattern_hash = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (patternHash as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
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
        var i = 0
        while i < chars.count - 1 {
            if chars[i].value >= 0x4E00 && chars[i].value <= 0x9FFF {
                let bigram = String(chars[i]) + String(chars[i + 1])
                tokens.insert(bigram)
                i += 1
            }
            i += 1
        }
        return tokens
    }

    /// Compute Jaccard similarity between two token sets.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    /// Return top failure patterns by frequency for self-improvement analysis.
    public func topPatterns(limit: Int = 5) -> [PatternSummary] {
        guard let db else { return [] }
        let sql = "SELECT intent, trigger_tools, root_cause, preemptive_instruction, frequency, success_after_fix FROM failure_patterns ORDER BY frequency DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [PatternSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(PatternSummary(
                intent: String(cString: sqlite3_column_text(stmt, 0)),
                triggerTools: String(cString: sqlite3_column_text(stmt, 1)),
                rootCause: String(cString: sqlite3_column_text(stmt, 2)),
                preemptiveInstruction: String(cString: sqlite3_column_text(stmt, 3)),
                frequency: Int(sqlite3_column_int(stmt, 4)),
                successAfterFix: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        sqlite3_finalize(stmt)
        return results
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
        let intentString = thread.source == .session ? "chat" : inferIntent(from: thread)
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
        if thread.workflowName != nil { return "workflow:\(thread.workflowName!)" }
        let hasTools = thread.steps.contains { $0.kind == .toolCall }
        return hasTools ? "task" : "chat"
    }

    private static func extractKeywords(from thread: Thread) -> [String] {
        // Use first user input and title as keywords for pattern matching
        var keywords: [String] = []
        if !thread.title.isEmpty && thread.title != "新会话" {
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
                for t in failedTools { counts[t, default: 0] += 1 }
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
