import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreChatSessionTests: LaicaiNativeFoundationTestCase {
    func testNewSessionSelectsNewestSession() {
        let store = AppStore.preview()

        store.newSession()

        XCTAssertEqual(store.state.selectedSession?.title, "新线程")
        XCTAssertEqual(store.state.sessions.first?.id, store.state.selectedSessionID)
    }
    func testSendDraftCreatesUnifiedTaskThreadImmediately() {
        let connector = makeConnector()
        let store = AppStore(state: testState(
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id
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

        XCTAssertNil(store.state.selectedTaskID)
        XCTAssertNotNil(store.state.selectedSessionID)
        XCTAssertEqual(store.state.selectedSession?.turns.map(\.role), [.user, .assistant])
        XCTAssertNil(runtime.requests.last?.tools)
        XCTAssertNil(runtime.requests.last?.messages)
        XCTAssertEqual(runtime.requests.last?.modeLabel, "聊天")
        XCTAssertEqual(store.state.modeLabel, "聊天")
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

        XCTAssertEqual(runtime.requests.last?.history.count, 2)
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

        let assistant = try XCTUnwrap(store.state.selectedSession?.turns.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.text, "你好，世界")
        XCTAssertEqual(assistant.metrics?.inputTokens, 12)
        XCTAssertEqual(assistant.metrics?.outputTokens, 4)
        XCTAssertEqual(store.state.selectedThread?.events.last?.metrics?.outputTokens, 4)
    }
    func testFrustratedDirectChatAddsRepairGuidance() async throws {
        let connector = makeConnector()
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(connectors: [connector], activeConnectorID: connector.id, runtime: runtime)

        store.updateDraft("你又胡说八道了")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.first?.tools?.isEmpty ?? true, true)
        XCTAssertTrue(runtime.requests.first?.systemPrompt?.contains("证据优先修复模式") == true)
    }
}
