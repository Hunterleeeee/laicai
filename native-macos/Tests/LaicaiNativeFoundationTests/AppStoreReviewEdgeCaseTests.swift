import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreReviewEdgeCaseTests: LaicaiNativeFoundationTestCase {
    func testApproveReviewRejectsMissingDiffContent() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("MissingDiff.md")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "缺少 diffNewContent",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "MissingDiff.md",
            diffOldContent: ""
        )
        let task = AgentTask(title: "缺少内容", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, false)
        XCTAssertTrue(store.state.selectedTask?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("缺少文件变更内容")
        } == true)
    }

    func testRejectingAllHunksDoesNotWriteFile() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("RejectAllHunks.md")
        let oldContent = "alpha\nbeta\n"
        try oldContent.write(to: target, atomically: true, encoding: .utf8)
        let firstHunk = DiffHunk(index: 0, oldText: "alpha\n", newText: "ALPHA\n", summary: "第一行")
        let secondHunk = DiffHunk(index: 1, oldText: "beta\n", newText: "BETA\n", summary: "第二行")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "全部 hunk 拒绝",
            toolName: "file.edit",
            toolParams: ["fullPath": target.path],
            diffFilePath: "RejectAllHunks.md",
            diffOldContent: oldContent,
            diffNewContent: "ALPHA\nBETA\n",
            diffHunks: [firstHunk, secondHunk]
        )
        let task = AgentTask(title: "拒绝 hunks", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))

        store.rejectHunk(taskID: task.id, stepID: step.id, hunkID: firstHunk.id)
        store.rejectHunk(taskID: task.id, stepID: step.id, hunkID: secondHunk.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), oldContent)
        XCTAssertEqual(store.state.selectedTask?.steps.first?.approved, false)
        XCTAssertTrue(store.state.selectedTask?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("所有 hunk 均已拒绝")
        } == true)
    }

    func testApproveAllPendingReviewsCancelsWhenAnyFileChangedExternally() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = workspace.appendingPathComponent("BatchSafe.md")
        let second = workspace.appendingPathComponent("BatchChanged.md")
        try "first old".write(to: first, atomically: true, encoding: .utf8)
        try "second old".write(to: second, atomically: true, encoding: .utf8)
        let firstStep = TaskStep(
            kind: .reviewRequest,
            text: "第一个批量写入",
            toolName: "file.write",
            toolParams: ["fullPath": first.path],
            diffFilePath: "BatchSafe.md",
            diffOldContent: "first old",
            diffNewContent: "first new"
        )
        let secondStep = TaskStep(
            kind: .reviewRequest,
            text: "第二个批量写入",
            toolName: "file.write",
            toolParams: ["fullPath": second.path],
            diffFilePath: "BatchChanged.md",
            diffOldContent: "second old",
            diffNewContent: "second new"
        )
        let task = AgentTask(
            title: "批量外部修改",
            steps: [firstStep, secondStep],
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let store = AppStore(state: testState(tasks: [task], selectedTaskID: task.id, workspacePath: workspace.path))
        try "external second".write(to: second, atomically: true, encoding: .utf8)

        store.approveAllPendingReviews(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first old")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "external second")
        let reviewSteps = store.state.selectedTask?.steps.filter { $0.kind == .reviewRequest } ?? []
        XCTAssertEqual(reviewSteps.map(\.approved), [nil, false])
        XCTAssertTrue(store.state.selectedTask?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("批量写入取消")
        } == true)
        XCTAssertFalse(AuditLog.shared.recentEntries.contains { $0.tool == "batch.apply" && $0.success })
    }
}
