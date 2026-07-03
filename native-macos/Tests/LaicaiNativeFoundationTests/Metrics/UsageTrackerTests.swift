import XCTest
@testable import LaicaiNativeFoundation

#if canImport(SQLite3)
import SQLite3
#endif

@MainActor
final class UsageTrackerTests: LaicaiNativeFoundationTestCase {
    func testEmptyThreadUsageDoesNotTouchDatabase() throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let tracker = UsageTracker(path: base.path)

        let usage = tracker.threadUsage(threadID: "")

        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.requestCount, 0)
        XCTAssertEqual(usage.estimatedCost, 0)
    }

    func testUsageTrackerSerializesConcurrentThreadUsageReadsAndWrites() async throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let tracker = UsageTracker(path: base.path)
        let threadID = UUID().uuidString

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                group.addTask {
                    tracker.record(
                        modelName: "test-model",
                        threadID: threadID,
                        inputTokens: index,
                        outputTokens: index + 1,
                        durationSeconds: 0.1
                    )
                    _ = tracker.threadUsage(threadID: threadID)
                    _ = tracker.dailyUsage(days: 1)
                }
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let usage = tracker.threadUsage(threadID: threadID)
        XCTAssertEqual(usage.requestCount, 80)
    }

    func testThreadUsageCacheInvalidatesWhenRecordingSameThread() async throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let tracker = UsageTracker(path: base.path)
        let threadID = UUID().uuidString

        tracker.record(
            modelName: "test-model",
            threadID: threadID,
            inputTokens: 10,
            outputTokens: 5,
            durationSeconds: 0.1
        )
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(tracker.threadUsage(threadID: threadID).requestCount, 1)

        tracker.record(
            modelName: "test-model",
            threadID: threadID,
            inputTokens: 7,
            outputTokens: 3,
            durationSeconds: 0.1
        )
        try await Task.sleep(nanoseconds: 250_000_000)

        let usage = tracker.threadUsage(threadID: threadID)
        XCTAssertEqual(usage.requestCount, 2)
        XCTAssertEqual(usage.inputTokens, 17)
        XCTAssertEqual(usage.outputTokens, 8)
    }

    func testUsageTrackerCreatesThreadIndex() throws {
        let base = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = UsageTracker(path: base.path)

        let dbPath = base.appendingPathComponent("Laicai/usage.sqlite3").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_usage_thread';",
            -1,
            &stmt,
            nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
    }
}
