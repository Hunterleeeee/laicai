import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTests: XCTestCase {
    func testNewSessionSelectsNewestSession() {
        let store = AppStore.preview()

        store.newSession()

        XCTAssertEqual(store.state.selectedSession?.title, "新线程")
        XCTAssertEqual(store.state.sessions.first?.id, store.state.selectedSessionID)
    }

    func testSendDraftCreatesUnifiedTaskThreadImmediately() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
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
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
        ))

        store.updateDraft("请继续 native rewrite")
        store.sendDraft()

        XCTAssertTrue(store.state.isGenerating)
        XCTAssertNil(store.state.selectedSessionID)
        XCTAssertNotNil(store.state.selectedTaskID)
        XCTAssertEqual(store.state.tasks.first?.steps.first?.kind, .userInput)
        XCTAssertEqual(store.state.threads.first?.source, .task)
    }

    func testPlainQuestionsUseDirectSessionWithoutTools() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
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

        store.updateDraft("你能生成视频吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertNotNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedSession?.turns.map(\.role), [.user, .assistant])
        XCTAssertNil(runtime.requests.last?.tools)
        XCTAssertNil(runtime.requests.last?.messages)
        XCTAssertEqual(runtime.requests.last?.modeLabel, "聊天")
        XCTAssertEqual(store.state.modeLabel, "聊天")
    }

    func testDirectShortQuestionsDoNotCarryUnrelatedHistory() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let session = ChatSession(
            title: "旧话题",
            preview: "删除文件",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "帮我删除 Obsidian 文件"),
                ChatTurn(role: .assistant, text: "删除前需要确认路径。")
            ]
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
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

        store.updateDraft("测试通过了吗")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertTrue(runtime.requests.last?.history.isEmpty == true)
    }

    func testDirectExplicitFollowUpsCarryRecentHistory() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let session = ChatSession(
            title: "旧话题",
            preview: "旧回答",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "解释一下 token 指标"),
                ChatTurn(role: .assistant, text: "token 指标包含输入、输出和速度。")
            ]
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
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

        store.updateDraft("继续这个话题")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.history.count, 2)
    }

    func testDirectSessionStreamsAndStoresMetrics() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
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
                runtimeClient: StreamingRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你好吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        let assistant = try XCTUnwrap(store.state.selectedSession?.turns.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.text, "你好，世界")
        XCTAssertEqual(assistant.metrics?.inputTokens, 12)
        XCTAssertEqual(assistant.metrics?.outputTokens, 4)
        XCTAssertEqual(store.state.selectedThread?.events.last?.metrics?.outputTokens, 4)
    }

    func testLocalDirectRequestsUseSmallOutputCap() async throws {
        let connector = ConnectorProfile(name: "Local Ollama", kind: "ollama", endpoint: "http://127.0.0.1:11434/v1", modelName: "qwen3.5:9b-q4_K_M", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Local Ollama", compactComposer: false, showDebugPanels: false)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你好吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 512)
    }

    func testLocalAgentRequestsUseConservativeBudget() async throws {
        let connector = ConnectorProfile(name: "Local Ollama", kind: "ollama", endpoint: "http://127.0.0.1:11434/v1", modelName: "qwen3.5:9b-q4_K_M", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Local Ollama", compactComposer: false, showDebugPanels: false, contextMode: .deep)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 1400)
    }

    func testApiQwenConnectorUsesApiBudget() async throws {
        let connector = ConnectorProfile(name: "Qwen API", kind: "openai-compatible", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", modelName: "qwen-plus", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(workspacePath: "/tmp", defaultConnectorName: "Qwen API", compactComposer: false, showDebugPanels: false, contextMode: .deep)
            ),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 7000)
    }

    func testStreamingOutputIsCoalescedAndFinalStepCarriesMetrics() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Agent",
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
                runtimeClient: StreamingRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("写一段长回复")
        store.sendDraft()
        try await waitUntilIdle(store)

        let outputs = store.state.selectedTask?.steps.filter { $0.kind == .textOutput } ?? []
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.text, "你好，世界")
        XCTAssertEqual(outputs.first?.metrics?.inputTokens, 12)
        XCTAssertEqual(outputs.first?.metrics?.outputTokens, 4)
    }

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

    func testStreamingDeltasUpdateCurrentThreadBeforeFinalOutput() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = StreamingRuntime()
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

        store.updateDraft("请写一段流式回答")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedTask?.steps.filter { $0.kind == .textOutput }.map(\.text), ["你好，世界"])
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

    func testSelectingConnectorUpdatesDefaultConnectorName() {
        let store = AppStore.preview()
        let target = try XCTUnwrap(store.state.connectors.last)

        store.selectConnector(id: target.id)

        XCTAssertEqual(store.state.activeConnectorID, target.id)
        XCTAssertEqual(store.state.settings.defaultConnectorName, target.name)
    }

    func testAddConnector() {
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            searchText: "",
            sessions: [],
            selectedSessionID: nil,
            workbenchTab: .tools,
            connectors: [],
            activeConnectorID: nil,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "None", compactComposer: false, showDebugPanels: false)
        ))

        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .ready)
        store.addConnector(connector)

        XCTAssertEqual(store.state.connectors.count, 1)
        XCTAssertEqual(store.state.activeConnectorID, connector.id)
    }

    func testCheckConnectorHealthMarksReady() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .offline)
        let runtime = HealthRuntime(health: .ready)
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.checkConnectorHealth(id: connector.id, showsToast: false)
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)

        XCTAssertEqual(runtime.healthRequests.count, 1)
        XCTAssertEqual(store.state.activeConnectorID, connector.id)
    }

    func testExplicitConnectorHealthProbeLearnsUnsupportedToolCallingCapability() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .offline)
        let runtime = ProbeHealthRuntime(result: .init(health: .ready, toolCallingCapability: .unsupported))
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.checkConnectorHealth(id: connector.id, showsToast: false)
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)

        XCTAssertEqual(runtime.probeRequests.map(\.probeToolCalling), [true])
        XCTAssertEqual(store.state.connectors.first?.toolCallingCapability, .unsupported)
        XCTAssertEqual(store.state.connectors.first?.toolCallingCapabilitySource, .connectorProbe)
        XCTAssertNotNil(store.state.connectors.first?.toolCallingCapabilityLearnedAt)
        XCTAssertTrue(store.state.toolActivities.contains {
            $0.name == "connector.capability" && $0.statusLine.contains("连接测试")
        })
    }

    func testAddConnectorAutomaticallyChecksHealthWhenConfigurationIsComplete() async throws {
        let runtime = HealthRuntime(health: .ready)
        let store = AppStore(
            state: testState(),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .attention)

        store.addConnector(connector)
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)

        XCTAssertEqual(runtime.healthRequests.count, 1)
        XCTAssertEqual(runtime.healthRequests.first?.endpoint, "https://example.com/v1")
    }

    func testAutomaticConnectorHealthRefreshSkipsToolCallingProbe() async throws {
        let runtime = ProbeHealthRuntime(result: .init(health: .ready, toolCallingCapability: .unsupported))
        let store = AppStore(
            state: testState(),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .attention)

        store.addConnector(connector)
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)

        XCTAssertEqual(runtime.probeRequests.map(\.probeToolCalling), [false])
        XCTAssertNil(store.state.connectors.first?.toolCallingCapability)
    }

    func testUpdateConnectorAutomaticallyRechecksHealthWhenConfigurationChanges() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .ready)
        let runtime = HealthRuntime(health: .ready)
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateConnector(ConnectorProfile(
            id: connector.id,
            name: connector.name,
            kind: connector.kind,
            endpoint: "https://example.com/v2",
            modelName: connector.modelName,
            note: connector.note,
            health: connector.health,
            lastCheckedAt: connector.lastCheckedAt
        ))
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)

        XCTAssertEqual(runtime.healthRequests.count, 1)
        XCTAssertEqual(runtime.healthRequests.first?.endpoint, "https://example.com/v2")
    }

    func testUpdatingConnectorIdentityClearsLearnedToolCallingCapabilityMetadata() {
        let learnedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingCapability: .unsupported,
            toolCallingCapabilitySource: .connectorProbe,
            toolCallingCapabilityLearnedAt: learnedAt,
            health: .ready
        )
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: HealthRuntime(health: .ready),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateConnector(ConnectorProfile(
            id: connector.id,
            name: connector.name,
            kind: connector.kind,
            endpoint: "https://example.com/v2",
            modelName: connector.modelName,
            note: connector.note,
            toolCallingPolicy: connector.toolCallingPolicy,
            toolCallingCapability: connector.toolCallingCapability,
            toolCallingCapabilitySource: connector.toolCallingCapabilitySource,
            toolCallingCapabilityLearnedAt: connector.toolCallingCapabilityLearnedAt,
            health: connector.health,
            lastCheckedAt: connector.lastCheckedAt
        ))

        XCTAssertNil(store.state.connectors.first?.toolCallingCapability)
        XCTAssertNil(store.state.connectors.first?.toolCallingCapabilitySource)
        XCTAssertNil(store.state.connectors.first?.toolCallingCapabilityLearnedAt)
    }

    func testSelectingAttentionConnectorAutomaticallyChecksHealth() async throws {
        let first = ConnectorProfile(name: "A", kind: "openai-compatible", endpoint: "https://example.com/a", modelName: "model-a", note: "key", health: .ready)
        let second = ConnectorProfile(name: "B", kind: "openai-compatible", endpoint: "https://example.com/b", modelName: "model-b", note: "key", health: .attention)
        let runtime = HealthRuntime(health: .ready)
        let store = AppStore(
            state: testState(connectors: [first, second], activeConnectorID: first.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.selectConnector(id: second.id)
        try await waitForConnectorHealth(store, id: second.id, health: .ready)

        XCTAssertEqual(store.state.activeConnectorID, second.id)
        XCTAssertEqual(runtime.healthRequests.count, 1)
        XCTAssertEqual(runtime.healthRequests.first?.endpoint, "https://example.com/b")
    }

    func testInFlightHealthCheckRetriesAgainstUpdatedConnectorConfiguration() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .attention)
        let runtime = PausedHealthRuntime()
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.checkConnectorHealth(id: connector.id, showsToast: false)
        try await waitForHealthRequestCount(runtime, count: 1)

        store.updateConnector(ConnectorProfile(
            id: connector.id,
            name: connector.name,
            kind: connector.kind,
            endpoint: "https://example.com/v2",
            modelName: connector.modelName,
            note: connector.note,
            health: connector.health,
            lastCheckedAt: connector.lastCheckedAt
        ))

        await runtime.resolveNext(with: .ready)
        try await waitForHealthRequestCount(runtime, count: 2)

        XCTAssertEqual(runtime.healthRequests.map(\.endpoint), ["https://example.com/v1", "https://example.com/v2"])
        XCTAssertEqual(store.state.connectors.first?.health, .attention)

        await runtime.resolveNext(with: .ready)
        try await waitForConnectorHealth(store, id: connector.id, health: .ready)
    }

    func testDirectProviderFailureMarksConnectorAttention() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .ready)
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: ProviderErrorRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你好")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.connectors.first?.health, .attention)
    }

    func testTaskProviderFailureMarksConnectorAttention() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .ready)
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: ProviderErrorRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedTask?.status, .failed)
        XCTAssertEqual(store.state.connectors.first?.health, .attention)
    }

    func testTaskCompatibilityFallbackDisablesToolsForFutureRuns() async throws {
        let connector = ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready)
        let runtime = ToolRejectedThenPlainRuntime()
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNil(store.state.connectors.first?.toolCallingPolicy)
        XCTAssertEqual(store.state.connectors.first?.toolCallingCapability, .unsupported)
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(store.state.toolActivities.contains { $0.name == "connector.capability" })

        store.selectTask(id: nil)
        store.updateDraft("请再搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.count, 3)
        XCTAssertNil(runtime.requests[2].tools)
        XCTAssertTrue(runtime.requests[2].messages?.first?.content?.contains("工具兼容限制") == true)
    }

    func testTaskSuccessLearnsToolCallingSupportForAutomaticMode() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        let updatedConnector = try XCTUnwrap(store.state.connectors.first)
        let profile = ConnectorCapabilityProfile.infer(for: updatedConnector, mode: .balanced)

        XCTAssertEqual(updatedConnector.toolCallingCapability, .supported)
        XCTAssertEqual(updatedConnector.toolCallingCapabilitySource, .taskRun)
        XCTAssertNotNil(updatedConnector.toolCallingCapabilityLearnedAt)
        XCTAssertEqual(profile.toolCallingSource, .learnedSupported)
        XCTAssertEqual(profile.learnedToolCallingSource, .taskRun)
        XCTAssertTrue(runtime.requests.first?.tools?.isEmpty == false)
    }

    func testClearingLearnedToolCallingCapabilityRestoresAutomaticToolUsageForFutureRuns() async throws {
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "",
            toolCallingCapability: .unsupported,
            health: .ready
        )
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertTrue(runtime.requests.first?.tools?.isEmpty ?? true)

        store.clearLearnedToolCallingCapability(id: connector.id, showsToast: false)

        let resetConnector = try XCTUnwrap(store.state.connectors.first)
        let resetProfile = ConnectorCapabilityProfile.infer(for: resetConnector, mode: .balanced)

        XCTAssertNil(resetConnector.toolCallingCapability)
        XCTAssertNil(resetConnector.toolCallingCapabilitySource)
        XCTAssertNil(resetConnector.toolCallingCapabilityLearnedAt)
        XCTAssertEqual(resetProfile.toolCallingSource, .automaticHeuristic)
        XCTAssertTrue(store.state.toolActivities.contains {
            $0.name == "connector.capability" && $0.summary.contains("已清除")
        })

        store.selectTask(id: nil)
        store.updateDraft("请再搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests[1].tools?.isEmpty == false)
    }

    func testSuccessfulChatMarksAttentionConnectorReady() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .attention)
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: StreamingRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你好")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.connectors.first?.health, .ready)
    }

    func testPreviouslySuccessfulConnectorStillNeedsRecheckOnLaunch() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .attention)
        let session = ChatSession(
            title: "已调通模型",
            preview: "你好",
            modelName: "Test",
            turns: [
                ChatTurn(role: .user, text: "你好"),
                ChatTurn(role: .assistant, text: "你好，世界")
            ]
        )

        let store = AppStore(state: testState(sessions: [session], connectors: [connector], activeConnectorID: connector.id))

        XCTAssertEqual(store.state.connectors.first?.health, .attention)
    }

    func testUpdatingConnectorSettingsResetsHealthToAttention() {
        let checkedAt = Date(timeIntervalSince1970: 1_713_000_000)
        let connector = ConnectorProfile(
            id: UUID(),
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            health: .ready,
            lastCheckedAt: checkedAt
        )
        let store = AppStore(state: testState(connectors: [connector], activeConnectorID: connector.id))

        store.updateConnector(ConnectorProfile(
            id: connector.id,
            name: connector.name,
            kind: connector.kind,
            endpoint: "https://example.com/v2",
            modelName: connector.modelName,
            note: connector.note,
            health: connector.health,
            lastCheckedAt: connector.lastCheckedAt
        ))

        XCTAssertEqual(store.state.connectors.first?.health, .attention)
        XCTAssertEqual(store.state.connectors.first?.lastCheckedAt, checkedAt)
    }

    func testUpdatingConnectorIdentityResetsLearnedToolCallingCapability() {
        let connector = ConnectorProfile(
            id: UUID(),
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingCapability: .unsupported,
            health: .ready
        )
        let store = AppStore(state: testState(connectors: [connector], activeConnectorID: connector.id))

        store.updateConnector(ConnectorProfile(
            id: connector.id,
            name: connector.name,
            kind: connector.kind,
            endpoint: connector.endpoint,
            modelName: "new-model",
            note: connector.note,
            toolCallingPolicy: connector.toolCallingPolicy,
            toolCallingCapability: connector.toolCallingCapability,
            health: connector.health,
            lastCheckedAt: connector.lastCheckedAt
        ))

        XCTAssertNil(store.state.connectors.first?.toolCallingCapability)
    }

    func testDeleteSession() {
        let store = AppStore.preview()
        let firstID = store.state.sessions.first?.id

        if let id = firstID {
            store.deleteSession(id: id)
            XCTAssertNil(store.state.sessions.first(where: { $0.id == id }))
        }
    }

    func testPinSession() {
        let store = AppStore.preview()
        let firstID = try XCTUnwrap(store.state.sessions.first?.id)
        let wasPinned = store.state.sessions.first?.isPinned ?? false

        store.pinSession(id: firstID)
        XCTAssertEqual(store.state.sessions.first?.isPinned, !wasPinned)
    }

    func testDeleteConnectorFallsBackToFirstRemaining() {
        let store = AppStore.preview()
        let activeID = try XCTUnwrap(store.state.activeConnectorID)

        store.deleteConnector(id: activeID)

        XCTAssertNotEqual(store.state.activeConnectorID, activeID)
        if let newActive = store.state.activeConnectorID {
            XCTAssertEqual(store.state.activeConnectorID, store.state.connectors.first?.id)
        }
    }

    func testNormalizesFailurePreview() {
        let raw = #"请求失败：provider returned {"error":{"message":"model does not exist","type":"invalid_request_error"}}"#

        XCTAssertEqual(normalizedSessionPreview(raw), "请求失败，请检查连接器配置。")
    }

    func testCapabilityQuestionStaysInChatMode() {
        XCTAssertEqual(IntentRouter.classify("你能生成视频吗？"), .chat)
        XCTAssertEqual(IntentRouter.classify("你可以创建图片吗?"), .chat)
        XCTAssertEqual(IntentRouter.classify("你能联网搜索吗？"), .chat)
        XCTAssertEqual(IntentRouter.classify("你支持运行测试吗？"), .chat)
    }

    func testConcreteGenerationRequestBecomesTask() {
        XCTAssertEqual(IntentRouter.classify("帮我生成一个 README"), .task)
    }

    func testPoliteExplanationRequestStaysInChatMode() {
        XCTAssertEqual(IntentRouter.classify("请先解释一下"), .chat)
        XCTAssertEqual(IntentRouter.classify("请说说你的能力"), .chat)
    }

    func testExplicitToolRequestsBecomeTask() {
        XCTAssertEqual(IntentRouter.classify("请帮我联网搜索一下 Qwen3.6 相比 3.5 有哪些新能力？"), .task)
        XCTAssertEqual(IntentRouter.classify("为什么不能联网搜搜呢？"), .task)
        XCTAssertEqual(IntentRouter.classify("上网查一下 Qwen3.6"), .task)
        XCTAssertEqual(IntentRouter.classify("帮我搜一下 Qwen3.6 比 Qwen3.5 强多少"), .task)
        XCTAssertEqual(IntentRouter.classify("读一下 https://example.com 这个页面"), .task)
        XCTAssertEqual(IntentRouter.classify("跑测试看看有没有问题"), .task)
    }

    func testFreshNewsRequestBecomesTask() {
        XCTAssertEqual(IntentRouter.classify("你先给我整理下今天的早间新闻，重点在AI领域"), .task)
        XCTAssertEqual(IntentRouter.classify("今天 AI 领域有什么最新动态？"), .task)
    }

    func testCurrentModelComparisonBecomesTask() {
        let decision = IntentRouter.plan("glm-5.1和kimi k2.6 能力对比")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertTrue(decision.expectedCapabilities.contains("联网检索"))
    }

    func testProjectRewritePlansReadAndMutation() {
        let decision = IntentRouter.plan("你能读取本地的项目吧？并且优化项目，直接改写本地文件")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertTrue(decision.expectedCapabilities.contains("读取工作区"))
        XCTAssertTrue(decision.expectedCapabilities.contains("提出文件修改"))
    }

    func testWorkflowRequestsRouteBySemanticGoal() {
        let decision = IntentRouter.plan("帮我审查一下这次改动")

        XCTAssertEqual(decision.intent, .workflow("code-review"))
        XCTAssertTrue(decision.reason.contains("代码审查"))
        XCTAssertTrue(decision.expectedCapabilities.contains("审查风险"))
        XCTAssertEqual(IntentRouter.classify("给这个模块补测试用例"), .workflow("test-gen"))
        XCTAssertEqual(IntentRouter.classify("排查一下这个报错"), .workflow("debug"))
    }

    func testWorkflowKeywordsNeedCodeOrProjectContext() {
        XCTAssertEqual(IntentRouter.classify("review 一下 Claude Code 和 Codex 的体验差距"), .chat)
        XCTAssertEqual(IntentRouter.classify("这个词怎么翻译更自然？"), .chat)
        XCTAssertEqual(IntentRouter.classify("帮我翻译这个文件"), .workflow("translate"))
    }

    func testPlannerDecisionExplainsRoute() {
        let decision = IntentRouter.plan("帮我搜一下 Qwen3.6 比 Qwen3.5 强多少")

        XCTAssertEqual(decision.intent, .task)
        XCTAssertGreaterThan(decision.confidence, 0.8)
        XCTAssertEqual(decision.routeLabel, "任务")
        XCTAssertTrue(decision.expectedCapabilities.contains("联网检索"))
        XCTAssertFalse(decision.reason.isEmpty)
    }

    func testFrustrationDetectorRecognizesContextLossComplaints() {
        XCTAssertTrue(UserFrustrationDetector.isFrustrated("你看，胡说八道了，刚才那个会话上下文没了"))
        XCTAssertTrue(UserFrustrationDetector.shouldRecoverRecentTask("输出被截断了，然后又新建线程"))
        XCTAssertFalse(UserFrustrationDetector.isFrustrated("请解释一下这个概念"))
    }

    func testFrustratedDirectChatAddsRepairGuidance() async throws {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let runtime = CapturingToolsRuntime()
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: runtime,
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateDraft("你又胡说八道了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.first?.tools?.isEmpty ?? true, true)
        XCTAssertTrue(runtime.requests.first?.systemPrompt?.contains("证据优先修复模式") == true)
    }

    func testSelectingSessionClearsSelectedTask() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: [session],
            selectedSessionID: nil,
            workbenchTab: .tools,
            connectors: [],
            activeConnectorID: nil,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "None", compactComposer: false, showDebugPanels: false),
            tasks: [task],
            selectedTaskID: task.id
        ))

        store.selectSession(id: session.id)

        XCTAssertEqual(store.state.selectedSessionID, session.id)
        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.selectedThreadSource, .session)
    }

    func testSelectingTaskSetsAuthoritativeThreadSelection() {
        let session = ChatSession(title: "会话", preview: "", modelName: "test")
        let task = AgentTask(title: "任务")
        let store = AppStore(state: testState(sessions: [session], tasks: [task], selectedTaskID: task.id))

        store.selectSession(id: session.id)
        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.selectedThreadSource, .session)

        store.selectTask(id: task.id)
        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.selectedThreadSource, .task)
        XCTAssertEqual(store.state.selectedTaskID, task.id)
        XCTAssertNil(store.state.selectedSessionID)
    }

    func testUnifiedThreadSearchMatchesTaskStepsAndTools() {
        let session = ChatSession(title: "普通聊天", preview: "你好", modelName: "test")
        let task = AgentTask(title: "任务", steps: [
            TaskStep(kind: .toolCall, text: "正在读取文件", toolName: "file.read"),
            TaskStep(kind: .toolResult, text: "发现 selectedThreadID 双轨状态")
        ])
        var state = testState(sessions: [session], tasks: [task])
        state.searchText = "selectedThreadID"

        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])

        state.searchText = "file.read"
        XCTAssertEqual(state.filteredThreads.map(\.id), [task.id])
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

    func testDeleteTurnUpdatesPreviewToRemainingLastMessage() {
        let first = ChatTurn(role: .user, text: "第一条")
        let second = ChatTurn(role: .assistant, text: "第二条")
        let session = ChatSession(title: "会话", preview: second.text, modelName: "test", turns: [first, second])
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: [session],
            selectedSessionID: session.id,
            workbenchTab: .tools,
            connectors: [],
            activeConnectorID: nil,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "None", compactComposer: false, showDebugPanels: false)
        ))

        store.deleteTurn(sessionID: session.id, turnID: second.id)

        XCTAssertEqual(store.state.selectedSession?.turns.map(\.id), [first.id])
        XCTAssertEqual(store.state.selectedSession?.preview, first.text)
    }

    func testSQLiteRepositoryPersistsTaskContext() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let task = AgentTask(
            title: "读取项目",
            status: .running,
            steps: [TaskStep(kind: .toolCall, text: "读取文件", toolName: "file.read", toolParams: ["path": "README.md"])],
            connectorID: UUID(),
            workflowName: "代码分析",
            context: TaskContext(
                workspaceRoot: "/tmp/workspace",
                relevantFiles: [
                    FileInfo(path: "README.md", language: "md", summary: "项目说明"),
                    FileInfo(path: "Sources/App.swift", language: "swift", summary: "入口")
                ],
                claudeMD: "记忆",
                gitBranch: "main",
                gitDiff: "1 file changed, 3 insertions(+)"
            )
        )

        try repository.saveTasks([task])
        let loaded = try XCTUnwrap(repository.loadTasks())
        let restored = try XCTUnwrap(loaded.first)

        XCTAssertEqual(restored.context.workspaceRoot, task.context.workspaceRoot)
        XCTAssertEqual(restored.context.gitBranch, task.context.gitBranch)
        XCTAssertEqual(restored.context.gitDiff, task.context.gitDiff)
        XCTAssertEqual(restored.context.relevantFiles.map(\.path), task.context.relevantFiles.map(\.path))
    }

    func testSQLiteRepositoryPersistsConnectorCapabilityMetadata() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let learnedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingPolicy: .automatic,
            toolCallingCapability: .supported,
            toolCallingCapabilitySource: .connectorProbe,
            toolCallingCapabilityLearnedAt: learnedAt,
            health: .ready
        )

        try repository.saveConnectors([connector], activeConnectorID: connector.id)
        let catalog = try XCTUnwrap(repository.loadConnectorCatalog())
        let restored = try XCTUnwrap(catalog.connectors.first)

        XCTAssertEqual(restored.toolCallingCapability, .supported)
        XCTAssertEqual(restored.toolCallingCapabilitySource, .connectorProbe)
        XCTAssertEqual(restored.toolCallingCapabilityLearnedAt, learnedAt)
        XCTAssertEqual(catalog.activeConnectorID, connector.id)
    }

    func testSQLiteRepositoryPersistsUnifiedThreadSnapshot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let task = AgentTask(
            title: "统一线程",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "生成 README", isCollapsible: false, isCollapsed: false),
                TaskStep(kind: .textOutput, text: "已生成")
            ],
            context: TaskContext(workspaceRoot: "/tmp/workspace")
        )
        let thread = ThreadRecord(task: task)

        try repository.saveThreads([thread])
        let loaded = try XCTUnwrap(repository.loadThreads())
        let restored = try XCTUnwrap(loaded.first)

        XCTAssertEqual(restored.id, thread.id)
        XCTAssertEqual(restored.title, "统一线程")
        XCTAssertEqual(restored.events.map(\.kind), [.user, .assistant])
        XCTAssertEqual(restored.task?.steps.map(\.text), ["生成 README", "已生成"])
    }

    func testToolResultFormatterSummarizesFileRead() {
        let result = ToolResult(
            output: "line 1\nline 2\nline 3",
            data: ["path": "README.md", "size": "20"]
        )

        let summary = ToolResultFormatter.displayText(toolName: "file.read", arguments: [:], result: result)

        XCTAssertTrue(summary.contains("README.md"))
        XCTAssertTrue(summary.contains("3 行"))
        XCTAssertFalse(summary.contains("line 1"))
    }

    func testToolResultFormatterCompressesLongModelContent() {
        let output = String(repeating: "abcdefg\n", count: 600)
        let content = ToolResultFormatter.modelContent(
            toolName: "code.search",
            result: ToolResult(output: output),
            limit: 1200
        )

        XCTAssertLessThan(content.count, output.count)
        XCTAssertTrue(content.contains("中间内容已省略"))
    }

    func testToolStepFormatterUsesProductLanguage() {
        XCTAssertEqual(
            ToolStepFormatter.callText(toolName: "file.read", arguments: ["path": "README.md"]),
            "正在读取文件：README.md"
        )
        XCTAssertEqual(
            ToolStepFormatter.callText(toolName: "code.search", arguments: ["query": "AppStore", "scope": "content"]),
            "正在搜索项目内容：AppStore"
        )
    }

    func testBuildURLExpandsOpenAICompatibleBaseEndpoint() {
        let base = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1", kind: "openai-compatible")
        let full = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1/chat/completions", kind: "openai-compatible")
        let malformed = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1/api/chat", kind: "openai-compatible")
        let wrongKind = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1", kind: "ollama")

        XCTAssertEqual(base.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(full.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(malformed.absoluteString, "https://api.deepseek.com/v1/api/chat")
        XCTAssertEqual(wrongKind.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }

    func testGenericOpenAICompatibleURLUsesUserInputExactly() {
        let url = LiveChatRuntime.buildURL(from: "https://api.example.com/custom", kind: "openai-compatible")

        XCTAssertEqual(url.absoluteString, "https://api.example.com/custom")
    }

    func testOllamaURLExpandsBaseEndpoints() {
        let base = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434", kind: "ollama")
        let apiBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/api", kind: "ollama")
        let compatBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/v1", kind: "ollama")
        let explicitNative = LiveChatRuntime.buildURL(from: "http://127.0.0.1:53759/api/chat", kind: "ollama")
        let explicitCompat = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/v1/chat/completions", kind: "ollama")

        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(apiBase.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(compatBase.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(explicitNative.absoluteString, "http://127.0.0.1:53759/api/chat")
        XCTAssertEqual(explicitCompat.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testMalformedEndpointFallsBackWithoutCrashing() {
        let url = LiveChatRuntime.buildURL(from: "not a url", kind: "openai-compatible")

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1/invalid-endpoint")
    }

    func testServiceBaseStripsChatCompletionPathForHealthCheck() {
        XCTAssertEqual(
            LiveChatRuntime.serviceBaseEndpoint(from: "https://api.deepseek.com/v1/chat/completions"),
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(
            LiveChatRuntime.serviceBaseEndpoint(from: "https://api.example.com/v1/chat/completions"),
            "https://api.example.com"
        )
    }

    func testOpenAICompatibleHealthCheckRequiresRequestedModelWhenModelListIsAvailable() async throws {
        let session = makeStubbedSession(body: #"{"data":[{"id":"other-model"}]}"#.data(using: .utf8)!)
        let runtime = LiveChatRuntime(session: session)

        let health = try await runtime.healthCheck(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible"
        )

        XCTAssertEqual(health, .attention)
    }

    func testLiveChatRuntimeProbeConnectorMarksSupportedWhenToolProbeSucceeds() async throws {
        var requestBodies: [String] = []
        let session = makeStubbedSession { request in
            let url = request.url ?? URL(string: "https://example.com")!
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
            }
            if let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) {
                requestBodies.append(body)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.data(using: .utf8)!)
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: true
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertEqual(result.toolCallingCapability, .supported)
        XCTAssertEqual(requestBodies.count, 1)
        XCTAssertTrue(requestBodies[0].contains("\"tools\""))
    }

    func testLiveChatRuntimeProbeConnectorMarksUnsupportedWhenToolProbeRejectsTools() async throws {
        let session = makeStubbedSession { request in
            let url = request.url ?? URL(string: "https://example.com")!
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 422,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"error":{"message":"tools are not supported by this model"}}"#.data(using: .utf8)!)
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: true
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertEqual(result.toolCallingCapability, .unsupported)
    }

    func testLiveChatRuntimeProbeConnectorSkipsToolProbeWhenDisabled() async throws {
        var requestMethods: [String] = []
        let session = makeStubbedSession { request in
            requestMethods.append(request.httpMethod ?? "")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: false
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertNil(result.toolCallingCapability)
        XCTAssertEqual(requestMethods, ["GET"])
    }

    func testSearchToolFindsExistingFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("README.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertEqual(result.data?["count"], "1")
    }

    func testSearchToolReturnsClearEmptyResult() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"MissingFile","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("未找到匹配文件"))
    }

    func testReadFileToolReadsSmallFileWithinWorkspace() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "one\ntwo\nthree".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"notes.txt","offset":2,"limit":1}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "two")
        XCTAssertEqual(result.data?["path"], "notes.txt")
    }

    func testReadFileToolListsDirectory() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".","limit":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("Sources/"))
        XCTAssertEqual(result.data?["type"], "directory")
    }

    func testReadFileToolTruncatesLargeFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let largeText = String(repeating: "0123456789\n", count: 6000)
        try largeText.write(to: workspace.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"large.txt"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertLessThan(result.output.count, largeText.count)
        XCTAssertTrue(result.output.contains("已截断"))
    }

    func testToolsRequireWorkspaceForRelativeOperations() async throws {
        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"README.md"}"#,
            context: TaskContext(workspaceRoot: "")
        )
        let search = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files"}"#,
            context: TaskContext(workspaceRoot: "")
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "workspace_missing")
        XCTAssertFalse(search.success)
        XCTAssertEqual(search.error, "workspace_missing")
    }

    func testToolDefinitionsExposeAPICompatibleNames() {
        let names = ToolRegistry.shared.toolDefinitions.map(\.function.name)

        XCTAssertTrue(names.contains("file_read"))
        XCTAssertTrue(names.contains("code_search"))
        XCTAssertTrue(names.contains("workspace_index"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertTrue(names.contains("wiki_build"))
        XCTAssertFalse(names.contains("file.read"))
        XCTAssertFalse(names.contains("code.search"))
    }

    func testShellToolDefinitionSteersProjectReadingToStructuredTools() {
        let shellDefinition = ToolRegistry.shared.toolDefinitions.first { $0.function.name == "shell_exec" }
        let commandDescription = shellDefinition?.function.parameters.properties["command"]?.description ?? ""

        XCTAssertTrue(commandDescription.contains("workspace_index"))
        XCTAssertTrue(commandDescription.contains("code_search"))
        XCTAssertTrue(commandDescription.contains("file_read"))
        XCTAssertTrue(commandDescription.contains("不要用"))
    }

    func testAgentLoopOmitsToolsForPlainChat() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "你能做什么？",
            intent: .chat,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(runtime.requests.first?.tools)
    }

    func testAgentLoopInjectsStructuredMemoryForContinuation() {
        let steps = [
            TaskStep(kind: .toolCall, text: "正在建立项目索引", toolName: "workspace.index"),
            TaskStep(kind: .toolResult, text: "已建立项目索引", toolName: "workspace.index"),
            TaskStep(kind: .toolCall, text: "搜索 AppStore", toolName: "code.search", toolParams: ["query": "AppStore"]),
            TaskStep(kind: .toolResult, text: "读取 README", toolName: "file.read", toolParams: ["path": "README.md"]),
            TaskStep(kind: .toolResult, text: "失败：工具策略拦截", toolName: "shell.exec", isFailure: true),
            TaskStep(kind: .textOutput, text: "项目入口在 native-macos。"),
            TaskStep(kind: .aiThinking, text: "任务检查点\n状态：失败\n建议下一步：继续读入口")
        ]

        let memory = AgentLoop.structuredTaskMemory(from: steps)
        let messages = AgentLoop.initialMessages(
            systemPrompt: "system",
            message: "继续",
            priorSteps: steps
        )

        XCTAssertTrue(memory?.contains("已建立工作区索引：是") == true)
        XCTAssertTrue(memory?.contains("README.md") == true)
        XCTAssertTrue(memory?.contains("shell.exec ×1") == true)
        XCTAssertTrue(messages.contains { $0.content?.contains("结构化任务记忆") == true })
        XCTAssertTrue(messages.contains { $0.content?.contains("不要重复已经成功的读取或搜索") == true })
    }

    func testTruncatedContinuationDoesNotBootstrapWorkspaceSearch() async throws {
        let runtime = CapturingContinuationRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )
        let priorSteps = [
            TaskStep(kind: .userInput, text: "今天有什么 AI 新闻？"),
            TaskStep(kind: .textOutput, text: "前半段新闻内容"),
            TaskStep(kind: .error, text: "输出达到当前上限（1024 tokens），内容可能被截断。", recoverable: true)
        ]

        let task = try await loop.run(
            message: "继续",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp"),
            priorSteps: priorSteps
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("本轮不会搜索") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall })
        XCTAssertEqual(runtime.requests.count, 1)
        XCTAssertNil(runtime.requests.first?.tools)
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("上一条回复因为输出上限被截断") } == true)
    }

    func testAgentLoopExecutesFallbackRecoveryTool() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = ShellTraversalThenFinalRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取项目",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "shell.exec" && $0.isFailure })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "workspace.index" && $0.text.contains("自动恢复") })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure && $0.text.contains("自动恢复成功") })
        XCTAssertTrue(runtime.requests.contains { request in
            request.messages.contains { $0.role == "user" && ($0.content ?? "").contains("自动恢复工具 workspace.index") }
        })
    }

    func testAgentLoopIncludesToolsForTasks() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "搜索 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertTrue(runtime.requests.first?.tools?.contains { $0.function.name == "code_search" } == true)
        XCTAssertEqual(runtime.requests.first?.maxOutputTokens, 1024)
    }

    func testAgentLoopOmitsToolsWhenConfigDisablesToolCalling() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp", supportsToolCalling: false),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "搜索 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(runtime.requests.first?.tools)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("已关闭工具调用") })
        XCTAssertTrue(runtime.requests.first?.messages?.first?.content?.contains("工具兼容限制") == true)
    }

    func testAgentLoopRetriesWithoutToolsWhenProviderRejectsToolCallingFormat() async throws {
        let runtime = ToolRejectedThenPlainRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理今天新闻",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests.first?.tools?.isEmpty == false)
        XCTAssertNil(runtime.requests.last?.tools)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("不兼容工具调用请求") })
        XCTAssertTrue(runtime.requests.last?.messages?.first?.content?.contains("工具兼容限制") == true)
    }

    func testAgentLoopAddsPlanVerifySummaryForComplexTasks() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取这个项目并找问题",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("执行计划") })
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("阶段总结") })
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("证据清单") })
        XCTAssertTrue(runtime.requests.first?.systemPrompt?.contains("Plan / Execute / Verify / Summarize") == true)
    }

    func testAgentLoopCarriesPersistedTaskMemoryIntoInitialMessages() {
        let context = TaskContext(
            workspaceRoot: "/tmp",
            memory: TaskMemory(
                readFiles: ["Sources/AppStore.swift"],
                searchedQueries: ["selectedThreadID"],
                failedTools: ["shell.exec ×1"],
                stageConclusions: ["已确认选中态需要统一。"],
                checkpoints: ["任务检查点：继续迁移线程。"],
                verificationStatus: "typecheck 已通过。",
                pendingFiles: ["Sources/SidebarView.swift"],
                userDecisions: ["用户要求不要重复搜索"]
            )
        )

        let messages = AgentLoop.initialMessages(
            systemPrompt: "system",
            message: "你又没读上下文，继续刚才任务",
            priorSteps: [],
            context: context
        )
        let combined = messages.map(\.content).joined(separator: "\n")

        XCTAssertTrue(combined.contains("Sources/AppStore.swift"))
        XCTAssertTrue(combined.contains("selectedThreadID"))
        XCTAssertTrue(combined.contains("shell.exec ×1"))
        XCTAssertTrue(combined.contains("typecheck 已通过"))
        XCTAssertTrue(combined.contains("Sources/SidebarView.swift"))
        XCTAssertTrue(combined.contains("用户要求不要重复搜索"))
        XCTAssertTrue(combined.contains("证据优先修复模式"))
    }

    func testAgentLoopBootstrapsWebSearchForFreshRequests() {
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "帮我整理今天的 AI 新闻", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "看看这个链接 https://example.com", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "glm-5.1和kimi k2.6 能力对比", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "为什么不能联网搜搜呢", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "上网查一下 Qwen3.6", intent: .task))
        XCTAssertFalse(AgentLoop.shouldBootstrapWebSearch(for: "为什么有的会话能调用联网工具", intent: .task))
        XCTAssertFalse(AgentLoop.shouldBootstrapWebSearch(for: "帮我整理今天的 AI 新闻", intent: .chat))

        let json = AgentLoop.bootstrapWebSearchArgumentsJSON(for: "帮我整理今天的 AI 新闻")
        XCTAssertTrue(json.contains("maxResults"))
        XCTAssertTrue(json.contains("今天"))
    }

    func testGenericWebFollowUpCarriesPreviousSubject() {
        let prior = [
            TaskStep(kind: .userInput, text: "glm-5.1和kimi k2.6 能力对比"),
            TaskStep(kind: .textOutput, text: "初步回答")
        ]

        let message = AgentLoop.bootstrapWebSearchMessage(
            for: "联网搜一下，另外，如果你一条输出不完，你可以输出两条",
            priorSteps: prior
        )

        XCTAssertTrue(message.contains("glm-5.1和kimi k2.6 能力对比"))
        XCTAssertTrue(message.contains("联网搜一下"))
    }

    func testAgentLoopBootstrapsWorkspaceSearchForTasks() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "Native harness notes".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "请解释 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "code.search" && $0.text.contains("README") })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.read" && $0.text.contains("README.md") })
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("自动读取的首个高相关文件片段") } == true)
        XCTAssertFalse(AgentLoop.shouldBootstrapWorkspaceSearch(for: "帮我整理今天的 AI 新闻", intent: .task, context: TaskContext(workspaceRoot: workspace.path)))
    }

    func testAgentLoopBootstrapsLocalPathReadBeforeWorkspaceSearch() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "attached".write(to: workspace.appendingPathComponent("attached.txt"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "请读取这个路径：\(workspace.appendingPathComponent("attached.txt").path)",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.read" && $0.text.contains("attached") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
    }

    func testWorkspaceIndexToolSummarizesProjectStructure() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try "# App".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let value = 1".write(to: workspace.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try "import XCTest".write(to: workspace.appendingPathComponent("Tests/AppTests/AppTests.swift"), atomically: true, encoding: .utf8)
        try "token".write(to: workspace.appendingPathComponent("Sources/App/auth_token.swift"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceIndexTool().execute(
            argumentsJSON: #"{"maxFiles":20,"maxDepth":5}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("swift"))
        XCTAssertTrue(result.output.contains("入口候选"))
        XCTAssertTrue(result.output.contains("测试候选"))
        XCTAssertTrue(result.output.contains("配置候选"))
        XCTAssertTrue(result.output.contains("风险/关注候选"))
        XCTAssertTrue(result.output.contains("Sources/App/main.swift"))
        XCTAssertTrue(result.output.contains("Tests/AppTests/AppTests.swift"))
        XCTAssertTrue(result.output.contains("Sources/App/auth_token.swift"))
        XCTAssertEqual(result.data?["fileCount"], "4")
        XCTAssertEqual(result.data?["entryCount"], "2")
        XCTAssertEqual(result.data?["testCount"], "1")
        XCTAssertEqual(result.data?["riskCount"], "1")
    }

    func testAgentLoopBootstrapsWorkspaceIndexForWholeProjectRequests() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "# App".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取这个项目并找问题",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(AgentLoop.shouldBootstrapWorkspaceIndex(for: "全量读取这个项目并找问题", intent: .task))
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "workspace.index" })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
    }

    func testBroadProjectImprovementUsesAuditSearchQuery() {
        let query = AgentLoop.bootstrapWorkspaceSearchQuery(for: "你能读取本地的项目吧？并且优化项目，直接改写本地文件")

        XCTAssertTrue(query.contains("TODO"))
        XCTAssertTrue(query.contains("ChatSession"))
        XCTAssertFalse(query.contains("你能读取"))
    }

    func testGenericContinuationDoesNotBecomeWorkspaceSearchQuery() {
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "继续"), "")
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "接着说"), "")
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "没发完"), "")
    }

    func testAgentLoopExtractsReadablePathFromSearchOutput() {
        let root = "/tmp/project"
        XCTAssertEqual(
            AgentLoop.firstReadablePath(inSearchOutput: "/tmp/project/Sources/AppStore.swift:12:final class AppStore", workspaceRoot: root),
            "Sources/AppStore.swift"
        )
        XCTAssertEqual(
            AgentLoop.firstReadablePath(inSearchOutput: "README.md", workspaceRoot: root),
            "README.md"
        )
        XCTAssertNil(
            AgentLoop.firstReadablePath(inSearchOutput: "/tmp/project/assets/icon.png:binary", workspaceRoot: root)
        )
    }

    func testAgentLoopAutoContinuesWhenProviderStopsForLength() async throws {
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: LengthThenContinuationRuntime()
        )

        let task = try await loop.run(
            message: "写一篇长文",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("正在自动续写下一段") })
        XCTAssertEqual(task.steps.filter { $0.kind == .textOutput }.map(\.text), [
            "这是一段被供应商截断的回复",
            "这是自动续写的第二段。"
        ])
    }

    func testAppSettingsDecodesBalancedContextModeByDefault() throws {
        let json = #"{"workspacePath":"/tmp","defaultConnectorName":"Test","compactComposer":false,"showDebugPanels":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.contextMode, .balanced)
    }

    func testAutoContextRespectsRelevantFileLimit() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "one".write(to: workspace.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "two".write(to: workspace.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace.path,
            userInput: "swift",
            fileLimit: 1
        )

        XCTAssertLessThanOrEqual(context.relevantFiles.count, 1)
    }

    func testAutoContextLoadsAgentsAndClaudeInstructions() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "agent rule".write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "claude rule".write(to: workspace.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let cursorRules = workspace.appendingPathComponent(".cursor/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorRules, withIntermediateDirectories: true)
        try "cursor rule".write(to: cursorRules.appendingPathComponent("project.mdc"), atomically: true, encoding: .utf8)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace.path,
            userInput: "读取项目",
            fileLimit: 0
        )

        XCTAssertTrue(context.claudeMD?.contains("### AGENTS.md") == true)
        XCTAssertTrue(context.claudeMD?.contains("agent rule") == true)
        XCTAssertTrue(context.claudeMD?.contains("### CLAUDE.md") == true)
        XCTAssertTrue(context.claudeMD?.contains("cursor rule") == true)
    }

    func testTokenBudgetBreakdownIncludesContextCategories() throws {
        let context = TaskContext(
            workspaceRoot: "/tmp/project",
            relevantFiles: [FileInfo(path: "Sources/App.swift", summary: "UI entry")],
            claudeMD: "project instructions",
            memory: TaskMemory(
                readFiles: ["Sources/App.swift"],
                searchedQueries: ["selectedThreadID"],
                failedTools: ["shell.exec"],
                stageConclusions: ["阶段结论"],
                checkpoints: ["下一步继续验证"],
                verificationStatus: "typecheck passed",
                pendingFiles: ["/tmp/attachment.md"],
                userDecisions: ["用户要求继续同一任务"]
            )
        )

        let budget = TokenBudget.estimate(context: context, userInput: "继续优化", mode: .balanced)

        XCTAssertGreaterThan(budget.inputTokens, 0)
        XCTAssertGreaterThan(budget.projectTokens, 0)
        XCTAssertGreaterThan(budget.memoryTokens, 0)
        XCTAssertGreaterThan(budget.toolTokens, 0)
        XCTAssertGreaterThan(budget.attachmentTokens, 0)
        XCTAssertGreaterThan(budget.systemReserveTokens, 0)
        XCTAssertTrue(budget.breakdownRows.contains { $0.label == "任务记忆" })
    }

    func testConnectorCapabilityProfileDoesNotTreatQwenAPIAsLocal() {
        let apiQwen = ConnectorProfile(
            name: "Qwen API",
            kind: "openai-compatible",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            modelName: "qwen-plus",
            note: "",
            health: .ready
        )
        let localQwen = ConnectorProfile(
            name: "Local Ollama",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434/v1",
            modelName: "qwen3.5:9b-q4_K_M",
            note: "",
            health: .ready
        )

        let apiProfile = ConnectorCapabilityProfile.infer(for: apiQwen, mode: .deep)
        let localProfile = ConnectorCapabilityProfile.infer(for: localQwen, mode: .deep)

        XCTAssertFalse(apiProfile.isLocal)
        XCTAssertEqual(apiProfile.maxIterations, ContextMode.deep.maxIterations)
        XCTAssertEqual(apiProfile.maxTokensPerTurn, ContextMode.deep.maxTokensPerTurn)
        XCTAssertNil(apiProfile.directOutputLimit)
        XCTAssertTrue(localProfile.isLocal)
        XCTAssertLessThan(localProfile.maxTokensPerTurn, apiProfile.maxTokensPerTurn)
        XCTAssertEqual(localProfile.directOutputLimit, 512)
    }

    func testConnectorCapabilityProfileRespectsDisabledToolCallingPolicy() {
        let connector = ConnectorProfile(
            name: "Local",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434",
            modelName: "qwen",
            note: "",
            toolCallingPolicy: .disabled,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertFalse(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .manualDisabled)
    }

    func testConnectorCapabilityProfilePrefersLearnedUnsupportedInAutomaticMode() {
        let connector = ConnectorProfile(
            name: "Local",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434",
            modelName: "qwen",
            note: "",
            toolCallingCapability: .unsupported,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertFalse(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .learnedUnsupported)
    }

    func testConnectorCapabilityProfileDescribesManualOverrideConflict() {
        let connector = ConnectorProfile(
            name: "Remote",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "",
            toolCallingPolicy: .enabled,
            toolCallingCapability: .unsupported,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertTrue(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingConflict, .unsupported)
        XCTAssertEqual(profile.toolCallingSourceDetail, "手动开启，覆盖已验证不兼容")
    }

    func testClearingLearnedToolCallingCapabilityKeepsManualOverrideEffective() {
        let connector = ConnectorProfile(
            name: "Remote",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "",
            toolCallingPolicy: .enabled,
            toolCallingCapability: .unsupported,
            health: .ready
        )
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: CapturingToolsRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.clearLearnedToolCallingCapability(id: connector.id, showsToast: false)

        let updatedConnector = store.state.connectors.first
        XCTAssertNotNil(updatedConnector)
        XCTAssertNil(updatedConnector?.toolCallingCapability)
        XCTAssertNil(updatedConnector?.toolCallingCapabilitySource)
        XCTAssertNil(updatedConnector?.toolCallingCapabilityLearnedAt)
        let profile = ConnectorCapabilityProfile.infer(for: updatedConnector, mode: .balanced)
        XCTAssertTrue(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .manualEnabled)
        XCTAssertNil(profile.toolCallingConflict)
        XCTAssertEqual(profile.toolCallingSourceDetail, "手动开启")
    }

    func testToolRegistryAcceptsAPICompatibleAliases() {
        XCTAssertEqual(ToolNameCodec.canonicalName("file_read"), "file.read")
        XCTAssertEqual(ToolNameCodec.canonicalName("code_search"), "code.search")
        XCTAssertEqual(ToolNameCodec.canonicalName("web_search"), "web.search")
        XCTAssertEqual(ToolNameCodec.canonicalName("web_fetch"), "web.fetch")
        XCTAssertEqual(ToolNameCodec.canonicalName("wiki_build"), "wiki.build")
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "file_read"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "code_search"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "web_search"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "web_fetch"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "wiki_build"))
    }

    func testWebFetchExtractsReadableTextFromHTML() {
        let html = """
        <html><head><title>Example &amp; Test</title><style>.x{}</style></head>
        <body><nav>menu</nav><h1>Hello</h1><p>Readable content &quot;here&quot;.</p><script>alert(1)</script></body></html>
        """

        let result = WebFetchTool.extractReadableText(fromHTML: html, url: "https://example.com/page", maxCharacters: 500)

        XCTAssertEqual(result.title, "Example & Test")
        XCTAssertTrue(result.content.contains("Hello"))
        XCTAssertTrue(result.content.contains(#"Readable content "here"."#))
        XCTAssertFalse(result.content.contains("alert"))
        XCTAssertFalse(result.content.contains("menu"))
    }

    func testAgentLoopBootstrapsWebFetchForExplicitURL() {
        XCTAssertEqual(
            AgentLoop.firstURL(in: "读一下 https://example.com/a?b=1，然后创建 skill"),
            "https://example.com/a?b=1"
        )

        let json = AgentLoop.bootstrapWebFetchArgumentsJSON(for: "https://example.com")
        XCTAssertTrue(json.contains("https://example.com"))
        XCTAssertTrue(json.contains("maxCharacters"))
    }

    func testFunctionCallArgumentsDecodeObjectPayloads() throws {
        let json = #"{"name":"web_search","arguments":{"query":"AI news","maxResults":3}}"#.data(using: .utf8)!
        let detail = try JSONDecoder().decode(FunctionCallDetail.self, from: json)

        XCTAssertEqual(detail.name, "web_search")
        XCTAssertTrue(detail.arguments.contains(#""query":"AI news""#))
        XCTAssertTrue(detail.arguments.contains(#""maxResults":3"#))
    }

    func testThreadRecordAdaptsSessionsAndTasks() {
        let turn = ChatTurn(role: .user, text: "hello")
        let session = ChatSession(title: "Chat", preview: "hello", modelName: "m", turns: [turn])
        let sessionThread = ThreadRecord(session: session)

        XCTAssertEqual(sessionThread.source, .session)
        XCTAssertEqual(sessionThread.events.first?.kind, .user)
        XCTAssertEqual(sessionThread.events.first?.text, "hello")

        let step = TaskStep(kind: .toolCall, text: "search", toolName: "web.search")
        let task = AgentTask(title: "Task", status: .running, steps: [step])
        let taskThread = ThreadRecord(task: task)

        XCTAssertEqual(taskThread.source, .task)
        XCTAssertEqual(taskThread.status, .running)
        XCTAssertEqual(taskThread.events.first?.kind, .toolCall)
    }

    func testAgentLoopStopsAtMaxIterations() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let loop = AgentLoop(
            config: .init(maxIterations: 1, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: LoopingToolRuntime()
        )
        let task = try await loop.run(
            message: "找 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "http://localhost", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.text.contains("最大迭代次数") })
    }

    func testAgentLoopMarksProviderErrorsAsFailed() async throws {
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: ProviderErrorRuntime()
        )
        let task = try await loop.run(
            message: "整理今天新闻",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.kind == .error && $0.text.contains("请求格式不被") })
        XCTAssertFalse(task.steps.contains { $0.kind == .textOutput && $0.text.contains("请求格式不被") })
        XCTAssertFalse(task.steps.contains { $0.text.contains("最大迭代次数") })
    }

    func testOpenAICompatibleToolRoundtripPreservesReasoningContent() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingReasoningRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "读 README",
            intent: .task,
            connector: ConnectorProfile(name: "DeepSeek", kind: "openai-compatible", endpoint: "https://api.deepseek.com/v1", modelName: "deepseek-v4-pro", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests[1].messages.contains {
            $0.role == "assistant" && $0.reasoningContent == "先读取文件。"
        })
    }

    func testOllamaToolResultsAreFedBackAsPlainText() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingOllamaRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "读 README",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests[1].messages.contains { $0.role == "user" && ($0.content ?? "").contains("工具 file.read 执行结果") })
        XCTAssertFalse(runtime.requests[1].messages.contains { $0.role == "tool" })
    }

    func testStartWorkflowCreatesTaskAndRunRecord() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: [],
            selectedSessionID: nil,
            workbenchTab: .workflows,
            connectors: [connector],
            activeConnectorID: connector.id,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
        ))

        store.startWorkflow(named: "code-review")

        XCTAssertEqual(store.state.workflowRuns.first?.name, "code-review")
        XCTAssertEqual(store.state.workflowRuns.first?.statusLine, "执行中")
        XCTAssertEqual(store.state.tasks.first?.workflowName, "code-review")
        XCTAssertEqual(store.state.selectedTaskID, store.state.tasks.first?.id)
        XCTAssertGreaterThanOrEqual(store.state.tasks.first?.steps.count ?? 0, 2)
        XCTAssertEqual(store.state.tasks.first?.steps[1].kind, .aiThinking)
        XCTAssertTrue(store.state.tasks.first?.steps[1].text.contains("规划：工作流") == true)
    }

    func testWorkflowParserSupportsFailureStrategyConditionsAndPromptBlocks() {
        let source = """
        name: custom-review
        description: 自定义审查
        steps:
          - name: 搜索
            tool: code.search
            on_failure: skip
            params:
              query: AppStore
              scope: content
          - name: 总结
            tool: llm
            when: previous.success
            prompt: |
              请总结：
              {{previous.output}}
        """

        let workflow = WorkflowParser.parse(source)

        XCTAssertEqual(workflow?.name, "custom-review")
        XCTAssertEqual(workflow?.steps.count, 2)
        XCTAssertEqual(workflow?.steps.first?.onFailure, "skip")
        XCTAssertEqual(workflow?.steps.first?.params["query"], "AppStore")
        XCTAssertEqual(workflow?.steps.last?.condition, "previous.success")
        XCTAssertTrue(workflow?.steps.last?.prompt?.contains("{{previous.output}}") == true)
    }

    func testWorkflowLibraryLoadsCustomYamlFromWorkspace() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dir = workspace.appendingPathComponent(".laicai/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        name: custom
        description: custom workflow
        steps:
          - name: list
            tool: shell.exec
            params:
              command: pwd
        """.write(to: dir.appendingPathComponent("custom.yaml"), atomically: true, encoding: .utf8)

        let workflows = WorkflowLibrary.available(workspaceRoot: workspace.path)

        XCTAssertTrue(workflows.contains { $0.name == "custom" })
        XCTAssertTrue(workflows.contains { $0.name == "code-review" })
    }

    func testSkillRegistryCreatesAndLoadsLocalDraft() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = SkillRegistry.shared

        let skill = try registry.createDraft(
            name: "整理日报",
            description: "生成项目日报",
            tools: ["code.search", "file.read"],
            workspaceRoot: workspace.path
        )
        registry.refresh(workspaceRoot: workspace.path)

        XCTAssertFalse(skill.isBuiltin)
        XCTAssertTrue(registry.skills.contains { $0.name == "整理日报" })
        XCTAssertTrue(SkillRegistry.loadLocalSkills(workspaceRoot: workspace.path).contains { $0.name == "整理日报" })
    }

    func testBootstrapSelectsLatestThreadAcrossSessionsAndTasks() {
        let olderSession = ChatSession(
            title: "旧线程",
            preview: "",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test"
        )
        let newerTask = AgentTask(
            title: "新任务",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [olderSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: [newerTask]),
            threadRepository: NoopThreadRepository()
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.selectedTaskID, newerTask.id)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertEqual(state.selectedThreadID, newerTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }

    func testBootstrapRestoresPersistedThreadSnapshotAsAuthoritativeSource() {
        let staleSession = ChatSession(
            title: "旧标题",
            preview: "旧",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test",
            turns: [ChatTurn(role: .user, text: "旧")]
        )
        let restoredTask = AgentTask(
            id: staleSession.id,
            title: "已升级任务",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取项目"),
                TaskStep(kind: .textOutput, text: "完成")
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [staleSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: []),
            threadRepository: FixedThreadRepository(threads: [ThreadRecord(task: restoredTask)])
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertEqual(state.tasks.first?.id, restoredTask.id)
        XCTAssertEqual(state.tasks.first?.title, "已升级任务")
        XCTAssertEqual(state.selectedThreadID, restoredTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }

    func testBootstrapCancelsStaleRunningTasks() {
        let staleTask = AgentTask(
            title: "旧任务",
            status: .running,
            updatedAt: Date(timeIntervalSinceNow: -3600)
        )
        let store = AppStore(
            state: testState(tasks: [staleTask], selectedTaskID: staleTask.id),
            environment: AppEnvironment(
                runtimeClient: PreviewChatRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        XCTAssertEqual(store.state.tasks.first?.status, .cancelled)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.contains("上次运行被中断") } == true)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.hasPrefix("任务检查点") } == true)
        XCTAssertEqual(store.state.selectedTaskID, staleTask.id)
    }

    func testWikiPreviewDoesNotWriteUntilSaved() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Python\nPython is useful for automation.".write(to: notes.appendingPathComponent("python.md"), atomically: true, encoding: .utf8)

        let preview = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":false}"#,
            context: TaskContext(workspaceRoot: "/tmp", vaultRoot: vault.path)
        )

        XCTAssertTrue(preview.success)
        XCTAssertEqual(preview.data?["saved"], "false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("03 Topics/python.md").path))
        XCTAssertTrue(preview.output.contains("[[02 Notes/python]]"))
    }

    func testWikiSaveWritesTopicPage() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }

        let saved = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":true}"#,
            context: TaskContext(workspaceRoot: "/tmp", vaultRoot: vault.path)
        )

        let target = vault.appendingPathComponent("03 Topics/python.md")
        XCTAssertTrue(saved.success)
        XCTAssertEqual(saved.data?["saved"], "true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(#"topic: "Python""#))
    }

    func testWikiEngineReturnsSourcesAndDiffForExistingTopic() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        let topics = vault.appendingPathComponent("03 Topics", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        try "# AI\n人工智能基础知识包括模型、数据和评估。".write(to: notes.appendingPathComponent("ai.md"), atomically: true, encoding: .utf8)
        try "# 人工智能\n旧内容".write(to: topics.appendingPathComponent("人工智能.md"), atomically: true, encoding: .utf8)

        let result = await WikiEngine.buildTopic(
            topic: "人工智能",
            vaultRoot: vault.path,
            save: false,
            useWeb: false,
            topK: 4
        )

        XCTAssertFalse(result.saved)
        XCTAssertEqual(result.notePath, "03 Topics/人工智能.md")
        XCTAssertNotNil(result.previousMarkdown)
        XCTAssertTrue(result.diffSummary.contains("更新主题页"))
        XCTAssertTrue(result.sources.contains { $0.path == "02 Notes/ai.md" })
        XCTAssertTrue(result.renderedMarkdown.contains("## Related Notes"))
    }

    func testGitToolReturnsFriendlyResultOutsideRepository() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await GitTool().execute(
            argumentsJSON: #"{"subcommand":"status"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["repository"], "false")
        XCTAssertTrue(result.output.contains("不是 git 仓库"))
    }

    func testWriteFileToolDoesNotChangeDiskBeforeApproval() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let nested = workspace.appendingPathComponent("Notes/New.md")

        let result = try await WriteFileTool().execute(
            argumentsJSON: #"{"path":"Notes/New.md","content":"hello","createDirectories":true}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path))
    }

    func testApproveReviewWritesFileAndRecordsAudit() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Approved.md")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path, "createDirectories": "true"],
            diffFilePath: "Approved.md",
            diffOldContent: "",
            diffNewContent: "approved"
        )
        let task = AgentTask(title: "写文件", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved")
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, true)
        XCTAssertTrue(store.state.selectedTask?.steps.contains(where: { $0.kind == .reviewResult && $0.approved == true }) == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.write" && $0.success })
    }

    func testRejectReviewDoesNotWriteFileAndRecordsAudit() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Rejected.md")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "Rejected.md",
            diffOldContent: "",
            diffNewContent: "rejected"
        )
        let task = AgentTask(title: "拒绝写入", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.rejectReview(taskID: task.id, stepID: step.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, false)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.write" && !$0.success })
    }

    func testRollbackLastApprovedWriteRestoresOldContent() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Rollback.md")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "Rollback.md",
            diffOldContent: "old",
            diffNewContent: "new"
        )
        let task = AgentTask(title: "回滚写入", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")

        store.rollbackLastApprovedWrite(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.kind == .reviewResult && $0.text.contains("已回滚") } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.rollback" && $0.success })
    }

    func testShellWhitelistAllowsPwdAndRejectsSudoAndProjectTraversal() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let pwd = try await ShellTool().execute(argumentsJSON: #"{"command":"pwd"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let sudo = try await ShellTool().execute(argumentsJSON: #"{"command":"sudo ls"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let findFiles = try await ShellTool().execute(argumentsJSON: #"{"command":"find . -type f"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let recursiveList = try await ShellTool().execute(argumentsJSON: #"{"command":"ls -R ."}"#, context: TaskContext(workspaceRoot: workspace.path))

        XCTAssertTrue(pwd.success)
        XCTAssertTrue(pwd.output.contains(workspace.path))
        XCTAssertFalse(sudo.success)
        XCTAssertEqual(sudo.error, "security_denied")
        XCTAssertFalse(findFiles.success)
        XCTAssertEqual(findFiles.error, "security_denied")
        XCTAssertTrue(findFiles.output.contains("workspace.index"))
        XCTAssertFalse(recursiveList.success)
        XCTAssertEqual(recursiveList.error, "security_denied")
    }

    func testShellPolicyRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "工具策略拦截：不要用 shell 遍历项目结构。",
            toolName: "shell.exec",
            params: ["command": "find . -type f"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, argumentsJSON) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
        XCTAssertTrue(argumentsJSON.contains("maxFiles"))
    }

    func testCodeSearchRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "搜索失败",
            toolName: "code.search",
            params: ["query": "AppStore"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, _) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
    }

    func testSensitivePathsAreBlocked() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "SECRET=1".write(to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".env"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let write = try await WriteFileTool().execute(
            argumentsJSON: #"{"path":".ssh/id_rsa","content":"secret"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "security_denied")
        XCTAssertFalse(write.success)
        XCTAssertEqual(write.error, "security_denied")
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStubbedSession(body: Data, statusCode: Int = 200) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        return URLSession(configuration: configuration)
    }

    private func makeStubbedSession(
        responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = responder
        return URLSession(configuration: configuration)
    }

    private func waitUntilIdle(_ store: AppStore) async throws {
        for _ in 0..<50 {
            if !store.state.isGenerating { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Store did not finish generating in time")
    }

    private func waitForConnectorHealth(_ store: AppStore, id: UUID, health: ConnectorHealth) async throws {
        for _ in 0..<50 {
            if store.state.connectors.first(where: { $0.id == id })?.health == health { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Connector did not reach \(health)")
    }

    private func waitForHealthRequestCount(_ runtime: PausedHealthRuntime, count: Int) async throws {
        for _ in 0..<50 {
            if runtime.healthRequests.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Health request count did not reach \(count)")
    }

    private func testState(
        sessions: [ChatSession] = [],
        tasks: [AgentTask] = [],
        selectedTaskID: UUID? = nil,
        workspacePath: String = "/tmp",
        connectors: [ConnectorProfile] = [],
        activeConnectorID: UUID? = nil
    ) -> AppState {
        AppState(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: sessions,
            selectedSessionID: nil,
            workbenchTab: .tools,
            connectors: connectors,
            activeConnectorID: activeConnectorID,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: workspacePath, defaultConnectorName: "None", compactComposer: false, showDebugPanels: false),
            tasks: tasks,
            selectedTaskID: selectedTaskID
        )
    }
}

private struct LoopingToolRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "我会先搜索项目。",
            toolCalls: [
                FunctionCallResponse(
                    id: "call_search",
                    function: FunctionCallDetail(
                        name: "code.search",
                        arguments: #"{"query":"README","scope":"files","maxResults":5}"#
                    )
                )
            ]
        )
    }
}

private struct ProviderErrorRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "请求格式不被 qwen 接受，请检查端点、模型名和请求兼容性。\nURL: http://127.0.0.1:11434/api/chat",
            toolActivities: [ToolActivity(name: "chat.error", summary: "qwen 返回 HTTP 400", statusLine: "bad request", isFailure: true)]
        )
    }
}

@MainActor
private final class ToolRejectedThenPlainRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if request.tools?.isEmpty == false {
            return SendMessageResponse(
                assistantText: "请求格式不被 qwen 接受，请检查端点、模型名和请求兼容性。\nURL: http://127.0.0.1:11434/api/chat",
                toolActivities: [ToolActivity(name: "chat.error", summary: "qwen 返回 HTTP 400", statusLine: "tool_calls bad request", isFailure: true)]
            )
        }
        return SendMessageResponse(assistantText: "当前连接器暂不兼容工具调用；我已改为无工具模式继续回答。")
    }
}

@MainActor
private final class LengthThenContinuationRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(assistantText: "这是一段被供应商截断的回复", finishReason: "length")
        }
        return SendMessageResponse(assistantText: "这是自动续写的第二段。")
    }
}

@MainActor
private final class FailingThenCapturingRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []
    var shouldFail = true

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if shouldFail {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
        }
        return SendMessageResponse(assistantText: "完成")
    }
}

@MainActor
private final class CapturingToolsRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "完成")
    }
}

@MainActor
private final class CapturingContinuationRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "后半段新闻内容")
    }
}

@MainActor
private final class ShellTraversalThenFinalRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "我先列出项目文件。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_shell_find",
                        function: FunctionCallDetail(
                            name: "shell_exec",
                            arguments: #"{"command":"find . -type f"}"#
                        )
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已基于恢复索引继续。")
    }
}

@MainActor
private final class StreamingRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "你好，世界")
    }

    func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        await onChunk("你好，")
        await onChunk("世界")
        return SendMessageResponse(
            assistantText: "你好，世界",
            metrics: ResponseMetrics(
                thinkingDuration: 0.1,
                totalDuration: 0.2,
                inputTokens: 12,
                outputTokens: 4,
                tokensPerSecond: 20
            )
        )
    }
}

@MainActor
private final class HealthRuntime: ChatRuntimeClient {
    let health: ConnectorHealth
    var healthRequests: [(endpoint: String, model: String, apiKey: String, kind: String)] = []

    init(health: ConnectorHealth) {
        self.health = health
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append((endpoint, model, apiKey, kind))
        return health
    }
}

@MainActor
private final class ProbeHealthRuntime: ChatRuntimeClient {
    let result: ConnectorProbeResult
    var probeRequests: [(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool)] = []

    init(result: ConnectorProbeResult) {
        self.result = result
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func probeConnector(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool) async throws -> ConnectorProbeResult {
        probeRequests.append((endpoint, model, apiKey, kind, probeToolCalling))
        return ConnectorProbeResult(
            health: result.health,
            toolCallingCapability: probeToolCalling ? result.toolCallingCapability : nil
        )
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        result.health
    }
}

@MainActor
private final class PausedHealthRuntime: ChatRuntimeClient {
    var healthRequests: [(endpoint: String, model: String, apiKey: String, kind: String)] = []
    private var continuations: [CheckedContinuation<ConnectorHealth, Error>] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append((endpoint, model, apiKey, kind))
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolveNext(with health: ConnectorHealth) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: health)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responseProvider: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = provider(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FixedSessionRepository: SessionRepository {
    var sessions: [ChatSession]

    func loadSessions() throws -> [ChatSession]? { sessions }
    func saveSessions(_ sessions: [ChatSession]) throws {}
}

private struct FixedTaskRepository: TaskRepository {
    var tasks: [AgentTask]

    func loadTasks() throws -> [AgentTask]? { tasks }
    func saveTasks(_ tasks: [AgentTask]) throws {}
    func appendTask(_ task: AgentTask) throws {}
    func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws {}
    func deleteTask(id: UUID) throws {}
}

private struct FixedThreadRepository: ThreadRepository {
    var threads: [ThreadRecord]

    func loadThreads() throws -> [ThreadRecord]? { threads }
    func saveThreads(_ threads: [ThreadRecord]) throws {}
}

@MainActor
private final class CapturingReasoningRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "",
                reasoningContent: "先读取文件。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_read",
                        function: FunctionCallDetail(name: "file_read", arguments: #"{"path":"README.md"}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "README 内容是 hello。")
    }
}

@MainActor
private final class CapturingOllamaRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_read",
                        function: FunctionCallDetail(name: "file_read", arguments: #"{"path":"README.md"}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "README 内容是 hello。")
    }
}
