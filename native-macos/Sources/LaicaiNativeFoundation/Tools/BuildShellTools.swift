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
                    "command": FunctionProperty(type: "string", description: "可选，自定义构建/测试命令。留空则自动检测（swift build / npm test / cargo build / make 等）"),
                    "changedFiles": FunctionProperty(type: "string", description: "可选，逗号或换行分隔的变更文件列表；提供后会优先选择相关测试"),
                    "fix": FunctionProperty(type: "boolean", description: "如果构建失败，是否返回错误详情供模型自动修复（默认 true）")
                ],
                required: []
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var command: String?
            var changedFiles: String?
            var fix: Bool?
        }

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

        let buildCommand: String
        if let custom = params.command, !custom.isEmpty {
            // Reject commands that are clearly not build commands
            let dangerousPatterns = ["python", "ruby", "node ", "curl ", "wget ", "rm -", "<<", "eval ", "exec ", "sudo ", "cat ", "echo ", "pip ", "brew "]
            let isSuspicious = dangerousPatterns.contains(where: { custom.lowercased().hasPrefix($0) || custom.lowercased().contains(" \($0)") })
            // Also reject heredocs and multi-line scripts
            let hasHeredoc = custom.contains("<<") || custom.contains("\"\"\"") || custom.contains("'''")
            let allowedBuildPrefixes = ["swift ", "xcodebuild", "cargo ", "make", "npm ", "yarn ", "pnpm ", "go ", "gradle", "mvn ", "cmake", "dotnet ", "gcc ", "g++ ", "clang", "bash build", "pytest", "npm run build", "npm run test"]
            let looksLikeBuild = allowedBuildPrefixes.contains(where: { custom.lowercased().hasPrefix($0) })
            if (isSuspicious || hasHeredoc) && !looksLikeBuild {
                let lowerCustom = custom.lowercased()
                let isContentCheck = lowerCustom.contains("assert") || lowerCustom.contains("read_text") || lowerCustom.contains("readtext")
                    || lowerCustom.contains("path(") || lowerCustom.contains("from pathlib")
                let redirect = isContentCheck
                    ? "\n💡 检查文件内容请改用 file_read / file_extract（读取后看返回值），而不是用 verify_build 跑 python assert。"
                    : "\n💡 verify_build 仅用于编译/测试。一般 shell 任务请改用 shell_exec。"
                return ToolResult(
                    output: "拒绝命令「\(String(custom.prefix(60)))…」：verify.build 仅接受编译/测试类命令。\(redirect)",
                    success: false,
                    error: "invalid_command"
                )
            } else {
                buildCommand = custom
            }
        } else {
            let changedFiles = Self.parseChangedFiles(params.changedFiles) + Self.detectChangedFiles(workspaceRoot: workspaceRoot)
            buildCommand = detectBuildCommand(workspaceRoot: workspaceRoot, changedFiles: changedFiles)
        }

        guard !buildCommand.isEmpty else {
            return ToolResult(output: "当前工作区无构建系统（未找到 Package.swift / package.json / Cargo.toml / Makefile 等）。无需调用 verify.build。", success: false, error: "no_build_system")
        }

        // Execute build command — use login shell so user PATH (brew, node, etc.) is available
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "cd \(shellEscape(workspaceRoot)) && \(buildCommand) 2>&1"]
        var buildEnv = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/usr/sbin", "/bin", "/sbin"
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
        process.environment = buildEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ToolResult(output: "无法启动构建命令：\(error.localizedDescription)", success: false, error: "exec_failed")
        }

        // Wait with timeout
        let timeout: TimeInterval = 120
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            process.terminate()
            return ToolResult(output: "构建命令超时（\(Int(timeout))秒）：\(buildCommand)", success: false, error: "timeout")
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus
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
            let fixHint = (params.fix ?? true)
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

    private func detectBuildCommand(workspaceRoot: String, changedFiles: [String] = []) -> String {
        let fm = FileManager.default
        // Swift / SPM
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("Package.swift")) {
            if changedFiles.contains(where: { $0.hasSuffix("Tests.swift") || $0.contains("/Tests/") }) {
                return "swift test 2>&1"
            }
            return "swift build 2>&1"
        }
        // build.sh
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("build.sh")) {
            return "bash build.sh 2>&1"
        }
        // Node.js
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("package.json")) {
            if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("node_modules/.bin/tsc")) {
                return "npx tsc --noEmit 2>&1"
            }
            if let testFile = changedFiles.first(where: { $0.contains(".test.") || $0.contains(".spec.") }) {
                return "npm test -- \(shellEscape(testFile)) 2>&1"
            }
            return "npm test 2>&1"
        }
        // Rust
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("Cargo.toml")) {
            return "cargo build 2>&1"
        }
        // Go
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("go.mod")) {
            if let packageDir = changedFiles.first.map({ ($0 as NSString).deletingLastPathComponent }), !packageDir.isEmpty {
                return "go test ./\(packageDir) 2>&1"
            }
            return "go build ./... 2>&1"
        }
        // Python
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("setup.py"))
            || fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("pyproject.toml")) {
            return "python3 -m py_compile $(find . -name '*.py' -not -path '*/venv/*' | head -20) 2>&1"
        }
        // Make
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("Makefile")) {
            return "make 2>&1"
        }
        // CMake
        if fm.fileExists(atPath: (workspaceRoot as NSString).appendingPathComponent("CMakeLists.txt")) {
            return "cmake --build build 2>&1"
        }
        return ""
    }

    private static func parseChangedFiles(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func detectChangedFiles(workspaceRoot: String) -> [String] {
        guard GitTool.isGitRepository(workspaceRoot) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "status", "--short"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        var gitEnv = ProcessInfo.processInfo.environment
        if gitEnv["LANG"] == nil { gitEnv["LANG"] = "en_US.UTF-8" }
        if gitEnv["LC_ALL"] == nil { gitEnv["LC_ALL"] = "en_US.UTF-8" }
        process.environment = gitEnv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
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

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Write File Tool (with diff generation)

public struct WriteFileTool: LaicaiTool {
    public var name: String { "file.write" }
    public var description: String { "写入文件内容（需用户审查确认）" }
    public var requiresReview: Bool { true }
    public var executionPolicy: ToolExecutionPolicy { .fileChangeReview }

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
                    "createDirectories": FunctionProperty(type: "boolean", description: "是否自动创建父目录（可选，默认 true）")
                ],
                required: ["path"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var content: String?
            var oldContent: String?
            var newContent: String?
            var createDirectories: Bool?
        }

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
        if let securityError = await SecurityManager.shared.checkWrite(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        let oldContent: String
        if FileManager.default.fileExists(atPath: fullPath) {
            oldContent = try String(contentsOfFile: fullPath, encoding: .utf8)
        } else {
            oldContent = ""
        }

        // Determine write mode: patch vs full
        // BUG FIX: Only enter patch mode if at least one of oldContent/newContent is non-empty.
        // Models sometimes send empty oldContent/newContent alongside a valid content param;
        // we must not let empty-string patch override the actual content.
        let finalContent: String
        if let oldSnippet = params.oldContent, let newSnippet = params.newContent,
           !oldSnippet.isEmpty || !newSnippet.isEmpty {
            // Patch mode: replace exact match of oldContent with newContent
            let trimmedOld = oldSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldContent.isEmpty || !FileManager.default.fileExists(atPath: fullPath) {
                // File doesn't exist or is empty → create with newContent
                finalContent = newSnippet
            } else if trimmedOld.isEmpty {
                // Empty oldContent means "overwrite entire file"
                finalContent = newSnippet
            } else if oldContent.contains(oldSnippet) {
                // Exact match found
                let occurrences = oldContent.components(separatedBy: oldSnippet).count - 1
                if occurrences > 1 {
                    return ToolResult(
                        output: "patch 模式失败：要替换的内容在文件中出现 \(occurrences) 次，无法确定替换位置。请提供更长的上下文以唯一标识。",
                        success: false,
                        error: "patch_ambiguous"
                    )
                }
                finalContent = oldContent.replacingOccurrences(of: oldSnippet, with: newSnippet)
            } else {
                // Exact match failed — try whitespace-normalized fuzzy match
                let normalizedFile = oldContent.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let normalizedSnippet = trimmedOld.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                if normalizedFile.contains(normalizedSnippet) {
                    // Fuzzy match: find the original range and replace
                    let lines = oldContent.components(separatedBy: "\n")
                    let snippetLines = oldSnippet.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    var matchStart = -1
                    for i in 0..<lines.count {
                        var matched = true
                        for j in 0..<snippetLines.count {
                            guard i + j < lines.count else { matched = false; break }
                            if lines[i + j].trimmingCharacters(in: .whitespaces) != snippetLines[j] {
                                matched = false; break
                            }
                        }
                        if matched { matchStart = i; break }
                    }
                    if matchStart >= 0 {
                        var result = lines
                        result.replaceSubrange(matchStart..<matchStart + snippetLines.count,
                                               with: newSnippet.components(separatedBy: "\n"))
                        finalContent = result.joined(separator: "\n")
                    } else {
                        // Fuzzy line match failed too — fall back to full overwrite
                        finalContent = newSnippet
                    }
                } else {
                    // No match at all — if oldSnippet looks like "the entire old file" (>80% of file length),
                    // treat as full overwrite instead of failing
                    if trimmedOld.count > oldContent.count * 4 / 5 {
                        finalContent = newSnippet
                    } else {
                        return ToolResult(
                            output: "patch 模式失败：在文件中未找到要替换的内容。请使用 file.read 先确认当前内容，或使用 content 参数全量写入。\n文件实际前 200 字符：\(String(oldContent.prefix(200)))",
                            success: false,
                            error: "patch_not_found"
                        )
                    }
                }
            }
        } else if let content = params.content {
            // Full write mode
            finalContent = content
        } else {
            return ToolResult(
                output: "参数错误：必须提供 content（全量写入）或 oldContent+newContent（patch 写入）",
                success: false,
                error: "invalid_params"
            )
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
                "createDirectories": createDirs ? "true" : "false"
            ],
            success: true
        )
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
        "echo", "which", "env", "pwd", "date", "touch", "mkdir", "cp", "mv",
        "cargo", "rustc", "go",
        "make", "cmake",
        "diff", "patch",
        "ruby", "gem", "pod", "flutter", "dart",
        "docker", "docker-compose",
        "sed", "awk", "sort", "uniq", "tr", "cut", "tee",
        "open", "pbcopy", "pbpaste",
        "laicai"
    ]

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "command": FunctionProperty(type: "string", description: "要执行的终端命令。仅用于测试、构建、git、包管理脚本或小范围诊断；不要用 find/ls -R/tree/grep 等方式遍历或读取整个项目，项目结构请用 workspace_index，内容查找请用 code_search，文件读取请用 file_read。"),
                    "timeout": FunctionProperty(type: "integer", description: "超时时间（秒），默认30秒"),
                    "background": FunctionProperty(type: "boolean", description: "后台运行（默认 false）。设为 true 可启动 dev server 等长运行进程而不阻塞。")
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
        if let securityError = ShellSecurityCheck(command: command, policy: policySnapshot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        // G2: Background process — start and return immediately
        if isBackground {
            return try await executeBackground(command: command, context: context)
        }

        // Sandbox execution — route through SandboxEngine if configured
        let sandboxConfig = await SecurityManager.shared.sandboxConfig
        if sandboxConfig.mode != .none {
            do {
                let (output, errOutput, exitCode) = try await SandboxExecutor.execute(
                    command: command,
                    workspaceRoot: context.workspaceRoot,
                    config: sandboxConfig
                )
                let combined = [output, errOutput].filter { !$0.isEmpty }.joined(separator: "\n")
                let trimmed = String(combined.suffix(8000))
                return ToolResult(
                    output: trimmed.isEmpty ? "(命令执行完成，无输出)" : trimmed,
                    data: ["exit_code": "\(exitCode)", "sandbox": sandboxConfig.mode.rawValue],
                    success: exitCode == 0,
                    error: exitCode == 0 ? nil : "exit_\(exitCode)"
                )
            } catch {
                return ToolResult(output: "沙箱执行失败：\(error.localizedDescription)", success: false, error: "sandbox_error")
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.bun/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        let mergedPath = (commonPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, path in
                if !path.isEmpty && !result.contains(path) { result.append(path) }
            }
            .joined(separator: ":")
        environment["PATH"] = mergedPath
        environment["SHELL"] = "/bin/zsh"
        environment["HOME"] = NSHomeDirectory()
        // Ensure UTF-8 locale for proper CJK character handling in command output.
        // macOS .app bundles don't inherit terminal locale, causing wc/find/etc to output ? for non-ASCII.
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["LC_ALL"] == nil { environment["LC_ALL"] = "en_US.UTF-8" }
        process.environment = environment
        if !context.workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let processBox = Locked(process)
        let stdoutBox = Locked(stdout)
        let stderrBox = Locked(stderr)
        let toolName = name

        return await withCheckedContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ToolResult(output: "无法启动命令：\(error.localizedDescription)", success: false, error: "launch_failed"))
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                processBox.withValue {
                    if $0.isRunning { $0.terminate() }
                }
            }
            timer.resume()

            // Async wait for process exit via NotificationCenter
            let observer = NotificationCenter.default.addObserver(
                forName: Process.didTerminateNotification,
                object: process,
                queue: .main
            ) { _ in
                timer.cancel()
                let exitCode = processBox.withValue { $0.terminationStatus }
                let outData = stdoutBox.withValue { $0.fileHandleForReading.readDataToEndOfFile() }
                let errData = stderrBox.withValue { $0.fileHandleForReading.readDataToEndOfFile() }
                let output = String(data: outData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errData, encoding: .utf8) ?? ""

                Task { @MainActor in
                    let auditOutput = exitCode == 0
                        ? "exit code 0"
                        : "exit code \(exitCode)：\(String(errorOutput.prefix(300)))"
                    AuditLog.shared.record(
                        tool: toolName,
                        input: command,
                        output: auditOutput,
                        success: exitCode == 0
                    )
                }

                continuation.resume(returning: Self.makeShellResult(exitCode: exitCode, stdout: output, stderr: errorOutput))
            }

            // If process already exited before observer was set
            if !process.isRunning {
                NotificationCenter.default.removeObserver(observer)
                timer.cancel()
                let exitCode = process.terminationStatus
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: Self.makeShellResult(exitCode: exitCode, stdout: output, stderr: errorOutput))
            }
        }
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
            environment["PATH"] ?? ""
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
