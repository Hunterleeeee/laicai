import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class TaskOutcomeRecorderTests: LaicaiNativeFoundationTestCase {
    func testEmptyOutcomeRecorderReturnsSafeDefaults() throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = TaskOutcomeRecorder(path: base.path)

        XCTAssertTrue(recorder.stats(days: 1).isEmpty)
        XCTAssertTrue(recorder.promptTagStats(days: 1).isEmpty)
        XCTAssertTrue(recorder.toolStats(days: 1).isEmpty)
        XCTAssertNil(recorder.avgIterations(intent: "task", days: 1))
        XCTAssertTrue(recorder.recentFailures(intent: "task").isEmpty)
    }

    func testOutcomeRecorderSerializesConcurrentReadsAndWrites() async throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = TaskOutcomeRecorder(path: base.path)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                group.addTask {
                    let id = "task-\(index)"
                    recorder.record(
                        taskID: id,
                        intent: "task",
                        routeLabel: "会话 执行",
                        executionMode: "auto",
                        iterations: index % 5 + 1,
                        status: index.isMultiple(of: 7) ? .failed : .completed,
                        hadFailure: index.isMultiple(of: 7),
                        wasCancelled: false,
                        wasTruncated: false,
                        toolCalls: 1,
                        toolFailures: index.isMultiple(of: 7) ? 1 : 0,
                        durationSeconds: 0.1,
                        userFollowupCount: 0,
                        promptTag: "baseline",
                        modelName: "test-model"
                    )
                    recorder.recordToolOutcome(
                        taskID: id,
                        toolName: "file.read",
                        modelName: "test-model",
                        success: !index.isMultiple(of: 7),
                        durationSeconds: 0.01
                    )
                    _ = recorder.stats(days: 1)
                    _ = recorder.toolStats(days: 1)
                    _ = recorder.avgIterations(intent: "task", days: 1)
                    _ = recorder.recentFailures(intent: "task")
                }
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let stats = recorder.stats(days: 1)
        let row = try XCTUnwrap(stats.first { $0.intent == "task" && $0.routeLabel == "会话 执行" })
        XCTAssertEqual(row.total, 80)
        XCTAssertGreaterThan(row.completed, 0)
        XCTAssertNotNil(recorder.avgIterations(intent: "task", days: 1))
        XCTAssertEqual(recorder.toolStats(days: 1).first?.total, 80)
        XCTAssertFalse(recorder.recentFailures(intent: "task").isEmpty)
    }

    func testStatsSplitByExecutionModeForSameIntentAndRoute() async throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = TaskOutcomeRecorder(path: base.path)

        recorder.record(
            taskID: "legacy-1",
            intent: "task",
            routeLabel: "会话 执行",
            executionMode: "pipeline",
            iterations: 4,
            status: .completed,
            hadFailure: false,
            wasCancelled: false,
            wasTruncated: false,
            toolCalls: 3,
            toolFailures: 0,
            durationSeconds: 1.2,
            userFollowupCount: 0,
            modelName: "test-model"
        )
        recorder.record(
            taskID: "codex-1",
            intent: "task",
            routeLabel: "会话 执行",
            executionMode: "codexFull",
            iterations: 6,
            status: .failed,
            hadFailure: true,
            wasCancelled: false,
            wasTruncated: false,
            toolCalls: 4,
            toolFailures: 1,
            durationSeconds: 2.3,
            userFollowupCount: 1,
            modelName: "test-model"
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        let rows = recorder.stats(days: 1).filter { $0.intent == "task" && $0.routeLabel == "会话 执行" }

        let pipeline = try XCTUnwrap(rows.first { $0.executionMode == "pipeline" })
        XCTAssertEqual(pipeline.total, 1)
        XCTAssertEqual(pipeline.completed, 1)

        let codex = try XCTUnwrap(rows.first { $0.executionMode == "codexFull" })
        XCTAssertEqual(codex.total, 1)
        XCTAssertEqual(codex.completed, 0)
    }
}
