import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTaskLifecycleTests: LaicaiNativeFoundationTestCase {
    func testCompletedAgentTaskKeepsSelectedThreadAndContinuesInPlace() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("帮我生成一个 README")
        store.sendDraft()
        try await waitUntilIdle(store)
        let threadID = try XCTUnwrap(store.state.selectedTaskID)

        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertEqual(store.state.selectedTaskID, threadID)
        XCTAssertEqual(store.state.selectedTask?.status, .completed)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .aiThinking && $0.text == "正在理解任务并准备执行。" }.count, 1)

        store.updateDraft("请继续这个话题")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertEqual(store.state.selectedTaskID, threadID)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.map(\.text), ["帮我生成一个 README", "请继续这个话题"])
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .aiThinking && $0.text == "正在理解任务并准备执行。" }.count, 1)
        XCTAssertEqual(runtime.requests.last?.sessionID, threadID)
        XCTAssertTrue(runtime.requests.last?.messages?.contains { $0.role == "assistant" && ($0.content ?? "").contains("完成") } == true)
    }
    func testFailedTaskGetsCheckpointAndContinuationCarriesIt() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = FailingThenCapturingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("帮我搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        let threadID = try XCTUnwrap(store.state.selectedTaskID)
        XCTAssertEqual(store.state.selectedTask?.status, .failed)
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("任务检查点") } == true)

        runtime.shouldFail = false
        store.updateDraft("继续这个任务")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedTaskID, threadID)
        XCTAssertTrue(runtime.requests.last?.messages?.contains { ($0.content ?? "").contains("任务检查点") } == true)
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.kind == .aiThinking && $0.text.contains("最近检查点") } == true)
    }
    func testSelectedLegacySessionPromotesToAgentThreadWhenContinued() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let session = ChatSession(
            title: "旧会话",
            preview: "旧回答",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "旧问题"),
                ChatTurn(role: .assistant, text: "旧回答")
            ]
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                sessions: [session],
                selectedSessionID: session.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请继续旧会话")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertTrue(store.state.sessions.isEmpty)
        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertEqual(store.state.selectedTaskID, session.id)
        XCTAssertEqual(runtime.requests.first?.sessionID, session.id)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.map(\.text), ["旧问题", "请继续旧会话"])
        XCTAssertTrue(runtime.requests.first?.messages?.contains { $0.role == "assistant" && ($0.content ?? "").contains("旧回答") } == true)
    }
    func testRetrySelectedTaskCreatesReplacementThread() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let failedTask = AgentTask(
            title: "失败线程",
            status: .failed,
            steps: [
                TaskStep(kind: .userInput, text: "重新整理今天的 AI 新闻", isCollapsible: false, isCollapsed: false),
                TaskStep(kind: .error, text: "请求失败", isFailure: true, recoverable: true)
            ],
            connectorID: connector.id
        )
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
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
            tasks: [failedTask],
            selectedTaskID: failedTask.id
        ))

        store.retryLastMessage()

        XCTAssertEqual(store.state.tasks.count, 2)
        XCTAssertEqual(store.state.tasks.first?.steps.first?.text, "重新整理今天的 AI 新闻")
        XCTAssertEqual(store.state.selectedTaskID, store.state.tasks.first?.id)
        XCTAssertTrue(store.state.isGenerating)
    }
    func testPrepareTaskContinuationSelectsTaskAndPrefillsDraft() {
        let task = AgentTask(title: "任务", status: .completed)
        let store = AppStore(state: testState(tasks: [task]))

        store.prepareTaskContinuation(id: task.id)

        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.modeLabel, "任务")
        XCTAssertEqual(store.state.draftMessage, "继续这个任务")
    }
    func testShortFollowUpOnSelectedTaskContinuesTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(title: "任务", status: .completed, steps: [
            TaskStep(kind: .userInput, text: "帮我生成 README"),
            TaskStep(kind: .textOutput, text: "完成")
        ])
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

        store.updateDraft("这个呢")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .userInput }.map(\.text), ["帮我生成 README", "这个呢"])
    }
    func testReplyOnIdleRunningTaskContinuesSameTask() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(title: "读取项目", status: .running, steps: [
            TaskStep(kind: .userInput, text: "读取本地项目并优化"),
            TaskStep(kind: .toolCall, text: "正在搜索项目内容", toolName: "code.search")
        ])
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

        store.updateDraft("为什么新建线程了？继续刚才这个任务")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.text.contains("上次执行没有正常结束") } == true)
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.kind == .userInput && $0.text.contains("继续刚才这个任务") } == true)
    }
}
