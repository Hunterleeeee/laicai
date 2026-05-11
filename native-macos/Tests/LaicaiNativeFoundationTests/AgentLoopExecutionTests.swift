import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AgentLoopExecutionTests: LaicaiNativeFoundationTestCase {
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
    func testAgentLoopRetriesEmptyResponsesWithoutSurfacingRuntimeFallbackText() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtime = EmptyThenFinalRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 4, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理到 wiki",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path, vaultRoot: workspace.path)
        )

        XCTAssertGreaterThanOrEqual(runtime.requests.count, 3)
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("模型返回空内容，自动重试") })
        XCTAssertTrue(task.steps.contains { $0.kind == .aiThinking && $0.text.contains("临时移除工具定义") })
        XCTAssertFalse(task.steps.contains { $0.kind == .textOutput && $0.text.contains("模型没有返回可显示内容") })
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
}
