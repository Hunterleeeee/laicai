import XCTest

@testable import LaicaiNativeFoundation

final class ProcessRunnerTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrWithoutDeadlock() throws {
        let script = "import sys; sys.stdout.write('o' * 200000); sys.stderr.write('e' * 200000)"
        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testTimeoutTerminatesProcess() throws {
        let startedAt = Date()
        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testWritesStandardInputAndCapturesOutput() throws {
        let input = Data("hello runner".utf8)
        let result = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            standardInput: input,
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, input)
    }

    func testAsyncRunnerDoesNotAddExitLatency() async throws {
        let startedAt = Date()
        let result = try await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }
}
