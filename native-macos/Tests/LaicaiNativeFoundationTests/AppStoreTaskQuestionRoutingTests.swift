import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTaskQuestionRoutingTests: LaicaiNativeFoundationTestCase {
    func testTaskStatusQuestionAnswersFromCurrentTaskWithoutRuntimeCall() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目",
            status: .failed,
            steps: [
                TaskStep(kind: .userInput, text: "读取项目"),
                TaskStep(kind: .toolCall, text: "find", toolName: "shell.exec"),
                TaskStep(kind: .toolResult, text: "失败：exit_15", toolName: "shell.exec", isFailure: true),
                TaskStep(kind: .textOutput, text: "阶段性输出")
            ],
            updatedAt: .now
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "任务",
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
                selectedTaskID: task.id
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("为什么会有工具失败？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.last?.text, "为什么会有工具失败？")
        XCTAssertTrue(store.state.selectedTask?.steps.last?.text.contains("shell.exec") == true)
        XCTAssertTrue(store.state.selectedTask?.steps.last?.text.contains("受控的项目索引") == true)
    }
    func testUnrelatedQuestionOnSelectedTaskStaysPlainChat() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取本地项目"),
                TaskStep(kind: .textOutput, text: "完成")
            ],
            updatedAt: .now
        )
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "任务",
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
                selectedTaskID: task.id
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("为什么 Claude Code 比来财体验更丝滑？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertEqual(store.state.tasks.first?.steps.filter { $0.kind == .userInput }.count, 1)
        XCTAssertEqual(store.state.modeLabel, "聊天")
    }
    func testStandaloneCapabilityQuestionDoesNotContinueSelectedTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "今天有什么 AI 新闻？",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "今天有什么 AI 新闻？"),
                TaskStep(kind: .textOutput, text: "AI 新闻内容")
            ],
            updatedAt: .now
        )
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "任务",
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
                selectedTaskID: task.id
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你现在能自我进化吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertEqual(store.state.tasks.first?.steps.filter { $0.kind == .userInput }.map(\.text), ["今天有什么 AI 新闻？"])
        XCTAssertEqual(store.state.modeLabel, "聊天")
    }
}
