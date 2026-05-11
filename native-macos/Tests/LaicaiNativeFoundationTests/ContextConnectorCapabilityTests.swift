import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class ContextConnectorCapabilityTests: LaicaiNativeFoundationTestCase {
    func testAppSettingsDecodesBalancedContextModeByDefault() throws {
        let json = #"{"workspacePath":"/tmp","defaultConnectorName":"Test","compactComposer":false,"showDebugPanels":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.contextMode, .balanced)
    }
    func testAutoContextRespectsRelevantFileLimit() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "one".write(to: workspace.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "two".write(to: workspace.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace.path,
            userInput: "swift",
            fileLimit: 1
        )

        XCTAssertLessThanOrEqual(context.relevantFiles.count, 1)
    }
    func testAutoContextLoadsAgentsAndClaudeInstructions() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "agent rule".write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "claude rule".write(to: workspace.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let cursorRules = workspace.appendingPathComponent(".cursor/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorRules, withIntermediateDirectories: true)
        try "cursor rule".write(to: cursorRules.appendingPathComponent("project.mdc"), atomically: true, encoding: .utf8)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace.path,
            userInput: "读取项目",
            fileLimit: 0
        )

        XCTAssertTrue(context.claudeMD?.contains("### AGENTS.md") == true)
        XCTAssertTrue(context.claudeMD?.contains("agent rule") == true)
        XCTAssertTrue(context.claudeMD?.contains("### CLAUDE.md") == true)
        XCTAssertTrue(context.claudeMD?.contains("cursor rule") == true)
    }
    func testTokenBudgetBreakdownIncludesContextCategories() throws {
        let context = TaskContext(
            workspaceRoot: "/tmp/project",
            relevantFiles: [FileInfo(path: "Sources/App.swift", summary: "UI entry")],
            claudeMD: "project instructions",
            memory: TaskMemory(
                readFiles: ["Sources/App.swift"],
                searchedQueries: ["selectedThreadID"],
                failedTools: ["shell.exec"],
                stageConclusions: ["阶段结论"],
                checkpoints: ["下一步继续验证"],
                verificationStatus: "typecheck passed",
                pendingFiles: ["/tmp/attachment.md"],
                userDecisions: ["用户要求继续同一任务"]
            )
        )

        let budget = TokenBudget.estimate(context: context, userInput: "继续优化", mode: .balanced)

        XCTAssertGreaterThan(budget.inputTokens, 0)
        XCTAssertGreaterThan(budget.projectTokens, 0)
        XCTAssertGreaterThan(budget.memoryTokens, 0)
        XCTAssertGreaterThan(budget.toolTokens, 0)
        XCTAssertGreaterThan(budget.attachmentTokens, 0)
        XCTAssertGreaterThan(budget.systemReserveTokens, 0)
        XCTAssertTrue(budget.breakdownRows.contains { $0.label == "任务记忆" })
    }
    func testConnectorCapabilityProfileDoesNotTreatQwenAPIAsLocal() {
        let apiQwen = ConnectorProfile(
            name: "Qwen API",
            kind: "openai-compatible",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            modelName: "qwen-plus",
            note: "",
            health: .ready
        )
        let localQwen = ConnectorProfile(
            name: "Local Ollama",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434/v1",
            modelName: "qwen3.5:9b-q4_K_M",
            note: "",
            health: .ready
        )

        let apiProfile = ConnectorCapabilityProfile.infer(for: apiQwen, mode: .deep)
        let localProfile = ConnectorCapabilityProfile.infer(for: localQwen, mode: .deep)

        XCTAssertFalse(apiProfile.isLocal)
        XCTAssertEqual(apiProfile.maxIterations, ContextMode.deep.maxIterations)
        XCTAssertEqual(apiProfile.maxTokensPerTurn, ContextMode.deep.maxTokensPerTurn)
        XCTAssertNil(apiProfile.directOutputLimit)
        XCTAssertTrue(localProfile.isLocal)
        XCTAssertLessThan(localProfile.maxTokensPerTurn, apiProfile.maxTokensPerTurn)
        XCTAssertEqual(localProfile.directOutputLimit, 512)
    }
    func testConnectorCapabilityProfileRespectsDisabledToolCallingPolicy() {
        let connector = ConnectorProfile(
            name: "Local",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434",
            modelName: "qwen",
            note: "",
            toolCallingPolicy: .disabled,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertFalse(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .manualDisabled)
    }
    func testConnectorCapabilityProfilePrefersLearnedUnsupportedInAutomaticMode() {
        let connector = ConnectorProfile(
            name: "Local",
            kind: "ollama",
            endpoint: "http://127.0.0.1:11434",
            modelName: "qwen",
            note: "",
            toolCallingCapability: .unsupported,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertFalse(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .learnedUnsupported)
    }
    func testConnectorCapabilityProfileDescribesManualOverrideConflict() {
        let connector = ConnectorProfile(
            name: "Remote",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "",
            toolCallingPolicy: .enabled,
            toolCallingCapability: .unsupported,
            health: .ready
        )

        let profile = ConnectorCapabilityProfile.infer(for: connector, mode: .balanced)

        XCTAssertTrue(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingConflict, .unsupported)
        XCTAssertEqual(profile.toolCallingSourceDetail, "手动开启，覆盖已验证不兼容")
    }
    func testClearingLearnedToolCallingCapabilityKeepsManualOverrideEffective() {
        let connector = ConnectorProfile(
            name: "Remote",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "",
            toolCallingPolicy: .enabled,
            toolCallingCapability: .unsupported,
            health: .ready
        )
        let store = AppStore(
            state: testState(connectors: [connector], activeConnectorID: connector.id),
            environment: AppEnvironment(
                runtimeClient: CapturingToolsRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        store.clearLearnedToolCallingCapability(id: connector.id, showsToast: false)

        let updatedConnector = store.state.connectors.first
        XCTAssertNotNil(updatedConnector)
        XCTAssertNil(updatedConnector?.toolCallingCapability)
        XCTAssertNil(updatedConnector?.toolCallingCapabilitySource)
        XCTAssertNil(updatedConnector?.toolCallingCapabilityLearnedAt)
        let profile = ConnectorCapabilityProfile.infer(for: updatedConnector, mode: .balanced)
        XCTAssertTrue(profile.supportsToolCalling)
        XCTAssertEqual(profile.toolCallingSource, .manualEnabled)
        XCTAssertNil(profile.toolCallingConflict)
        XCTAssertEqual(profile.toolCallingSourceDetail, "手动开启")
    }
    func testThreadRecordAdaptsSessionsAndTasks() {
        let turn = ChatTurn(role: .user, text: "hello")
        let session = ChatSession(title: "Chat", preview: "hello", modelName: "m", turns: [turn])
        let sessionThread = ThreadRecord(session: session)

        XCTAssertEqual(sessionThread.source, .session)
        XCTAssertEqual(sessionThread.events.first?.kind, .user)
        XCTAssertEqual(sessionThread.events.first?.text, "hello")

        let step = TaskStep(kind: .toolCall, text: "search", toolName: "web.search")
        let task = AgentTask(title: "Task", status: .running, steps: [step])
        let taskThread = ThreadRecord(task: task)

        XCTAssertEqual(taskThread.source, .task)
        XCTAssertEqual(taskThread.status, .running)
        XCTAssertEqual(taskThread.events.first?.kind, .toolCall)
    }
}
