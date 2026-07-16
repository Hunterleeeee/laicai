import Darwin
import Foundation
import LaicaiNativeDomain

// MARK: - Verify Build Tool (auto build/test)

public struct VerifyBuildTool: LaicaiTool {
    public var name: String { "verify.build" }
    public var description: String { "自动检测项目构建系统并运行编译/测试，返回成功或失败信息。写完代码后务必调用此工具验证。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "command": FunctionProperty(
                        type: "string", description: "可选，自定义构建/测试命令。留空则自动检测（swift build / npm test / cargo build / make 等）"),
                    "changedFiles": FunctionProperty(type: "string", description: "可选，逗号或换行分隔的变更文件列表；提供后会优先选择相关测试"),
                    "fix": FunctionProperty(type: "boolean", description: "如果构建失败，是否返回错误详情供模型自动修复（默认 true）"),
                ],
                required: []
            )
        )
    }

    private static let suspiciousVerifyCommandPatterns = [
        "python", "ruby", "node ", "curl ", "wget ", "rm -", "<<", "eval ", "exec ", "sudo ", "cat ", "echo ", "pip ", "brew ",
    ]

    private static let allowedBuildPrefixes = [
        "swift ", "xcodebuild", "cargo ", "make", "npm ", "yarn ", "pnpm ", "go ",
        "gradle", "mvn ", "cmake", "dotnet ", "gcc ", "g++ ", "clang",
        "bash build", "pytest", "npm run build", "npm run test",
    ]

    private static let contentCheckPatterns = ["assert", "read_text", "readtext", "path(", "from pathlib"]

    private struct Params: Codable {
        var command: String?
        var changedFiles: String?
        var fix: Bool?
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败", success: false, error: "invalid_params")
        }

        let workspaceRoot = context.workspaceRoot
        guard !workspaceRoot.isEmpty else {
            return ToolResult(output: "未设置工作区，无法执行构建验证", success: false, error: "workspace_missing")
        }

        let resolved = buildCommand(from: params, workspaceRoot: workspaceRoot)
        if let failure = resolved.failure {
            return failure
        }
        let buildCommand = resolved.command

        guard !buildCommand.isEmpty else {
            return ToolResult(
                output: "当前工作区无构建系统（未找到 Package.swift / package.json / Cargo.toml / Makefile 等）。无需调用 verify.build。", success: false,
                error: "no_build_system")
        }

        // Execute build command — use login shell so user PATH (brew, node, etc.) is available.
        // ProcessRunner drains stdout/stderr concurrently to prevent large builds deadlocking.
        var buildEnv = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/usr/sbin", "/bin", "/sbin",
        ]
        let existingPath = buildEnv["PATH"] ?? ""
        let existingParts = Set(existingPath.components(separatedBy: ":"))
        let mergedPath = (commonPaths.filter { !existingParts.contains($0) } + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        buildEnv["PATH"] = mergedPath
        buildEnv["HOME"] = NSHomeDirectory()
        if buildEnv["LANG"] == nil { buildEnv["LANG"] = "en_US.UTF-8" }
        if buildEnv["LC_ALL"] == nil { buildEnv["LC_ALL"] = "en_US.UTF-8" }
        let processResult: ProcessRunResult
        do {
            processResult = try await ProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", buildCommand],
                currentDirectoryURL: URL(fileURLWithPath: workspaceRoot),
                environment: buildEnv,
                timeout: 120
            )
        } catch {
            return ToolResult(output: "无法启动构建命令：\(error.localizedDescription)", success: false, error: "exec_failed")
        }

        if processResult.timedOut {
            return ToolResult(output: "构建命令超时（120秒）：\(buildCommand)", success: false, error: "timeout")
        }

        let output = [processResult.stdoutString, processResult.stderrString]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let exitCode = processResult.exitCode
        let truncatedOutput = output.count > 8000 ? String(output.suffix(8000)) : output

        await AuditLog.shared.record(
            tool: name,
            input: buildCommand,
            output: "exit \(exitCode)",
            success: exitCode == 0
        )

        if exitCode == 0 {
            return ToolResult(
                output: "✅ 构建成功\n命令：\(buildCommand)\n\(String(truncatedOutput.suffix(2000)))",
                data: ["command": buildCommand, "exitCode": "0"],
                success: true
            )
        } else {
            // Extract error lines for model to fix
            let errorLines = extractErrorLines(from: output)
            let fixHint =
                (params.fix ?? true)
                ? "\n\n请根据以上错误信息修复代码，然后再次调用 verify_build 验证。"
                : ""
            return ToolResult(
                output: "❌ 构建失败（exit \(exitCode)）\n命令：\(buildCommand)\n\n错误输出：\n\(errorLines)\(fixHint)",
                data: ["command": buildCommand, "exitCode": "\(exitCode)"],
                success: false,
                error: "build_failed"
            )
        }
    }

    private static func customBuildCommandRejection(_ command: String) -> ToolResult? {
        let lowerCommand = command.lowercased()
        let isSuspicious = suspiciousVerifyCommandPatterns.contains {
            lowerCommand.hasPrefix($0) || lowerCommand.contains(" \($0)")
        }
        let hasHeredoc = command.contains("<<") || command.contains("\"\"\"") || command.contains("'''")
        guard (isSuspicious || hasHeredoc) && !looksLikeBuildCommand(lowerCommand) else { return nil }
        let redirect =
            contentCheckPatterns.contains(where: lowerCommand.contains)
            ? "\n💡 检查文件内容请改用 file_read / file_extract（读取后看返回值），而不是用 verify_build 跑 python assert。"
            : "\n💡 verify_build 仅用于编译/测试。一般 shell 任务请改用 shell_exec。"
        return ToolResult(
            output: "拒绝命令「\(String(command.prefix(60)))…」：verify.build 仅接受编译/测试类命令。\(redirect)",
            success: false,
            error: "invalid_command"
        )
    }

    private static func looksLikeBuildCommand(_ lowerCommand: String) -> Bool {
        allowedBuildPrefixes.contains { lowerCommand.hasPrefix($0) }
    }

    private func buildCommand(from params: Params, workspaceRoot: String) -> (command: String, failure: ToolResult?) {
        if let custom = params.command, !custom.isEmpty {
            if let rejection = Self.customBuildCommandRejection(custom) {
                return ("", rejection)
            }
            return (custom, nil)
        }
        let changedFiles = Self.parseChangedFiles(params.changedFiles) + Self.detectChangedFiles(workspaceRoot: workspaceRoot)
        return (detectBuildCommand(workspaceRoot: workspaceRoot, changedFiles: changedFiles), nil)
    }

    private func detectBuildCommand(workspaceRoot: String, changedFiles: [String] = []) -> String {
        // Swift / SPM
        if Self.workspaceContains("Package.swift", root: workspaceRoot) {
            return Self.swiftBuildCommand(changedFiles: changedFiles)
        }
        // build.sh
        if Self.workspaceContains("build.sh", root: workspaceRoot) {
            return "bash build.sh 2>&1"
        }
        // Node.js
        if Self.workspaceContains("package.json", root: workspaceRoot) {
            return nodeBuildCommand(workspaceRoot: workspaceRoot, changedFiles: changedFiles)
        }
        // Rust
        if Self.workspaceContains("Cargo.toml", root: workspaceRoot) {
            return "cargo build 2>&1"
        }
        // Go
        if Self.workspaceContains("go.mod", root: workspaceRoot) {
            return Self.goBuildCommand(changedFiles: changedFiles)
        }
        // Python
        if Self.isPythonProject(workspaceRoot) {
            return "python3 -m py_compile $(find . -name '*.py' -not -path '*/venv/*' | head -20) 2>&1"
        }
        // Make
        if Self.workspaceContains("Makefile", root: workspaceRoot) {
            return "make 2>&1"
        }
        // CMake
        if Self.workspaceContains("CMakeLists.txt", root: workspaceRoot) {
            return "cmake --build build 2>&1"
        }
        return ""
    }

    private static func workspaceContains(_ relativePath: String, root: String) -> Bool {
        FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(relativePath))
    }

    private static func swiftBuildCommand(changedFiles: [String]) -> String {
        changedFiles.contains { $0.hasSuffix("Tests.swift") || $0.contains("/Tests/") }
            ? "swift test 2>&1"
            : "swift build 2>&1"
    }

    private func nodeBuildCommand(workspaceRoot: String, changedFiles: [String]) -> String {
        if Self.workspaceContains("node_modules/.bin/tsc", root: workspaceRoot) {
            return "npx tsc --noEmit 2>&1"
        }
        if let testFile = changedFiles.first(where: { $0.contains(".test.") || $0.contains(".spec.") }) {
            return "npm test -- \(shellEscape(testFile)) 2>&1"
        }
        return "npm test 2>&1"
    }

    private static func goBuildCommand(changedFiles: [String]) -> String {
        if let packageDir = changedFiles.first.map({ ($0 as NSString).deletingLastPathComponent }), !packageDir.isEmpty {
            return "go test ./\(packageDir) 2>&1"
        }
        return "go build ./... 2>&1"
    }

    private static func isPythonProject(_ workspaceRoot: String) -> Bool {
        workspaceContains("setup.py", root: workspaceRoot) || workspaceContains("pyproject.toml", root: workspaceRoot)
    }

    private static func parseChangedFiles(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return
            raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func detectChangedFiles(workspaceRoot: String) -> [String] {
        guard GitTool.isGitRepository(workspaceRoot) else { return [] }
        var gitEnv = ProcessInfo.processInfo.environment
        if gitEnv["LANG"] == nil { gitEnv["LANG"] = "en_US.UTF-8" }
        if gitEnv["LC_ALL"] == nil { gitEnv["LC_ALL"] = "en_US.UTF-8" }
        do {
            let result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "status", "--short"],
                currentDirectoryURL: URL(fileURLWithPath: workspaceRoot),
                environment: gitEnv,
                timeout: 10
            )
            guard result.exitCode == 0, !result.timedOut else { return [] }
            let output = result.stdoutString
            return output.components(separatedBy: .newlines).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 3 else { return nil }
                return String(trimmed.dropFirst(3))
            }
        } catch {
            return []
        }
    }

    private func extractErrorLines(from output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        let errorLines = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("failed") || lower.contains("错误")
                || lower.contains("undefined") || lower.contains("cannot find")
                || lower.contains("no such") || lower.contains("syntax error")
        }
        if errorLines.isEmpty {
            // Return last 40 lines if no specific error lines found
            return lines.suffix(40).joined(separator: "\n")
        }
        return errorLines.prefix(30).joined(separator: "\n")
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Write File Tool (with diff generation)

public struct WriteFileTool: LaicaiTool {
    public init() {}

    public var name: String { "file.write" }
    public var description: String { "写入文件内容（需用户审查确认）" }
    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .fileChangeReview }

    private struct Params: Codable {
        var path: String
        var content: String?
        var oldContent: String?
        var newContent: String?
        var createDirectories: Bool?
    }

    private enum WriteContentResolution {
        case content(String)
        case failure(ToolResult)
    }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "content": FunctionProperty(type: "string", description: "文件完整内容（与 oldContent/newContent 二选一）"),
                    "oldContent": FunctionProperty(type: "string", description: "要替换的原始内容片段（patch 模式，精确匹配）"),
                    "newContent": FunctionProperty(type: "string", description: "替换后的新内容片段（patch 模式）"),
                    "createDirectories": FunctionProperty(type: "boolean", description: "是否自动创建父目录（可选，默认 true）"),
                ],
                required: ["path"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let path = params.path
        let createDirs = params.createDirectories ?? true

        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            fullPath = (context.workspaceRoot as NSString).appendingPathComponent(path)
        }

        // Security check
        if let securityError = await SecurityManager.shared.checkWrite(
            path: fullPath,
            workspaceRoot: context.workspaceRoot
        ) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        let oldContent: String
        if FileManager.default.fileExists(atPath: fullPath) {
            oldContent = try String(contentsOfFile: fullPath, encoding: .utf8)
        } else {
            oldContent = ""
        }
        if let dangerousError = DangerousOperationGuard.writeViolation(path: fullPath, oldContent: oldContent, context: context) {
            return ToolResult(output: dangerousError, success: false, error: "dangerous_operation")
        }

        // Determine write mode: patch vs full
        // BUG FIX: Only enter patch mode if at least one of oldContent/newContent is non-empty.
        // Models sometimes send empty oldContent/newContent alongside a valid content param;
        // we must not let empty-string patch override the actual content.
        let finalContent: String
        switch Self.resolveFinalContent(params: params, oldContent: oldContent, fullPath: fullPath) {
        case .content(let content):
            finalContent = content
        case .failure(let result):
            return result
        }

        let diff = Self.generateDiff(oldContent: oldContent, newContent: finalContent, filePath: path)

        await AuditLog.shared.record(
            tool: name,
            input: "\(path) (\(finalContent.count) 字符)",
            output: diff.summary,
            success: true
        )

        // Return diff for review - actual write happens after user approval
        return ToolResult(
            output: "文件修改已准备，等待审查：\(path)\n\(diff.summary)",
            data: [
                "path": path,
                "fullPath": fullPath,
                "diffOld": oldContent,
                "diffNew": finalContent,
                "addedLines": "\(diff.addedLines)",
                "removedLines": "\(diff.removedLines)",
                "createDirectories": createDirs ? "true" : "false",
            ],
            success: true
        )
    }

    private static func resolveFinalContent(
        params: Params,
        oldContent: String,
        fullPath: String
    ) -> WriteContentResolution {
        if let oldSnippet = params.oldContent, let newSnippet = params.newContent,
            !oldSnippet.isEmpty || !newSnippet.isEmpty
        {
            return resolvePatchContent(
                oldSnippet: oldSnippet,
                newSnippet: newSnippet,
                oldContent: oldContent,
                fullPath: fullPath
            )
        }
        if let content = params.content {
            return .content(content)
        }
        return .failure(
            ToolResult(
                output: "参数错误：必须提供 content（全量写入）或 oldContent+newContent（patch 写入）",
                success: false,
                error: "invalid_params"
            ))
    }

    private static func resolvePatchContent(
        oldSnippet: String,
        newSnippet: String,
        oldContent: String,
        fullPath: String
    ) -> WriteContentResolution {
        let trimmedOld = oldSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldContent.isEmpty || !FileManager.default.fileExists(atPath: fullPath) {
            return .content(newSnippet)
        }
        guard !trimmedOld.isEmpty else {
            return .failure(
                ToolResult(
                    output: "patch 模式失败：现有文件的 oldContent 不能为空；如需全量替换请使用 content 参数。",
                    success: false,
                    error: "patch_empty_old_content"
                )
            )
        }
        if oldContent.contains(oldSnippet) {
            return exactPatchContent(oldSnippet: oldSnippet, newSnippet: newSnippet, oldContent: oldContent)
        }
        return fuzzyPatchContent(
            oldSnippet: oldSnippet,
            newSnippet: newSnippet,
            oldContent: oldContent,
            trimmedOld: trimmedOld
        )
    }

    private static func exactPatchContent(
        oldSnippet: String,
        newSnippet: String,
        oldContent: String
    ) -> WriteContentResolution {
        let occurrences = oldContent.components(separatedBy: oldSnippet).count - 1
        guard occurrences <= 1 else {
            return .failure(
                ToolResult(
                    output: "patch 模式失败：要替换的内容在文件中出现 \(occurrences) 次，无法确定替换位置。请提供更长的上下文以唯一标识。",
                    success: false,
                    error: "patch_ambiguous"
                ))
        }
        return .content(oldContent.replacingOccurrences(of: oldSnippet, with: newSnippet))
    }

    private static func fuzzyPatchContent(
        oldSnippet: String,
        newSnippet: String,
        oldContent: String,
        trimmedOld: String
    ) -> WriteContentResolution {
        let normalizedFile = normalizedWhitespace(oldContent)
        let normalizedSnippet = normalizedWhitespace(trimmedOld)
        guard normalizedFile.contains(normalizedSnippet) else {
            return unmatchedPatchContent(oldContent: oldContent, trimmedOld: trimmedOld)
        }
        let lines = oldContent.components(separatedBy: "\n")
        let snippetLines = oldSnippet.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let matchStart = fuzzyLineMatchStart(lines: lines, snippetLines: snippetLines) else {
            return .failure(
                ToolResult(
                    output: "patch 模式失败：空白归一化后相似，但无法唯一定位原始行。请重新读取文件并提供精确 oldContent。",
                    success: false,
                    error: "patch_not_found"
                )
            )
        }
        var result = lines
        result.replaceSubrange(matchStart..<matchStart + snippetLines.count, with: newSnippet.components(separatedBy: "\n"))
        return .content(result.joined(separator: "\n"))
    }

    private static func unmatchedPatchContent(
        oldContent: String,
        trimmedOld: String
    ) -> WriteContentResolution {
        return .failure(
            ToolResult(
                output:
                    "patch 模式失败：在文件中未找到要替换的内容。请使用 file.read 先确认当前内容，或使用 content 参数全量写入。\n文件实际前 200 字符：\(String(oldContent.prefix(200)))",
                success: false,
                error: "patch_not_found"
            ))
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func fuzzyLineMatchStart(lines: [String], snippetLines: [String]) -> Int? {
        for lineIndex in 0..<lines.count where lineWindowMatches(lines: lines, snippetLines: snippetLines, start: lineIndex) {
            return lineIndex
        }
        return nil
    }

    private static func lineWindowMatches(lines: [String], snippetLines: [String], start: Int) -> Bool {
        for snippetIndex in 0..<snippetLines.count {
            guard start + snippetIndex < lines.count else { return false }
            if lines[start + snippetIndex].trimmingCharacters(in: .whitespaces) != snippetLines[snippetIndex] {
                return false
            }
        }
        return true
    }

    public func validate(result: ToolResult) -> Bool {
        result.success && result.data?["path"] != nil
    }

    private struct DiffSummary {
        var summary: String
        var addedLines: Int
        var removedLines: Int
    }

    private static func generateDiff(oldContent: String, newContent: String, filePath: String) -> DiffSummary {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")
        let added = max(newLines.count - oldLines.count, 0)
        let removed = max(oldLines.count - newLines.count, 0)
        let action = oldContent.isEmpty ? "新建" : "修改"
        return DiffSummary(
            summary: "\(action) \(filePath)（+\(added) -\(removed) 行）",
            addedLines: added,
            removedLines: removed
        )
    }

    /// Actually write the file after approval
    public func performWrite(fullPath: String, content: String, createDirectories: Bool = true) throws {
        if createDirectories {
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: parentDir) {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            }
        }
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Shell Tool (with whitelist)

public struct ShellTool: LaicaiTool {
    public var name: String { "shell.exec" }
    public var description: String { "执行终端命令（仅限白名单命令）。不要用它遍历项目结构；项目扫描请使用 workspace.index，查找内容请使用 code.search，读取文件请使用 file.read。" }

    public static let allowedPrefixes = [
        "ls", "cat", "head", "tail", "wc", "find", "grep", "rg", "fd",
        "git", "npm", "npx", "yarn", "pnpm", "bun", "deno", "node",
        "python3", "python", "pip3", "pip", "uv", "pipx", "poetry", "conda",
        "swift", "xcodebuild", "swiftc", "xcrun",
        "brew", "curl", "wget",
        "echo", "which", "env", "pwd", "date",
        "cargo", "rustc", "go",
        "make", "cmake",
        "diff", "patch",
        "ruby", "gem", "pod", "flutter", "dart",
        "docker", "docker-compose",
        "sed", "awk", "sort", "uniq", "tr", "cut",
        "laicai",
    ]

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "command": FunctionProperty(
                        type: "string",
                        description: [
                            "要执行的终端命令。仅用于测试、构建、git、包管理脚本或小范围诊断；",
                            "不要用 find/ls -R/tree/grep 等方式遍历或读取整个项目，项目结构请用 workspace_index，",
                            "内容查找请用 code_search，文件读取请用 file_read。",
                        ].joined()
                    ),
                    "timeout": FunctionProperty(type: "integer", description: "超时时间（秒），默认30秒"),
                    "background": FunctionProperty(type: "boolean", description: "后台运行（默认 false）。设为 true 可启动 dev server 等长运行进程而不阻塞。"),
                ],
                required: ["command"]
            )
        )
    }

    // G2: Track background processes so agent can check/kill them later
    private static var backgroundProcesses: [String: Process] = [:]

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var command: String
            var timeout: Int?
            var background: Bool?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let command = params.command.trimmingCharacters(in: .whitespaces)
        let timeout = Double(params.timeout ?? 30)
        let isBackground = params.background ?? false

        // Security check — use free function with policy snapshot to avoid MainActor hop
        let policySnapshot = await SecurityManager.shared.policySnapshot
        if let securityError = shellSecurityCheck(command: command, policy: policySnapshot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        // G2: Background process — start and return immediately
        if isBackground {
            return try await executeBackground(command: command, context: context)
        }

        // Sandbox execution — route through SandboxEngine if configured
        if let sandboxResult = await Self.sandboxedResultIfNeeded(command: command, context: context) {
            return sandboxResult
        }

        let result: ProcessRunResult
        do {
            result = try await ProcessRunner.runAsync(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command],
                currentDirectoryURL: context.workspaceRoot.isEmpty ? nil : URL(fileURLWithPath: context.workspaceRoot),
                environment: Self.shellEnvironment(),
                timeout: timeout
            )
        } catch {
            return ToolResult(output: "无法启动命令：\(error.localizedDescription)", success: false, error: "launch_failed")
        }
        let output = result.stdoutString
        let errorOutput = result.stderrString
        let auditOutput =
            result.exitCode == 0
            ? "exit code 0"
            : "exit code \(result.exitCode)：\(String(errorOutput.prefix(300)))"
        await AuditLog.shared.record(
            tool: name,
            input: command,
            output: auditOutput,
            success: result.exitCode == 0
        )
        if result.timedOut {
            return ToolResult(output: "命令执行超时（\(Int(timeout))秒）：\(command)", success: false, error: "timeout")
        }
        return Self.makeShellResult(exitCode: result.exitCode, stdout: output, stderr: errorOutput)
    }

    private static func sandboxedResultIfNeeded(command: String, context: TaskContext) async -> ToolResult? {
        let sandboxConfig = await SecurityManager.shared.sandboxConfig
        guard sandboxConfig.mode != .none else { return nil }
        do {
            let result = try await SandboxExecutor.execute(
                command: command,
                workspaceRoot: context.workspaceRoot,
                config: sandboxConfig
            )
            let combined = [result.output, result.error].filter { !$0.isEmpty }.joined(separator: "\n")
            let trimmed = String(combined.suffix(8000))
            return ToolResult(
                output: trimmed.isEmpty ? "(命令执行完成，无输出)" : trimmed,
                data: ["exit_code": "\(result.exitCode)", "sandbox": sandboxConfig.mode.rawValue],
                success: result.exitCode == 0,
                error: result.exitCode == 0 ? nil : "exit_\(result.exitCode)"
            )
        } catch {
            return ToolResult(output: "沙箱执行失败：\(error.localizedDescription)", success: false, error: "sandbox_error")
        }
    }

    private static func shellEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.bun/bin",
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = mergedPath(commonPaths: commonPaths, existingPath: existingPath)
        environment["SHELL"] = "/bin/zsh"
        environment["HOME"] = NSHomeDirectory()
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["LC_ALL"] == nil { environment["LC_ALL"] = "en_US.UTF-8" }
        return environment
    }

    private static func mergedPath(commonPaths: [String], existingPath: String) -> String {
        (commonPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, path in
                if !path.isEmpty && !result.contains(path) { result.append(path) }
            }
            .joined(separator: ":")
    }

    static let retryablePatterns = ["command not found", "No such file or directory", "not found in PATH"]

    static func isRetryable(stderr: String) -> Bool {
        retryablePatterns.contains(where: { stderr.localizedCaseInsensitiveContains($0) })
    }

    private static func makeShellResult(exitCode: Int32, stdout: String, stderr: String) -> ToolResult {
        let combinedOutput: String
        if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedOutput = stdout
        } else if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combinedOutput = stderr
        } else {
            combinedOutput = stdout + "\n\nstderr:\n" + stderr
        }
        let truncated = combinedOutput.count > 20000 ? String(combinedOutput.prefix(20000)) + "\n... (已截断)" : combinedOutput
        if exitCode == 0 {
            return ToolResult(output: truncated, data: ["exitCode": "0"])
        }

        // Provide actionable hint for common failures
        var hint = ""
        if isRetryable(stderr: stderr) {
            hint = "\n\n提示：命令未找到，可能需要使用绝对路径或先安装该工具。"
        } else if exitCode == 126 {
            hint = "\n\n提示：权限不足，请检查文件是否可执行。"
        }

        return ToolResult(
            output: "命令失败（退出码 \(exitCode)）：\n\(truncated)\(hint)",
            data: ["exitCode": "\(exitCode)"],
            success: false,
            error: "exit_\(exitCode)"
        )
    }

    // G2: Background process execution — start and return immediately
    private func executeBackground(command: String, context: TaskContext) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.cargo/bin", "\(NSHomeDirectory())/.bun/bin",
            environment["PATH"] ?? "",
        ].joined(separator: ":")
        process.environment = environment
        if !context.workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ToolResult(output: "无法启动后台命令：\(error.localizedDescription)", success: false, error: "launch_failed")
        }

        let pid = process.processIdentifier
        let processID = "\(pid)"
        Self.backgroundProcesses[processID] = process

        // Wait briefly to catch immediate failures
        try? await Task.sleep(for: .milliseconds(500))
        if !process.isRunning {
            let exitCode = process.terminationStatus
            let outData = stdout.fileHandleForReading.availableData
            let errData = stderr.fileHandleForReading.availableData
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8) ?? ""
            Self.backgroundProcesses.removeValue(forKey: processID)
            if exitCode != 0 {
                return Self.makeShellResult(exitCode: exitCode, stdout: output, stderr: errorOutput)
            }
        }

        return ToolResult(
            output: "后台进程已启动（PID \(pid)）：\(command)\n提示：进程在后台运行，你可以继续执行其他操作。",
            data: ["pid": processID, "command": command, "background": "true"],
            success: true
        )
    }

    /// Check or kill a background process by PID
    public static func checkBackgroundProcess(pid: String) -> String {
        guard let process = backgroundProcesses[pid] else {
            return "进程 \(pid) 不存在或已结束"
        }
        if process.isRunning {
            return "进程 \(pid) 仍在运行"
        } else {
            backgroundProcesses.removeValue(forKey: pid)
            return "进程 \(pid) 已退出（exit \(process.terminationStatus)）"
        }
    }

    public static func killBackgroundProcess(pid: String) -> String {
        guard let process = backgroundProcesses[pid] else {
            return "进程 \(pid) 不存在"
        }
        process.terminate()
        backgroundProcesses.removeValue(forKey: pid)
        return "已终止进程 \(pid)"
    }
}
