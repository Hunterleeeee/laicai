import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class AgentLoopBootstrapTests: LaicaiNativeFoundationTestCase {
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
        XCTAssertTrue(messages.contains { $0.content?.contains("结构化会话记忆") == true })
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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
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
        let combined = messages.compactMap(\.content).joined(separator: "\n")

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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path, vaultRoot: workspace.path)
        )

        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.extract" && $0.toolCallId == "call_bootstrap_file_extract" })
        XCTAssertTrue(task.steps.contains { $0.kind == .toolResult && $0.toolName == "file.extract" && !$0.isFailure && $0.text.contains("会员系统") })
        XCTAssertFalse(task.steps.contains { $0.kind == .toolCall && $0.toolName == "file.read" && $0.toolCallId == "call_bootstrap_file_read" })
        XCTAssertTrue(runtime.requests.first?.messages?.contains { ($0.content ?? "").contains("我已直接提取用户提供的表格/文档") } == true)
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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
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
    func testGeneralDomainCorrectionsDoNotBootstrapWorkspaceSearch() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = TaskContext(workspaceRoot: workspace.path)

        let prompts = [
            "你用易经算啊",
            "数据不对",
            "我说让你干啊 我只要结果",
            "这个skill都能干嘛呢",
            "我想知道拓日新能这个股票下午能涨到多少"
        ]

        for prompt in prompts {
            XCTAssertFalse(
                AgentLoop.shouldBootstrapWorkspaceSearch(for: prompt, intent: .task, context: context),
                prompt
            )
        }
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
            connector: ConnectorProfile(
                name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("正在自动续写下一段") })
        XCTAssertEqual(
            task.steps.filter { $0.kind == .textOutput }.map(\.text),
            [
                "这是一段被供应商截断的回复",
                "这是自动续写的第二段。"
            ])
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
}
