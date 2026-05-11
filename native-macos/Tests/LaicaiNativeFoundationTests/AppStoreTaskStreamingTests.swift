import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTaskStreamingTests: LaicaiNativeFoundationTestCase {
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
}
