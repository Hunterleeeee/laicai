import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTaskFollowUpRoutingTests: LaicaiNativeFoundationTestCase {
    func testTinyFollowUpWithoutSelectionRestoresRecentTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "读取本地项目")],
            updatedAt: .now
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "聊天",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false),
                tasks: [task],
                selectedTaskID: nil
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertEqual(store.state.selectedTask?.title, "读取项目")
    }
    func testExplicitContinuationRestoresRecentTaskEvenFromEmptySession() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目",
            status: .cancelled,
            steps: [TaskStep(kind: .userInput, text: "读取本地项目")],
            updatedAt: .now
        )
        let emptySession = ChatSession(title: "新线程", preview: "", modelName: "test", turns: [])
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "聊天",
                sessions: [emptySession],
                selectedSessionID: emptySession.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false),
                tasks: [task],
                selectedTaskID: nil
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("继续这个任务")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertTrue(store.state.sessions.isEmpty)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.last?.text, "继续这个任务")
    }
    func testContextualTaskReferenceFromEmptySessionRestoresRecentTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取本地项目",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取本地项目"),
                TaskStep(kind: .textOutput, text: "输出达到当前上限，回复已被截断。")
            ],
            updatedAt: .now
        )
        let emptySession = ChatSession(title: "新线程", preview: "", modelName: "test", turns: [])
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "聊天",
                sessions: [emptySession],
                selectedSessionID: emptySession.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false),
                tasks: [task],
                selectedTaskID: nil
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("刚才那个读取本地项目的对话输出没结束就被截断了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertTrue(store.state.sessions.isEmpty)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.last?.text, "刚才那个读取本地项目的对话输出没结束就被截断了")
    }
    func testFrustratedEmptySessionRestoresRecentTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取本地项目",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "读取本地项目")],
            updatedAt: .now
        )
        let emptySession = ChatSession(title: "新线程", preview: "", modelName: "test", turns: [])
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "聊天",
                sessions: [emptySession],
                selectedSessionID: emptySession.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false),
                tasks: [task],
                selectedTaskID: nil
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你看，胡说八道了，刚才那个会话上下文没了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("证据优先修复模式") } == true)
    }
}
