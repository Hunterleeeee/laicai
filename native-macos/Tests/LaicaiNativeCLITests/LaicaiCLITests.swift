import Foundation
import LaicaiNativeDomain
import LaicaiNativeFoundation
import XCTest

@testable import LaicaiNativeCLI

final class LaicaiCLITests: XCTestCase {
    func testParserRejectsUnknownOptionAndMissingValue() {
        XCTAssertThrowsError(try CLIConfig.parse(["laicai", "--wat"], readStdin: false)) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownOption("--wat"))
        }
        XCTAssertThrowsError(try CLIConfig.parse(["laicai", "--model"], readStdin: false)) { error in
            XCTAssertEqual(error as? CLIParseError, .missingValue("--model"))
        }
    }

    func testParserKeepsMultiwordMessageAndRecognizesSubcommands() throws {
        let config = try CLIConfig.parse(
            ["laicai", "please", "fix", "this", "project"],
            readStdin: false
        )
        XCTAssertEqual(config.message, "please fix this project")

        for command in [CLICommand.doctor, .health, .skills] {
            let parsed = try CLIConfig.parse(["laicai", command.rawValue], readStdin: false)
            XCTAssertEqual(parsed.command, command)
            XCTAssertNil(parsed.message)
        }
    }

    func testParserTreatsArgumentsAfterDoubleDashAsMessage() throws {
        let config = try CLIConfig.parse(
            ["laicai", "--", "--not-a-flag", "two words"],
            readStdin: false
        )
        XCTAssertEqual(config.message, "--not-a-flag two words")
    }

    func testConnectorResolutionReusesActiveAppConnector() throws {
        let active = ConnectorProfile(
            name: "App connector",
            kind: "openai-compatible",
            endpoint: "https://example.test/v1",
            modelName: "example-model",
            note: "secret",
            health: .ready
        )
        let other = ConnectorProfile(
            name: "Other",
            kind: "ollama",
            endpoint: "http://localhost:11434",
            modelName: "local",
            note: "",
            health: .ready
        )

        let connector = try resolveConnector(
            config: CLIConfig(),
            environment: [:],
            repository: { ConnectorCatalog(connectors: [other, active], activeConnectorID: active.id) }
        )
        XCTAssertEqual(connector, active)
    }

    func testExplicitOpenAIConfigUsesOpenAIDefaults() throws {
        let connector = try resolveConnector(
            config: CLIConfig(),
            environment: ["OPENAI_API_KEY": "test-key"],
            repository: {
                XCTFail("Explicit configuration should not read the App database")
                return nil
            }
        )
        XCTAssertEqual(connector.modelName, "gpt-4.1-mini")
        XCTAssertEqual(connector.kind, "openai-compatible")
        XCTAssertEqual(connector.note, "test-key")
    }

    @MainActor
    func testReviewApplierWritesResolvedFullPathAndRejectsStaleContent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("laicai-cli-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("actual.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)

        let review = TaskStep(
            kind: .reviewRequest,
            text: "review",
            toolParams: ["fullPath": target.path],
            diffFilePath: "display-name.txt",
            diffOldContent: "old",
            diffNewContent: "new"
        )
        XCTAssertEqual(
            try CLIReviewApplier.apply(step: review, workspace: workspace.path),
            target.path
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")

        XCTAssertThrowsError(try CLIReviewApplier.apply(step: review, workspace: workspace.path)) { error in
            guard case CLIReviewError.changedSinceReview = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRunReturnsUsageAndFailureExitCodes() async {
        let unknown = await LaicaiCLI.run(
            arguments: ["laicai", "--unknown"],
            readStdin: false,
            environment: [:],
            stdinIsTTY: false
        )
        XCTAssertEqual(unknown, 64)

        let requestFailure = await LaicaiCLI.run(
            arguments: [
                "laicai", "--endpoint", "http://localhost:11434", "--model", "test", "hello",
            ],
            readStdin: false,
            environment: [:],
            stdinIsTTY: false,
            taskExecutor: { _, _, _, _, _ in false }
        )
        XCTAssertEqual(requestFailure, 1)
    }
}
