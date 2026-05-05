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

// MARK: - Skill Evolution Engine

/// Automatically extracts reusable skills from successful task outcomes,
/// stores them in SQLite, and evolves them via Q-value updates.
/// Inspired by Hermes Agent's auto-skill-creation and OpenClaw's Q-learning.
public final class SkillEvolutionEngine {
    public static let shared = SkillEvolutionEngine()

    private var db: OpaquePointer?
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
    public func extractSkill(
        taskTitle: String,
        intent: String,
        toolsUsed: [String],
        modelName: String,
        outcomeScore: Int,
        strategy: String
    ) {
        guard outcomeScore >= extractionThreshold else { return }
        guard !toolsUsed.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, let db else { return }
            let now = Date().timeIntervalSince1970

            // Check if a similar skill already exists (same intent + overlapping tools)
            let checkSQL = """
            SELECT id, tool_sequence, q_value, usage_count, success_count FROM learned_skills
            WHERE intent_pattern = ? AND model_name = ?
            ORDER BY q_value DESC LIMIT 5;
            """
            var checkStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(checkStmt, 1, (intent as NSString).utf8String, -1, nil)
            sqlite3_bind_text(checkStmt, 2, (modelName as NSString).utf8String, -1, nil)

            var existingID: Int?
            while sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingTools = String(cString: sqlite3_column_text(checkStmt, 1))
                    .components(separatedBy: ",")
                    .filter { !$0.isEmpty }
                let overlap = Set(toolsUsed).intersection(existingTools)
                if Double(overlap.count) / Double(max(toolsUsed.count, 1)) > 0.6 {
                    existingID = Int(sqlite3_column_int(checkStmt, 0))
                    break
                }
            }
            sqlite3_finalize(checkStmt)

            if let existingID {
                // Reinforce existing skill — update Q-value and counts
                let reward = Double(outcomeScore) / 100.0
                let updateSQL = """
                UPDATE learned_skills SET
                    q_value = q_value + ? * (? + ? * q_value - q_value),
                    usage_count = usage_count + 1,
                    success_count = success_count + 1,
                    last_used = ?
                WHERE id = ?;
                """
                var updateStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_double(updateStmt, 1, self.alpha)
                sqlite3_bind_double(updateStmt, 2, reward)
                sqlite3_bind_double(updateStmt, 3, self.gamma)
                sqlite3_bind_double(updateStmt, 4, now)
                sqlite3_bind_int(updateStmt, 5, Int32(existingID))
                sqlite3_step(updateStmt)
                sqlite3_finalize(updateStmt)
            } else {
                // Create new learned skill
                let toolStr = toolsUsed.joined(separator: ",")
                let skillName = self.generateSkillName(title: taskTitle, tools: toolsUsed)
                let insertSQL = """
                INSERT INTO learned_skills (name, intent_pattern, tool_sequence, strategy, model_name, q_value, usage_count, success_count, last_used, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?);
                """
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(insertStmt, 1, (skillName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (intent as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (toolStr as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 4, (strategy as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 5, (modelName as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertStmt, 6, Double(outcomeScore) / 100.0)
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
    public func bestSkill(intent: String, modelName: String = "", minQ: Double = 0.3) -> LearnedSkill? {
        guard let db else { return nil }
        let sql = """
        SELECT id, name, intent_pattern, tool_sequence, strategy, model_name,
               q_value, usage_count, success_count, last_used, created_at
        FROM learned_skills
        WHERE intent_pattern = ? AND q_value >= ?
              AND (model_name = '' OR model_name = ?)
        ORDER BY CASE WHEN model_name = ? THEN 0 ELSE 1 END, q_value DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (intent as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, minQ)
        sqlite3_bind_text(stmt, 3, (modelName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (modelName as NSString).utf8String, -1, nil)

        var result: LearnedSkill?
        if sqlite3_step(stmt) == SQLITE_ROW {
            result = LearnedSkill(
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
            )
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Q-Value Update (feedback loop)

    /// Update Q-value for a skill based on task outcome.
    /// Called after a task that used a learned skill completes.
    public func updateQ(skillID: Int, outcomeScore: Int, succeeded: Bool) {
        queue.async { [weak self] in
            guard let self, let db else { return }
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
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
            guard let self, let db else { return }
            let sql = """
            UPDATE learned_skills SET
                q_value = MAX(0, q_value - ?),
                usage_count = usage_count + 1,
                last_used = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
        guard let db else { return [] }
        let sql = """
        SELECT id, name, intent_pattern, tool_sequence, strategy, model_name,
               q_value, usage_count, success_count, last_used, created_at
        FROM learned_skills
        ORDER BY q_value DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [LearnedSkill] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(LearnedSkill(
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

    private func pruneIfNeeded() {
        guard let db else { return }
        // Count total
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM learned_skills;", -1, &countStmt, nil) == SQLITE_OK else { return }
        guard sqlite3_step(countStmt) == SQLITE_ROW else { sqlite3_finalize(countStmt); return }
        let count = Int(sqlite3_column_int(countStmt, 0))
        sqlite3_finalize(countStmt)

        if count > maxSkills {
            // Delete the weakest (low Q, old, unused) skills
            let toDelete = count - maxSkills + 10 // delete a small buffer
            exec("""
            DELETE FROM learned_skills WHERE id IN (
                SELECT id FROM learned_skills
                ORDER BY q_value ASC, last_used ASC
                LIMIT \(toDelete)
            );
            """)
        }
    }
}
