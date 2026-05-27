import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStorePersistenceAndRuntimeTests: LaicaiNativeFoundationTestCase {
    func testSQLiteRepositoryPersistsTaskContext() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let task = AgentTask(
            title: "读取项目",
            status: .running,
            steps: [TaskStep(kind: .toolCall, text: "读取文件", toolName: "file.read", toolParams: ["path": "README.md"])],
            connectorID: UUID(),
            workflowName: "代码分析",
            context: TaskContext(
                workspaceRoot: "/tmp/workspace",
                relevantFiles: [
                    FileInfo(path: "README.md", language: "md", summary: "项目说明"),
                    FileInfo(path: "Sources/App.swift", language: "swift", summary: "入口")
                ],
                claudeMD: "记忆",
                gitBranch: "main",
                gitDiff: "1 file changed, 3 insertions(+)"
            )
        )

        try repository.saveTasks([task])
        let loaded = try XCTUnwrap(repository.loadTasks())
        let restored = try XCTUnwrap(loaded.first)

        XCTAssertEqual(restored.context.workspaceRoot, task.context.workspaceRoot)
        XCTAssertEqual(restored.context.gitBranch, task.context.gitBranch)
        XCTAssertEqual(restored.context.gitDiff, task.context.gitDiff)
        XCTAssertEqual(restored.context.relevantFiles.map(\.path), task.context.relevantFiles.map(\.path))
    }
    func testSQLiteRepositoryPersistsConnectorCapabilityMetadata() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let learnedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let connector = ConnectorProfile(
            name: "Test",
            kind: "openai-compatible",
            endpoint: "https://example.com/v1",
            modelName: "test-model",
            note: "key",
            toolCallingPolicy: .automatic,
            toolCallingCapability: .supported,
            toolCallingCapabilitySource: .connectorProbe,
            toolCallingCapabilityLearnedAt: learnedAt,
            health: .ready
        )

        try repository.saveConnectors([connector], activeConnectorID: connector.id)
        let catalog = try XCTUnwrap(repository.loadConnectorCatalog())
        let restored = try XCTUnwrap(catalog.connectors.first)

        XCTAssertEqual(restored.toolCallingCapability, .supported)
        XCTAssertEqual(restored.toolCallingCapabilitySource, .connectorProbe)
        XCTAssertEqual(restored.toolCallingCapabilityLearnedAt, learnedAt)
        XCTAssertEqual(catalog.activeConnectorID, connector.id)
    }
    func testSQLiteRepositoryPersistsUnifiedThreadSnapshot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let task = AgentTask(
            title: "统一线程",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "生成 README", isCollapsible: false, isCollapsed: false),
                TaskStep(kind: .textOutput, text: "已生成")
            ],
            context: TaskContext(workspaceRoot: "/tmp/workspace")
        )
        let thread = Thread(
            id: task.id,
            title: task.title,
            preview: task.preview,
            status: task.status,
            steps: task.steps,
            connectorID: task.connectorID,
            workflowName: task.workflowName,
            context: task.context,
            updatedAt: task.updatedAt,
            executionState: Thread.inferAgentState(status: task.status),
            goal: task.steps.first(where: { $0.kind == .userInput })?.text,
            taskProtocol: task.taskProtocol,
            executionLedger: task.executionLedger
        )

        try repository.saveThreads([thread])
        let loaded = try XCTUnwrap(repository.loadThreads())
        let restored = try XCTUnwrap(loaded.first)

        XCTAssertEqual(restored.id, thread.id)
        XCTAssertEqual(restored.title, "统一线程")
        XCTAssertEqual(restored.steps.map(\.kind), [.userInput, .textOutput])
        XCTAssertEqual(restored.steps.map(\.text), ["生成 README", "已生成"])
    }
    func testSQLiteRepositoryDeletesThreadsAfterReload() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = Thread(title: "保留", preview: "keep", updatedAt: Date(timeIntervalSince1970: 10))
        let second = Thread(title: "删除", preview: "delete", updatedAt: Date(timeIntervalSince1970: 20))
        try SQLiteRepository(path: base.path).saveThreads([first, second])

        let reloaded = SQLiteRepository(path: base.path)
        try reloaded.saveThreads([first])

        let loaded = try XCTUnwrap(SQLiteRepository(path: base.path).loadThreads())
        XCTAssertEqual(loaded.map(\.id), [first.id])
    }

    func testSQLiteRepositorySavesPayloadChangesWithoutTimestampChange() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var thread = Thread(
            title: "历史会话",
            preview: "hello",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let repository = SQLiteRepository(path: base.path)
        try repository.saveThreads([thread])

        try repository.saveThreads([thread])

        let loaded = try XCTUnwrap(SQLiteRepository(path: base.path).loadThreads())
        XCTAssertEqual(loaded.first?.updatedAt, Date(timeIntervalSince1970: 10))
    }

    func testThreadDecodingToleratesMissingMigrationFields() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "旧线程",
          "preview": "旧预览",
          "status": "completed",
          "steps": [],
          "context": {},
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let thread = try decoder.decode(Thread.self, from: Data(json.utf8))

        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.modelName, "")
        XCTAssertEqual(thread.category, .engineering)
        XCTAssertFalse(thread.isPinned)
    }

    func testThreadDecodingWithoutTitleDefaultsToNewSession() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "preview": "旧预览",
          "status": "completed",
          "steps": [],
          "context": {},
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let thread = try decoder.decode(Thread.self, from: Data(json.utf8))

        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.title, "新会话")
    }

    func testExportSelectedThreadMarkdownUsesNewSessionFallbackTitle() throws {
        let thread = Thread(title: "", preview: "", status: .completed)
        let store = AppStore(state: testState(threads: [thread], selectedThreadID: thread.id))

        let markdown = try XCTUnwrap(store.exportSelectedThreadMarkdown())

        XCTAssertTrue(markdown.hasPrefix("# 新会话\n"))
    }

    func testExportSelectedTaskEvidenceMarkdownUsesSessionWording() throws {
        let thread = Thread(
            title: "",
            status: .completed,
            steps: [TaskStep(kind: .toolCall, text: "读取文件", toolName: "file.read")],
            executionState: .completed
        )
        let store = AppStore(state: testState(threads: [thread], selectedThreadID: thread.id))

        let markdown = try XCTUnwrap(store.exportSelectedTaskEvidenceMarkdown())

        XCTAssertTrue(markdown.hasPrefix("# 会话证据清单：新会话\n"))
    }

    func testThreadPersistsAgentSnapshotFields() throws {
        let artifact = AgentArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            title: "result.pdf",
            path: "/tmp/result.pdf",
            kind: "document",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let thread = Thread(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            title: "翻译文档",
            status: .running,
            executionState: .running,
            goal: "把文档翻译成英文",
            currentPlan: ["读取源文档", "生成译文", "导出 PDF"],
            artifacts: [artifact]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(thread)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("executionState"))
        XCTAssertTrue(json.contains("currentPlan"))
        XCTAssertTrue(json.contains("artifacts"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Thread.self, from: data)

        XCTAssertEqual(decoded.executionState, .running)
        XCTAssertEqual(decoded.goal, "把文档翻译成英文")
        XCTAssertEqual(decoded.currentPlan, ["读取源文档", "生成译文", "导出 PDF"])
        XCTAssertEqual(decoded.artifacts, [artifact])
    }

    func testThreadPersistsTaskProtocolAndExecutionLedger() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000333")!
        let taskProtocol = AgentTaskProtocol(
            taskGoal: "修复继续按钮",
            workspaceRoot: "/tmp/workspace",
            threadID: id,
            expectedOutcome: "按钮可继续原 Agent",
            completionCriteria: ["不新建会话", "读取执行账本"],
            riskPolicy: .act,
            continuationPolicy: .ownFollowUps,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        var ledger = AgentExecutionLedger(
            originalRequest: "修复继续按钮",
            goal: "修复继续按钮",
            state: .executing,
            plan: ["复现", "修复", "验证"],
            nextAction: "点击继续后从账本恢复",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        ledger.appendUnique("Sources/AppStore.swift", to: \.readFiles)
        ledger.appendUnique("Tests/AppStoreTests.swift", to: \.modifiedFiles)
        let thread = Thread(
            id: id,
            title: "修复继续按钮",
            status: .running,
            taskProtocol: taskProtocol,
            executionLedger: ledger
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(Thread.self, from: data)

        XCTAssertEqual(decoded.taskProtocol?.taskGoal, "修复继续按钮")
        XCTAssertEqual(decoded.taskProtocol?.completionCriteria, ["不新建会话", "读取执行账本"])
        XCTAssertEqual(decoded.executionLedger?.state, .executing)
        XCTAssertEqual(decoded.executionLedger?.readFiles, ["Sources/AppStore.swift"])
        XCTAssertEqual(decoded.executionLedger?.modifiedFiles, ["Tests/AppStoreTests.swift"])
        XCTAssertEqual(AgentTask(thread: decoded).executionLedger?.nextAction, "点击继续后从账本恢复")
    }

    func testPersistentMemoryUsesBoundParameters() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = SQLiteRepository(path: base.path)
        let workspace = "/tmp/laicai user's workspace"
        let category = "quote's"
        repository.saveMemory(workspace: workspace, category: category, key: "k", value: "v")

        XCTAssertEqual(repository.loadMemories(workspace: workspace, category: category).first?.value, "v")
        repository.deleteMemory(id: repository.loadMemories(workspace: workspace, category: category).first?.id ?? "")
        XCTAssertTrue(repository.loadMemories(workspace: workspace, category: category).isEmpty)
    }
    func testToolResultFormatterSummarizesFileRead() {
        let result = ToolResult(
            output: "line 1\nline 2\nline 3",
            data: ["path": "README.md", "size": "20"]
        )

        let summary = ToolResultFormatter.displayText(toolName: "file.read", arguments: [:], result: result)

        XCTAssertTrue(summary.contains("README.md"))
        XCTAssertTrue(summary.contains("3 行"))
        XCTAssertFalse(summary.contains("line 1"))
    }
    func testToolResultFormatterCompressesLongModelContent() {
        let output = String(repeating: "abcdefg\n", count: 600)
        let content = ToolResultFormatter.modelContent(
            toolName: "code.search",
            result: ToolResult(output: output),
            limit: 1200
        )

        XCTAssertLessThan(content.count, output.count)
        XCTAssertTrue(content.contains("中间内容已省略"))
    }
    func testToolStepFormatterUsesProductLanguage() {
        XCTAssertEqual(
            ToolStepFormatter.callText(toolName: "file.read", arguments: ["path": "README.md"]),
            "正在读取文件：README.md"
        )
        XCTAssertEqual(
            ToolStepFormatter.callText(toolName: "code.search", arguments: ["query": "AppStore", "scope": "content"]),
            "正在搜索项目内容：AppStore"
        )
    }
    func testBuildURLExpandsOpenAICompatibleBaseEndpoint() {
        let base = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1", kind: "openai-compatible")
        let full = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1/chat/completions", kind: "openai-compatible")
        let malformed = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1/api/chat", kind: "openai-compatible")
        let wrongKind = LiveChatRuntime.buildURL(from: "https://api.deepseek.com/v1", kind: "ollama")

        XCTAssertEqual(base.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(full.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(malformed.absoluteString, "https://api.deepseek.com/v1/api/chat")
        XCTAssertEqual(wrongKind.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }
    func testGenericOpenAICompatibleURLUsesUserInputExactly() {
        let url = LiveChatRuntime.buildURL(from: "https://api.example.com/custom", kind: "openai-compatible")

        XCTAssertEqual(url.absoluteString, "https://api.example.com/custom")
    }
    func testOllamaURLExpandsBaseEndpoints() {
        let base = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434", kind: "ollama")
        let apiBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/api", kind: "ollama")
        let compatBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/v1", kind: "ollama")
        let localCompatBase = LiveChatRuntime.buildURL(from: "http://127.0.0.1:53759/v1", kind: "ollama")
        let explicitNative = LiveChatRuntime.buildURL(from: "http://127.0.0.1:53759/api/chat", kind: "ollama")
        let explicitCompat = LiveChatRuntime.buildURL(from: "http://127.0.0.1:11434/v1/chat/completions", kind: "ollama")

        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(apiBase.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(compatBase.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(localCompatBase.absoluteString, "http://127.0.0.1:53759/v1/chat/completions")
        XCTAssertEqual(explicitNative.absoluteString, "http://127.0.0.1:53759/api/chat")
        XCTAssertEqual(explicitCompat.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }
    func testConnectorKindNormalizesExplicitV1EndpointsSavedAsOllama() {
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "https://ds2api.endpoint.oai.red/v1"),
            "openai-compatible"
        )
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "http://127.0.0.1:53759/v1"),
            "openai-compatible"
        )
        XCTAssertEqual(
            LiveChatRuntime.normalizedConnectorKind("ollama", endpoint: "http://127.0.0.1:11434"),
            "ollama"
        )
    }
    func testMalformedEndpointFallsBackWithoutCrashing() {
        let url = LiveChatRuntime.buildURL(from: "not a url", kind: "openai-compatible")

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1/invalid-endpoint")
    }
    func testServiceBaseStripsChatCompletionPathForHealthCheck() {
        XCTAssertEqual(
            LiveChatRuntime.serviceBaseEndpoint(from: "https://api.deepseek.com/v1/chat/completions"),
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(
            LiveChatRuntime.serviceBaseEndpoint(from: "https://api.example.com/v1/chat/completions"),
            "https://api.example.com"
        )
    }
    func testOpenAICompatibleHealthCheckRequiresRequestedModelWhenModelListIsAvailable() async throws {
        let session = makeStubbedSession(body: #"{"data":[{"id":"other-model"}]}"#.data(using: .utf8)!)
        let runtime = LiveChatRuntime(session: session)

        let health = try await runtime.healthCheck(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible"
        )

        XCTAssertEqual(health, .attention)
    }
}
