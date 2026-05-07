import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreToolingTests: LaicaiNativeFoundationTestCase {
    func testSearchToolFindsExistingFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("README.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertEqual(result.data?["count"], "1")
    }

    func testSearchToolReturnsClearEmptyResult() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"MissingFile","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("未找到匹配文件"))
    }

    func testReadFileToolReadsSmallFileWithinWorkspace() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "one\ntwo\nthree".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"notes.txt","offset":2,"limit":1}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "two")
        XCTAssertEqual(result.data?["path"], "notes.txt")
    }

    func testReadFileToolListsDirectory() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let value = 1".write(to: workspace.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".","limit":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("Sources/"))
        XCTAssertTrue(result.output.contains("Sources/App/main.swift"))
        XCTAssertEqual(result.data?["type"], "directory")
        XCTAssertEqual(result.data?["recursive"], "true")
    }

    func testReadFileToolRejectsXLSXWithExtractHint() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let xlsx = workspace.appendingPathComponent("需求.xlsx")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: xlsx)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"需求.xlsx"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "unsupported_binary_file")
        XCTAssertEqual(result.data?["recommendedTool"], "file.extract")
        XCTAssertTrue(result.output.contains("file_extract"))
    }

    func testExtractFileToolExtractsXLSXCells() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let xlsx = workspace.appendingPathComponent("需求.xlsx")
        try makeMinimalXLSX(at: xlsx)

        let result = try await ExtractFileTool().execute(
            argumentsJSON: #"{"path":"需求.xlsx"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success, result.output)
        XCTAssertEqual(result.data?["extension"], "xlsx")
        XCTAssertTrue(result.output.contains("会员系统"))
        XCTAssertTrue(result.output.contains("替换需求"))
    }

    func testReadFileToolTruncatesLargeFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let largeText = String(repeating: "0123456789\n", count: 6000)
        try largeText.write(to: workspace.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"large.txt"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertLessThan(result.output.count, largeText.count)
        XCTAssertTrue(result.output.contains("已截断"))
    }

    func testToolsRequireWorkspaceForRelativeOperations() async throws {
        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"README.md"}"#,
            context: TaskContext(workspaceRoot: "")
        )
        let search = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files"}"#,
            context: TaskContext(workspaceRoot: "")
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "workspace_missing")
        XCTAssertFalse(search.success)
        XCTAssertEqual(search.error, "workspace_missing")
    }

    func testToolDefinitionsExposeAPICompatibleNames() {
        let names = ToolRegistry.shared.toolDefinitions.map(\.function.name)

        XCTAssertTrue(names.contains("file_read"))
        XCTAssertTrue(names.contains("file_extract"))
        XCTAssertTrue(names.contains("code_search"))
        XCTAssertTrue(names.contains("workspace_index"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertTrue(names.contains("wiki_build"))
        XCTAssertFalse(names.contains("file.read"))
        XCTAssertFalse(names.contains("file.extract"))
        XCTAssertFalse(names.contains("code.search"))
    }

    func testAgentLoopPrioritizesEvidenceToolsInExplorePhase() {
        let names = AgentLoop.toolDefinitions(for: .task, phase: .explore).map {
            ToolNameCodec.canonicalName($0.function.name)
        }
        let workspaceIndex = names.firstIndex(of: "workspace.index")
        let codeSearch = names.firstIndex(of: "code.search")
        let fileRead = names.firstIndex(of: "file.read")
        let fileEdit = names.firstIndex(of: "file.edit")

        XCTAssertNotNil(workspaceIndex)
        XCTAssertNotNil(codeSearch)
        XCTAssertNotNil(fileRead)
        XCTAssertNotNil(fileEdit)
        XCTAssertLessThan(workspaceIndex!, fileEdit!)
        XCTAssertLessThan(codeSearch!, fileEdit!)
        XCTAssertLessThan(fileRead!, fileEdit!)
    }

    func testShellToolDefinitionSteersProjectReadingToStructuredTools() {
        let shellDefinition = ToolRegistry.shared.toolDefinitions.first { $0.function.name == "shell_exec" }
        let commandDescription = shellDefinition?.function.parameters.properties["command"]?.description ?? ""

        XCTAssertTrue(commandDescription.contains("workspace_index"))
        XCTAssertTrue(commandDescription.contains("code_search"))
        XCTAssertTrue(commandDescription.contains("file_read"))
        XCTAssertTrue(commandDescription.contains("不要用"))
    }

    func testAgentLoopOmitsToolsForPlainChat() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "你能做什么？",
            intent: .chat,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(runtime.requests.first?.tools)
    }

    func testAgentLoopInjectsStructuredMemoryForContinuation() {
        let steps = [
            TaskStep(kind: .toolCall, text: "正在建立项目索引", toolName: "workspace.index"),
            TaskStep(kind: .toolResult, text: "已建立项目索引", toolName: "workspace.index"),
            TaskStep(kind: .toolCall, text: "搜索 AppStore", toolName: "code.search", toolParams: ["query": "AppStore"]),
            TaskStep(kind: .toolResult, text: "读取 README", toolName: "file.read", toolParams: ["path": "README.md"]),
            TaskStep(kind: .toolResult, text: "失败：工具策略拦截", toolName: "shell.exec", isFailure: true),
            TaskStep(kind: .textOutput, text: "项目入口在 native-macos。"),
            TaskStep(kind: .aiThinking, text: "任务检查点\n状态：失败\n建议下一步：继续读入口")
        ]

        let memory = AgentLoop.structuredTaskMemory(from: steps)
        let messages = AgentLoop.initialMessages(
            systemPrompt: "system",
            message: "继续",
            priorSteps: steps
        )

        XCTAssertTrue(memory?.contains("已建立工作区索引：是") == true)
        XCTAssertTrue(memory?.contains("README.md") == true)
        XCTAssertTrue(memory?.contains("shell.exec ×1") == true)
        XCTAssertTrue(messages.contains { $0.content?.contains("结构化任务记忆") == true })
        XCTAssertTrue(messages.contains { $0.content?.contains("不要重复已经成功的读取或搜索") == true })
    }

    func testTruncatedContinuationDoesNotBootstrapWorkspaceSearch() async throws {
        let runtime = CapturingContinuationRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )
        let priorSteps = [
            TaskStep(kind: .userInput, text: "今天有什么 AI 新闻？"),
            TaskStep(kind: .textOutput, text: "前半段新闻内容"),
            TaskStep(kind: .error, text: "输出达到当前上限（1024 tokens），内容可能被截断。", recoverable: true)
        ]

        let task = try await loop.run(
            message: "继续",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp"),
            priorSteps: priorSteps
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("本轮不会搜索") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall })
        XCTAssertEqual(runtime.requests.count, 1)
        XCTAssertNil(runtime.requests.first?.tools)
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("上一条回复因为输出上限被截断") } == true)
    }

    func testAgentLoopExecutesFallbackRecoveryTool() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = ShellTraversalThenFinalRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取项目",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "shell.exec" && $0.isFailure })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "workspace.index" && $0.text.contains("自动恢复") })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure && $0.text.contains("自动恢复成功") })
        XCTAssertTrue(runtime.requests.contains { request in
            request.messages.contains { $0.role == "user" && ($0.content ?? "").contains("自动恢复工具 workspace.index") }
        })
    }

    func testAgentLoopIncludesToolsForTasks() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "搜索 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertTrue(runtime.requests.first?.tools?.contains { $0.function.name == "code_search" } == true)
        XCTAssertEqual(runtime.requests.first?.maxOutputTokens, 1024)
    }

    func testAgentLoopOmitsToolsWhenConfigDisablesToolCalling() async throws {
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp", supportsToolCalling: false),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "搜索 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(runtime.requests.first?.tools)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("已关闭工具调用") })
        XCTAssertTrue(runtime.requests.first?.messages?.first?.content?.contains("工具兼容限制") == true)
    }

    func testAgentLoopRetriesWithoutToolsWhenProviderRejectsToolCallingFormat() async throws {
        let runtime = ToolRejectedThenPlainRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理今天新闻",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests.first?.tools?.isEmpty == false)
        XCTAssertNil(runtime.requests.last?.tools)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("不兼容工具调用请求") })
        XCTAssertTrue(runtime.requests.last?.messages?.first?.content?.contains("工具兼容限制") == true)
    }

    func testAgentLoopAddsPlanVerifySummaryForComplexTasks() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取这个项目并找问题",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("执行计划") })
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("阶段总结") })
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("证据清单") })
        XCTAssertTrue(runtime.requests.first?.systemPrompt?.contains("Plan / Execute / Verify / Summarize") == true)
    }

    func testAgentLoopCarriesPersistedTaskMemoryIntoInitialMessages() {
        let context = TaskContext(
            workspaceRoot: "/tmp",
            memory: TaskMemory(
                readFiles: ["Sources/AppStore.swift"],
                searchedQueries: ["selectedThreadID"],
                failedTools: ["shell.exec ×1"],
                stageConclusions: ["已确认选中态需要统一。"],
                checkpoints: ["任务检查点：继续迁移线程。"],
                verificationStatus: "typecheck 已通过。",
                pendingFiles: ["Sources/SidebarView.swift"],
                userDecisions: ["用户要求不要重复搜索"]
            )
        )

        let messages = AgentLoop.initialMessages(
            systemPrompt: "system",
            message: "你又没读上下文，继续刚才任务",
            priorSteps: [],
            context: context
        )
        let combined = messages.map(\.content).joined(separator: "\n")

        XCTAssertTrue(combined.contains("Sources/AppStore.swift"))
        XCTAssertTrue(combined.contains("selectedThreadID"))
        XCTAssertTrue(combined.contains("shell.exec ×1"))
        XCTAssertTrue(combined.contains("typecheck 已通过"))
        XCTAssertTrue(combined.contains("Sources/SidebarView.swift"))
        XCTAssertTrue(combined.contains("用户要求不要重复搜索"))
        XCTAssertTrue(combined.contains("证据优先修复模式"))
    }

    func testAgentLoopBootstrapsWebSearchForFreshRequests() {
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "帮我整理今天的 AI 新闻", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "看看这个链接 https://example.com", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "glm-5.1和kimi k2.6 能力对比", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "为什么不能联网搜搜呢", intent: .task))
        XCTAssertTrue(AgentLoop.shouldBootstrapWebSearch(for: "上网查一下 Qwen3.6", intent: .task))
        XCTAssertFalse(AgentLoop.shouldBootstrapWebSearch(for: "为什么有的会话能调用联网工具", intent: .task))
        XCTAssertFalse(AgentLoop.shouldBootstrapWebSearch(for: "帮我整理今天的 AI 新闻", intent: .chat))

        let json = AgentLoop.bootstrapWebSearchArgumentsJSON(for: "帮我整理今天的 AI 新闻")
        XCTAssertTrue(json.contains("maxResults"))
        XCTAssertTrue(json.contains("今天"))
    }

    func testGenericWebFollowUpCarriesPreviousSubject() {
        let prior = [
            TaskStep(kind: .userInput, text: "glm-5.1和kimi k2.6 能力对比"),
            TaskStep(kind: .textOutput, text: "初步回答")
        ]

        let message = AgentLoop.bootstrapWebSearchMessage(
            for: "联网搜一下，另外，如果你一条输出不完，你可以输出两条",
            priorSteps: prior
        )

        XCTAssertTrue(message.contains("glm-5.1和kimi k2.6 能力对比"))
        XCTAssertTrue(message.contains("联网搜一下"))
    }

    func testAgentLoopBootstrapsWorkspaceSearchForTasks() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "Native harness notes".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "请解释 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "code.search" && $0.text.contains("README") })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.read" && $0.text.contains("README.md") })
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("自动读取的首个高相关文件片段") } == true)
        XCTAssertFalse(AgentLoop.shouldBootstrapWorkspaceSearch(for: "帮我整理今天的 AI 新闻", intent: .task, context: TaskContext(workspaceRoot: workspace.path)))
    }

    func testAgentLoopBootstrapsLocalPathReadBeforeWorkspaceSearch() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "attached".write(to: workspace.appendingPathComponent("attached.txt"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "请读取这个路径：\(workspace.appendingPathComponent("attached.txt").path)",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.read" && $0.text.contains("attached") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
    }

    func testAgentLoopBootstrapsSpreadsheetAttachmentWithFileExtract() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let xlsx = workspace.appendingPathComponent("会员系统替换需求调研0428.xlsx")
        try makeMinimalXLSX(at: xlsx)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理到wiki\n请读取这个附件：\(xlsx.path)",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path, vaultRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.extract" && $0.toolCallId == "call_bootstrap_file_extract" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.extract" && !$0.isFailure && $0.text.contains("会员系统") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" && $0.toolCallId == "call_bootstrap_file_read" })
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("我已直接提取用户提供的表格/文档") } == true)
    }

    func testAgentLoopDoesNotCompleteWikiTaskWithoutSavedWiki() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "迁移计划".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理到 wiki\n请读取这个附件：\(workspace.appendingPathComponent("notes.txt").path)",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path, vaultRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("Wiki 任务尚未保存") })
        XCTAssertFalse(task.steps.contains { $0.toolName == "wiki.build" && !$0.isFailure })
    }

    func testLearnedSkillDoesNotReturnUnrelatedHighQSkill() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let engine = SkillEvolutionEngine(path: workspace.path)
        engine.extractSkill(
            taskTitle: "你是谁",
            intent: "task",
            toolsUsed: ["code.search"],
            modelName: "test-model",
            outcomeScore: 95,
            strategy: "回答模型身份"
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(engine.bestSkill(intent: "task", modelName: "test-model", message: "整理到 wiki\n请读取这个附件：/tmp/需求.xlsx"))
    }

    func testWorkspaceIndexToolSummarizesProjectStructure() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try "# App".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let value = 1".write(to: workspace.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try "import XCTest".write(to: workspace.appendingPathComponent("Tests/AppTests/AppTests.swift"), atomically: true, encoding: .utf8)
        try "token".write(to: workspace.appendingPathComponent("Sources/App/auth_token.swift"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceIndexTool().execute(
            argumentsJSON: #"{"maxFiles":20,"maxDepth":5}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("swift"))
        XCTAssertTrue(result.output.contains("入口候选"))
        XCTAssertTrue(result.output.contains("测试候选"))
        XCTAssertTrue(result.output.contains("配置候选"))
        XCTAssertTrue(result.output.contains("风险/关注候选"))
        XCTAssertTrue(result.output.contains("Sources/App/main.swift"))
        XCTAssertTrue(result.output.contains("Tests/AppTests/AppTests.swift"))
        XCTAssertTrue(result.output.contains("Sources/App/auth_token.swift"))
        XCTAssertEqual(result.data?["fileCount"], "4")
        XCTAssertEqual(result.data?["entryCount"], "2")
        XCTAssertEqual(result.data?["testCount"], "1")
        XCTAssertEqual(result.data?["riskCount"], "1")
    }

    func testAgentLoopBootstrapsWorkspaceIndexForWholeProjectRequests() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "# App".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingToolsRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "全量读取这个项目并找问题",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(AgentLoop.shouldBootstrapWorkspaceIndex(for: "全量读取这个项目并找问题", intent: .task))
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "workspace.index" })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "code.search" })
    }

    func testBroadProjectImprovementUsesAuditSearchQuery() {
        let query = AgentLoop.bootstrapWorkspaceSearchQuery(for: "你能读取本地的项目吧？并且优化项目，直接改写本地文件")

        XCTAssertTrue(query.contains("TODO"))
        XCTAssertTrue(query.contains("ChatSession"))
        XCTAssertFalse(query.contains("你能读取"))
    }

    func testGenericContinuationDoesNotBecomeWorkspaceSearchQuery() {
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "继续"), "")
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "接着说"), "")
        XCTAssertEqual(AgentLoop.bootstrapWorkspaceSearchQuery(for: "没发完"), "")
    }

    func testAgentLoopExtractsReadablePathFromSearchOutput() {
        let root = "/tmp/project"
        XCTAssertEqual(
            AgentLoop.firstReadablePath(inSearchOutput: "/tmp/project/Sources/AppStore.swift:12:final class AppStore", workspaceRoot: root),
            "Sources/AppStore.swift"
        )
        XCTAssertEqual(
            AgentLoop.firstReadablePath(inSearchOutput: "README.md", workspaceRoot: root),
            "README.md"
        )
        XCTAssertNil(
            AgentLoop.firstReadablePath(inSearchOutput: "/tmp/project/assets/icon.png:binary", workspaceRoot: root)
        )
    }

    func testAgentLoopAutoContinuesWhenProviderStopsForLength() async throws {
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: LengthThenContinuationRuntime()
        )

        let task = try await loop.run(
            message: "写一篇长文",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("正在自动续写下一段") })
        XCTAssertEqual(task.steps.filter { $0.kind == .textOutput }.map(\.text), [
            "这是一段被供应商截断的回复",
            "这是自动续写的第二段。"
        ])
    }

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

    func testToolRegistryAcceptsAPICompatibleAliases() {
        XCTAssertEqual(ToolNameCodec.canonicalName("file_read"), "file.read")
        XCTAssertEqual(ToolNameCodec.canonicalName("code_search"), "code.search")
        XCTAssertEqual(ToolNameCodec.canonicalName("web_search"), "web.search")
        XCTAssertEqual(ToolNameCodec.canonicalName("web_fetch"), "web.fetch")
        XCTAssertEqual(ToolNameCodec.canonicalName("wiki_build"), "wiki.build")
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "file_read"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "code_search"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "web_search"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "web_fetch"))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "wiki_build"))
    }

    func testWebFetchExtractsReadableTextFromHTML() {
        let html = """
        <html><head><title>Example &amp; Test</title><style>.x{}</style></head>
        <body><nav>menu</nav><h1>Hello</h1><p>Readable content &quot;here&quot;.</p><script>alert(1)</script></body></html>
        """

        let result = WebFetchTool.extractReadableText(fromHTML: html, url: "https://example.com/page", maxCharacters: 500)

        XCTAssertEqual(result.title, "Example & Test")
        XCTAssertTrue(result.content.contains("Hello"))
        XCTAssertTrue(result.content.contains(#"Readable content "here"."#))
        XCTAssertFalse(result.content.contains("alert"))
        XCTAssertFalse(result.content.contains("menu"))
    }

    func testAgentLoopBootstrapsWebFetchForExplicitURL() {
        XCTAssertEqual(
            AgentLoop.firstURL(in: "读一下 https://example.com/a?b=1，然后创建 skill"),
            "https://example.com/a?b=1"
        )

        let json = AgentLoop.bootstrapWebFetchArgumentsJSON(for: "https://example.com")
        XCTAssertTrue(json.contains("https://example.com"))
        XCTAssertTrue(json.contains("maxCharacters"))
    }

    func testFunctionCallArgumentsDecodeObjectPayloads() throws {
        let json = #"{"name":"web_search","arguments":{"query":"AI news","maxResults":3}}"#.data(using: .utf8)!
        let detail = try JSONDecoder().decode(FunctionCallDetail.self, from: json)

        XCTAssertEqual(detail.name, "web_search")
        XCTAssertTrue(detail.arguments.contains(#""query":"AI news""#))
        XCTAssertTrue(detail.arguments.contains(#""maxResults":3"#))
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

    func testAgentLoopStopsAtMaxIterations() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let loop = AgentLoop(
            config: .init(maxIterations: 1, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: LoopingToolRuntime()
        )
        let task = try await loop.run(
            message: "找 README",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "http://localhost", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.text.contains("最大迭代次数") })
    }

    func testAgentLoopMarksProviderErrorsAsFailed() async throws {
        let loop = AgentLoop(
            config: .init(maxIterations: 3, maxTokensPerTurn: 1024, workspaceRoot: "/tmp"),
            runtime: ProviderErrorRuntime()
        )
        let task = try await loop.run(
            message: "整理今天新闻",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.kind == .error && $0.text.contains("请求格式不被") })
        XCTAssertFalse(task.steps.contains { $0.kind == .textOutput && $0.text.contains("请求格式不被") })
        XCTAssertFalse(task.steps.contains { $0.text.contains("最大迭代次数") })
    }

    func testOpenAICompatibleToolRoundtripPreservesReasoningContent() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingReasoningRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "读 README",
            intent: .task,
            connector: ConnectorProfile(name: "DeepSeek", kind: "openai-compatible", endpoint: "https://api.deepseek.com/v1", modelName: "deepseek-v4-pro", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests[1].messages.contains {
            $0.role == "assistant" && $0.reasoningContent == "先读取文件。"
        })
    }

    func testOllamaToolResultsAreFedBackAsPlainText() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = CapturingOllamaRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 2, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        _ = try await loop.run(
            message: "读 README",
            intent: .task,
            connector: ConnectorProfile(name: "qwen", kind: "ollama", endpoint: "http://127.0.0.1:11434", modelName: "qwen", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertTrue(runtime.requests[1].messages.contains { $0.role == "user" && ($0.content ?? "").contains("工具 file.read 执行结果") })
        XCTAssertFalse(runtime.requests[1].messages.contains { $0.role == "tool" })
    }

    func testStartWorkflowCreatesTaskAndRunRecord() {
        let connector = ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready)
        let store = AppStore(state: .init(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: [],
            selectedSessionID: nil,
            workbenchTab: .workflows,
            connectors: [connector],
            activeConnectorID: connector.id,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: "/tmp", defaultConnectorName: "Test", compactComposer: false, showDebugPanels: false)
        ))

        store.startWorkflow(named: "code-review")

        XCTAssertEqual(store.state.workflowRuns.first?.name, "code-review")
        XCTAssertEqual(store.state.workflowRuns.first?.statusLine, "执行中")
        XCTAssertEqual(store.state.tasks.first?.workflowName, "code-review")
        XCTAssertEqual(store.state.selectedTaskID, store.state.tasks.first?.id)
        XCTAssertGreaterThanOrEqual(store.state.tasks.first?.steps.count ?? 0, 2)
        XCTAssertEqual(store.state.tasks.first?.steps[1].kind, .aiThinking)
        XCTAssertTrue(store.state.tasks.first?.steps[1].text.contains("规划：工作流") == true)
    }

    func testWorkflowParserSupportsFailureStrategyConditionsAndPromptBlocks() {
        let source = """
        name: custom-review
        description: 自定义审查
        steps:
          - name: 搜索
            tool: code.search
            on_failure: skip
            params:
              query: AppStore
              scope: content
          - name: 总结
            tool: llm
            when: previous.success
            prompt: |
              请总结：
              {{previous.output}}
        """

        let workflow = WorkflowParser.parse(source)

        XCTAssertEqual(workflow?.name, "custom-review")
        XCTAssertEqual(workflow?.steps.count, 2)
        XCTAssertEqual(workflow?.steps.first?.onFailure, "skip")
        XCTAssertEqual(workflow?.steps.first?.params["query"], "AppStore")
        XCTAssertEqual(workflow?.steps.last?.condition, "previous.success")
        XCTAssertTrue(workflow?.steps.last?.prompt?.contains("{{previous.output}}") == true)
    }

    func testWorkflowLibraryLoadsCustomYamlFromWorkspace() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dir = workspace.appendingPathComponent(".laicai/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        name: custom
        description: custom workflow
        steps:
          - name: list
            tool: shell.exec
            params:
              command: pwd
        """.write(to: dir.appendingPathComponent("custom.yaml"), atomically: true, encoding: .utf8)

        let workflows = WorkflowLibrary.available(workspaceRoot: workspace.path)

        XCTAssertTrue(workflows.contains { $0.name == "custom" })
        XCTAssertTrue(workflows.contains { $0.name == "code-review" })
    }

    func testSkillRegistryCreatesAndLoadsLocalDraft() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = SkillRegistry.shared

        let skill = try registry.createDraft(
            name: "整理日报",
            description: "生成项目日报",
            tools: ["code.search", "file.read"],
            workspaceRoot: workspace.path
        )
        registry.refresh(workspaceRoot: workspace.path)

        XCTAssertFalse(skill.isBuiltin)
        XCTAssertTrue(registry.skills.contains { $0.name == "整理日报" })
        XCTAssertTrue(SkillRegistry.loadLocalSkills(workspaceRoot: workspace.path).contains { $0.name == "整理日报" })
    }

    func testBootstrapSelectsLatestThreadAcrossSessionsAndTasks() {
        let olderSession = ChatSession(
            title: "旧线程",
            preview: "",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test"
        )
        let newerTask = AgentTask(
            title: "新任务",
            status: .completed,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [olderSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: [newerTask]),
            threadRepository: NoopThreadRepository()
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertEqual(state.selectedTaskID, newerTask.id)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertEqual(state.selectedThreadID, newerTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }

    func testBootstrapRestoresPersistedThreadSnapshotAsAuthoritativeSource() {
        let staleSession = ChatSession(
            title: "旧标题",
            preview: "旧",
            updatedAt: Date(timeIntervalSince1970: 10),
            category: .engineering,
            modelName: "test",
            turns: [ChatTurn(role: .user, text: "旧")]
        )
        let restoredTask = AgentTask(
            id: staleSession.id,
            title: "已升级任务",
            status: .completed,
            steps: [
                TaskStep(kind: .userInput, text: "读取项目"),
                TaskStep(kind: .textOutput, text: "完成")
            ],
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let environment = AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: FixedSessionRepository(sessions: [staleSession]),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: FixedTaskRepository(tasks: []),
            threadRepository: FixedThreadRepository(threads: [Thread(task: restoredTask)])
        )

        let state = AppState.bootstrap(environment: environment)

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertEqual(state.tasks.first?.id, restoredTask.id)
        XCTAssertEqual(state.tasks.first?.title, "已升级任务")
        XCTAssertEqual(state.selectedThreadID, restoredTask.id)
        XCTAssertEqual(state.selectedThreadSource, .task)
    }

    func testBootstrapCancelsStaleRunningTasks() {
        let staleTask = AgentTask(
            title: "旧任务",
            status: .running,
            updatedAt: Date(timeIntervalSinceNow: -3600)
        )
        let store = AppStore(
            state: testState(tasks: [staleTask], selectedTaskID: staleTask.id),
            environment: AppEnvironment(
                runtimeClient: PreviewChatRuntime(),
                sessionRepository: NoopSessionRepository(),
                connectorRepository: NoopConnectorRepository(),
                taskRepository: NoopTaskRepository(),
                threadRepository: NoopThreadRepository()
            )
        )

        XCTAssertEqual(store.state.tasks.first?.status, .cancelled)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.contains("上次运行被中断") } == true)
        XCTAssertTrue(store.state.tasks.first?.steps.contains { $0.text.hasPrefix("任务检查点") } == true)
        XCTAssertEqual(store.state.selectedTaskID, staleTask.id)
    }

    func testWikiPreviewDoesNotWriteUntilSaved() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Python\nPython is useful for automation.".write(to: notes.appendingPathComponent("python.md"), atomically: true, encoding: .utf8)

        let preview = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":false}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        XCTAssertTrue(preview.success)
        XCTAssertEqual(preview.data?["saved"], "false")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/Python.md").path))
        XCTAssertTrue(preview.output.contains("[[python]]"))
    }

    func testWikiSaveWritesTopicPage() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }

        let saved = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"Python","save":true}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        let target = vault.appendingPathComponent("02 Atomic/Python.md")
        XCTAssertTrue(saved.success)
        XCTAssertEqual(saved.data?["saved"], "true")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains(#"topic: "Python""#))
    }

    func testWikiEngineReturnsSourcesAndDiffForExistingTopic() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }
        let notes = vault.appendingPathComponent("02 Notes", isDirectory: true)
        let topics = vault.appendingPathComponent("02 Atomic", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        try "# AI\n人工智能基础知识包括模型、数据和评估。".write(to: notes.appendingPathComponent("ai.md"), atomically: true, encoding: .utf8)
        try "# 人工智能\n旧内容".write(to: topics.appendingPathComponent("人工智能.md"), atomically: true, encoding: .utf8)

        let result = await WikiEngine.buildTopic(
            topic: "人工智能",
            vaultRoot: vault.path,
            save: false,
            useWeb: false,
            topK: 4
        )

        XCTAssertFalse(result.saved)
        XCTAssertEqual(result.notePath, "02 Atomic/人工智能.md")
        XCTAssertNotNil(result.previousMarkdown)
        XCTAssertTrue(result.diffSummary.contains("更新"))
        XCTAssertTrue(result.sources.contains { $0.path == "02 Notes/ai.md" })
        XCTAssertTrue(result.renderedMarkdown.contains("## Related Notes"))
    }

    func testWikiTopicSanitizesPathSeparators() async throws {
        let vault = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: vault) }

        let saved = try await WikiBuildTool().execute(
            argumentsJSON: #"{"topic":"API/Token: 安全?","save":true}"#,
            context: TaskContext(workspaceRoot: vault.path, vaultRoot: vault.path)
        )

        XCTAssertTrue(saved.success)
        XCTAssertEqual(saved.data?["path"], "02 Atomic/API - Token - 安全.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/API - Token - 安全.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("02 Atomic/API/Token: 安全?.md").path))
    }

    func testCompletionCriteriaRequiresSavedWikiForWikiTasks() {
        let task = AgentTask(
            title: "整理到 wiki",
            steps: [
                TaskStep(kind: .userInput, text: "整理到 wiki\n请读取这个附件：/tmp/a.xlsx"),
                TaskStep(kind: .toolCall, text: "读取", toolName: "file.read", toolParams: ["path": "/tmp/a.xlsx"]),
                TaskStep(kind: .toolResult, text: "已读取目录", toolName: "file.read"),
                TaskStep(kind: .textOutput, text: "我会整理成 Wiki。")
            ]
        )

        XCTAssertFalse(AgentLoop.meetsCompletionCriteria(task: task, intent: .task, didComplete: true, hadFailure: false, wasTruncated: false))

        var saved = task
        saved.steps.append(TaskStep(kind: .toolCall, text: "保存 Wiki", toolName: "wiki.build", toolParams: ["topic": "迁移", "save": "true"]))
        saved.steps.append(TaskStep(kind: .toolResult, text: "已保存 Wiki：迁移 → 02 Atomic/迁移.md", toolName: "wiki.build", toolParams: ["save": "true"]))

        XCTAssertTrue(AgentLoop.meetsCompletionCriteria(task: saved, intent: .task, didComplete: true, hadFailure: false, wasTruncated: false))
    }

    func testGitToolReturnsFriendlyResultOutsideRepository() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await GitTool().execute(
            argumentsJSON: #"{"subcommand":"status"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["repository"], "false")
        XCTAssertTrue(result.output.contains("不是 git 仓库"))
    }

    func testWriteFileToolDoesNotChangeDiskBeforeApproval() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let nested = workspace.appendingPathComponent("Notes/New.md")

        let result = try await WriteFileTool().execute(
            argumentsJSON: #"{"path":"Notes/New.md","content":"hello","createDirectories":true}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path))
    }

    func testApproveReviewWritesFileAndRecordsAudit() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Approved.md")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path, "createDirectories": "true"],
            diffFilePath: "Approved.md",
            diffOldContent: "",
            diffNewContent: "approved"
        )
        let task = AgentTask(title: "写文件", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved")
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, true)
        XCTAssertTrue(store.state.selectedTask?.steps.contains(where: { $0.kind == .reviewResult && $0.approved == true }) == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.write" && $0.success })
    }

    func testRejectReviewDoesNotWriteFileAndRecordsAudit() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Rejected.md")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "Rejected.md",
            diffOldContent: "",
            diffNewContent: "rejected"
        )
        let task = AgentTask(title: "拒绝写入", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.rejectReview(taskID: task.id, stepID: step.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, false)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.write" && !$0.success })
    }

    func testRollbackLastApprovedWriteRestoresOldContent() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Rollback.md")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "Rollback.md",
            diffOldContent: "old",
            diffNewContent: "new"
        )
        let task = AgentTask(title: "回滚写入", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")

        store.rollbackLastApprovedWrite(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.kind == .reviewResult && $0.text.contains("已回滚") } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.rollback" && $0.success })
    }

    func testShellWhitelistAllowsPwdAndRejectsSudoAndProjectTraversal() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let pwd = try await ShellTool().execute(argumentsJSON: #"{"command":"pwd"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let sudo = try await ShellTool().execute(argumentsJSON: #"{"command":"sudo ls"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let findFiles = try await ShellTool().execute(argumentsJSON: #"{"command":"find . -type f"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let recursiveList = try await ShellTool().execute(argumentsJSON: #"{"command":"ls -R ."}"#, context: TaskContext(workspaceRoot: workspace.path))

        XCTAssertTrue(pwd.success)
        XCTAssertTrue(pwd.output.contains(workspace.path))
        XCTAssertFalse(sudo.success)
        XCTAssertEqual(sudo.error, "security_denied")
        XCTAssertFalse(findFiles.success)
        XCTAssertEqual(findFiles.error, "security_denied")
        XCTAssertTrue(findFiles.output.contains("workspace.index"))
        XCTAssertFalse(recursiveList.success)
        XCTAssertEqual(recursiveList.error, "security_denied")
    }

    func testShellPolicyRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "工具策略拦截：不要用 shell 遍历项目结构。",
            toolName: "shell.exec",
            params: ["command": "find . -type f"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, argumentsJSON) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
        XCTAssertTrue(argumentsJSON.contains("maxFiles"))
    }

    func testCodeSearchRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "搜索失败",
            toolName: "code.search",
            params: ["query": "AppStore"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, _) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
    }

    func testUnsupportedBinaryReadRecoveryFallsBackToFileExtract() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "unsupported_binary_file：这是 XLSX 文档/表格，请改用 file_extract",
            toolName: "file.read",
            params: ["path": "/tmp/需求.xlsx"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, argumentsJSON) = plan.action else {
            XCTFail("Expected file.extract fallback")
            return
        }

        XCTAssertEqual(toolName, "file.extract")
        XCTAssertTrue(argumentsJSON.contains("/tmp/需求.xlsx"))
        XCTAssertTrue(argumentsJSON.contains("60000"))
    }

    func testSensitivePathsAreBlocked() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "SECRET=1".write(to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".env"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let write = try await WriteFileTool().execute(
            argumentsJSON: #"{"path":".ssh/id_rsa","content":"secret"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "security_denied")
        XCTAssertFalse(write.success)
        XCTAssertEqual(write.error, "security_denied")
    }

    func testCheckpointPathsOnlyIncludeWorkspaceRelativeWriteTargets() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceDir = workspace.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let inside = sourceDir.appendingPathComponent("App.swift")
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("outside.txt")

        let paths = AgentLoop.normalizedCheckpointPaths(
            ["Sources/App.swift", inside.path, outside.path, ""],
            workspaceRoot: workspace.path
        )

        XCTAssertEqual(paths, ["Sources/App.swift"])
        XCTAssertEqual(
            AgentLoop.checkpointPaths(toolName: "file.write", arguments: ["path": "Sources/App.swift"], workspaceRoot: workspace.path),
            ["Sources/App.swift"]
        )
        XCTAssertTrue(AgentLoop.checkpointPaths(toolName: "shell.exec", arguments: ["command": "touch x"], workspaceRoot: workspace.path).isEmpty)
    }

    func testGitStatusLinePathParsingHandlesRenamesAndUntrackedFiles() {
        XCTAssertEqual(GitTool.pathFromStatusLine(" M native-macos/build.sh"), "native-macos/build.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("?? scripts/check_project_hygiene.sh"), "scripts/check_project_hygiene.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("R  old.swift -> new.swift"), "new.swift")
        XCTAssertNil(GitTool.pathFromStatusLine("  "))
    }

}
