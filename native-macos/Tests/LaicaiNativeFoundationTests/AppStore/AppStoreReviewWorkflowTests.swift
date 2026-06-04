import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class AppStoreReviewWorkflowTests: LaicaiNativeFoundationTestCase {
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
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "approved")
        XCTAssertEqual(store.state.selectedThread?.steps.first?.approved, true)
        XCTAssertTrue(store.state.selectedThread?.steps.contains(where: { $0.kind == .reviewResult && $0.approved == true }) == true)
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
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.rejectReview(taskID: task.id, stepID: step.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(store.state.selectedThread?.steps.first?.approved, false)
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
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.approveReview(taskID: task.id, stepID: step.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")

        store.rollbackLastApprovedWrite(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.kind == .reviewResult && $0.text.contains("已回滚") } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.rollback" && $0.success })
    }
    func testApproveAllPendingReviewsWritesEveryFileAndRecordsBatchAudit() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = workspace.appendingPathComponent("BatchFirst.md")
        let second = workspace.appendingPathComponent("BatchSecond.md")
        try "first old".write(to: first, atomically: true, encoding: .utf8)
        try "second old".write(to: second, atomically: true, encoding: .utf8)
        let firstStep = TaskStep(
            kind: .reviewRequest,
            text: "准备批量写入第一个文件",
            toolName: "file.write",
            toolParams: ["fullPath": first.path],
            diffFilePath: "BatchFirst.md",
            diffOldContent: "first old",
            diffNewContent: "first new"
        )
        let secondStep = TaskStep(
            kind: .reviewRequest,
            text: "准备批量写入第二个文件",
            toolName: "file.write",
            toolParams: ["fullPath": second.path],
            diffFilePath: "BatchSecond.md",
            diffOldContent: "second old",
            diffNewContent: "second new"
        )
        let task = AgentTask(
            title: "批量写入",
            steps: [firstStep, secondStep],
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.approveAllPendingReviews(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first new")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second new")
        let reviewSteps = store.state.selectedThread?.steps.filter { $0.kind == .reviewRequest } ?? []
        XCTAssertEqual(reviewSteps.count, 2)
        XCTAssertTrue(reviewSteps.allSatisfy { $0.approved == true })
        XCTAssertTrue(store.state.selectedThread?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("批量写入成功：2 个文件")
        } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "batch.apply" && $0.success })
    }
    func testRollbackBatchRestoresFilesAndReopensReviews() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = workspace.appendingPathComponent("RollbackBatchFirst.md")
        let second = workspace.appendingPathComponent("RollbackBatchSecond.md")
        try "first old".write(to: first, atomically: true, encoding: .utf8)
        try "second old".write(to: second, atomically: true, encoding: .utf8)
        let firstStep = TaskStep(
            kind: .reviewRequest,
            text: "准备批量写入第一个文件",
            toolName: "file.write",
            toolParams: ["fullPath": first.path],
            diffFilePath: "RollbackBatchFirst.md",
            diffOldContent: "first old",
            diffNewContent: "first new"
        )
        let secondStep = TaskStep(
            kind: .reviewRequest,
            text: "准备批量写入第二个文件",
            toolName: "file.write",
            toolParams: ["fullPath": second.path],
            diffFilePath: "RollbackBatchSecond.md",
            diffOldContent: "second old",
            diffNewContent: "second new"
        )
        let task = AgentTask(
            title: "批量回滚",
            steps: [firstStep, secondStep],
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.approveAllPendingReviews(taskID: task.id)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first new")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second new")

        store.rollbackBatch(taskID: task.id)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first old")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second old")
        let reviewSteps = store.state.selectedThread?.steps.filter { $0.kind == .reviewRequest } ?? []
        XCTAssertEqual(reviewSteps.count, 2)
        XCTAssertTrue(reviewSteps.allSatisfy { $0.approved == nil })
        XCTAssertTrue(store.state.selectedThread?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("批量回滚完成：2/2 个文件已恢复")
        } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "batch.rollback" && $0.success })
    }
    func testApproveReviewRejectsWhenFileChangedExternally() throws {
        AuditLog.shared.clear()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("ExternalChange.md")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备写入文件",
            toolName: "file.write",
            toolParams: ["fullPath": target.path],
            diffFilePath: "ExternalChange.md",
            diffOldContent: "old",
            diffNewContent: "new"
        )
        let task = AgentTask(title: "外部修改拦截", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))
        try "external".write(to: target, atomically: true, encoding: .utf8)

        store.approveReview(taskID: task.id, stepID: step.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external")
        XCTAssertEqual(store.state.selectedThread?.steps.first?.approved, false)
        XCTAssertTrue(store.state.selectedThread?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("文件在审查期间被外部修改")
        } == true)
        XCTAssertTrue(AuditLog.shared.recentEntries.contains { $0.tool == "file.write" && !$0.success })
    }
    func testHunkApprovalWritesOnlyAcceptedHunks() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("Hunka.md")
        let oldContent = "alpha\nbeta\ngamma\n"
        try oldContent.write(to: target, atomically: true, encoding: .utf8)
        let firstHunk = DiffHunk(index: 0, oldText: "alpha\n", newText: "ALPHA\n", summary: "更新第一行")
        let secondHunk = DiffHunk(index: 1, oldText: "beta\n", newText: "BETA\n", summary: "更新第二行")
        let step = TaskStep(
            kind: .reviewRequest,
            text: "准备按 hunk 写入",
            toolName: "file.edit",
            toolParams: ["fullPath": target.path],
            diffFilePath: "Hunka.md",
            diffOldContent: oldContent,
            diffNewContent: "ALPHA\nBETA\ngamma\n",
            diffHunks: [firstHunk, secondHunk]
        )
        let task = AgentTask(title: "Hunk 审查", steps: [step], context: TaskContext(workspaceRoot: workspace.path))
        let store = AppStore(state: testState(tasks: [task], selectedThreadID: task.id, workspacePath: workspace.path))

        store.approveHunk(taskID: task.id, stepID: step.id, hunkID: firstHunk.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), oldContent)

        store.rejectHunk(taskID: task.id, stepID: step.id, hunkID: secondHunk.id)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "ALPHA\nbeta\ngamma\n")
        XCTAssertEqual(store.state.selectedThread?.steps.first?.approved, true)
        XCTAssertEqual(store.state.selectedThread?.steps.first?.diffHunks?.map { $0.approved == true }, [true, false])
        XCTAssertTrue(store.state.selectedThread?.steps.contains {
            $0.kind == .reviewResult && $0.text.contains("接受 1 / 拒绝 1 个 hunk")
        } == true)
    }
}
