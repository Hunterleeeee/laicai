import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreTaskQuestionRoutingTests: LaicaiNativeFoundationTestCase {
    func testContinuationMessagesCarryOriginalGoalIntoAgentContext() throws {
        let original = "把 /tmp/demo.pptx 翻译成英文版并保存到桌面"
        let priorSteps = [
            TaskStep(kind: .userInput, text: original),
            TaskStep(
                kind: .toolCall, text: "document.transform prepare", toolName: "document.transform",
                toolParams: ["action": "prepare", "sourcePath": "/tmp/demo.pptx"]),
            TaskStep(kind: .toolResult, text: "缺少 translationsJSON", toolName: "document.transform", toolParams: ["action": "apply"], isFailure: true)
        ]
        var context = TaskContext(workspaceRoot: "/tmp")
        context.memory.appendDecision("[continuation] 已准备 PPT 工作区，但 apply 参数失败。")

        let messages = AgentLoop.initialMessages(
            systemPrompt: "system",
            message: "继续",
            priorSteps: priorSteps,
            context: context
        )
        let joined = messages.compactMap(\.content).joined(separator: "\n")

        XCTAssertTrue(joined.contains("续跑恢复现场"))
        XCTAssertTrue(joined.contains(original))
        XCTAssertTrue(joined.contains("缺少 translationsJSON"))
        XCTAssertTrue(joined.contains("不要把「继续」当作搜索词或命令"))
    }

    func testTaskStatusQuestionAnswersFromCurrentTaskWithoutRuntimeCall() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
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
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "为什么会有工具失败？")
        XCTAssertTrue(store.state.selectedThread?.steps.last?.text.contains("shell.exec") == true)
        XCTAssertTrue(store.state.selectedThread?.steps.last?.text.contains("受控的项目索引") == true)
        XCTAssertEqual(store.state.modeLabel, "会话")
    }
    func testUnrelatedQuestionOnSelectedTaskStaysPlainChat() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
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
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.count, 2)
        XCTAssertEqual(store.state.threads.first?.steps.filter { $0.kind == .userInput }.count, 1)
        XCTAssertEqual(store.state.modeLabel, "会话 问答")
    }
    func testRecentBadDomainQuestionsDoNotContinueSelectedToolTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let prompts = ["大小六壬 梅花易数呢", "这个skill都能干嘛呢"]

        for prompt in prompts {
            let task = AgentTask(
                title: "读取项目",
                status: .completed,
                steps: [
                    TaskStep(kind: .userInput, text: "读取本地项目"),
                    TaskStep(kind: .toolCall, text: "搜索 AppStore", toolName: "code.search"),
                    TaskStep(kind: .toolResult, text: "命中 AppStore.swift", toolName: "code.search"),
                    TaskStep(kind: .textOutput, text: "完成")
                ],
                updatedAt: .now
            )
            let runtime = StreamingRuntime()
            let store = AppStore(
                state: .init(
                    workspaceName: "Test",
                    modeLabel: "执行",
                    sessions: [],
                    selectedSessionID: nil,
                    workbenchTab: .tools,
                    connectors: [connector],
                    activeConnectorID: connector.id,
                    toolActivities: [],
                    workflowRuns: [],
                    draftMessage: "",
                    isGenerating: false,
                    settings: .init(
                        workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                        showDebugPanels: false),
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

            store.updateDraft(prompt)
            store.sendDraft()
            try await waitUntilIdle(store)

            XCTAssertNotNil(store.state.selectedThreadID, prompt)
            XCTAssertEqual(store.state.threads.count, 2, prompt)
            XCTAssertNotNil(store.state.selectedThread?.steps.first(where: { $0.kind == .userInput }), prompt)
        }
    }

    func testContextualComplaintContinuesSelectedTaskInsteadOfCreatingNewSession() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "升级来财 UI",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "参考 Dumate 升级 UI"),
                TaskStep(kind: .toolCall, text: "读取 SidebarView", toolName: "file.read"),
                TaskStep(kind: .toolResult, text: "已读取", toolName: "file.read"),
                TaskStep(kind: .textOutput, text: "已完成初版")
            ],
            updatedAt: .now
        )
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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

        store.updateDraft("为什么会有两个窗口呢")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "为什么会有两个窗口呢")
    }

    func testReadOnlyContinuationDoesNotEscalateToWriteOrShellTools() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let thread = Thread(
            title: "全量体验",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "全量体验，我感觉不好用 你看看"),
                TaskStep(kind: .toolCall, text: "读取 RootView", toolName: "file.read"),
                TaskStep(kind: .toolResult, text: "已读取", toolName: "file.read"),
                TaskStep(kind: .textOutput, text: "初步看完入口体验")
            ],
            connectorID: connector.id,
            context: TaskContext(workspaceRoot: LaicaiNativeFoundationTestCase.safeTestWorkspacePath),
            updatedAt: .now,
            goal: "全量体验，我感觉不好用 你看看"
        )
        let runtime = CapturingToolsRuntime()
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

        store.updateDraft("继续看，我觉得编排层有问题")
        store.sendDraft()
        try await waitUntilIdle(store)

        let tools = runtime.requests.last?.tools?.map { ToolNameCodec.canonicalName($0.function.name) } ?? []
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.modeLabel, "会话 分析")
        XCTAssertEqual(store.state.selectedThread?.taskProtocol?.riskPolicy, .inspect)
        XCTAssertTrue(tools.contains("file.read"), tools.joined(separator: ","))
        XCTAssertTrue(tools.contains("code.search"), tools.joined(separator: ","))
        XCTAssertFalse(tools.contains("file.write"), tools.joined(separator: ","))
        XCTAssertFalse(tools.contains("file.edit"), tools.joined(separator: ","))
        XCTAssertFalse(tools.contains("diff.apply"), tools.joined(separator: ","))
        XCTAssertFalse(tools.contains("shell.exec"), tools.joined(separator: ","))
    }

    func testContinueAgentActionResumesPausedTaskDirectly() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "修复继续按钮",
            status: .cancelled,
            steps: [
                TaskStep(kind: .userInput, text: "修复继续按钮"),
                TaskStep(kind: .error, text: "上次运行被中断，已自动标记为已暂停。", isFailure: false, recoverable: true, retryAction: "继续")
            ],
            updatedAt: .now
        )
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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

        store.continueThread(id: task.id)
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "继续处理，并优先基于当前证据形成结论；不要重复已经完成的读取、搜索或执行步骤。")
        XCTAssertFalse(runtime.requests.isEmpty)
    }

    func testPlainChatDoesNotReuseToolTaskJustBecauseItHadToolHistory() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let task = AgentTask(
            title: "修复构建",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "修复构建"),
                TaskStep(kind: .toolCall, text: "运行构建", toolName: "shell.exec", toolParams: ["command": "swift build"]),
                TaskStep(kind: .toolResult, text: "BUILD SUCCESS", toolName: "shell.exec", toolParams: ["command": "swift build"]),
                TaskStep(kind: .textOutput, text: "构建修好了")
            ],
            updatedAt: .now
        )
        let runtime = StreamingRuntime()
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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

        store.updateDraft("你喜欢什么样的工作方式？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.count, 2)
        XCTAssertNotNil(store.state.selectedThread?.steps.first(where: { $0.kind == .userInput }))
    }
    func testStandaloneCapabilityQuestionDoesNotContinueSelectedTask() async throws {
        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
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
                modeLabel: "执行",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [connector],
                activeConnectorID: connector.id,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "Test", compactComposer: false,
                    showDebugPanels: false),
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

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.count, 2)
        XCTAssertNotNil(store.state.selectedThread?.steps.first(where: { $0.kind == .userInput }))
        XCTAssertEqual(store.state.modeLabel, "会话 问答")
    }
}
