import LaicaiNativeDomain
import XCTest

@testable import LaicaiNativeFoundation

final class HeadlessRunnerTests: XCTestCase {
    func testFailedHeadlessResultReturnsFailureExitCode() {
        let thread = LaicaiThread(
            status: .failed,
            steps: [
                TaskStep(kind: .textOutput, text: "partial"),
                TaskStep(kind: .error, text: "request failed", isFailure: true),
            ]
        )

        let result = HeadlessRunner.result(for: thread)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output, "partial")
        XCTAssertEqual(result.errors, ["request failed"])
        XCTAssertEqual(HeadlessRunner.exitCode(for: result), 1)
    }

    func testCompletedHeadlessResultReturnsZero() {
        let thread = LaicaiThread(
            status: .completed,
            steps: [TaskStep(kind: .textOutput, text: "done")]
        )

        let result = HeadlessRunner.result(for: thread)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(HeadlessRunner.exitCode(for: result), 0)
    }
}
