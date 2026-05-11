import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreConnectorProbeTests: LaicaiNativeFoundationTestCase {
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
}
