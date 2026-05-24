import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreChatTokenBudgetTests: LaicaiNativeFoundationTestCase {
    func testLocalDirectRequestsUseSmallOutputCap() async throws {
        let connector = makeConnector(name: "Local Ollama", kind: "ollama", endpoint: "http://127.0.0.1:11434/v1", modelName: "qwen3.5:9b-q4_K_M")
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Local Ollama",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("你好吗？")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 512)
    }
    func testLocalAgentRequestsUseConservativeBudget() async throws {
        let connector = makeConnector(name: "Local Ollama", kind: "ollama", endpoint: "http://127.0.0.1:11434/v1", modelName: "qwen3.5:9b-q4_K_M")
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Local Ollama",
            contextMode: .deep,
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 1400)
    }
    func testApiQwenConnectorUsesApiBudget() async throws {
        let connector = makeConnector(name: "Qwen API", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", modelName: "qwen-plus")
        let runtime = CapturingToolsRuntime()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Qwen API",
            contextMode: .deep,
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("请搜索 README")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(runtime.requests.last?.maxOutputTokens, 65536)
    }
}
