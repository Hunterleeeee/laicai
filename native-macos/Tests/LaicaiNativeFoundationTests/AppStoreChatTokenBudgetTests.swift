import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreChatTokenBudgetTests: LaicaiNativeFoundationTestCase {
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
}
