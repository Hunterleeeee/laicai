import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Legacy Database Migrator
// Handles one-time import of data from the 8 legacy SQLite databases
// into the unified database. Safe to run multiple times (idempotent).

public struct LegacyMigrator {

    /// Run all legacy imports. Returns a summary of what was imported.
    @discardableResult
    public static func migrateAll(unifiedDB: UnifiedDatabase = .shared) -> [String: Int] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("Laicai")
        var results: [String: Int] = [:]

        // 1. store.sqlite3 → tasks, memories, connectors
        let storePath = (dir as NSString).appendingPathComponent("store.sqlite3")
        results["store"] = unifiedDB.importLegacy(sourceDB: storePath, tableMappings: [
            (source: "tasks", target: "tasks", columns: "id, title, status, connector_id, context_json, steps_json, created_at, updated_at"),
            (source: "memories", target: "memories", columns: "workspace, category, key, value, created_at, updated_at"),
            (source: "connectors", target: "connectors", columns: "id, name, config_json, created_at"),
        ])

        // 2. outcomes.sqlite3 → task_outcomes, tool_outcomes
        let outcomesPath = (dir as NSString).appendingPathComponent("outcomes.sqlite3")
        results["outcomes"] = unifiedDB.importLegacy(sourceDB: outcomesPath, tableMappings: [
            (source: "task_outcomes", target: "task_outcomes", columns: "task_id, intent, model_name, status, iterations, duration_seconds, score, had_failure, was_cancelled, was_truncated, created_at"),
            (source: "tool_outcomes", target: "tool_outcomes", columns: "task_id, tool_name, model_name, success, duration_seconds, was_retry, created_at"),
        ])

        // 3. skill_evolution.sqlite3 → skills
        let skillPath = (dir as NSString).appendingPathComponent("skill_evolution.sqlite3")
        results["skills"] = unifiedDB.importLegacy(sourceDB: skillPath, tableMappings: [
            (source: "skills", target: "skills", columns: "name, intent, strategy, tool_sequence, success_rate, q_value, usage_count, model_name, keywords, created_at, updated_at"),
        ])

        // 4. memory.db → semantic_memories
        let memoryPath = (dir as NSString).appendingPathComponent("memory.db")
        results["memory"] = unifiedDB.importLegacy(sourceDB: memoryPath, tableMappings: [
            (source: "memories", target: "semantic_memories", columns: "content, category, source, importance, access_count, created_at"),
        ])

        // 5. patterns.sqlite3 → failure_patterns
        let patternsPath = (dir as NSString).appendingPathComponent("patterns.sqlite3")
        results["patterns"] = unifiedDB.importLegacy(sourceDB: patternsPath, tableMappings: [
            (source: "failure_patterns", target: "failure_patterns", columns: "pattern_hash, intent, trigger_tools, trigger_keywords, root_cause, preemptive_instruction, model_name, hit_count, last_hit, created_at"),
        ])

        // 6. audit.sqlite3 → audit_log
        let auditPath = (dir as NSString).appendingPathComponent("audit.sqlite3")
        results["audit"] = unifiedDB.importLegacy(sourceDB: auditPath, tableMappings: [
            (source: "audit_log", target: "audit_log", columns: "id, timestamp, event_type, tool_name, details, risk_level"),
        ])

        // 7. self_improvement.sqlite3 → improvements
        let improvePath = (dir as NSString).appendingPathComponent("self_improvement.sqlite3")
        results["improvements"] = unifiedDB.importLegacy(sourceDB: improvePath, tableMappings: [
            (source: "improvements", target: "improvements", columns: "category, observation, suggestion, status, created_at"),
        ])

        // 8. goals.sqlite3 → goals
        let goalsPath = (dir as NSString).appendingPathComponent("goals.sqlite3")
        results["goals"] = unifiedDB.importLegacy(sourceDB: goalsPath, tableMappings: [
            (source: "goals", target: "goals", columns: "id, title, description, status, priority, parent_id, metadata_json, created_at, updated_at"),
        ])

        return results
    }

    /// Check if legacy migration has been completed for all known databases.
    public static func isFullyMigrated(unifiedDB: UnifiedDatabase = .shared) -> Bool {
        let expectedSources = [
            "store.sqlite3", "outcomes.sqlite3", "skill_evolution.sqlite3",
            "memory.db", "patterns.sqlite3", "audit.sqlite3",
            "self_improvement.sqlite3", "goals.sqlite3"
        ]
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("Laicai")

        for source in expectedSources {
            let sourcePath = (dir as NSString).appendingPathComponent(source)
            guard FileManager.default.fileExists(atPath: sourcePath) else { continue }
            var imported = false
            unifiedDB.query("SELECT 1 FROM _legacy_imports WHERE source_db = ?", bind: { stmt in
                sqlite3_bind_text(stmt, 1, (sourcePath as NSString).utf8String, -1, nil)
            }) { _ in
                imported = true
            }
            if !imported { return false }
        }
        return true
    }
}
