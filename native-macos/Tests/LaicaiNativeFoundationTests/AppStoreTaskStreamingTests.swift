import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreTaskStreamingTests: LaicaiNativeFoundationTestCase {
    func testStreamingOutputIsCoalescedAndFinalStepCarriesMetrics() async throws {
        let connector = makeConnector()
        let store = makeTestStore(
            modeLabel: "Agent",
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: StreamingRuntime()
        )

        store.updateDraft("写一段长回复")
        store.sendDraft()
        try await waitUntilIdle(store)

        let outputs = store.state.selectedThread?.steps.filter { $0.kind == .textOutput } ?? []
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.text, "你好，世界")
        XCTAssertEqual(outputs.first?.metrics?.inputTokens, 12)
        XCTAssertEqual(outputs.first?.metrics?.outputTokens, 4)
    }
    func testStreamingDeltasUpdateCurrentThreadBeforeFinalOutput() async throws {
        let connector = makeConnector()
        let runtime = StreamingRuntime()
        let store = makeTestStore(
            defaultConnectorName: "Test",
            connectors: [connector],
            activeConnectorID: connector.id,
            runtime: runtime
        )

        store.updateDraft("请写一段流式回答")
        store.sendDraft()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.state.selectedThread?.steps.filter { $0.kind == .textOutput }.map(\.text), ["你好，世界"])
    }
}
