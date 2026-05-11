import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AgentLoopToolDefinitionTests: LaicaiNativeFoundationTestCase {
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
    func testAgentLoopBlocksExplicitReviewToolsWithoutRunningSideEffects() async throws {
        let runtime = RealBrowserToolThenFinalRuntime()
        let loop = AgentLoop(
            config: .init(
                maxIterations: 3,
                maxTokensPerTurn: 1024,
                workspaceRoot: "/tmp",
                allowedTools: ["browser.real"],
                usePipeline: false
            ),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "打开真实浏览器",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: "/tmp")
        )

        XCTAssertEqual(task.status, .failed)
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "browser.real" })
        XCTAssertTrue(task.steps.contains { step in
            step.kind == .toolResult
                && step.toolName == "browser.real"
                && step.isFailure
                && step.text.contains("approval_required")
        })
        XCTAssertTrue(runtime.requests.contains { request in
            request.messages.contains { $0.role == "tool" && ($0.content ?? "").contains("approval_required") }
        })
    }
    func testDiffApplyUsesFileChangeToolSemantics() {
        let names = AgentLoop.toolDefinitions(for: .task, phase: .execute).map {
            ToolNameCodec.canonicalName($0.function.name)
        }

        XCTAssertTrue(AgentLoop.isFileChangeTool("diff.apply"))
        XCTAssertTrue(AgentLoop.isFileChangeTool("diff_apply"))
        XCTAssertTrue(names.contains("diff.apply"))
    }
    func testToolExecutionPoliciesSeparateReviewFromExplicitApproval() {
        XCTAssertEqual(WriteFileTool().executionPolicy, .fileChangeReview)
        XCTAssertEqual(FileEditTool().executionPolicy, .fileChangeReview)
        XCTAssertEqual(DiffApplyTool().executionPolicy, .fileChangeReview)
        XCTAssertEqual(RealBrowserTool().executionPolicy, .explicitUserApproval)

        XCTAssertFalse(AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: "diff.apply", tool: DiffApplyTool()))
        XCTAssertTrue(AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: "browser.real", tool: RealBrowserTool()))
    }
    func testShellToolDefinitionSteersProjectReadingToStructuredTools() {
        let shellDefinition = ToolRegistry.shared.toolDefinitions.first { $0.function.name == "shell_exec" }
        let commandDescription = shellDefinition?.function.parameters.properties["command"]?.description ?? ""

        XCTAssertTrue(commandDescription.contains("workspace_index"))
        XCTAssertTrue(commandDescription.contains("code_search"))
        XCTAssertTrue(commandDescription.contains("file_read"))
        XCTAssertTrue(commandDescription.contains("不要用"))
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
}
