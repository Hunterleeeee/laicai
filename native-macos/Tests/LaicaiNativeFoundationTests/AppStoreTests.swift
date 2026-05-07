import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTests: LaicaiNativeFoundationTestCase {
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

    func testSQLiteRepositoryDeletesThreadsAfterReload() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = Thread(title: "保留", preview: "keep", updatedAt: Date(timeIntervalSince1970: 10), source: .session)
        let second = Thread(title: "删除", preview: "delete", updatedAt: Date(timeIntervalSince1970: 20), source: .session)
        try SQLiteRepository(path: base.path).saveThreads([first, second])

        let reloaded = SQLiteRepository(path: base.path)
        try reloaded.saveThreads([first])

        let loaded = try XCTUnwrap(SQLiteRepository(path: base.path).loadThreads())
        XCTAssertEqual(loaded.map(\.id), [first.id])
    }

    func testThreadDecodingToleratesMissingMigrationFields() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "旧线程",
          "preview": "旧预览",
          "status": "completed",
          "steps": [],
          "context": {},
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let thread = try decoder.decode(Thread.self, from: Data(json.utf8))

        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.source, .session)
        XCTAssertEqual(thread.modelName, "")
        XCTAssertEqual(thread.category, .engineering)
        XCTAssertFalse(thread.isPinned)
    }

    func testPersistentMemoryUsesBoundParameters() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let workspace = "/tmp/laicai user's workspace"
        let category = "quote's"
        repository.saveMemory(workspace: workspace, category: category, key: "k", value: "v")

        XCTAssertEqual(repository.loadMemories(workspace: workspace, category: category).first?.value, "v")
        repository.deleteMemory(id: repository.loadMemories(workspace: workspace, category: category).first?.id ?? "")
        XCTAssertTrue(repository.loadMemories(workspace: workspace, category: category).isEmpty)
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
        let localCompatBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:53759/v1", kind: "ollama")
        let explicitNative = LiveChatRuntime.buildURL(from: "http://127.0.0.1:53759/api/chat", kind: "ollama")
        let explicitCompat = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/v1/chat/completions", kind: "ollama")

        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(apiBase.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(compatBase.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(localCompatBase.absoluteString, "http://127.0.0.1:53759/v1/chat/completions")
        XCTAssertEqual(explicitNative.absoluteString, "http://127.0.0.1:53759/api/chat")
        XCTAssertEqual(explicitCompat.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testConnectorKindNormalizesExplicitV1EndpointsSavedAsOllama() {
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "https://ds2api.endpoint.oai.red/v1"),
            "openai-compatible"
        )
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "http://127.0.0.1:53759/v1"),
            "openai-compatible"
        )
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "http://127.0.0.1:11434"),
            "ollama"
        )
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

    func testLiveChatRuntimePreservesEmptyAssistantContentForOrchestratorRecovery() async throws {
        let session = makeStubbedSession(
            body: #"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        )
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: UUID(),
            message: "ping",
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://api.example.com/v1/chat/completions", modelName: "test", note: "", health: .ready),
            modeLabel: "测试"
        ))

        XCTAssertEqual(response.assistantText, "")
        XCTAssertFalse(response.assistantText.contains("模型没有返回可显示内容"))
    }

    func testLiveChatRuntimeTreatsLocalV1OllamaProfileAsOpenAICompatible() async throws {
        var capturedURL: URL?
        var capturedBody = ""
        let session = makeStubbedSession { request in
            capturedURL = request.url
            capturedBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.data(using: .utf8)!)
        }
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: UUID(),
            message: "ping",
            connector: ConnectorProfile(
                name: "本地",
                kind: "ollama",
                endpoint: "http://127.0.0.1:53759/v1",
                modelName: "gpt-5.5",
                note: "",
                health: .ready
            ),
            modeLabel: "测试"
        ))

        XCTAssertEqual(response.assistantText, "ok")
        XCTAssertEqual(capturedURL?.absoluteString, "http://127.0.0.1:53759/v1/chat/completions")
        XCTAssertTrue(capturedBody.contains(#""max_tokens""#))
        XCTAssertFalse(capturedBody.contains(#""keep_alive""#))
    }
}
