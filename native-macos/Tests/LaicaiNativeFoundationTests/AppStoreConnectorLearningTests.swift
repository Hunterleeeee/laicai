import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreConnectorLearningTests: LaicaiNativeFoundationTestCase {
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

        XCTAssertEqual(store.state.selectedThread?.status, .failed)
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

        store.selectThread(id: nil)
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

        store.selectThread(id: nil)
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
}
