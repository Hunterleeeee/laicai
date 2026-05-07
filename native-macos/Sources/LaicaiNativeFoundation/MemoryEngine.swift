import Foundation
import SQLite3
import LaicaiNativeDomain

// MARK: - Memory Entry

public struct MemoryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public var kind: Kind
    public var content: String
    public var summary: String?
    public var source: String          // e.g. "task:uuid", "chat:uuid", "user"
    public var tags: [String]
    public var score: Double           // relevance boost; user-pinned = high
    public var createdAt: Date
    public var accessedAt: Date
    public var accessCount: Int

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fact         // extracted knowledge
        case preference   // user preference
        case outcome      // task outcome summary
        case skill        // learned skill pattern
        case note         // user-pinned note
    }

    public init(
        id: UUID = UUID(),
        kind: Kind = .fact,
        content: String,
        summary: String? = nil,
        source: String = "",
        tags: [String] = [],
        score: Double = 1.0,
        createdAt: Date = Date(),
        accessedAt: Date = Date(),
        accessCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.summary = summary
        self.source = source
        self.tags = tags
        self.score = score
        self.createdAt = createdAt
        self.accessedAt = accessedAt
        self.accessCount = accessCount
    }
}

// MARK: - Memory Engine (FTS5 backed)

@MainActor
public final class MemoryEngine: ObservableObject {
    public static let shared = MemoryEngine()

    @Published public private(set) var entryCount: Int = 0
    @Published public private(set) var lastRecallResults: [MemoryEntry] = []

    private var db: OpaquePointer?
    private var isOpen = false

    private init() {}

    // MARK: - Open / Close

    public func open(dataDir: String? = nil) {
        guard !isOpen else { return }
        let dir = dataDir ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
            return (appSupport as NSString).appendingPathComponent("Laicai")
        }()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = (dir as NSString).appendingPathComponent("memory.db")

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        isOpen = true
        createTables()
        refreshCount()
    }

    public func close() {
        guard isOpen else { return }
        sqlite3_close(db)
        db = nil
        isOpen = false
    }

    private func createTables() {
        // Main table
        exec("""
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL DEFAULT 'fact',
                content TEXT NOT NULL,
                summary TEXT,
                source TEXT DEFAULT '',
                tags TEXT DEFAULT '',
                score REAL DEFAULT 1.0,
                created_at REAL NOT NULL,
                accessed_at REAL NOT NULL,
                access_count INTEGER DEFAULT 0
            )
        """)

        // FTS5 virtual table for full-text search
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                content, summary, tags,
                content='memories',
                content_rowid='rowid'
            )
        """)

        // Triggers to keep FTS in sync
        exec("""
            CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
                INSERT INTO memories_fts(rowid, content, summary, tags)
                VALUES (new.rowid, new.content, new.summary, new.tags);
            END
        """)
        exec("""
            CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, content, summary, tags)
                VALUES ('delete', old.rowid, old.content, old.summary, old.tags);
            END
        """)
        exec("""
            CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, content, summary, tags)
                VALUES ('delete', old.rowid, old.content, old.summary, old.tags);
                INSERT INTO memories_fts(rowid, content, summary, tags)
                VALUES (new.rowid, new.content, new.summary, new.tags);
            END
        """)
    }

    // MARK: - Store

    @discardableResult
    public func store(_ entry: MemoryEntry) -> Bool {
        guard isOpen else { return false }
        let sql = """
            INSERT OR REPLACE INTO memories (id, kind, content, summary, source, tags, score, created_at, accessed_at, access_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, entry.kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, entry.content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let summary = entry.summary {
            sqlite3_bind_text(stmt, 4, summary, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, entry.source, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 6, entry.tags.joined(separator: ","), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 7, entry.score)
        sqlite3_bind_double(stmt, 8, entry.createdAt.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(stmt, 9, entry.accessedAt.timeIntervalSinceReferenceDate)
        sqlite3_bind_int(stmt, 10, Int32(entry.accessCount))

        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if ok { refreshCount() }
        return ok
    }

    // MARK: - Recall (FTS5 search)

    public func recall(query: String, limit: Int = 10) -> [MemoryEntry] {
        guard isOpen, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Sanitize query for FTS5
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = sanitized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let ftsQuery = terms.map { "\"\($0)\"" }.joined(separator: " OR ")

        let sql = """
            SELECT m.id, m.kind, m.content, m.summary, m.source, m.tags, m.score,
                   m.created_at, m.accessed_at, m.access_count,
                   bm25(memories_fts) as rank
            FROM memories m
            JOIN memories_fts f ON f.rowid = m.rowid
            WHERE memories_fts MATCH ?
            ORDER BY (rank * m.score) ASC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [MemoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = readEntry(from: stmt) else { continue }
            results.append(entry)
        }

        // Update access timestamps
        for entry in results {
            bumpAccess(id: entry.id)
        }

        lastRecallResults = results
        return results
    }

    // MARK: - Keyword recall (simple LIKE fallback)

    public func recallByKeyword(_ keyword: String, limit: Int = 10) -> [MemoryEntry] {
        guard isOpen else { return [] }
        let sql = """
            SELECT id, kind, content, summary, source, tags, score, created_at, accessed_at, access_count
            FROM memories
            WHERE content LIKE ? OR summary LIKE ? OR tags LIKE ?
            ORDER BY score DESC, accessed_at DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(keyword)%"
        for i: Int32 in 1...3 {
            sqlite3_bind_text(stmt, i, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int(stmt, 4, Int32(limit))

        var results: [MemoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = readEntry(from: stmt) else { continue }
            results.append(entry)
        }
        return results
    }

    // MARK: - Recent memories

    public func recent(limit: Int = 20) -> [MemoryEntry] {
        guard isOpen else { return [] }
        let sql = """
            SELECT id, kind, content, summary, source, tags, score, created_at, accessed_at, access_count
            FROM memories ORDER BY created_at DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [MemoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = readEntry(from: stmt) else { continue }
            results.append(entry)
        }
        return results
    }

    // MARK: - Delete

    public func delete(id: UUID) {
        guard isOpen else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM memories WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text_safe(stmt, 1, id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        refreshCount()
    }

    public func deleteOlderThan(days: Int) {
        guard isOpen else { return }
        let cutoff = Date().addingTimeInterval(Double(-days * 86400)).timeIntervalSinceReferenceDate
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM memories WHERE score < ? AND accessed_at < ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, 5.0)
        sqlite3_bind_double(stmt, 2, cutoff)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        refreshCount()
    }

    // MARK: - Auto-extract from task

    public func extractFromTask(_ task: AgentTask) {
        // Extract outcome summary
        let toolNames = task.steps
            .filter { $0.kind == .toolCall }
            .compactMap { $0.toolName }
        let uniqueTools = Array(Set(toolNames))
        let stepCount = task.steps.count
        let succeeded = task.status == .completed

        let taskTitle = task.title.isEmpty ? "无标题" : task.title
        let summary = """
        任务「\(taskTitle)」\(succeeded ? "成功" : "失败")完成，\
        共 \(stepCount) 步，使用工具：\(uniqueTools.joined(separator: ", "))
        """

        store(MemoryEntry(
            kind: .outcome,
            content: summary,
            summary: taskTitle,
            source: "task:\(task.id)",
            tags: uniqueTools + [succeeded ? "success" : "failure"],
            score: succeeded ? 2.0 : 1.0
        ))

        // Extract key decisions / patterns
        let textSteps = task.steps.filter { $0.kind == .textOutput }
        let longTexts = textSteps.filter { $0.text.count > 200 }
        for step in longTexts.prefix(3) {
            let excerpt = String(step.text.prefix(500))
            store(MemoryEntry(
                kind: .fact,
                content: excerpt,
                source: "task:\(task.id)",
                tags: uniqueTools
            ))
        }
    }

    // MARK: - Context integration

    /// Build memory context string for system prompt injection
    public func buildMemoryContext(for query: String, maxTokens: Int = 2000) -> String? {
        let results = recall(query: query, limit: 8)
        guard !results.isEmpty else { return nil }

        var parts: [String] = ["## 来财记忆"]
        var totalLen = 0
        let charBudget = maxTokens * 3 // rough token→char

        for entry in results {
            let text = entry.summary ?? String(entry.content.prefix(300))
            if totalLen + text.count > charBudget { break }
            let kindLabel: String
            switch entry.kind {
            case .fact: kindLabel = "知识"
            case .preference: kindLabel = "偏好"
            case .outcome: kindLabel = "历史"
            case .skill: kindLabel = "技能"
            case .note: kindLabel = "笔记"
            }
            parts.append("- [\(kindLabel)] \(text)")
            totalLen += text.count
        }

        return parts.count > 1 ? parts.joined(separator: "\n") : nil
    }

    // MARK: - User preferences

    public func storePreference(key: String, value: String) {
        // Check if exists
        let existing = recallByKeyword("偏好:\(key)", limit: 1)
        if let old = existing.first {
            delete(id: old.id)
        }
        store(MemoryEntry(
            kind: .preference,
            content: "偏好:\(key) = \(value)",
            tags: ["preference", key],
            score: 10.0 // preferences are high priority
        ))
    }

    // MARK: - Stats

    public var stats: (total: Int, facts: Int, outcomes: Int, preferences: Int) {
        guard isOpen else { return (0, 0, 0, 0) }
        let total = countWhere(nil)
        let facts = countWhere("kind = 'fact'")
        let outcomes = countWhere("kind = 'outcome'")
        let prefs = countWhere("kind = 'preference'")
        return (total, facts, outcomes, prefs)
    }

    // MARK: - Internals

    private func readEntry(from stmt: OpaquePointer?) -> MemoryEntry? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let kindStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let kind = MemoryEntry.Kind(rawValue: kindStr),
              let content = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else { return nil }

        let summary = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let source = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let tagsStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let tags = tagsStr.components(separatedBy: ",").filter { !$0.isEmpty }
        let score = sqlite3_column_double(stmt, 6)
        let createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7))
        let accessedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
        let accessCount = Int(sqlite3_column_int(stmt, 9))

        return MemoryEntry(
            id: id, kind: kind, content: content, summary: summary,
            source: source, tags: tags, score: score,
            createdAt: createdAt, accessedAt: accessedAt, accessCount: accessCount
        )
    }

    private func bumpAccess(id: UUID) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE memories SET accessed_at = ?, access_count = access_count + 1 WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
        sqlite3_bind_text_safe(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func refreshCount() {
        entryCount = countWhere(nil)
    }

    private func countWhere(_ condition: String?) -> Int {
        guard isOpen else { return 0 }
        let sql: String
        switch condition {
        case "kind = 'fact'":
            sql = "SELECT COUNT(*) FROM memories WHERE kind = 'fact'"
        case "kind = 'outcome'":
            sql = "SELECT COUNT(*) FROM memories WHERE kind = 'outcome'"
        case "kind = 'preference'":
            sql = "SELECT COUNT(*) FROM memories WHERE kind = 'preference'"
        default:
            sql = "SELECT COUNT(*) FROM memories"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
