import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreTaskFollowUpRoutingTests: LaicaiNativeFoundationTestCase {
    func testWikiPersistenceFollowUpFallsBackWhenModelOnlySuggestsWiki() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let connector = makeConnector()
        let original = Thread(
            title: "https://mp.weixin.qq.com/s/JKfkg",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA 阅读并理解，整理"),
                TaskStep(
                    kind: .toolCall, text: "正在读取网页：https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA", toolName: "web.fetch",
                    toolParams: ["url": "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA"]),
                TaskStep(
                    kind: .toolResult, text: "已读取网页：mp.weixin.qq.com · 4188 字符", toolName: "web.fetch",
                    toolParams: ["url": "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA"]),
                TaskStep(kind: .textOutput, text: "## Vibe Coding 产品上线安全检查清单\n\n- 供应链安全\n- 权限边界\n- 上线前验证"),
            ],
            connectorID: connector.id,
            updatedAt: .now.addingTimeInterval(-30),
            goal: "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA 阅读并理解，整理"
        )
        let runtime = WikiPlanOnlyRuntime()
        let store = AppStore(
            state: testState(
                threads: [original],
                selectedThreadID: original.id,
                workspacePath: workspace.path,
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment(runtime: runtime)
        )

        store.updateDraft("我觉得你的这个输出，需要沉淀到wiki")
        store.sendDraft()
        try await waitUntilIdle(store)

        let selected = try XCTUnwrap(store.state.selectedThread)
        let stepDump = selected.steps.map { "\($0.kind.rawValue):\($0.toolName ?? "-"):\($0.toolParams ?? [:]):\($0.text.prefix(80))" }
            .joined(separator: "\n")
        XCTAssertEqual(selected.id, original.id)
        XCTAssertTrue(runtime.requests.first?.tools?.contains { ToolNameCodec.canonicalName($0.function.name) == "wiki.build" } == true)
        XCTAssertTrue(
            selected.steps.contains { $0.kind == .toolCall && $0.toolName == "wiki.build" && $0.toolParams?["save"] == "true" }, stepDump)
        XCTAssertTrue(selected.steps.contains { $0.kind == .toolResult && $0.toolName == "wiki.build" && !$0.isFailure }, stepDump)
        XCTAssertFalse(
            selected.steps.contains { $0.toolName == "wiki.build" && ($0.toolParams?["topic"] ?? "").contains("__thread_output") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("02 Atomic/Vibe Coding 产品上线安全检查清单.md").path))
    }

    func testWikiPersistenceFollowUpContinuesSelectedWebThreadAndSavesWiki() async throws {
        let workspace = try makeTemporaryWorkspace()
        let connector = makeConnector()
        let original = Thread(
            title: "https://mp.weixin.qq.com/s/JKfkg",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA 阅读并理解，整理"),
                TaskStep(
                    kind: .toolCall, text: "正在读取网页：https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA", toolName: "web.fetch",
                    toolParams: ["url": "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA"]),
                TaskStep(
                    kind: .toolResult, text: "已读取网页：mp.weixin.qq.com · 4188 字符", toolName: "web.fetch",
                    toolParams: ["url": "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA"]),
                TaskStep(kind: .textOutput, text: "已基于微信文章整理出 Vibe Coding 产品上线安全检查清单，包含供应链、权限、代码审查、上线前验证等要点。"),
            ],
            connectorID: connector.id,
            updatedAt: .now.addingTimeInterval(-30),
            goal: "https://mp.weixin.qq.com/s/JKfkgANWrjU94PyBrVgwOA 阅读并理解，整理"
        )
        let runtime = WikiBuildWhenAvailableRuntime()
        let store = AppStore(
            state: testState(
                threads: [original],
                selectedThreadID: original.id,
                workspacePath: workspace.path,
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment(runtime: runtime)
        )

        store.updateDraft("我觉得你的这个输出，需要沉淀到wiki")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(IntentRouter.plan("我觉得你的这个输出，需要沉淀到wiki").intent, .task)
        XCTAssertEqual(store.state.selectedThreadID, original.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "我觉得你的这个输出，需要沉淀到wiki")
        let requestedTools = runtime.requests.first?.tools?.map { ToolNameCodec.canonicalName($0.function.name) } ?? []
        XCTAssertTrue(requestedTools.contains("wiki.build"))
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .toolCall && $0.toolName == "wiki.build" } == true)
        XCTAssertTrue(
            store.state.selectedThread?.steps.contains { $0.kind == .toolResult && $0.toolName == "wiki.build" && !$0.isFailure } == true)
    }

    func testPreviewFollowUpFromNewPlaceholderRestoresRecentDeliverableTask() async throws {
        let connector = makeConnector()
        let original = Thread(
            title: "出一个水生万物，财自流转的icon图",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "出一个水生万物，财自流转的icon图"),
                TaskStep(
                    kind: .toolCall, text: "准备写入文件：water-wealth-cycle-icon.svg", toolName: "file.write",
                    toolParams: ["path": "water-wealth-cycle-icon.svg"]),
                TaskStep(
                    kind: .reviewRequest, text: "已写入文件（可回滚）：/tmp/water-wealth-cycle-icon.svg", toolName: "file.write",
                    diffFilePath: "/tmp/water-wealth-cycle-icon.svg"),
                TaskStep(
                    kind: .toolResult, text: "已准备文件写入 · /tmp/water-wealth-cycle-icon.svg", toolName: "file.write",
                    toolParams: ["path": "/tmp/water-wealth-cycle-icon.svg"]),
                TaskStep(kind: .textOutput, text: "已生成 SVG icon 文件：/tmp/water-wealth-cycle-icon.svg"),
            ],
            updatedAt: .now.addingTimeInterval(-30),
            goal: "出一个水生万物，财自流转的icon图"
        )
        let placeholder = Thread(title: "新会话", status: .queued, steps: [], updatedAt: .now)
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: testState(
                threads: [placeholder, original],
                selectedThreadID: placeholder.id,
                workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath,
                connectors: [connector],
                activeConnectorID: connector.id
            ),
            environment: makeTestEnvironment(runtime: runtime)
        )

        store.updateDraft("在哪了？我要预览啊")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, original.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == TaskStepKind.userInput }.last?.text, "在哪了？我要预览啊")
    }

    func testTaskLikeHistoricalSessionPromotesToExecutionAgent() {
        let historical = Thread(
            title: "出一个 icon",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "出一个 icon"),
                TaskStep(kind: .toolCall, text: "写文件", toolName: "file.write"),
                TaskStep(kind: .toolResult, text: "已写入", toolName: "file.write"),
            ],
            executionState: .idle
        )

        XCTAssertTrue(historical.isExecution)
        XCTAssertTrue(historical.canContinue)
    }

    func testTinyFollowUpWithoutSelectionDoesNotRestoreRandomRecentTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
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
                modeLabel: "会话 问答",
                threads: [
                    Thread(
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
                ],
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

        store.updateDraft("？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertTrue(store.state.threads.contains(where: { $0.id == task.id }))
        XCTAssertEqual(store.state.threads.count, 2)
        XCTAssertEqual(store.state.selectedThread?.steps.first?.text, "？")
        // Chat mode now provides read-only tools instead of nil
        XCTAssertNotNil(runtime.requests.last?.tools)
    }
    func testExplicitContinuationRestoresRecentTaskEvenFromEmptySession() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取项目",
            status: .cancelled,
            steps: [TaskStep(kind: .userInput, text: "读取本地项目")],
            updatedAt: .now
        )
        let emptyThread = Thread(
            id: UUID(),
            title: "新线程",
            preview: "",
            steps: [],
            modelName: "test",
            executionState: .idle
        )
        let taskThread = Thread(
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
                modeLabel: "会话 问答",
                threads: [emptyThread, taskThread],
                selectedThreadID: emptyThread.id,
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

        store.updateDraft("继续这个 Agent")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, task.id)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == TaskStepKind.userInput }.last?.text, "继续这个 Agent")
    }
    func testContextualTaskReferenceFromEmptySessionRestoresRecentTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取本地项目",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取本地项目"),
                TaskStep(kind: .textOutput, text: "输出达到当前上限，回复已被截断。"),
            ],
            updatedAt: .now
        )
        let emptyThread = Thread(
            id: UUID(),
            title: "新线程",
            preview: "",
            steps: [],
            modelName: "test",
            executionState: .idle
        )
        let taskThread = Thread(
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
                modeLabel: "会话 问答",
                threads: [emptyThread, taskThread],
                selectedThreadID: emptyThread.id,
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

        store.updateDraft("刚才那个读取本地项目的对话输出没结束就被截断了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == TaskStepKind.userInput }.last?.text, "刚才那个读取本地项目的对话输出没结束就被截断了")
    }
    func testFrustratedEmptySessionRestoresRecentTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "读取本地项目",
            status: .completed,
            steps: [TaskStep(kind: .userInput, text: "读取本地项目")],
            updatedAt: .now
        )
        let emptyThread = Thread(
            id: UUID(),
            title: "新线程",
            preview: "",
            steps: [],
            modelName: "test",
            executionState: .idle
        )
        let taskThread = Thread(
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
                modeLabel: "会话 问答",
                threads: [emptyThread, taskThread],
                selectedThreadID: emptyThread.id,
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

        store.updateDraft("你看，胡说八道了，刚才那个会话上下文没了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("证据优先修复模式") } == true)
    }
}
