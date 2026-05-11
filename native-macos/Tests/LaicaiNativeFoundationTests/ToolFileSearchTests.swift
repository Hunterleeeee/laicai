import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class ToolFileSearchTests: LaicaiNativeFoundationTestCase {
    func testSearchToolFindsExistingFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("README.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertEqual(result.data?["count"], "1")
    }
    func testSearchToolReturnsClearEmptyResult() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await SearchTool().execute(
            argumentsJSON: #"{"query":"MissingFile","scope":"files","maxResults":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("未找到匹配文件"))
    }
    func testReadFileToolReadsSmallFileWithinWorkspace() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "one\ntwo\nthree".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"notes.txt","offset":2,"limit":1}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "two")
        XCTAssertEqual(result.data?["path"], "notes.txt")
    }
    func testReadFileToolListsDirectory() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "hello".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let value = 1".write(to: workspace.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":".","limit":10}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("Sources/"))
        XCTAssertTrue(result.output.contains("Sources/App/main.swift"))
        XCTAssertEqual(result.data?["type"], "directory")
        XCTAssertEqual(result.data?["recursive"], "true")
    }
    func testReadFileToolRejectsXLSXWithExtractHint() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let xlsx = workspace.appendingPathComponent("需求.xlsx")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: xlsx)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"需求.xlsx"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "unsupported_binary_file")
        XCTAssertEqual(result.data?["recommendedTool"], "file.extract")
        XCTAssertTrue(result.output.contains("file_extract"))
    }
    func testExtractFileToolExtractsXLSXCells() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let xlsx = workspace.appendingPathComponent("需求.xlsx")
        try makeMinimalXLSX(at: xlsx)

        let result = try await ExtractFileTool().execute(
            argumentsJSON: #"{"path":"需求.xlsx"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success, result.output)
        XCTAssertEqual(result.data?["extension"], "xlsx")
        XCTAssertTrue(result.output.contains("会员系统"))
        XCTAssertTrue(result.output.contains("替换需求"))
    }
    func testReadFileToolTruncatesLargeFile() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let largeText = String(repeating: "0123456789\n", count: 6000)
        try largeText.write(to: workspace.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"large.txt"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertLessThan(result.output.count, largeText.count)
        XCTAssertTrue(result.output.contains("已截断"))
    }
    func testToolsRequireWorkspaceForRelativeOperations() async throws {
        let read = try await ReadFileTool().execute(
            argumentsJSON: #"{"path":"README.md"}"#,
            context: TaskContext(workspaceRoot: "")
        )
        let search = try await SearchTool().execute(
            argumentsJSON: #"{"query":"README","scope":"files"}"#,
            context: TaskContext(workspaceRoot: "")
        )

        XCTAssertFalse(read.success)
        XCTAssertEqual(read.error, "workspace_missing")
        XCTAssertFalse(search.success)
        XCTAssertEqual(search.error, "workspace_missing")
    }
    func testWorkspaceIndexToolSummarizesProjectStructure() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try "# App".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let value = 1".write(to: workspace.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try "import XCTest".write(to: workspace.appendingPathComponent("Tests/AppTests/AppTests.swift"), atomically: true, encoding: .utf8)
        try "token".write(to: workspace.appendingPathComponent("Sources/App/auth_token.swift"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceIndexTool().execute(
            argumentsJSON: #"{"maxFiles":20,"maxDepth":5}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("README.md"))
        XCTAssertTrue(result.output.contains("swift"))
        XCTAssertTrue(result.output.contains("入口候选"))
        XCTAssertTrue(result.output.contains("测试候选"))
        XCTAssertTrue(result.output.contains("配置候选"))
        XCTAssertTrue(result.output.contains("风险/关注候选"))
        XCTAssertTrue(result.output.contains("Sources/App/main.swift"))
        XCTAssertTrue(result.output.contains("Tests/AppTests/AppTests.swift"))
        XCTAssertTrue(result.output.contains("Sources/App/auth_token.swift"))
        XCTAssertEqual(result.data?["fileCount"], "4")
        XCTAssertEqual(result.data?["entryCount"], "2")
        XCTAssertEqual(result.data?["testCount"], "1")
        XCTAssertEqual(result.data?["riskCount"], "1")
    }
    func testWebFetchExtractsReadableTextFromHTML() {
        let html = """
        <html><head><title>Example &amp; Test</title><style>.x{}</style></head>
        <body><nav>menu</nav><h1>Hello</h1><p>Readable content &quot;here&quot;.</p><script>alert(1)</script></body></html>
        """

        let result = WebFetchTool.extractReadableText(fromHTML: html, url: "https://example.com/page", maxCharacters: 500)

        XCTAssertEqual(result.title, "Example & Test")
        XCTAssertTrue(result.content.contains("Hello"))
        XCTAssertTrue(result.content.contains(#"Readable content "here"."#))
        XCTAssertFalse(result.content.contains("alert"))
        XCTAssertFalse(result.content.contains("menu"))
    }
    func testFunctionCallArgumentsDecodeObjectPayloads() throws {
        let json = #"{"name":"web_search","arguments":{"query":"AI news","maxResults":3}}"#.data(using: .utf8)!
        let detail = try JSONDecoder().decode(FunctionCallDetail.self, from: json)

        XCTAssertEqual(detail.name, "web_search")
        XCTAssertTrue(detail.arguments.contains(#""query":"AI news""#))
        XCTAssertTrue(detail.arguments.contains(#""maxResults":3"#))
    }
    func testGitToolReturnsFriendlyResultOutsideRepository() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await GitTool().execute(
            argumentsJSON: #"{"subcommand":"status"}"#,
            context: TaskContext(workspaceRoot: workspace.path)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["repository"], "false")
        XCTAssertTrue(result.output.contains("不是 git 仓库"))
    }
}
