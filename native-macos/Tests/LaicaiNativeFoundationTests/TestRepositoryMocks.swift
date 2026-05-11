import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

struct FixedSessionRepository: SessionRepository {
    var sessions: [ChatSession]

    func loadSessions() throws -> [ChatSession]? { sessions }
    func saveSessions(_ sessions: [ChatSession]) throws {}
}

struct FixedTaskRepository: TaskRepository {
    var tasks: [AgentTask]

    func loadTasks() throws -> [AgentTask]? { tasks }
    func saveTasks(_ tasks: [AgentTask]) throws {}
    func appendTask(_ task: AgentTask) throws {}
    func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws {}
    func deleteTask(id: UUID) throws {}
}

struct FixedThreadRepository: ThreadRepository {
    var threads: [Thread]

    func loadThreads() throws -> [Thread]? { threads }
    func saveThreads(_ threads: [Thread]) throws {}
}
