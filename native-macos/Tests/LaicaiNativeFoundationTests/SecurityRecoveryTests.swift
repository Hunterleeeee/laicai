import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class SecurityRecoveryTests: LaicaiNativeFoundationTestCase {
    func testShellWhitelistAllowsPwdAndRejectsSudoAndProjectTraversal() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let pwd = try await ShellTool().execute(argumentsJSON: #"{"command":"pwd"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let sudo = try await ShellTool().execute(argumentsJSON: #"{"command":"sudo ls"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let findFiles = try await ShellTool().execute(argumentsJSON: #"{"command":"find . -type f"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let recursiveList = try await ShellTool().execute(argumentsJSON: #"{"command":"ls -R ."}"#, context: TaskContext(workspaceRoot: workspace.path))

        XCTAssertTrue(pwd.success)
        XCTAssertTrue(pwd.output.contains(workspace.path))
        XCTAssertFalse(sudo.success)
        XCTAssertEqual(sudo.error, "security_denied")
        XCTAssertFalse(findFiles.success)
        XCTAssertEqual(findFiles.error, "security_denied")
        XCTAssertTrue(findFiles.output.contains("workspace.index"))
        XCTAssertFalse(recursiveList.success)
        XCTAssertEqual(recursiveList.error, "security_denied")
    }
    func testShellPolicyRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "工具策略拦截：不要用 shell 遍历项目结构。",
            toolName: "shell.exec",
            params: ["command": "find . -type f"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, argumentsJSON) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
        XCTAssertTrue(argumentsJSON.contains("maxFiles"))
    }
    func testCodeSearchRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "搜索失败",
            toolName: "code.search",
            params: ["query": "AppStore"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, _) = plan.action else {
            XCTFail("Expected fallback tool recovery")
            return
        }

        XCTAssertEqual(toolName, "workspace.index")
    }
    func testUnsupportedBinaryReadRecoveryFallsBackToFileExtract() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "unsupported_binary_file：这是 XLSX 文档/表格，请改用 file_extract",
            toolName: "file.read",
            params: ["path": "/tmp/需求.xlsx"],
            attemptCount: 0
        )

        guard case let .fallbackTool(toolName, argumentsJSON) = plan.action else {
            XCTFail("Expected file.extract fallback")
            return
        }

        XCTAssertEqual(toolName, "file.extract")
        XCTAssertTrue(argumentsJSON.contains("/tmp/需求.xlsx"))
        XCTAssertTrue(argumentsJSON.contains("60000"))
    }
    func testSensitivePathsAreBlocked() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "SECRET=1".write(to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".env"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )
        let write = try await WriteFileTool().execute(
            argumentsJSON: #"{"path":".ssh/id_rsa","content":"secret"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "security_denied")
        XCTAssertFalse(write.success)
        XCTAssertEqual(write.error, "security_denied")
    }
    func testCheckpointPathsOnlyIncludeWorkspaceRelativeWriteTargets() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceDir = workspace.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let inside = sourceDir.appendingPathComponent("App.swift")
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("outside.txt")

        let paths = AgentLoop.normalizedCheckpointPaths(
            ["Sources/App.swift", inside.path, outside.path, ""],
            workspaceRoot: workspace.path
        )

        XCTAssertEqual(paths, ["Sources/App.swift"])
        XCTAssertEqual(
            AgentLoop.checkpointPaths(toolName: "file.write", arguments: ["path": "Sources/App.swift"], workspaceRoot: workspace.path),
            ["Sources/App.swift"]
        )
        XCTAssertTrue(AgentLoop.checkpointPaths(toolName: "shell.exec", arguments: ["command": "touch x"], workspaceRoot: workspace.path).isEmpty)
    }
    func testGitStatusLinePathParsingHandlesRenamesAndUntrackedFiles() {
        XCTAssertEqual(GitTool.pathFromStatusLine(" M native-macos/build.sh"), "native-macos/build.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("?? scripts/check_project_hygiene.sh"), "scripts/check_project_hygiene.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("R  old.swift -> new.swift"), "new.swift")
        XCTAssertNil(GitTool.pathFromStatusLine("  "))
    }
}
