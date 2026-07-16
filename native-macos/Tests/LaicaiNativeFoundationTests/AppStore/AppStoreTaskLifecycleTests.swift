import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreTaskLifecycleTests: LaicaiNativeFoundationTestCase {
    func testCompletedAgentTaskKeepsSelectedThreadAndContinuesInPlace() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = EvidenceProducingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                threads: [],
                selectedThreadID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
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
        let threadID = try XCTUnwrap(store.state.selectedThreadID)

        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertEqual(store.state.selectedThread?.status, .completed)
        XCTAssertEqual(store.state.selectedThread?.executionState, .completed)
        XCTAssertEqual(store.state.selectedThread?.goal, "帮我生成一个 README")
        XCTAssertFalse(store.state.selectedThread?.currentPlan.isEmpty ?? true)
        XCTAssertEqual(store.state.selectedThread?.taskProtocol?.taskGoal, "帮我生成一个 README")
        XCTAssertEqual(store.state.selectedThread?.taskProtocol?.threadID, threadID)
        XCTAssertEqual(store.state.selectedThread?.executionLedger?.goal, "帮我生成一个 README")
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .aiThinking && $0.text == "正在理解会话目标并准备执行。" }.count, 1)

        store.updateDraft("请继续这个话题")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.map(\.text), ["帮我生成一个 README", "请继续这个话题"])
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .aiThinking && $0.text == "正在理解会话目标并准备执行。" }.count, 1)
        XCTAssertEqual(runtime.requests.last?.sessionID, threadID)
        XCTAssertTrue(runtime.requests.last?.messages?.contains { $0.role == "assistant" && ($0.content ?? "").contains("完成") } == true)
        XCTAssertEqual(store.state.selectedThread?.taskProtocol?.threadID, threadID)
    }
    func testFailedTaskGetsCheckpointAndContinuationCarriesIt() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = FailingThenCapturingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                threads: [],
                selectedThreadID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
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

        let threadID = try XCTUnwrap(store.state.selectedThreadID)
        XCTAssertEqual(store.state.selectedThread?.status, .failed)
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("任务检查点") } == true)

        runtime.shouldFail = false
        store.updateDraft("继续这个 Agent")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertTrue(runtime.requests.last?.messages?.contains { ($0.content ?? "").contains("任务检查点") } == true)
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .aiThinking && $0.text.contains("最近检查点") } == true)
    }
    func testSelectedLegacySessionPromotesToAgentThreadWhenContinued() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let session = ChatSession(
            title: "旧会话",
            preview: "旧回答",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "旧问题"),
                ChatTurn(role: .assistant, text: "旧回答"),
            ]
        )
        let thread = Thread(
            id: session.id,
            title: session.title,
            preview: session.preview,
            steps: session.turns.map { turn in
                TaskStep(kind: turn.role == .user ? .userInput : .textOutput, text: turn.text)
            },
            modelName: session.modelName,
            category: session.category,
            isPinned: session.isPinned,
            updatedAt: session.updatedAt,
            executionState: .idle
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                threads: [thread],
                selectedThreadID: thread.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
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

        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThreadID, thread.id)
        XCTAssertEqual(runtime.requests.first?.sessionID, thread.id)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.map(\.text), ["旧问题", "请继续旧会话"])
        XCTAssertTrue(runtime.requests.first?.messages?.contains { $0.role == "assistant" && ($0.content ?? "").contains("旧回答") } == true)
    }
    func testRetrySelectedTaskCreatesReplacementThread() {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let failedTask = AgentTask(
            title: "失败线程",
            status: .failed,
            steps: [
                TaskStep(kind: .userInput, text: "重新整理今天的 AI 新闻", isCollapsible: false, isCollapsed: false),
                TaskStep(kind: .error, text: "请求失败", isFailure: true, recoverable: true),
            ],
            connectorID: connector.id
        )
        let thread = Thread(
            id: failedTask.id,
            title: failedTask.title,
            preview: failedTask.preview,
            status: failedTask.status,
            steps: failedTask.steps,
            connectorID: failedTask.connectorID,
            workflowName: failedTask.workflowName,
            context: failedTask.context,
            updatedAt: failedTask.updatedAt,
            executionState: Thread.inferAgentState(status: failedTask.status),
            goal: failedTask.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: failedTask.taskProtocol,
            executionLedger: failedTask.executionLedger
        )
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                threads: [thread],
                selectedThreadID: thread.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
            ))

        store.retryLastMessage()

        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.threads.first?.steps.first?.text, "重新整理今天的 AI 新闻")
        XCTAssertEqual(store.state.selectedThreadID, store.state.threads.first?.id)
        XCTAssertTrue(store.state.isGenerating)
    }
    func testPrepareTaskContinuationSelectsTaskAndPrefillsDraft() {
        let task = AgentTask(title: "任务", status: .completed)
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let store = AppStore(state: testState(threads: [thread], selectedThreadID: thread.id))

        store.prepareTaskContinuation(id: task.id)

        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.modeLabel, "会话")
        XCTAssertEqual(store.state.draftMessage, "继续这个会话")
    }
    func testShortFollowUpOnSelectedTaskContinuesTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "任务", status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "帮我生成 README"),
                TaskStep(kind: .textOutput, text: "完成"),
            ])
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "执行",
                threads: [thread],
                selectedThreadID: thread.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
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

        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.map(\.text), ["帮我生成 README", "这个呢"])
    }
    func testReplyOnIdleRunningTaskContinuesSameTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目", status: .running,
            steps: [
                TaskStep(kind: .userInput, text: "读取本地项目并优化"),
                TaskStep(kind: .toolCall, text: "正在搜索项目内容", toolName: "code.search"),
            ])
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "执行",
                threads: [thread],
                selectedThreadID: thread.id,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test",
                    compactComposer: false,
                    showDebugPanels: false)
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

        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.text.contains("上次执行没有正常结束") } == true)
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .userInput && $0.text.contains("继续刚才这个任务") } == true)
    }

    func testTaskCreatedWithoutSelectionIgnoresGlobalActiveProject() async throws {
        let previousActiveProjectID = ProjectManager.shared.activeProjectID
        ProjectManager.shared.activeProjectID = UUID()
        defer { ProjectManager.shared.activeProjectID = previousActiveProjectID }
        let connector = makeConnector()
        let store = makeTestStore(connectors: [connector], activeConnectorID: connector.id)

        store.updateDraft("帮我生成一个 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedThread?.projectID)
    }

    func testProjectPlaceholderKeepsProjectIDWhenPromotedToTask() async throws {
        let projectID = UUID()
        let connector = makeConnector()
        let store = makeTestStore(connectors: [connector], activeConnectorID: connector.id)

        store.newThreadInProject(projectID)
        let threadID = try XCTUnwrap(store.state.selectedThreadID)
        store.updateDraft("帮我生成一个 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertEqual(store.state.selectedThread?.projectID, projectID)
    }

    func testContinueButtonUsesLedgerNextAction() async throws {
        let connector = makeConnector()
        var ledger = AgentExecutionLedger(
            originalRequest: "修复继续按钮",
            goal: "修复继续按钮",
            state: .paused,
            plan: ["读取账本", "继续执行"],
            nextAction: "恢复 pendingFollowUp 并继续验证"
        )
        ledger.appendUnique("Sources/AppStore.swift", to: \.readFiles)
        let task = AgentTask(
            title: "修复继续按钮",
            status: .cancelled,
            steps: [
                TaskStep(kind: .userInput, text: "修复继续按钮"),
                TaskStep(kind: .toolResult, text: "读取完成", toolName: "file.read", toolParams: ["path": "Sources/AppStore.swift"]),
            ],
            connectorID: connector.id,
            context: TaskContext(workspaceRoot: "/tmp"),
            executionLedger: ledger
        )
        let runtime = CapturingToolsRuntime()
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let store = AppStore(
            state: testState(
                threads: [thread],
                selectedThreadID: thread.id,
                workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath,
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment(runtime: runtime)
        )

        store.continueTask()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertTrue(
            store.state.selectedThread?.steps.contains { $0.kind == .userInput && $0.text.contains("恢复 pendingFollowUp 并继续验证") } == true)
        XCTAssertTrue(runtime.requests.last?.messages?.contains { ($0.content ?? "").contains("execution-ledger") } == true)
    }

    func testRunningThreadFollowUpQueuesInsteadOfDropping() {
        let connector = makeConnector()
        let task = AgentTask(
            title: "运行任务", status: .running,
            steps: [
                TaskStep(kind: .userInput, text: "优化性能")
            ])
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let store = AppStore(
            state: testState(
                threads: [thread],
                selectedThreadID: thread.id,
                connectors: [connector],
                activeConnectorID: connector.id
            )
        )
        store.state.isGenerating = true
        store.updateDraft("左边历史任务还是卡")

        XCTAssertNil(store.state.pendingFollowUp)
        XCTAssertNil(store.state.selectedThread?.executionLedger?.pendingFollowUp)
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.text), ["优化性能"])

        store.sendDraft()

        XCTAssertEqual(store.state.pendingFollowUp, "左边历史任务还是卡")
        XCTAssertEqual(store.state.draftMessage, "")
        XCTAssertEqual(store.state.selectedThread?.executionLedger?.pendingFollowUp, "左边历史任务还是卡")
        XCTAssertEqual(store.state.selectedThread?.executionLedger?.state, .executing)
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.text), ["优化性能"])
    }

    func testTwentyFollowUpsStayOnSelectedThread() {
        let connector = makeConnector()
        let task = AgentTask(
            title: "修复会话归属", status: .running,
            steps: [
                TaskStep(kind: .userInput, text: "修复继续追问新建会话 bug")
            ])
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )
        let store = AppStore(
            state: testState(
                threads: [thread],
                selectedThreadID: thread.id,
                connectors: [connector],
                activeConnectorID: connector.id
            )
        )
        store.state.isGenerating = true

        for index in 1...20 {
            store.updateDraft("继续，第 \(index) 次")
            store.sendDraft()
            XCTAssertEqual(store.state.selectedThreadID, task.id)
            XCTAssertEqual(store.state.threads.count, 1)
        }

        let pending = store.state.selectedThread?.executionLedger?.pendingFollowUp ?? ""
        XCTAssertTrue(pending.contains("继续，第 1 次"), pending)
        XCTAssertTrue(pending.contains("继续，第 20 次"), pending)
        XCTAssertEqual(pending.components(separatedBy: "追加补充：").count - 1, 19)
        XCTAssertEqual(store.state.selectedThread?.executionLedger?.state, .executing)
    }

    func testFailedToolWritesRecoveryPathIntoLedger() {
        var thread = Thread(
            title: "修复编辑失败",
            status: .failed,
            steps: [
                TaskStep(kind: .userInput, text: "修复文件"),
                TaskStep(kind: .toolResult, text: "oldText 匹配失败", toolName: "file.edit", isFailure: true),
            ],
            executionState: .failed,
            goal: "修复文件"
        )

        AppStore.rebuildExecutionLedger(&thread)

        XCTAssertTrue(
            thread.executionLedger?.alternativePaths.contains {
                $0.contains("file.read + file.write")
            } == true)
    }
}
