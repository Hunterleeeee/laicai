import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AgentLoopWikiSkillTests: LaicaiNativeFoundationTestCase {
    func testAgentLoopFallbackSavesWikiTaskFromExtractedMaterial() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "迁移计划".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let runtime = EmptyThenFinalRuntime()
        let loop = AgentLoop(
            config: .init(maxIterations: 4, maxTokensPerTurn: 1024, workspaceRoot: workspace.path),
            runtime: runtime
        )

        let task = try await loop.run(
            message: "整理到 wiki\n请读取这个附件：\(workspace.appendingPathComponent("notes.txt").path)",
            intent: .task,
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://example.com/v1", modelName: "test", note: "", health: .ready),
            context: TaskContext(workspaceRoot: workspace.path, vaultRoot: workspace.path)
        )

        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.steps.contains { $0.kind == .toolCall && $0.toolName == "wiki.build" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("02 Atomic/notes.md").path))
    }
    func testAgentLoopDoesNotCompleteWikiTaskWithoutSavedWikiInReadOnlyMode() {
        let task = AgentTask(
            title: "整理到 wiki",
            steps: [
                TaskStep(kind: .userInput, text: "整理到 wiki\n请读取这个附件：/tmp/a.xlsx"),
                TaskStep(kind: .toolCall, text: "读取", toolName: "file.extract", toolParams: ["path": "/tmp/a.xlsx"]),
                TaskStep(kind: .toolResult, text: "已提取 /tmp/a.xlsx", toolName: "file.extract", toolParams: ["path": "/tmp/a.xlsx"]),
                TaskStep(kind: .textOutput, text: "我会整理成 Wiki。")
            ]
        )

        XCTAssertFalse(AgentLoop.meetsCompletionCriteria(task: task, intent: .task, didComplete: true, hadFailure: false, wasTruncated: false, isReadOnlyRun: true))
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
}
