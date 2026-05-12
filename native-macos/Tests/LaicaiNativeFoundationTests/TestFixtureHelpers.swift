import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
extension LaicaiNativeFoundationTestCase {
    func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func waitUntilIdle(_ store: AppStore) async throws {
        for _ in 0..<50 {
            if !store.state.isGenerating { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Store did not finish generating in time")
    }

    func waitForConnectorHealth(_ store: AppStore, id: UUID, health: ConnectorHealth) async throws {
        for _ in 0..<50 {
            if store.state.connectors.first(where: { $0.id == id })?.health == health { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Connector did not reach \(health)")
    }

    func waitForHealthRequestCount(_ runtime: PausedHealthRuntime, count: Int) async throws {
        for _ in 0..<50 {
            if runtime.healthRequests.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Health request count did not reach \(count)")
    }

    func makeConnector(
        name: String = "Test",
        kind: String = "openai-compatible",
        endpoint: String = "https://example.com/v1",
        modelName: String = "test",
        note: String = "",
        toolCallingPolicy: ConnectorToolCallingPolicy? = nil,
        toolCallingCapability: ConnectorToolCallingCapability? = nil,
        toolCallingCapabilitySource: ConnectorToolCallingCapabilityObservationSource? = nil,
        toolCallingCapabilityLearnedAt: Date? = nil,
        health: ConnectorHealth = .ready
    ) -> ConnectorProfile {
        ConnectorProfile(
            name: name,
            kind: kind,
            endpoint: endpoint,
            modelName: modelName,
            note: note,
            toolCallingPolicy: toolCallingPolicy,
            toolCallingCapability: toolCallingCapability,
            toolCallingCapabilitySource: toolCallingCapabilitySource,
            toolCallingCapabilityLearnedAt: toolCallingCapabilityLearnedAt,
            health: health
        )
    }

    func testState(
        threads: [Thread]? = nil,
        sessions: [ChatSession] = [],
        selectedSessionID: UUID? = nil,
        modeLabel: String = "Build",
        tasks: [AgentTask] = [],
        selectedTaskID: UUID? = nil,
        workspacePath: String = "/tmp",
        defaultConnectorName: String = "None",
        contextMode: ContextMode = .balanced,
        connectors: [ConnectorProfile] = [],
        activeConnectorID: UUID? = nil
    ) -> AppState {
        if let threads {
            return AppState(
                workspaceName: "Test",
                modeLabel: modeLabel,
                threads: threads,
                selectedThreadID: selectedTaskID ?? selectedSessionID,
                workbenchTab: .tools,
                connectors: connectors,
                activeConnectorID: activeConnectorID,
                toolActivities: [],
                workflowRuns: [],
                draftMessage: "",
                isGenerating: false,
                settings: .init(
                    workspacePath: workspacePath,
                    defaultConnectorName: defaultConnectorName,
                    compactComposer: false,
                    showDebugPanels: false,
                    contextMode: contextMode
                )
            )
        }
        AppState(
            workspaceName: "Test",
            modeLabel: modeLabel,
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            workbenchTab: .tools,
            connectors: connectors,
            activeConnectorID: activeConnectorID,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(
                workspacePath: workspacePath,
                defaultConnectorName: defaultConnectorName,
                compactComposer: false,
                showDebugPanels: false,
                contextMode: contextMode
            ),
            tasks: tasks,
            selectedTaskID: selectedTaskID
        )
    }

    func makeTestEnvironment(
        runtime: any ChatRuntimeClient = CapturingToolsRuntime(),
        sessionRepository: any SessionRepository = NoopSessionRepository(),
        connectorRepository: any ConnectorRepository = NoopConnectorRepository(),
        taskRepository: any TaskRepository = NoopTaskRepository(),
        threadRepository: any ThreadRepository = NoopThreadRepository()
    ) -> AppEnvironment {
        AppEnvironment(
            runtimeClient: runtime,
            sessionRepository: sessionRepository,
            connectorRepository: connectorRepository,
            taskRepository: taskRepository,
            threadRepository: threadRepository
        )
    }

    func makeTestStore(
        sessions: [ChatSession] = [],
        selectedSessionID: UUID? = nil,
        modeLabel: String = "Build",
        tasks: [AgentTask] = [],
        selectedTaskID: UUID? = nil,
        workspacePath: String = "/tmp",
        defaultConnectorName: String = "None",
        contextMode: ContextMode = .balanced,
        connectors: [ConnectorProfile] = [],
        activeConnectorID: UUID? = nil,
        runtime: any ChatRuntimeClient = CapturingToolsRuntime()
    ) -> AppStore {
        AppStore(
            state: testState(
                sessions: sessions,
                selectedSessionID: selectedSessionID,
                modeLabel: modeLabel,
                tasks: tasks,
                selectedTaskID: selectedTaskID,
                workspacePath: workspacePath,
                defaultConnectorName: defaultConnectorName,
                contextMode: contextMode,
                connectors: connectors,
                activeConnectorID: activeConnectorID
            ),
            environment: makeTestEnvironment(runtime: runtime)
        )
    }
}
