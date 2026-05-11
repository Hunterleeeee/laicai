import XCTest
@testable import LaicaiNativeFoundation

@MainActor
final class UsageTrackerTests: LaicaiNativeFoundationTestCase {
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

        try await Task.sleep(nanoseconds: 200_000_000)
        let usage = tracker.threadUsage(threadID: threadID)
        XCTAssertEqual(usage.requestCount, 80)
    }
}
