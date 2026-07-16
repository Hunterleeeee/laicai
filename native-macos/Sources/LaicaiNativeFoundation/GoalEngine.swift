import Foundation
import LaicaiNativeDomain

#if canImport(SQLite3)
    import SQLite3
#endif

// MARK: - Goal Definition

/// A persistent, pausable, cross-session workflow goal.
/// Goals survive app restarts and can be paused/resumed.
public struct Goal: Identifiable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var description: String
    public var status: Status
    public var steps: [GoalStep]
    public var currentStepIndex: Int
    public var workflowName: String?
    public var message: String
    public var context: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var threadID: UUID?

    public enum Status: String, Codable, Sendable {
        case pending
        case running
        case paused
        case completed
        case failed
        case cancelled

        public var displayText: String {
            switch self {
            case .pending: return "等待中"
            case .running: return "执行中"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }

        public var icon: String {
            switch self {
            case .pending: return "clock"
            case .running: return "play.circle.fill"
            case .paused: return "pause.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .cancelled: return "stop.circle.fill"
            }
        }
    }
}

public struct GoalStep: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var message: String
    public var status: StepStatus
    public var result: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public enum StepStatus: String, Codable, Sendable {
        case pending, running, completed, failed, skipped
    }

    public init(
        id: UUID = UUID(),
        name: String,
        message: String,
        status: StepStatus = .pending,
        result: String? = nil
    ) {
        self.id = id
        self.name = name
        self.message = message
        self.status = status
    }
}

// MARK: - Goal Engine

@MainActor
public final class GoalEngine: ObservableObject {
    public static let shared = GoalEngine()

    @Published public private(set) var goals: [Goal] = []

    private var database: OpaquePointer?
    private let dbPath: String

    /// Callback to execute a goal step through the main app
    public var onExecuteStep: ((String, UUID?) async -> (success: Bool, result: String))?  // (message, threadID) -> result

    private init() {
        let directory = LaicaiStoragePaths.ensureDirectory(LaicaiStoragePaths.appDirectory)
        dbPath = directory.appendingPathComponent("goals.sqlite3").path
        open()
        migrate()
        loadGoals()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - DB

    private func open() {
        if sqlite3_open(dbPath, &database) != SQLITE_OK { database = nil }
    }

    private func exec(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func migrate() {
        exec(
            """
            CREATE TABLE IF NOT EXISTS goals (
                id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_goal_status ON goals(status);")
    }

    // MARK: - CRUD

    public func createGoal(
        title: String,
        description: String = "",
        message: String,
        steps: [GoalStep] = [],
        workflowName: String? = nil
    ) -> Goal {
        let goal = Goal(
            id: UUID(),
            title: title,
            description: description,
            status: .pending,
            steps: steps.isEmpty ? [GoalStep(name: "执行任务", message: message)] : steps,
            currentStepIndex: 0,
            workflowName: workflowName,
            message: message,
            context: [:],
            createdAt: Date(),
            updatedAt: Date()
        )
        goals.insert(goal, at: 0)
        persistGoal(goal)
        return goal
    }

    public func pauseGoal(id: UUID) {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].status == .running else { return }
        goals[index].status = .paused
        goals[index].updatedAt = Date()
        persistGoal(goals[index])
    }

    public func resumeGoal(id: UUID) {
        guard let index = goals.firstIndex(where: { $0.id == id }),
            [.paused, .pending, .failed].contains(goals[index].status)
        else { return }
        goals[index].status = .running
        goals[index].updatedAt = Date()
        persistGoal(goals[index])

        Task { [weak self] in
            await self?.executeGoal(id: id)
        }
    }

    public func cancelGoal(id: UUID) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[index].status = .cancelled
        goals[index].updatedAt = Date()
        persistGoal(goals[index])
    }

    public func deleteGoal(id: UUID) {
        goals.removeAll { $0.id == id }
        guard let database else { return }
        let sql = "DELETE FROM goals WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3BindTextSafe(stmt, 1, id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Execution

    private func executeGoal(id: UUID) async {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].status == .running else { return }
        guard let executor = onExecuteStep else { return }

        while goals[index].currentStepIndex < goals[index].steps.count {
            // Check if paused/cancelled
            guard goals[index].status == .running else { break }

            let stepIdx = goals[index].currentStepIndex
            goals[index].steps[stepIdx].status = .running
            goals[index].steps[stepIdx].startedAt = Date()
            goals[index].updatedAt = Date()
            persistGoal(goals[index])

            let stepMessage = goals[index].steps[stepIdx].message
            let threadID = goals[index].threadID
            let (success, result) = await executor(stepMessage, threadID)

            // Re-fetch index in case array shifted
            guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }

            goals[idx].steps[stepIdx].status = success ? .completed : .failed
            goals[idx].steps[stepIdx].result = String(result.prefix(500))
            goals[idx].steps[stepIdx].completedAt = Date()

            if success {
                goals[idx].currentStepIndex += 1
                goals[idx].context["step_\(stepIdx)_result"] = String(result.prefix(200))
            } else {
                goals[idx].status = .failed
                goals[idx].updatedAt = Date()
                persistGoal(goals[idx])
                NotificationManager.shared.post(title: "目标失败", body: "\(goals[idx].title)：步骤「\(goals[idx].steps[stepIdx].name)」失败")
                return
            }

            goals[idx].updatedAt = Date()
            persistGoal(goals[idx])
        }

        // All steps done
        if let idx = goals.firstIndex(where: { $0.id == id }), goals[idx].status == .running {
            goals[idx].status = .completed
            goals[idx].completedAt = Date()
            goals[idx].updatedAt = Date()
            persistGoal(goals[idx])
            NotificationManager.shared.post(title: "目标完成", body: goals[idx].title)
        }
    }

    // MARK: - Persistence

    private func persistGoal(_ goal: Goal) {
        guard let database else { return }
        guard let data = try? JSONEncoder().encode(goal),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let sql = """
            INSERT OR REPLACE INTO goals (id, data, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3BindTextSafe(stmt, 1, goal.id.uuidString)
        sqlite3BindTextSafe(stmt, 2, json)
        sqlite3BindTextSafe(stmt, 3, goal.status.rawValue)
        sqlite3_bind_double(stmt, 4, goal.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, goal.updatedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func loadGoals() {
        guard let database else { return }
        let sql = "SELECT data FROM goals ORDER BY updated_at DESC LIMIT 100;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var loaded: [Goal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let json = String(cString: sqlite3_column_text(stmt, 0))
            guard let data = json.data(using: .utf8),
                let goal = try? JSONDecoder().decode(Goal.self, from: data)
            else { continue }
            loaded.append(goal)
        }
        sqlite3_finalize(stmt)
        goals = loaded
    }

    // MARK: - Queries

    public var activeGoals: [Goal] {
        goals.filter { [.pending, .running, .paused].contains($0.status) }
    }

    public var completedGoals: [Goal] {
        goals.filter { $0.status == .completed }
    }

    public func goal(for threadID: UUID) -> Goal? {
        goals.first { $0.threadID == threadID }
    }
}
