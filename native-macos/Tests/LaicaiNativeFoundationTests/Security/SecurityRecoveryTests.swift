import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class SecurityRecoveryTests: LaicaiNativeFoundationTestCase {
    func testDisposableSmokeWorkspacesAreNotValidWorkspaceRoots() {
        XCTAssertTrue(WorkspaceSandbox.isDisposableSmokeWorkspace("/tmp/laicai-pptx-smoke"))
        XCTAssertTrue(WorkspaceSandbox.isDisposableSmokeWorkspace("/private/tmp/laicai-render-smoke"))
        XCTAssertFalse(WorkspaceSandbox.isDisposableSmokeWorkspace("/tmp/laicai-real-project"))
        XCTAssertFalse(WorkspaceSandbox.isDisposableSmokeWorkspace("/Users/test/Projects/laicai-smoke-app"))
    }

    func testTemporaryVarFoldersAreRejectedAsDisposableSmokeWorkspaces() {
        XCTAssertTrue(WorkspaceSandbox.isDisposableSmokeWorkspace("/var/folders/aa/bb/T/laicai-smoke"))
        XCTAssertTrue(WorkspaceSandbox.isDisposableSmokeWorkspace("/private/var/folders/aa/bb/T/laicai-smoke"))
        XCTAssertFalse(WorkspaceSandbox.isDisposableSmokeWorkspace("/var/folders/aa/bb/T/real-project"))
        XCTAssertFalse(WorkspaceSandbox.isDisposableSmokeWorkspace("/Users/test/Projects/laicai"))
    }
    func testDefaultSandboxKeepsNativeExecutionUntilUserOptsIn() {
        XCTAssertEqual(SandboxConfig.default.mode, .none)
        XCTAssertFalse(SandboxConfig.default.networkEnabled)
        XCTAssertTrue(SandboxConfig.default.mountWorkspace)
    }
    func testShellAllowlistAllowsPwdAndRejectsSudoAndProjectTraversal() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let previousSandboxConfig = SecurityManager.shared.sandboxConfig
        SecurityManager.shared.sandboxConfig = SandboxConfig(mode: .none)
        defer { SecurityManager.shared.sandboxConfig = previousSandboxConfig }

        let pwd = try await ShellTool().execute(argumentsJSON: #"{"command":"pwd"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let sudo = try await ShellTool().execute(
            argumentsJSON: #"{"command":"sudo ls"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let findFiles = try await ShellTool().execute(
            argumentsJSON: #"{"command":"find . -type f"}"#, context: TaskContext(workspaceRoot: workspace.path))
        let recursiveList = try await ShellTool().execute(
            argumentsJSON: #"{"command":"ls -R ."}"#, context: TaskContext(workspaceRoot: workspace.path))

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
    func testShellAllowlistValidatesEveryCommandAndRejectsEvaluationOrWrites() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = TaskContext(workspaceRoot: workspace.path)

        let allowedPipeline = try await ShellTool().execute(
            argumentsJSON: #"{"command":"echo ok | head -1"}"#,
            context: context
        )
        let chainedUnknown = try await ShellTool().execute(
            argumentsJSON: #"{"command":"echo ok; osascript -e 'return 1'"}"#,
            context: context
        )
        let inlineEvaluation = try await ShellTool().execute(
            argumentsJSON: #"{"command":"python3 -c 'print(1)'"}"#,
            context: context
        )
        let redirectedWrite = try await ShellTool().execute(
            argumentsJSON: #"{"command":"echo hacked > sentinel.txt"}"#,
            context: context
        )

        XCTAssertTrue(allowedPipeline.success)
        XCTAssertEqual(allowedPipeline.output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        for result in [chainedUnknown, inlineEvaluation, redirectedWrite] {
            XCTAssertFalse(result.success)
            XCTAssertEqual(result.error, "security_denied")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("sentinel.txt").path))
    }
    func testShellAllowlistAcceptsQuotedSeparatorsAndValidatedEnvWrapper() {
        let policy = SandboxPolicy()

        XCTAssertTrue(policy.isCommandAllowed("echo 'a;b'"))
        XCTAssertTrue(policy.isCommandAllowed("/usr/bin/env python3 --version"))
        XCTAssertTrue(policy.isCommandAllowed("echo ok && pwd"))
        XCTAssertTrue(policy.isCommandAllowed("echo '$(literal)'"))
        XCTAssertFalse(policy.isCommandAllowed("/usr/bin/env osascript -e test"))
        XCTAssertFalse(policy.isCommandAllowed("echo $(osascript -e test)"))
        XCTAssertFalse(policy.isCommandAllowed(#"echo "$(osascript -e test)""#))
        XCTAssertFalse(policy.isCommandAllowed(#"echo "`osascript -e test`""#))
    }
    func testFileEditCircuitBreakerNeverBuildsAnAutomaticWrite() async {
        let step = TaskStep(
            kind: .toolCall,
            text: "edit",
            toolName: "file.edit",
            toolParams: ["path": "Sources/App.swift", "edits": #"[{"oldText":"a","newText":"b"}]"#]
        )

        let result = await AgentLoop.attemptCircuitBreakerRepair(
            toolName: "file.edit",
            callStep: step,
            taskContext: TaskContext(workspaceRoot: NSTemporaryDirectory()),
            toolRegistry: ToolRegistry.shared
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "file_edit_circuit_broken")
        XCTAssertNil(result.data?["diffNew"])
    }
    func testWritePatchRejectsEmptyOrUnlocatableOldContent() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("sample.txt")
        try "alpha beta gamma\nkeep me\n".write(to: target, atomically: true, encoding: .utf8)
        let context = TaskContext(workspaceRoot: workspace.path)

        func arguments(oldContent: String, newContent: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "path": "sample.txt",
                "oldContent": oldContent,
                "newContent": newContent,
            ])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }

        let emptyOld = try await WriteFileTool().execute(
            argumentsJSON: try arguments(oldContent: "", newContent: "replacement"),
            context: context
        )
        let differentLineLayout = try await WriteFileTool().execute(
            argumentsJSON: try arguments(oldContent: "alpha\nbeta\ngamma", newContent: "replacement"),
            context: context
        )

        XCTAssertFalse(emptyOld.success)
        XCTAssertEqual(emptyOld.error, "patch_empty_old_content")
        XCTAssertFalse(differentLineLayout.success)
        XCTAssertEqual(differentLineLayout.error, "patch_not_found")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "alpha beta gamma\nkeep me\n")
    }
    func testShellPolicyRecoveryFallsBackToWorkspaceIndex() {
        let plan = ErrorRecoveryEngine.planRecovery(
            error: "工具策略拦截：不要用 shell 遍历项目结构。",
            toolName: "shell.exec",
            params: ["command": "find . -type f"],
            attemptCount: 0
        )

        guard case .fallbackTool(let toolName, let argumentsJSON) = plan.action else {
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

        guard case .fallbackTool(let toolName, _) = plan.action else {
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

        guard case .fallbackTool(let toolName, let argumentsJSON) = plan.action else {
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
        XCTAssertTrue(
            AgentLoop.checkpointPaths(toolName: "shell.exec", arguments: ["command": "touch x"], workspaceRoot: workspace.path).isEmpty)
    }
    func testGitStatusLinePathParsingHandlesRenamesAndUntrackedFiles() {
        XCTAssertEqual(GitTool.pathFromStatusLine(" M native-macos/build.sh"), "native-macos/build.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("?? scripts/check-project-hygiene.sh"), "scripts/check-project-hygiene.sh")
        XCTAssertEqual(GitTool.pathFromStatusLine("R  old.swift -> new.swift"), "new.swift")
        XCTAssertNil(GitTool.pathFromStatusLine("  "))
    }
}
