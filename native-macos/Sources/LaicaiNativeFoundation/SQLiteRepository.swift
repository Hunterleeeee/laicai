import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import LaicaiNativeDomain

public struct PersistentMemoryRow: Sendable, Identifiable {
    public let id: String
    public let category: String
    public let key: String
    public let value: String

    public init(id: String, category: String, key: String, value: String) {
        self.id = id
        self.category = category
        self.key = key
        self.value = value
    }
}

public final class SQLiteRepository {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "laicai.sqlite", qos: .utility)
    private let path: String
    /// H3: Track last-saved timestamps to enable incremental saves
    private var lastSavedTimestamps: [UUID: TimeInterval] = [:]
    private var lastSavedPayloads: [UUID: String] = [:]

    private struct DirtyThreadRecord {
        let thread: LaicaiThread
        let timestamp: TimeInterval
        let json: String
    }

    public init(path: String? = nil) {
        let base = path ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory())
        let dir = (base as NSString).appendingPathComponent("Laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("store.sqlite3")
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

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            preview TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            category TEXT NOT NULL DEFAULT 'general',
            model_name TEXT NOT NULL DEFAULT '',
            unread_count INTEGER NOT NULL DEFAULT 0,
            turns_json TEXT NOT NULL DEFAULT '[]'
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS connectors (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            model_name TEXT NOT NULL,
            api_key TEXT NOT NULL DEFAULT '',
            health INTEGER NOT NULL DEFAULT 1,
            last_checked REAL NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("ALTER TABLE connectors ADD COLUMN tool_calling_policy TEXT NOT NULL DEFAULT 'automatic';")
        exec("ALTER TABLE connectors ADD COLUMN tool_calling_capability TEXT;")
        exec("ALTER TABLE connectors ADD COLUMN tool_calling_capability_source TEXT;")
        exec("ALTER TABLE connectors ADD COLUMN tool_calling_capability_learned_at REAL;")
        exec("ALTER TABLE connectors ADD COLUMN role TEXT;")
        exec("ALTER TABLE connectors ADD COLUMN probed_context_window INTEGER;")
        exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            steps_json TEXT NOT NULL DEFAULT '[]',
            context_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            connector_id TEXT,
            workflow_name TEXT
        );
        """)
        exec("ALTER TABLE tasks ADD COLUMN context_json TEXT NOT NULL DEFAULT '{}';")
        exec("""
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        // G1: Persistent memory — cross-session project knowledge
        exec("""
        CREATE TABLE IF NOT EXISTS persistent_memory (
            id TEXT PRIMARY KEY,
            workspace TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT 'general',
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            access_count INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_pm_workspace ON persistent_memory(workspace);")
        exec("CREATE INDEX IF NOT EXISTS idx_pm_category ON persistent_memory(category);")
        refreshThreadSaveCache()
    }

    // MARK: - Persistent Memory (G1)

    public func saveMemory(id: String = UUID().uuidString, workspace: String, category: String, key: String, value: String) {
        let now = Date().timeIntervalSinceReferenceDate
        guard let stmt = prepare("""
            INSERT OR REPLACE INTO persistent_memory (id, workspace, category, key, value, created_at, updated_at, access_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT access_count FROM persistent_memory WHERE id = ?), 0))
        """) else { return }
        bindText(stmt, index: 1, value: id)
        bindText(stmt, index: 2, value: workspace)
        bindText(stmt, index: 3, value: category)
        bindText(stmt, index: 4, value: key)
        bindText(stmt, index: 5, value: value)
        sqlite3_bind_double(stmt, 6, now)
        sqlite3_bind_double(stmt, 7, now)
        bindText(stmt, index: 8, value: id)
        _ = step(stmt)
    }

    public func loadMemories(workspace: String, category: String? = nil, limit: Int = 50) -> [PersistentMemoryRow] {
        let boundedLimit = max(1, min(limit, 500))
        let sql: String
        if let category {
            sql = """
            SELECT id, category, key, value
            FROM persistent_memory
            WHERE workspace = ? AND category = ?
            ORDER BY updated_at DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            bindText(stmt, index: 1, value: workspace)
            bindText(stmt, index: 2, value: category)
            sqlite3_bind_int(stmt, 3, Int32(boundedLimit))
            return readMemoryRows(from: stmt)
        } else {
            sql = """
            SELECT id, category, key, value
            FROM persistent_memory
            WHERE workspace = ?
            ORDER BY updated_at DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            bindText(stmt, index: 1, value: workspace)
            sqlite3_bind_int(stmt, 2, Int32(boundedLimit))
            return readMemoryRows(from: stmt)
        }
    }

    private func readMemoryRows(from stmt: OpaquePointer?) -> [PersistentMemoryRow] {
        var results: [PersistentMemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let category = String(cString: sqlite3_column_text(stmt, 1))
            let key = String(cString: sqlite3_column_text(stmt, 2))
            let value = String(cString: sqlite3_column_text(stmt, 3))
            results.append(PersistentMemoryRow(id: id, category: category, key: key, value: value))
        }
        sqlite3_finalize(stmt)
        return results
    }

    public func deleteMemory(id: String) {
        guard let stmt = prepare("DELETE FROM persistent_memory WHERE id = ?") else { return }
        bindText(stmt, index: 1, value: id)
        _ = step(stmt)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, index: Int, value: String) {
        sqlite3_bind_text_safe(stmt, Int32(index), value)
    }

    private func step(_ stmt: OpaquePointer) -> Bool {
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    private func refreshThreadSaveCache() {
        lastSavedTimestamps.removeAll()
        lastSavedPayloads.removeAll()
        guard let stmt = prepare("SELECT id, updated_at, record_json FROM threads") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idText = String(cString: sqlite3_column_text(stmt, 0))
            guard let id = UUID(uuidString: idText) else { continue }
            lastSavedTimestamps[id] = sqlite3_column_double(stmt, 1)
            lastSavedPayloads[id] = String(cString: sqlite3_column_text(stmt, 2))
        }
        sqlite3_finalize(stmt)
    }
}

extension SQLiteRepository: ThreadRepository {
    public func loadThreads() throws -> [LaicaiThread]? {
        guard let stmt = prepare("SELECT record_json FROM threads ORDER BY updated_at DESC") else {
            return nil
        }
        var threads: [LaicaiThread] = []
        let decoder = JSONDecoder()
        var decodedIDs: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recordJSON = String(cString: sqlite3_column_text(stmt, 0))
            if let data = recordJSON.data(using: .utf8),
               let thread = try? decoder.decode(Thread.self, from: data) {
                threads.append(thread)
                decodedIDs.insert(thread.id)
            }
        }
        sqlite3_finalize(stmt)
        lastSavedTimestamps = lastSavedTimestamps.filter { decodedIDs.contains($0.key) }
        lastSavedPayloads = lastSavedPayloads.filter { decodedIDs.contains($0.key) }
        // If no threads in unified table, try migrating from legacy session/task tables
        if threads.isEmpty {
            return try migrateLegacyToThreads()
        }
        return threads
    }

    public func saveThreads(_ threads: [LaicaiThread]) throws {
        // Safety: never wipe a non-empty DB with an empty list (protects against decode-fail cascades)
        if threads.isEmpty {
            if let countStmt = prepare("SELECT count(*) FROM threads") {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    let existing = sqlite3_column_int(countStmt, 0)
                    sqlite3_finalize(countStmt)
                    if existing > 0 { return }
                } else {
                    sqlite3_finalize(countStmt)
                }
            }
        }

        let encoder = JSONEncoder()
        let currentIDs = Set(threads.map { $0.id })

        // H3: Incremental save — write threads whose timestamp or payload changed
        var dirtyThreads: [DirtyThreadRecord] = []
        for thread in threads {
            let timestamp = thread.updatedAt.timeIntervalSince1970
            let data = (try? encoder.encode(thread)) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "{}"
            if lastSavedTimestamps[thread.id] != timestamp || lastSavedPayloads[thread.id] != json {
                dirtyThreads.append(DirtyThreadRecord(thread: thread, timestamp: timestamp, json: json))
            }
        }

        // Detect deleted threads (present in DB but not in current list)
        let deletedIDs = Set(lastSavedTimestamps.keys).subtracting(currentIDs)

        guard !dirtyThreads.isEmpty || !deletedIDs.isEmpty else { return }

        exec("BEGIN")

        // Delete removed threads
        for id in deletedIDs {
            if let stmt = prepare("DELETE FROM threads WHERE id = ?") {
                bindText(stmt, index: 1, value: id.uuidString)
                _ = step(stmt)
            }
            lastSavedTimestamps.removeValue(forKey: id)
            lastSavedPayloads.removeValue(forKey: id)
        }

        // Upsert dirty threads
        for record in dirtyThreads {
            let thread = record.thread
            guard let stmt = prepare("INSERT OR REPLACE INTO threads (id, updated_at, record_json) VALUES (?, ?, ?)") else { continue }
            bindText(stmt, index: 1, value: thread.id.uuidString)
            sqlite3_bind_double(stmt, 2, record.timestamp)
            bindText(stmt, index: 3, value: record.json)
            _ = step(stmt)
            lastSavedTimestamps[thread.id] = record.timestamp
            lastSavedPayloads[thread.id] = record.json
        }

        exec("COMMIT")
    }

    /// One-time migration: load sessions + tasks from legacy tables, convert to Thread, save to threads table.
    private func migrateLegacyToThreads() throws -> [LaicaiThread] {
        var threads: [LaicaiThread] = []
        if let sessions = try? loadSessions() {
            threads += sessions.map(Thread.init(session:))
        }
        if let tasks = try? loadTasks() {
            threads += tasks.map(Thread.init(task:))
        }
        if !threads.isEmpty {
            try saveThreads(threads)
        }
        return threads
    }
}

extension SQLiteRepository: AgentRepository {
    public func loadAgents() throws -> [LaicaiThread]? {
        try loadThreads()
    }

    public func saveAgents(_ agents: [LaicaiThread]) throws {
        try saveThreads(agents)
    }
}

extension SQLiteRepository: SessionRepository {
    public func loadSessions() throws -> [ChatSession]? {
        guard let stmt = prepare("""
            SELECT id, title, preview, updated_at, is_pinned, category, model_name,
                   unread_count, turns_json
            FROM sessions
            ORDER BY updated_at DESC
        """) else {
            return nil
        }
        var sessions: [ChatSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let preview = String(cString: sqlite3_column_text(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let isPinned = sqlite3_column_int(stmt, 4) != 0
            let categoryStr = String(cString: sqlite3_column_text(stmt, 5))
            let category = SessionCategory(rawValue: categoryStr) ?? .inbox
            let modelName = String(cString: sqlite3_column_text(stmt, 6))
            let unreadCount = Int(sqlite3_column_int(stmt, 7))
            let turnsJSON = String(cString: sqlite3_column_text(stmt, 8))
            let turns = (try? JSONDecoder().decode([ChatTurn].self, from: turnsJSON.data(using: .utf8) ?? Data())) ?? []
            sessions.append(ChatSession(
                id: id, title: title, preview: preview,
                updatedAt: updatedAt, isPinned: isPinned,
                category: category, modelName: modelName,
                unreadCount: unreadCount, turns: turns
            ))
        }
        sqlite3_finalize(stmt)
        return sessions
    }

    public func saveSessions(_ sessions: [ChatSession]) throws {
        exec("BEGIN")
        exec("DELETE FROM sessions")
        for session in sessions {
            guard let stmt = prepare("""
                INSERT INTO sessions (
                    id, title, preview, updated_at, is_pinned, category, model_name,
                    unread_count, turns_json
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) else { continue }
            bindText(stmt, index: 1, value: session.id.uuidString)
            bindText(stmt, index: 2, value: session.title)
            bindText(stmt, index: 3, value: session.preview)
            sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 5, session.isPinned ? 1 : 0)
            bindText(stmt, index: 6, value: session.category.rawValue)
            bindText(stmt, index: 7, value: session.modelName)
            sqlite3_bind_int(stmt, 8, Int32(session.unreadCount))
            let turnsData = (try? JSONEncoder().encode(session.turns)) ?? Data()
            bindText(stmt, index: 9, value: String(data: turnsData, encoding: .utf8) ?? "[]")
            _ = step(stmt)
        }
        exec("COMMIT")
    }
}

extension SQLiteRepository: TaskRepository {
    public func loadTasks() throws -> [AgentTask]? {
        guard let stmt = prepare("""
            SELECT id, title, status, steps_json, context_json, created_at,
                   updated_at, connector_id, workflow_name
            FROM tasks
            ORDER BY updated_at DESC
        """) else {
            return nil
        }
        var tasks: [AgentTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let statusStr = String(cString: sqlite3_column_text(stmt, 2))
            let status = TaskStatus(rawValue: statusStr) ?? .queued
            let stepsJSON = String(cString: sqlite3_column_text(stmt, 3))
            let steps = (try? JSONDecoder().decode([TaskStep].self, from: stepsJSON.data(using: .utf8) ?? Data())) ?? []
            let contextJSON = String(cString: sqlite3_column_text(stmt, 4))
            let context = (try? JSONDecoder().decode(TaskContext.self, from: contextJSON.data(using: .utf8) ?? Data())) ?? TaskContext()
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let connectorID = sqlite3_column_text(stmt, 7).map { UUID(uuidString: String(cString: $0)) } ?? nil
            let workflowName = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            tasks.append(AgentTask(
                id: id, title: title, status: status, steps: steps,
                connectorID: connectorID, workflowName: workflowName,
                context: context, createdAt: createdAt, updatedAt: updatedAt
            ))
        }
        sqlite3_finalize(stmt)
        return tasks
    }

    public func saveTasks(_ tasks: [AgentTask]) throws {
        exec("BEGIN")
        exec("DELETE FROM tasks")
        for task in tasks {
            try appendTask(task)
        }
        exec("COMMIT")
    }

    public func appendTask(_ task: AgentTask) throws {
        guard let stmt = prepare("""
            INSERT INTO tasks (
                id, title, status, steps_json, context_json, created_at,
                updated_at, connector_id, workflow_name
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) else { return }
        bindText(stmt, index: 1, value: task.id.uuidString)
        bindText(stmt, index: 2, value: task.title)
        bindText(stmt, index: 3, value: task.status.rawValue)
        let stepsData = (try? JSONEncoder().encode(task.steps)) ?? Data()
        bindText(stmt, index: 4, value: String(data: stepsData, encoding: .utf8) ?? "[]")
        let contextData = (try? JSONEncoder().encode(task.context)) ?? Data()
        bindText(stmt, index: 5, value: String(data: contextData, encoding: .utf8) ?? "{}")
        sqlite3_bind_double(stmt, 6, task.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, task.updatedAt.timeIntervalSince1970)
        if let connectorID = task.connectorID {
            bindText(stmt, index: 8, value: connectorID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let workflowName = task.workflowName {
            bindText(stmt, index: 9, value: workflowName)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        _ = step(stmt)
    }

    public func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws {
        var tasks = try loadTasks() ?? []
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[idx])
        // Update single row
        let task = tasks[idx]
        guard let stmt = prepare("""
            UPDATE tasks
            SET title=?, status=?, steps_json=?, context_json=?, updated_at=?,
                connector_id=?, workflow_name=?
            WHERE id=?
        """) else { return }
        bindText(stmt, index: 1, value: task.title)
        bindText(stmt, index: 2, value: task.status.rawValue)
        let stepsData = (try? JSONEncoder().encode(task.steps)) ?? Data()
        bindText(stmt, index: 3, value: String(data: stepsData, encoding: .utf8) ?? "[]")
        let contextData = (try? JSONEncoder().encode(task.context)) ?? Data()
        bindText(stmt, index: 4, value: String(data: contextData, encoding: .utf8) ?? "{}")
        sqlite3_bind_double(stmt, 5, task.updatedAt.timeIntervalSince1970)
        if let connectorID = task.connectorID {
            bindText(stmt, index: 6, value: connectorID.uuidString)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let workflowName = task.workflowName {
            bindText(stmt, index: 7, value: workflowName)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bindText(stmt, index: 8, value: id.uuidString)
        _ = step(stmt)
    }

    public func deleteTask(id: UUID) throws {
        guard let stmt = prepare("DELETE FROM tasks WHERE id=?") else { return }
        bindText(stmt, index: 1, value: id.uuidString)
        _ = step(stmt)
    }
}

extension SQLiteRepository: ConnectorRepository {
    public func loadConnectorCatalog() throws -> ConnectorCatalog? {
        guard let stmt = prepare("""
            SELECT id, name, kind, endpoint, model_name, api_key, health, last_checked,
                   tool_calling_policy, tool_calling_capability,
                   tool_calling_capability_source, tool_calling_capability_learned_at,
                   is_active, role, probed_context_window
            FROM connectors
        """) else {
            return nil
        }
        var connectors: [ConnectorProfile] = []
        var activeID: UUID?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let kind = String(cString: sqlite3_column_text(stmt, 2))
            let endpoint = String(cString: sqlite3_column_text(stmt, 3))
            let modelName = String(cString: sqlite3_column_text(stmt, 4))
            let apiKey = String(cString: sqlite3_column_text(stmt, 5))
            let healthInt = sqlite3_column_int(stmt, 6)
            let health: ConnectorHealth = healthInt == 2 ? .ready : healthInt == 1 ? .attention : .offline
            let lastChecked = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            let toolCallingPolicy: ConnectorToolCallingPolicy?
            if sqlite3_column_type(stmt, 8) == SQLITE_NULL {
                toolCallingPolicy = nil
            } else {
                toolCallingPolicy = ConnectorToolCallingPolicy(rawValue: String(cString: sqlite3_column_text(stmt, 8)))
            }
            let toolCallingCapability: ConnectorToolCallingCapability?
            if sqlite3_column_type(stmt, 9) == SQLITE_NULL {
                toolCallingCapability = nil
            } else {
                toolCallingCapability = ConnectorToolCallingCapability(rawValue: String(cString: sqlite3_column_text(stmt, 9)))
            }
            let toolCallingCapabilitySource: ConnectorToolCallingCapabilityObservationSource?
            if sqlite3_column_type(stmt, 10) == SQLITE_NULL {
                toolCallingCapabilitySource = nil
            } else {
                toolCallingCapabilitySource = ConnectorToolCallingCapabilityObservationSource(rawValue: String(cString: sqlite3_column_text(stmt, 10)))
            }
            let toolCallingCapabilityLearnedAt: Date?
            if sqlite3_column_type(stmt, 11) == SQLITE_NULL {
                toolCallingCapabilityLearnedAt = nil
            } else {
                toolCallingCapabilityLearnedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            }
            let isActive = sqlite3_column_int(stmt, 12) != 0
            let role: ConnectorRole?
            if sqlite3_column_type(stmt, 13) == SQLITE_NULL {
                role = nil
            } else {
                role = ConnectorRole(rawValue: String(cString: sqlite3_column_text(stmt, 13)))
            }
            let probedContextWindow: Int?
            if sqlite3_column_type(stmt, 14) == SQLITE_NULL {
                probedContextWindow = nil
            } else {
                probedContextWindow = Int(sqlite3_column_int(stmt, 14))
            }
            connectors.append(ConnectorProfile(
                id: id, name: name, kind: kind, endpoint: endpoint,
                modelName: modelName,
                note: apiKey,
                role: role,
                toolCallingPolicy: toolCallingPolicy,
                toolCallingCapability: toolCallingCapability,
                toolCallingCapabilitySource: toolCallingCapabilitySource,
                toolCallingCapabilityLearnedAt: toolCallingCapabilityLearnedAt,
                probedContextWindow: probedContextWindow,
                health: health,
                lastCheckedAt: lastChecked
            ))
            if isActive { activeID = id }
        }
        sqlite3_finalize(stmt)
        return ConnectorCatalog(connectors: connectors, activeConnectorID: activeID)
    }

    public func saveConnectors(_ connectors: [ConnectorProfile], activeConnectorID: UUID?) throws {
        exec("BEGIN")
        exec("DELETE FROM connectors")
        for connector in connectors {
            guard let stmt = prepare("""
                INSERT INTO connectors (
                    id, name, kind, endpoint, model_name, api_key, health, last_checked,
                    tool_calling_policy, tool_calling_capability,
                    tool_calling_capability_source, tool_calling_capability_learned_at,
                    is_active, role, probed_context_window
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) else { continue }
            bindText(stmt, index: 1, value: connector.id.uuidString)
            bindText(stmt, index: 2, value: connector.name)
            bindText(stmt, index: 3, value: connector.kind)
            bindText(stmt, index: 4, value: connector.endpoint)
            bindText(stmt, index: 5, value: connector.modelName)
            bindText(stmt, index: 6, value: connector.note)
            let healthInt: Int32 = connector.health == .ready ? 2 : connector.health == .attention ? 1 : 0
            sqlite3_bind_int(stmt, 7, healthInt)
            sqlite3_bind_double(stmt, 8, connector.lastCheckedAt.timeIntervalSince1970)
            bindText(stmt, index: 9, value: (connector.toolCallingPolicy ?? .automatic).rawValue)
            if let capability = connector.toolCallingCapability {
                bindText(stmt, index: 10, value: capability.rawValue)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let source = connector.toolCallingCapabilitySource {
                bindText(stmt, index: 11, value: source.rawValue)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if let learnedAt = connector.toolCallingCapabilityLearnedAt {
                sqlite3_bind_double(stmt, 12, learnedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            sqlite3_bind_int(stmt, 13, (connector.id == activeConnectorID) ? 1 : 0)
            if let role = connector.role {
                bindText(stmt, index: 14, value: role.rawValue)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            if let contextWindow = connector.probedContextWindow {
                sqlite3_bind_int(stmt, 15, Int32(contextWindow))
            } else {
                sqlite3_bind_null(stmt, 15)
            }
            _ = step(stmt)
        }
        exec("COMMIT")
    }
}
