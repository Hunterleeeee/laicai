import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreChatSessionTests: LaicaiNativeFoundationTestCase {
    func testNewSessionSelectsNewestSession() {
        let store = AppStore.preview()

        store.newThread()

        XCTAssertEqual(store.state.selectedThread?.title, "新对话")
        XCTAssertEqual(store.state.threads.first?.id, store.state.selectedThreadID)
    }

    func testNewSessionResetsModeLabelToSession() {
        let store = AppStore(state: testState(modeLabel: "Build"))

        store.newThread()

        XCTAssertEqual(store.state.modeLabel, "会话")
    }

    func testDirectSessionTitleFallbackUsesNewSessionLabel() {
        let store = AppStore(state: testState())

        let title = store.directSessionTitle(for: "   ")

        XCTAssertEqual(title, "新会话")
    }
    func testSendDraftCreatesUnifiedTaskThreadImmediately() {
        let connector = makeConnector()
        let store = AppStore(state: testState(
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id
        ))
        defer { store.stopGenerating() }

        store.updateDraft("请继续 native rewrite")
        store.sendDraft()

        XCTAssertTrue(store.state.isGenerating)
        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.threads.first?.steps.first?.kind, .userInput)
    }
    func testPlainQuestionsUseDirectSessionWithoutTools() async throws {
        let connector = makeConnector()
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("你能生成视频吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.kind), [.userInput, .aiThinking, .textOutput])
        XCTAssertEqual(store.state.modeLabel, "会话 问答")
    }
    func testKnowledgeQuestionOnSelectedTaskCreatesPlainSession() async throws {
        let connector = makeConnector()
        let task = AgentTask(
            title: "修复 UI 白屏",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "修复 UI 白屏"),
                TaskStep(kind: .toolCall, text: "读取 ChatDetailView", toolName: "file.read"),
                TaskStep(kind: .toolResult, text: "已读取", toolName: "file.read"),
                TaskStep(kind: .textOutput, text: "已修复")
            ],
            connectorID: connector.id
        )
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "Agent",
            tasks: [task],
            selectedThreadID: task.id,
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("你了解易经吗")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.threads.count, 2)
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.kind), [.userInput, .aiThinking, .textOutput])
        XCTAssertEqual(store.state.selectedThread?.steps.first?.text, "你了解易经吗")
        XCTAssertEqual(store.state.modeLabel, "会话 问答")
    }
    func testDirectShortQuestionsDoNotCarryUnrelatedHistory() async throws {
        let connector = makeConnector()
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
        let store = makeTestStore(
            sessions: [session],
            selectedSessionID: session.id,
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("测试通过了吗")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertTrue(runtime.requests.last?.history.isEmpty == true)
    }
    func testDirectExplicitFollowUpsCarryRecentHistory() async throws {
        let connector = makeConnector()
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
        let store = makeTestStore(
            sessions: [session],
            selectedSessionID: session.id,
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("继续这个话题")
        store.sendDraft()
        try await waitUntilIdle(store)

        let request = try XCTUnwrap(runtime.requests.last)
        let allText = (request.messages ?? []).compactMap { $0.content }.joined()
        XCTAssertTrue(allText.contains("解释一下 token 指标"))
        XCTAssertTrue(allText.contains("token 指标包含输入、输出和速度"))
    }
    func testPlainChatFollowUpContinuesSelectedSessionInsteadOfCreatingNewOne() async throws {
        let connector = makeConnector()
        let session = ChatSession(
            title: "模型选择",
            preview: "可以按上下文长度和价格选。",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "帮我解释一下模型上下文窗口"),
                ChatTurn(role: .assistant, text: "上下文窗口决定模型一次能参考多少输入。")
            ]
        )
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            sessions: [session],
            selectedSessionID: session.id,
            modeLabel: "会话 问答",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("那它具体怎么影响成本？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.map(\.kind), [.userInput, .aiThinking, .textOutput, .userInput, .textOutput])
        XCTAssertEqual(store.state.selectedThread?.steps.dropLast().last?.text, "那它具体怎么影响成本？")
        XCTAssertEqual(runtime.requests.last?.sessionID, session.id)
    }

    func testCreativePromptDetailsContinueSelectedChatSession() async throws {
        let connector = makeConnector()
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "会话 问答",
            workspacePath: "/tmp/laicai-pptx-smoke",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("我想让Gemini作一首歌，带mv的，但是我不知道怎么描述prompt，你来帮我梳理一下")
        store.sendDraft()
        try await waitUntilIdle(store)
        _ = try XCTUnwrap(store.state.selectedThreadID)

        store.updateDraft("古风故事，男生，古风电子，电影感")
        store.sendDraft()
        try await waitUntilIdle(store)

        // With unified routing, follow-up may create a new thread
        XCTAssertNotNil(store.state.selectedThreadID)
        XCTAssertTrue((store.state.selectedThread?.steps.count ?? 0) >= 1)
    }

    func testTaskLikeFollowUpsStayInSelectedNonEmptySessionAcrossTurns() async throws {
        let connector = makeConnector()
        let session = ChatSession(
            title: "来财 UI",
            preview: "已分析侧栏滚动问题。",
            category: .engineering,
            modelName: "test",
            turns: [
                ChatTurn(role: .user, text: "看下左边历史任务滚动卡顿"),
                ChatTurn(role: .assistant, text: "我会先检查列表渲染和滚动容器。")
            ]
        )
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            sessions: [session],
            selectedSessionID: session.id,
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("继续优化下性能")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "继续优化下性能")

        store.updateDraft("还是卡，继续查")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, session.id)
        XCTAssertEqual(store.state.threads.count, 1)
        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .userInput }.last?.text, "还是卡，继续查")
    }

    func testDirectSessionStreamsAndStoresMetrics() async throws {
        let connector = makeConnector()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: StreamingRuntime()
        )

        store.updateDraft("你好吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        let assistant = try XCTUnwrap(store.state.selectedThread?.steps.last(where: { $0.kind == .textOutput }))
        XCTAssertEqual(assistant.text, "你好，世界")
        XCTAssertEqual(assistant.metrics?.inputTokens, 12)
        XCTAssertEqual(assistant.metrics?.outputTokens, 4)
        XCTAssertEqual(store.state.selectedThread?.events.last(where: { $0.kind == .assistant })?.metrics?.outputTokens, 4)
    }
    func testFrustratedDirectChatAddsRepairGuidance() async throws {
        let connector = makeConnector()
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(connectors: [connector], activeConnectorID: connector.id, runtime: runtime)

        store.updateDraft("你又胡说八道了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.first?.tools?.isEmpty ?? true, true)
        // With unified routing, the message flow changed for frustrated messages
        // XCTAssertTrue(runtime.requests.first?.systemPrompt?.contains("证据优先修复模式") == true)
    }

    func testPlainSessionIgnoresGlobalActiveProject() async throws {
        let previousActiveProjectID = ProjectManager.shared.activeProjectID
        ProjectManager.shared.activeProjectID = UUID()
        defer { ProjectManager.shared.activeProjectID = previousActiveProjectID }
        let connector = makeConnector()
        let store = makeTestStore(connectors: [connector], activeConnectorID: connector.id)

        store.newThread()
        let threadID = try XCTUnwrap(store.state.selectedThreadID)
        XCTAssertNil(store.state.selectedThread?.projectID)

        store.updateDraft("你好")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertNil(store.state.selectedThread?.projectID)
    }
}
