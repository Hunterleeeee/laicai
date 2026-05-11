import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Unified Database
// Consolidates 8 separate SQLite databases into one:
//   store.sqlite3, outcomes.sqlite3, skill_evolution.sqlite3,
//   memory.db, patterns.sqlite3, audit.sqlite3,
//   self_improvement.sqlite3, goals.sqlite3
//
// Each former DB becomes a logical "schema" (table prefix) within the unified DB.
// Migration system ensures forward-compatible schema evolution.

public final class UnifiedDatabase: @unchecked Sendable {
    public static let shared = UnifiedDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "laicai.unified_db", qos: .utility)
    public let path: String

    // MARK: - Init

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("laicai_unified.sqlite3")
        open()
        runMigrations()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open / Close

    private func open() {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        // Performance pragmas
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA foreign_keys=ON")
    }

    // MARK: - Public API

    /// Execute a SQL statement (no results).
    @discardableResult
    public func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var ok = false
        queue.sync {
            ok = sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
        return ok
    }

    /// Execute a SQL query with a row handler.
    public func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil, row: (OpaquePointer) -> Void) {
        guard let db else { return }
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            bind?(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                row(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Execute a SQL statement with bind parameters, returning success.
    @discardableResult
    public func execute(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard let db else { return false }
        var ok = false
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            bind?(stmt)
            ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
        }
        return ok
    }

    /// Raw db pointer for advanced usage (must be used within queue.sync).
    public func withDB<T>(_ body: (OpaquePointer?) throws -> T) rethrows -> T {
        try queue.sync { try body(db) }
    }

    // MARK: - Migration System

    private func runMigrations() {
        // Create migration tracking table
        exec("""
        CREATE TABLE IF NOT EXISTS _migrations (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
        """)

        let currentVersion = getCurrentVersion()
        let migrations = allMigrations()

        for migration in migrations where migration.version > currentVersion {
            let success = exec(migration.sql)
            if success {
                execute("INSERT INTO _migrations (version, name) VALUES (?, ?)") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(migration.version))
                    sqlite3_bind_text(stmt, 2, (migration.name as NSString).utf8String, -1, nil)
                }
            } else {
                // Migration failed — stop here
                break
            }
        }
    }

    private func getCurrentVersion() -> Int {
        var version = 0
        query("SELECT MAX(version) FROM _migrations") { stmt in
            version = Int(sqlite3_column_int(stmt, 0))
        }
        return version
    }

    // MARK: - Migration Definitions

    struct Migration {
        let version: Int
        let name: String
        let sql: String
    }

    private func allMigrations() -> [Migration] {
        [
            // V1: Core store tables (from SQLiteRepository)
            Migration(version: 1, name: "core_store", sql: """
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    status TEXT,
                    connector_id TEXT,
                    context_json TEXT,
                    steps_json TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now'))
                );
                CREATE TABLE IF NOT EXISTS memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    workspace TEXT NOT NULL,
                    category TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now')),
                    UNIQUE(workspace, category, key)
                );
                CREATE INDEX IF NOT EXISTS idx_memories_workspace ON memories(workspace);
                CREATE TABLE IF NOT EXISTS connectors (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    config_json TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                );
            """),

            // V2: Task outcomes (from TaskOutcomeRecorder)
            Migration(version: 2, name: "task_outcomes", sql: """
                CREATE TABLE IF NOT EXISTS task_outcomes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL,
                    intent TEXT NOT NULL,
                    model_name TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL,
                    iterations INTEGER NOT NULL DEFAULT 0,
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    score INTEGER NOT NULL DEFAULT 0,
                    had_failure INTEGER NOT NULL DEFAULT 0,
                    was_cancelled INTEGER NOT NULL DEFAULT 0,
                    was_truncated INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_outcomes_intent ON task_outcomes(intent);
                CREATE INDEX IF NOT EXISTS idx_outcomes_model ON task_outcomes(model_name);

                CREATE TABLE IF NOT EXISTS tool_outcomes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    model_name TEXT NOT NULL DEFAULT '',
                    success INTEGER NOT NULL DEFAULT 0,
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    was_retry INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_tool_outcomes_tool ON tool_outcomes(tool_name);
            """),

            // V3: Skill evolution (from SkillEvolutionEngine)
            Migration(version: 3, name: "skill_evolution", sql: """
                CREATE TABLE IF NOT EXISTS skills (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    intent TEXT NOT NULL,
                    strategy TEXT NOT NULL DEFAULT '',
                    tool_sequence TEXT NOT NULL DEFAULT '[]',
                    success_rate REAL NOT NULL DEFAULT 0,
                    q_value REAL NOT NULL DEFAULT 0,
                    usage_count INTEGER NOT NULL DEFAULT 0,
                    model_name TEXT NOT NULL DEFAULT '',
                    keywords TEXT NOT NULL DEFAULT '',
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_skills_intent ON skills(intent);
            """),

            // V4: Memory engine (from MemoryEngine - memory.db)
            Migration(version: 4, name: "memory_engine", sql: """
                CREATE TABLE IF NOT EXISTS semantic_memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content TEXT NOT NULL,
                    embedding_json TEXT,
                    category TEXT NOT NULL DEFAULT 'general',
                    source TEXT NOT NULL DEFAULT '',
                    importance REAL NOT NULL DEFAULT 0.5,
                    access_count INTEGER NOT NULL DEFAULT 0,
                    last_accessed TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                );
            """),

            // V5: Failure patterns (from FailurePatternDB)
            Migration(version: 5, name: "failure_patterns", sql: """
                CREATE TABLE IF NOT EXISTS failure_patterns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pattern_hash TEXT NOT NULL UNIQUE,
                    intent TEXT NOT NULL,
                    trigger_tools TEXT NOT NULL DEFAULT '[]',
                    trigger_keywords TEXT NOT NULL DEFAULT '[]',
                    root_cause TEXT NOT NULL,
                    preemptive_instruction TEXT NOT NULL,
                    model_name TEXT NOT NULL DEFAULT '',
                    hit_count INTEGER NOT NULL DEFAULT 1,
                    last_hit TEXT DEFAULT (datetime('now')),
                    created_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_patterns_intent ON failure_patterns(intent);
            """),

            // V6: Security audit (from SecurityEngine)
            Migration(version: 6, name: "security_audit", sql: """
                CREATE TABLE IF NOT EXISTS audit_log (
                    id TEXT PRIMARY KEY,
                    timestamp TEXT NOT NULL DEFAULT (datetime('now')),
                    event_type TEXT NOT NULL,
                    tool_name TEXT,
                    details TEXT,
                    risk_level TEXT NOT NULL DEFAULT 'low'
                );
                CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp);
            """),

            // V7: Self-improvement (from SelfImprovementEngine)
            Migration(version: 7, name: "self_improvement", sql: """
                CREATE TABLE IF NOT EXISTS improvements (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    category TEXT NOT NULL,
                    observation TEXT NOT NULL,
                    suggestion TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT DEFAULT (datetime('now'))
                );
            """),

            // V8: Goals (from GoalEngine)
            Migration(version: 8, name: "goals", sql: """
                CREATE TABLE IF NOT EXISTS goals (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'active',
                    priority INTEGER NOT NULL DEFAULT 0,
                    parent_id TEXT,
                    metadata_json TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_goals_status ON goals(status);
            """),

            // V9: Data import markers
            Migration(version: 9, name: "import_markers", sql: """
                CREATE TABLE IF NOT EXISTS _legacy_imports (
                    source_db TEXT PRIMARY KEY,
                    imported_at TEXT DEFAULT (datetime('now')),
                    row_count INTEGER NOT NULL DEFAULT 0
                );
            """),
        ]
    }

    // MARK: - Legacy Import

    /// Import data from a legacy SQLite database file.
    /// Returns number of rows imported, or -1 on failure.
    public func importLegacy(sourceDB: String, tableMappings: [(source: String, target: String, columns: String)]) -> Int {
        // Check if already imported
        var alreadyImported = false
        query("SELECT 1 FROM _legacy_imports WHERE source_db = ?", bind: { stmt in
            sqlite3_bind_text(stmt, 1, (sourceDB as NSString).utf8String, -1, nil)
        }) { _ in
            alreadyImported = true
        }
        guard !alreadyImported else { return 0 }

        guard FileManager.default.fileExists(atPath: sourceDB) else { return -1 }

        // Attach legacy DB
        let attachSQL = "ATTACH DATABASE '\(sourceDB)' AS legacy"
        guard exec(attachSQL) else { return -1 }
        defer { exec("DETACH DATABASE legacy") }

        var totalRows = 0
        for mapping in tableMappings {
            let importSQL = "INSERT OR IGNORE INTO \(mapping.target) (\(mapping.columns)) SELECT \(mapping.columns) FROM legacy.\(mapping.source)"
            if exec(importSQL) {
                // Count imported rows
                query("SELECT changes()") { stmt in
                    totalRows += Int(sqlite3_column_int(stmt, 0))
                }
            }
        }

        // Mark as imported
        execute("INSERT INTO _legacy_imports (source_db, row_count) VALUES (?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, (sourceDB as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(totalRows))
        }

        return totalRows
    }
}
