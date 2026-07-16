import LaicaiNativeDomain
import XCTest

@testable import LaicaiNativeFoundation

final class AppStateBootstrapFreshInstallTests: XCTestCase {
    func testProductionEmptyStateContainsNoPreviewData() {
        let state = AppState.empty

        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertTrue(state.connectors.isEmpty)
        XCTAssertNil(state.selectedThreadID)
        XCTAssertNil(state.activeConnectorID)
        XCTAssertEqual(state.settings.defaultConnectorName, "无模型")
    }

    func testFreshBootstrapDoesNotInjectSampleThreadsOrConnectors() {
        let state = AppState.bootstrap(environment: .preview)

        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertTrue(state.connectors.isEmpty)
        XCTAssertNil(state.selectedThreadID)
        XCTAssertNil(state.activeConnectorID)
    }

    func testBootstrapSurfacesRepositoryLoadFailures() {
        let repository = FailingBootstrapRepository()
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: repository,
            connectorRepository: repository,
            taskRepository: repository,
            threadRepository: repository,
            agentRepository: repository
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.notice?.style, .error)
        XCTAssertTrue(state.notice?.message.contains("读取会话快照失败") == true)
        XCTAssertTrue(state.notice?.message.contains("读取连接器失败") == true)
        XCTAssertTrue(state.threads.isEmpty)
        XCTAssertTrue(state.connectors.isEmpty)
    }
}

private struct FailingBootstrapRepository: SessionRepository, ConnectorRepository, TaskRepository,
    ThreadRepository, AgentRepository
{
    private var error: NSError { NSError(domain: "BootstrapTest", code: 42) }

    func loadSessions() throws -> [ChatSession]? { throw error }
    func saveSessions(_ sessions: [ChatSession]) throws { throw error }
    func loadConnectorCatalog() throws -> ConnectorCatalog? { throw error }
    func saveConnectors(_ connectors: [ConnectorProfile], activeConnectorID: UUID?) throws { throw error }
    func loadTasks() throws -> [AgentTask]? { throw error }
    func saveTasks(_ tasks: [AgentTask]) throws { throw error }
    func appendTask(_ task: AgentTask) throws { throw error }
    func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws { throw error }
    func deleteTask(id: UUID) throws { throw error }
    func loadThreads() throws -> [Thread]? { throw error }
    func saveThreads(_ threads: [Thread]) throws { throw error }
    func loadAgents() throws -> [Thread]? { throw error }
    func saveAgents(_ agents: [Thread]) throws { throw error }
}
