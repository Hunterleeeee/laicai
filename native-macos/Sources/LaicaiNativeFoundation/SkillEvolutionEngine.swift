import Foundation
import LaicaiNativeDomain

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Learned Skill (DB-backed, evolvable)

/// A skill automatically extracted from a successful task and stored in SQLite.
/// Evolved over time with Q-value updates from subsequent task outcomes.
public struct LearnedSkill: Identifiable, Sendable {
    public let id: Int
    public var name: String
    public var intentPattern: String
    public var toolSequence: [String]
    public var strategy: String
    public var modelName: String
    public var qValue: Double
    public var usageCount: Int
    public var successCount: Int
    public var lastUsed: Date
    public var createdAt: Date

    public var successRate: Double {
        guard usageCount > 0 else { return 0 }
        return Double(successCount) / Double(usageCount)
    }
}

public struct SkillExtractionRequest: Sendable {
    public let taskTitle: String
    public let intent: String
    public let toolsUsed: [String]
    public let modelName: String
    public let outcomeScore: Int
    public let strategy: String

    public init(
        taskTitle: String,
        intent: String,
        toolsUsed: [String],
        modelName: String,
        outcomeScore: Int,
        strategy: String = ""
    ) {
        self.taskTitle = taskTitle
        self.intent = intent
        self.toolsUsed = toolsUsed
        self.modelName = modelName
        self.outcomeScore = outcomeScore
        self.strategy = strategy
    }
}

private struct SkillMatchCandidate {
    let skill: LearnedSkill
    let score: Double
    let overlap: Int
    let toolBonus: Double
}

// MARK: - Skill Evolution Engine

/// Automatically extracts reusable skills from successful task outcomes,
/// stores them in SQLite, and evolves them via Q-value updates.
/// Inspired by Hermes Agent's auto-skill-creation and OpenClaw's Q-learning.
public final class SkillEvolutionEngine {
    public static let shared = SkillEvolutionEngine()

    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "laicai.skill-evolution", qos: .utility)
    private let path: String

    /// Q-value learning rate
    private let alpha: Double = 0.15
    /// Q-value discount factor
    private let gamma: Double = 0.9
    /// Minimum outcome score to consider a task worth extracting a skill from
    private let extractionThreshold: Int = 70
    /// Maximum number of learned skills to keep
    private let maxSkills: Int = 200

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("skill_evolution.sqlite3")
        open()
        migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    private func open() {
        if sqlite3_open(path, &database) != SQLITE_OK {
            database = nil
        }
    }

    private func exec(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func migrate() {
        exec(
            """
            CREATE TABLE IF NOT EXISTS learned_skills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                intent_pattern TEXT NOT NULL,
                tool_sequence TEXT NOT NULL DEFAULT '',
                strategy TEXT NOT NULL DEFAULT '',
                model_name TEXT NOT NULL DEFAULT '',
                q_value REAL NOT NULL DEFAULT 0.5,
                usage_count INTEGER NOT NULL DEFAULT 0,
                success_count INTEGER NOT NULL DEFAULT 0,
                last_used REAL NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_skill_intent ON learned_skills(intent_pattern);")
        exec("CREATE INDEX IF NOT EXISTS idx_skill_qvalue ON learned_skills(q_value);")
        exec("CREATE INDEX IF NOT EXISTS idx_skill_model ON learned_skills(model_name);")
    }

    // MARK: - Skill Extraction

    /// Extract a reusable skill from a successful task.
    /// Only called when outcome score exceeds extractionThreshold.
    public func extractSkill(_ request: SkillExtractionRequest) {
        guard request.outcomeScore >= extractionThreshold else { return }
        guard !request.toolsUsed.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, let database else { return }
            let now = Date().timeIntervalSince1970

            // Check if a similar skill already exists (same intent + overlapping tools)
            let checkSQL = """
                SELECT id, tool_sequence, q_value, usage_count, success_count FROM learned_skills
                WHERE intent_pattern = ? AND model_name = ?
                ORDER BY q_value DESC LIMIT 5;
                """
            var checkStmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text_safe(checkStmt, 1, request.intent)
            sqlite3_bind_text_safe(checkStmt, 2, request.modelName)

            var existingID: Int?
            while sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingTools = String(cString: sqlite3_column_text(checkStmt, 1))
                    .components(separatedBy: ",")
                    .filter { !$0.isEmpty }
                let overlap = Set(request.toolsUsed).intersection(existingTools)
                if Double(overlap.count) / Double(max(request.toolsUsed.count, 1)) > 0.6 {
                    existingID = Int(sqlite3_column_int(checkStmt, 0))
                    break
                }
            }
            sqlite3_finalize(checkStmt)

            if let existingID {
                // Reinforce existing skill — update Q-value and counts
                let reward = Double(request.outcomeScore) / 100.0
                let updateSQL = """
                    UPDATE learned_skills SET
                        q_value = q_value + ? * (? + ? * q_value - q_value),
                        usage_count = usage_count + 1,
                        success_count = success_count + 1,
                        last_used = ?
                    WHERE id = ?;
                    """
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(database, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_double(updateStmt, 1, self.alpha)
                sqlite3_bind_double(updateStmt, 2, reward)
                sqlite3_bind_double(updateStmt, 3, self.gamma)
                sqlite3_bind_double(updateStmt, 4, now)
                sqlite3_bind_int(updateStmt, 5, Int32(existingID))
                sqlite3_step(updateStmt)
                sqlite3_finalize(updateStmt)
            } else {
                // Create new learned skill
                let toolStr = request.toolsUsed.joined(separator: ",")
                let skillName = self.generateSkillName(title: request.taskTitle, tools: request.toolsUsed)
                let insertSQL = """
                    INSERT INTO learned_skills (
                        name, intent_pattern, tool_sequence, strategy, model_name, q_value,
                        usage_count, success_count, last_used, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?);
                    """
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(database, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_text_safe(insertStmt, 1, skillName)
                sqlite3_bind_text_safe(insertStmt, 2, request.intent)
                sqlite3_bind_text_safe(insertStmt, 3, toolStr)
                sqlite3_bind_text_safe(insertStmt, 4, request.strategy)
                sqlite3_bind_text_safe(insertStmt, 5, request.modelName)
                sqlite3_bind_double(insertStmt, 6, Double(request.outcomeScore) / 100.0)
                sqlite3_bind_double(insertStmt, 7, now)
                sqlite3_bind_double(insertStmt, 8, now)
                sqlite3_step(insertStmt)
                sqlite3_finalize(insertStmt)

                // Prune if over limit
                self.pruneIfNeeded()
            }
        }
    }

    // MARK: - Skill Retrieval

    /// Find the best matching learned skill for a given intent and model.
    /// Uses exact intent match plus token similarity for fuzzy matching.
    public func bestSkill(intent: String, modelName: String = "", message: String = "", minQ: Double = 0.3) -> LearnedSkill? {
        guard let database else { return nil }
        let sql = """
            SELECT id, name, intent_pattern, tool_sequence, strategy, model_name,
                   q_value, usage_count, success_count, last_used, created_at
            FROM learned_skills
            WHERE intent_pattern = ? AND q_value >= ?
                  AND (model_name = '' OR model_name = ?)
            ORDER BY CASE WHEN model_name = ? THEN 0 ELSE 1 END, q_value DESC
            LIMIT 20;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text_safe(stmt, 1, intent)
        sqlite3_bind_double(stmt, 2, minQ)
        sqlite3_bind_text_safe(stmt, 3, modelName)
        sqlite3_bind_text_safe(stmt, 4, modelName)

        var candidates: [LearnedSkill] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            candidates.append(
                LearnedSkill(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    intentPattern: String(cString: sqlite3_column_text(stmt, 2)),
                    toolSequence: String(cString: sqlite3_column_text(stmt, 3)).components(separatedBy: ",").filter { !$0.isEmpty },
                    strategy: String(cString: sqlite3_column_text(stmt, 4)),
                    modelName: String(cString: sqlite3_column_text(stmt, 5)),
                    qValue: sqlite3_column_double(stmt, 6),
                    usageCount: Int(sqlite3_column_int(stmt, 7)),
                    successCount: Int(sqlite3_column_int(stmt, 8)),
                    lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                ))
        }
        sqlite3_finalize(stmt)
        guard !candidates.isEmpty else { return nil }

        let messageTokens = Self.matchTokens(in: message)
        // Reject chitchat-derived skills: the patterns "你是谁", "你能", "你好" etc.
        // produced "skills" from interactions with no real domain — they tend to
        // accidentally match unrelated tasks just by their high Q value.
        let chitChatPrefixes = ["你是", "你能", "你会", "你好", "你叫", "你来", "你看", "继续", "再丰富", "好，加入", "这就完了", "为什么"]
        let cleanCandidates = candidates.filter { skill in
            !chitChatPrefixes.contains(where: { skill.name.hasPrefix($0) })
        }
        let pool = cleanCandidates.isEmpty ? candidates : cleanCandidates
        if messageTokens.isEmpty {
            return pool.first { $0.successRate >= 0.65 && $0.usageCount >= 2 }
        }
        return
            pool
            .map { skill -> SkillMatchCandidate in
                let skillTokens = Self.matchTokens(in: [skill.name, skill.strategy, skill.toolSequence.joined(separator: " ")].joined(separator: " "))
                let overlapCount = messageTokens.intersection(skillTokens).count
                let denominator = Double(max(1, min(messageTokens.count, 8)))
                let semanticScore = Double(overlapCount) / denominator
                let toolBonus = Self.toolIntentBonus(skill: skill, message: message)
                let score = semanticScore + toolBonus + min(skill.qValue, 2.0) * 0.05
                return SkillMatchCandidate(
                    skill: skill,
                    score: score,
                    overlap: overlapCount,
                    toolBonus: toolBonus
                )
            }
            .filter { entry in
                // Stricter gates:
                // - Require at least 1 real token overlap (prevents Q-only matches)
                // - AND either composite score >= 0.40 OR strong tool keyword bonus >= 0.35
                guard entry.overlap >= 1 else { return false }
                return entry.score >= 0.40 || entry.toolBonus >= 0.35
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.skill.qValue > rhs.skill.qValue }
                return lhs.score > rhs.score
            }
            .first?.skill
    }

    // MARK: - Q-Value Update (feedback loop)

    /// Update Q-value for a skill based on task outcome.
    /// Called after a task that used a learned skill completes.
    public func updateQ(skillID: Int, outcomeScore: Int, succeeded: Bool) {
        queue.async { [weak self] in
            guard let self, let database else { return }
            let reward = Double(outcomeScore) / 100.0
            let now = Date().timeIntervalSince1970
            let sql = """
                UPDATE learned_skills SET
                    q_value = q_value + ? * (? + ? * q_value - q_value),
                    usage_count = usage_count + 1,
                    success_count = success_count + CASE WHEN ? THEN 1 ELSE 0 END,
                    last_used = ?
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, self.alpha)
            sqlite3_bind_double(stmt, 2, reward)
            sqlite3_bind_double(stmt, 3, self.gamma)
            sqlite3_bind_int(stmt, 4, succeeded ? 1 : 0)
            sqlite3_bind_double(stmt, 5, now)
            sqlite3_bind_int(stmt, 6, Int32(skillID))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Penalize a skill when a task using it fails.
    public func penalize(skillID: Int) {
        queue.async { [weak self] in
            guard let self, let database else { return }
            let sql = """
                UPDATE learned_skills SET
                    q_value = MAX(0, q_value - ?),
                    usage_count = usage_count + 1,
                    last_used = ?
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, self.alpha * 0.5)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(skillID))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Stats

    /// Returns all learned skills, sorted by Q-value.
    public func allSkills(limit: Int = 50) -> [LearnedSkill] {
        guard let database else { return [] }
        let sql = """
            SELECT id, name, intent_pattern, tool_sequence, strategy, model_name,
                   q_value, usage_count, success_count, last_used, created_at
            FROM learned_skills
            ORDER BY q_value DESC
            LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [LearnedSkill] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                LearnedSkill(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    intentPattern: String(cString: sqlite3_column_text(stmt, 2)),
                    toolSequence: String(cString: sqlite3_column_text(stmt, 3)).components(separatedBy: ",").filter { !$0.isEmpty },
                    strategy: String(cString: sqlite3_column_text(stmt, 4)),
                    modelName: String(cString: sqlite3_column_text(stmt, 5)),
                    qValue: sqlite3_column_double(stmt, 6),
                    usageCount: Int(sqlite3_column_int(stmt, 7)),
                    successCount: Int(sqlite3_column_int(stmt, 8)),
                    lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                ))
        }
        sqlite3_finalize(stmt)
        return rows
    }

    // MARK: - Private

    private func generateSkillName(title: String, tools: [String]) -> String {
        let toolPart = tools.prefix(3).joined(separator: "+")
        let titlePart = String(title.prefix(20))
        return "\(titlePart)[\(toolPart)]"
    }

    private static func matchTokens(in text: String) -> Set<String> {
        let lower = text.lowercased()
        var tokens = Set<String>()
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).inverted
        for token in lower.components(separatedBy: separators) where token.count >= 2 {
            tokens.insert(token)
        }
        let phraseTokens = ["wiki", "知识库", "整理", "整理到", "笔记", "附件", "读取", "表格", "xlsx", "excel", "搜索", "修改", "创建", "修复", "代码", "文件"]
        for token in phraseTokens where lower.contains(token) {
            tokens.insert(token)
        }
        return tokens
    }

    private static func toolIntentBonus(skill: LearnedSkill, message: String) -> Double {
        let lower = message.lowercased()
        let tools = Set(skill.toolSequence.map { ToolNameCodec.canonicalName($0) })
        var bonus = 0.0
        if (lower.contains("wiki") || lower.contains("知识库") || lower.contains("整理到")) && tools.contains("wiki.build") {
            bonus += 0.45
        }
        if (lower.contains("xlsx") || lower.contains("excel") || lower.contains("表格")) && tools.contains("file.extract") {
            bonus += 0.35
        }
        if (lower.contains("搜索") || lower.contains("查找") || lower.contains("search")) && tools.contains("code.search") {
            bonus += 0.20
        }
        if (lower.contains("修改") || lower.contains("修复") || lower.contains("改")) && (tools.contains("file.edit") || tools.contains("file.write")) {
            bonus += 0.25
        }
        return bonus
    }

    private func pruneIfNeeded() {
        guard let database else { return }
        // Count total
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM learned_skills;", -1, &countStmt, nil) == SQLITE_OK else { return }
        guard sqlite3_step(countStmt) == SQLITE_ROW else {
            sqlite3_finalize(countStmt)
            return
        }
        let count = Int(sqlite3_column_int(countStmt, 0))
        sqlite3_finalize(countStmt)

        if count > maxSkills {
            // Delete the weakest (low Q, old, unused) skills
            let toDelete = count - maxSkills + 10  // delete a small buffer
            var deleteStmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    database,
                    """
                    DELETE FROM learned_skills WHERE id IN (
                        SELECT id FROM learned_skills
                        ORDER BY q_value ASC, last_used ASC
                        LIMIT ?
                    );
                    """, -1, &deleteStmt, nil) == SQLITE_OK
            else { return }
            sqlite3_bind_int(deleteStmt, 1, Int32(toDelete))
            sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
    }
}
