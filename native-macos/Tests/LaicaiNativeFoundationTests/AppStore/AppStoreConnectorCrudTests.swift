import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AppStoreConnectorCrudTests: LaicaiNativeFoundationTestCase {
    func testSelectingConnectorUpdatesDefaultConnectorName() throws {
        let store = AppStore.preview()
        let target = try XCTUnwrap(store.state.connectors.last)

        store.selectConnector(id: target.id)

        XCTAssertEqual(store.state.activeConnectorID, target.id)
        XCTAssertEqual(store.state.settings.defaultConnectorName, target.name)
    }
    func testAddConnector() {
        let store = AppStore(
            state: .init(
                workspaceName: "Test",
                modeLabel: "Build",
                searchText: "",
                sessions: [],
                selectedSessionID: nil,
                workbenchTab: .tools,
                connectors: [],
                activeConnectorID: nil,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: LaicaiNativeFoundationTestCase.safeTestWorkspacePath, defaultConnectorName: "None", compactComposer: false,
                    showDebugPanels: false)
            ))

        let connector = ConnectorProfile(
            name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test-model", note: "key", health: .ready)
        store.addConnector(connector)

        XCTAssertEqual(store.state.connectors.count, 1)
        XCTAssertEqual(store.state.activeConnectorID, connector.id)
    }
    func testDeleteConnectorFallsBackToFirstRemaining() throws {
        let store = AppStore.preview()
        let activeID = try XCTUnwrap(store.state.activeConnectorID)

        store.deleteConnector(id: activeID)

        XCTAssertNotEqual(store.state.activeConnectorID, activeID)
        if store.state.activeConnectorID != nil {
            XCTAssertEqual(store.state.activeConnectorID, store.state.connectors.first?.id)
        }
    }
    func testUpdatingConnectorIdentityClearsLearnedToolCallingCapabilityMetadata() {
        let learnedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingCapability: .unsupported,
            toolCallingCapabilitySource: .connectorProbe,
            toolCallingCapabilityLearnedAt: learnedAt,
            health: .ready
        )
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: HealthRuntime(health: .ready),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.updateConnector(
            ConnectorProfile(
                id: connector.id,
                name: connector.name,
                kind: connector.kind,
                endpoint: "https://example.com/v2",
                modelName: connector.modelName,
                note: connector.note,
                toolCallingPolicy: connector.toolCallingPolicy,
                toolCallingCapability: connector.toolCallingCapability,
                toolCallingCapabilitySource: connector.toolCallingCapabilitySource,
                toolCallingCapabilityLearnedAt: connector.toolCallingCapabilityLearnedAt,
                health: connector.health,
                lastCheckedAt: connector.lastCheckedAt
            ))

        XCTAssertNil(store.state.connectors.first?.toolCallingCapability)
        XCTAssertNil(store.state.connectors.first?.toolCallingCapabilitySource)
        XCTAssertNil(store.state.connectors.first?.toolCallingCapabilityLearnedAt)
    }
    func testUpdatingConnectorSettingsResetsHealthToAttention() {
        let checkedAt = Date(timeIntervalSince1970: 1_713_000_000)
        let connector = ConnectorProfile(
            id: UUID(),
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            health: .ready,
            lastCheckedAt: checkedAt
        )
        let store = AppStore(state: testState(connectors: [connector], activeConnectorID: connector.id))

        store.updateConnector(
            ConnectorProfile(
                id: connector.id,
                name: connector.name,
                kind: connector.kind,
                endpoint: "https://example.com/v2",
                modelName: connector.modelName,
                note: connector.note,
                health: connector.health,
                lastCheckedAt: connector.lastCheckedAt
            ))

        XCTAssertEqual(store.state.connectors.first?.health, .attention)
        XCTAssertEqual(store.state.connectors.first?.lastCheckedAt, checkedAt)
    }
    func testUpdatingConnectorIdentityResetsLearnedToolCallingCapability() {
        let connector = ConnectorProfile(
            id: UUID(),
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingCapability: .unsupported,
            health: .ready
        )
        let store = AppStore(state: testState(connectors: [connector], activeConnectorID: connector.id))

        store.updateConnector(
            ConnectorProfile(
                id: connector.id,
                name: connector.name,
                kind: connector.kind,
                endpoint: connector.endpoint,
                modelName: "new-model",
                note: connector.note,
                toolCallingPolicy: connector.toolCallingPolicy,
                toolCallingCapability: connector.toolCallingCapability,
                health: connector.health,
                lastCheckedAt: connector.lastCheckedAt
            ))

        XCTAssertNil(store.state.connectors.first?.toolCallingCapability)
    }
}
