import Foundation
import LaicaiNativeDomain

// MARK: - Tool Registry

@MainActor
public final class ToolRegistry {
    public static let shared = ToolRegistry()
    private var tools: [String: any LaicaiTool] = [:]

    private init() {
        register(ReadFileTool())
        register(FileEditTool())
        register(WriteFileTool())
        register(ShellTool())
        register(SearchTool())
        register(WorkspaceIndexTool())
        register(VerifyBuildTool())
        register(WebSearchTool())
        register(WebFetchTool())
        register(WikiBuildTool())
        register(GitTool())
        register(ComfyUITool())
        register(LSPTool())         // G3: LSP go-to-definition / find-references
        register(DiffApplyTool())   // G11: Unified diff apply
        register(SkillManageTool()) // Agent self-creates/updates/deletes skills
        register(BrowserTool())     // Browser control: navigate, extract, screenshot, JS
        register(MemoryTool())      // Cross-session memory: store, recall, search
    }

    public func register(_ tool: any LaicaiTool) {
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any LaicaiTool)? {
        tools[ToolNameCodec.canonicalName(name)]
    }

    public var allTools: [any LaicaiTool] {
        Array(tools.values)
    }

    /// Get tool definitions for OpenAI function calling
    public var toolDefinitions: [ToolDefinition] {
        allTools.map { tool in
            var function = tool.functionDefinition
            function.name = ToolNameCodec.apiName(tool.name)
            return ToolDefinition(function: function)
        }
    }
}

public enum ToolNameCodec {
    public static func apiName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    public static func canonicalName(_ name: String) -> String {
        switch name {
        case "file_read": return "file.read"
        case "file_edit": return "file.edit"
        case "file_write": return "file.write"
        case "code_search": return "code.search"
        case "workspace_index": return "workspace.index"
        case "verify_build": return "verify.build"
        case "shell_exec": return "shell.exec"
        case "web_search": return "web.search"
        case "web_fetch": return "web.fetch"
        case "wiki_build": return "wiki.build"
        case "image_generate": return "image.generate"
        case "skill_manage": return "skill.manage"
        default: return name
        }
    }
}

// MARK: - Read File Tool

public struct ReadFileTool: LaicaiTool {
    public var name: String { "file.read" }
    public var description: String { "读取工作区中的文件内容" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "offset": FunctionProperty(type: "integer", description: "起始行号（可选，从1开始）"),
                    "limit": FunctionProperty(type: "integer", description: "最大读取行数（可选，默认读取全部）")
                ],
                required: ["path"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var offset: Int?
            var limit: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let path = params.path
        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolResult(output: "请先设置工作区后再读取文件。", success: false, error: "workspace_missing")
            }
            fullPath = (context.workspaceRoot as NSString).appendingPathComponent(path)
        }

        // Security check - verify path is not sensitive
        if let securityError = await SecurityManager.shared.checkRead(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            return ToolResult(output: "文件不存在：\(path)", success: false, error: "file_not_found")
        }

        if isDirectory.boolValue {
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .prefix(max(1, params.limit ?? 200))
                let lines = entries.map { entry -> String in
                    let child = (fullPath as NSString).appendingPathComponent(entry)
                    var childIsDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory)
                    return childIsDirectory.boolValue ? "\(entry)/" : entry
                }
                let output = lines.isEmpty
                    ? "目录为空：\(path)"
                    : "目录：\(path)\n" + lines.joined(separator: "\n")

                await AuditLog.shared.record(
                    tool: name,
                    input: argumentsJSON,
                    output: "读取目录 \(path)，\(lines.count) 项",
                    success: true
                )

                return ToolResult(output: output, data: ["path": path, "type": "directory", "count": "\(lines.count)"])
            } catch {
                return ToolResult(output: "读取目录失败：\(error.localizedDescription)", success: false, error: "read_error")
            }
        }

        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")

            // Apply offset and limit
            if let offset = params.offset, offset > 0 {
                let startIdx = max(0, offset - 1)
                lines = Array(lines.dropFirst(startIdx))
            }
            if let limit = params.limit, limit > 0 {
                lines = Array(lines.prefix(limit))
            }

            let resultText = lines.joined(separator: "\n")
            let maxChars: Int
            switch context.contextMode {
            case .economy: maxChars = 10_000
            case .balanced: maxChars = 50_000
            case .deep: maxChars = 200_000
            }
            let truncated = resultText.count > maxChars ? String(resultText.prefix(maxChars)) + "\n... (已截断，当前\(context.contextMode.rawValue)模式)" : resultText

            await AuditLog.shared.record(
                tool: name,
                input: argumentsJSON,
                output: "读取 \(path)，\(resultText.count) 字符",
                success: true
            )

            return ToolResult(output: truncated, data: ["path": path, "size": "\(resultText.count)"])
        } catch {
            return ToolResult(output: "读取文件失败：\(error.localizedDescription)", success: false, error: "read_error")
        }
    }
}

// MARK: - File Edit Tool (precise search/replace)

public struct FileEditTool: LaicaiTool {
    public var name: String { "file.edit" }
    public var description: String { "精准编辑文件：查找并替换指定内容片段，支持多处同时替换。优先使用此工具而非 file.write 全量覆盖。" }
    public var requiresReview: Bool { true }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径（相对或绝对路径）"),
                    "edits": FunctionProperty(type: "string", description: "JSON 数组，每项含 oldText 和 newText。例：[{\"oldText\":\"foo\",\"newText\":\"bar\"}]"),
                    "batchEdits": FunctionProperty(type: "string", description: "可选，批量编辑 JSON 数组，每项含 path 和 edits。例：[{\"path\":\"a.swift\",\"edits\":[{\"oldText\":\"foo\",\"newText\":\"bar\"}]}]"),
                    "createIfMissing": FunctionProperty(type: "boolean", description: "文件不存在时是否用第一条 edit 的 newText 创建（可选，默认 false）")
                ],
                required: []
            )
        )
    }

    private struct EditOp: Codable {
        var oldText: String
        var newText: String
    }

    private struct BatchEdit: Codable {
        var path: String
        var edits: [EditOp]
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String?
            var edits: String?
            var batchEdits: String?
            var createIfMissing: Bool?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        if let batchEdits = params.batchEdits {
            return try await executeBatch(batchEditsJSON: batchEdits, createIfMissing: params.createIfMissing == true, context: context)
        }

        guard let path = params.path, let editsJSON = params.edits else {
            return ToolResult(output: "参数错误：必须提供 path+edits，或提供 batchEdits。", success: false, error: "invalid_params")
        }

        let edits: [EditOp]
        do {
            let editsData = editsJSON.data(using: .utf8) ?? Data()
            edits = try JSONDecoder().decode([EditOp].self, from: editsData)
        } catch {
            return ToolResult(output: "edits 参数格式错误，需要 JSON 数组 [{\"oldText\":\"...\",\"newText\":\"...\"}]", success: false, error: "invalid_edits")
        }

        guard !edits.isEmpty else {
            return ToolResult(output: "edits 数组为空", success: false, error: "empty_edits")
        }

        return try await executeSingle(path: path, edits: edits, createIfMissing: params.createIfMissing == true, context: context)
    }

    private func executeSingle(path: String, edits: [EditOp], createIfMissing: Bool, context: TaskContext) async throws -> ToolResult {
        let fullPath = try resolveWritePath(path: path, context: context)
        if let securityError = await SecurityManager.shared.checkWrite(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }
        var content: String
        if FileManager.default.fileExists(atPath: fullPath) {
            content = try String(contentsOfFile: fullPath, encoding: .utf8)
        } else if createIfMissing, let first = edits.first {
            content = first.newText
        } else {
            return ToolResult(output: "文件不存在：\(path)。设置 createIfMissing=true 可以创建新文件。", success: false, error: "file_not_found")
        }

        // File change detection: warn if file was modified externally since last read
        let resolvedPath = path.hasPrefix("/") ? path : (context.workspaceRoot as NSString).appendingPathComponent(path)
        var externalChangeWarning: String?
        if let cachedContent = context.memory.fileContentCache[resolvedPath],
           content != cachedContent {
            externalChangeWarning = "⚠️ 文件 \(path) 自上次读取后已被外部修改（磁盘版本与缓存不同）。编辑基于最新磁盘版本。"
            await AuditLog.shared.record(tool: name, input: path, output: externalChangeWarning!, success: true)
        }

        let oldContent = content
        var appliedCount = 0
        var errors: [String] = []
        var appliedEdits: [EditOp] = []

        for (i, edit) in edits.enumerated() {
            if edit.oldText == edit.newText {
                errors.append("第\(i+1)条编辑：oldText 和 newText 相同，跳过")
                continue
            }

            // Try exact match first
            if content.contains(edit.oldText) {
                let occurrences = content.components(separatedBy: edit.oldText).count - 1
                if occurrences > 1 {
                    errors.append("第\(i+1)条编辑：oldText 出现 \(occurrences) 次，需提供更多上下文以唯一标识")
                    continue
                }
                content = content.replacingOccurrences(of: edit.oldText, with: edit.newText)
                appliedCount += 1
                appliedEdits.append(edit)
            } else if let fuzzyResult = Self.fuzzyReplace(in: content, oldText: edit.oldText, newText: edit.newText) {
                // Fuzzy match: whitespace-normalized or indent-aware
                content = fuzzyResult.content
                appliedCount += 1
                appliedEdits.append(edit)
                errors.append("第\(i+1)条编辑：模糊匹配成功（\(fuzzyResult.matchType)）")
            } else {
                errors.append("第\(i+1)条编辑：未找到 oldText（前80字符：\(String(edit.oldText.prefix(80)))）")
                continue
            }
        }

        // Post-edit format hook: normalize trailing newline
        if appliedCount > 0 && !content.hasSuffix("\n") && oldContent.hasSuffix("\n") {
            content += "\n"
        }

        if appliedCount == 0 {
            return ToolResult(
                output: "所有编辑均失败：\n" + errors.joined(separator: "\n"),
                success: false,
                error: "all_edits_failed"
            )
        }

        if let warning = externalChangeWarning {
            errors.insert(warning, at: 0)
        }
        return makeEditResult(path: path, fullPath: fullPath, oldContent: oldContent, newContent: content, appliedEdits: appliedEdits, appliedCount: appliedCount, totalCount: edits.count, errors: errors)
    }

    private func executeBatch(batchEditsJSON: String, createIfMissing: Bool, context: TaskContext) async throws -> ToolResult {
        let batch: [BatchEdit]
        do {
            let data = batchEditsJSON.data(using: .utf8) ?? Data()
            batch = try JSONDecoder().decode([BatchEdit].self, from: data)
        } catch {
            return ToolResult(output: "batchEdits 参数格式错误：\(error.localizedDescription)\n需要 JSON 数组格式：[{\"path\":\"file.py\",\"edits\":[{\"oldText\":\"旧内容\",\"newText\":\"新内容\"}]}]", success: false, error: "invalid_batch_edits")
        }
        guard !batch.isEmpty else {
            return ToolResult(output: "batchEdits 数组为空", success: false, error: "empty_batch_edits")
        }

        var data: [String: String] = ["batchCount": "\(batch.count)"]
        var summaries: [String] = []
        var failures: [String] = []
        for (index, item) in batch.enumerated() {
            let result = try await executeSingle(path: item.path, edits: item.edits, createIfMissing: createIfMissing, context: context)
            if result.success, let itemData = result.data {
                let prefix = "batch\(index)"
                data["\(prefix).path"] = itemData["path"]
                data["\(prefix).fullPath"] = itemData["fullPath"]
                data["\(prefix).diffOld"] = itemData["diffOld"]
                data["\(prefix).diffNew"] = itemData["diffNew"]
                data["\(prefix).addedLines"] = itemData["addedLines"]
                data["\(prefix).removedLines"] = itemData["removedLines"]
                data["\(prefix).appliedEdits"] = itemData["appliedEdits"]
                data["\(prefix).totalEdits"] = itemData["totalEdits"]
                data["\(prefix).createDirectories"] = itemData["createDirectories"]
                data["\(prefix).hunkCount"] = itemData["hunkCount"]
                for hunkIndex in 0..<(Int(itemData["hunkCount"] ?? "0") ?? 0) {
                    data["\(prefix).hunk\(hunkIndex).oldText"] = itemData["hunk\(hunkIndex).oldText"]
                    data["\(prefix).hunk\(hunkIndex).newText"] = itemData["hunk\(hunkIndex).newText"]
                    data["\(prefix).hunk\(hunkIndex).summary"] = itemData["hunk\(hunkIndex).summary"]
                }
                summaries.append(result.output)
            } else {
                failures.append("\(item.path): \(result.error ?? result.output)")
            }
        }
        guard failures.isEmpty else {
            return ToolResult(output: "批量编辑失败，未生成审查：\n" + failures.joined(separator: "\n"), success: false, error: "batch_failed")
        }
        await AuditLog.shared.record(tool: name, input: "batch \(batch.count) files", output: "prepared batch review", success: true)
        return ToolResult(output: "批量编辑已准备，等待审查：\n" + summaries.joined(separator: "\n"), data: data, success: true)
    }

    private struct FuzzyReplaceResult {
        let content: String
        let matchType: String
    }

    private static func fuzzyReplace(in content: String, oldText: String, newText: String) -> FuzzyReplaceResult? {
        let contentLines = content.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n")
        guard !oldLines.isEmpty else { return nil }

        // Strategy 1: Whitespace-trimmed line matching
        let trimmedOld = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let trimmedSlice = slice.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmedSlice == trimmedOld {
                // Found! Detect indent of matched region and apply to newText
                let matchedIndent = detectIndent(Array(slice))
                let oldIndent = detectIndent(oldLines)
                let adjustedNew = reindent(newText, from: oldIndent, to: matchedIndent)
                var result = contentLines
                result.replaceSubrange(startIdx..<(startIdx + oldLines.count), with: adjustedNew.components(separatedBy: "\n"))
                return FuzzyReplaceResult(content: result.joined(separator: "\n"), matchType: "空白标准化")
            }
        }

        // Strategy 2: Indent-stripped matching (ignore all leading whitespace)
        let strippedOld = oldLines.map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
        for startIdx in 0...(max(0, contentLines.count - oldLines.count)) {
            let slice = contentLines[startIdx..<min(startIdx + oldLines.count, contentLines.count)]
            let strippedSlice = slice.map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
            if strippedSlice == strippedOld {
                let matchedIndent = detectIndent(Array(slice))
                let adjustedNew = reindent(newText, from: 0, to: matchedIndent)
                var result = contentLines
                result.replaceSubrange(startIdx..<(startIdx + oldLines.count), with: adjustedNew.components(separatedBy: "\n"))
                return FuzzyReplaceResult(content: result.joined(separator: "\n"), matchType: "缩进感知")
            }
        }

        return nil
    }

    private static func detectIndent(_ lines: [String]) -> Int {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        return nonEmpty.map { line -> Int in
            var count = 0
            for ch in line {
                if ch == " " { count += 1 }
                else if ch == "\t" { count += 4 }
                else { break }
            }
            return count
        }.min() ?? 0
    }

    private static func reindent(_ text: String, from oldIndent: Int, to newIndent: Int) -> String {
        guard oldIndent != newIndent else { return text }
        let delta = newIndent - oldIndent
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if delta > 0 {
                return String(repeating: " ", count: delta) + line
            } else {
                let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
                let currentIndent = line.count - stripped.count
                let newLineIndent = max(0, currentIndent + delta)
                return String(repeating: " ", count: newLineIndent) + stripped
            }
        }.joined(separator: "\n")
    }

    private func resolveWritePath(path: String, context: TaskContext) throws -> String {
        if path.hasPrefix("/") {
            return path
        }
        guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "FileEditTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先设置工作区。"])
        }
        return (context.workspaceRoot as NSString).appendingPathComponent(path)
    }

    private func makeEditResult(path: String, fullPath: String, oldContent: String, newContent: String, appliedEdits: [EditOp], appliedCount: Int, totalCount: Int, errors: [String]) -> ToolResult {
        let oldLines = oldContent.components(separatedBy: "\n").count
        let newLines = newContent.components(separatedBy: "\n").count

        var summary = "已准备 \(appliedCount)/\(totalCount) 条编辑到 \(path)（\(oldLines)→\(newLines) 行）"
        if !errors.isEmpty {
            summary += "\n部分失败：\n" + errors.joined(separator: "\n")
        }

        var data = [
            "path": path,
            "fullPath": fullPath,
            "diffOld": oldContent,
            "diffNew": newContent,
            "addedLines": "\(max(newLines - oldLines, 0))",
            "removedLines": "\(max(oldLines - newLines, 0))",
            "appliedEdits": "\(appliedCount)",
            "totalEdits": "\(totalCount)",
            "createDirectories": "true",
            "hunkCount": "\(appliedEdits.count)"
        ]
        for (index, edit) in appliedEdits.enumerated() {
            data["hunk\(index).oldText"] = edit.oldText
            data["hunk\(index).newText"] = edit.newText
            data["hunk\(index).summary"] = "Hunk \(index + 1): \(edit.oldText.components(separatedBy: "\n").count)→\(edit.newText.components(separatedBy: "\n").count) 行"
        }

        return ToolResult(
            output: summary,
            data: data,
            success: true
        )
    }
}

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
            buildCommand = custom
        } else {
            let changedFiles = Self.parseChangedFiles(params.changedFiles) + Self.detectChangedFiles(workspaceRoot: workspaceRoot)
            buildCommand = detectBuildCommand(workspaceRoot: workspaceRoot, changedFiles: changedFiles)
        }

        guard !buildCommand.isEmpty else {
            return ToolResult(output: "未检测到构建系统（Package.swift / package.json / Cargo.toml / Makefile / build.sh 均不存在）", success: false, error: "no_build_system")
        }

        // Execute build command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "cd \(shellEscape(workspaceRoot)) && \(buildCommand) 2>&1"]
        process.environment = ProcessInfo.processInfo.environment

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
        let finalContent: String
        if let oldSnippet = params.oldContent, let newSnippet = params.newContent {
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
        process.environment = environment
        if !context.workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Wrap non-Sendable types for closure capture — safe because access is serialized
        // (process only touched after termination, pipes only read after process exits)
        final class UnsafeSendableBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
        let processBox = UnsafeSendableBox(process)
        let stdoutBox = UnsafeSendableBox(stdout)
        let stderrBox = UnsafeSendableBox(stderr)
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
                if processBox.value.isRunning { processBox.value.terminate() }
            }
            timer.resume()

            // Async wait for process exit via NotificationCenter
            let observer = NotificationCenter.default.addObserver(
                forName: Process.didTerminateNotification,
                object: process,
                queue: .main
            ) { _ in
                timer.cancel()
                let exitCode = processBox.value.terminationStatus
                let outData = stdoutBox.value.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrBox.value.fileHandleForReading.readDataToEndOfFile()
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

// MARK: - Search Tool

public struct SearchTool: LaicaiTool {
    public var name: String { "code.search" }
    public var description: String { "在工作区中搜索文件或内容" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "query": FunctionProperty(type: "string", description: "搜索关键词"),
                    "scope": FunctionProperty(
                        type: "string",
                        description: "搜索范围：files（文件名）或 content（文件内容）",
                        enumValues: ["files", "content"]
                    ),
                    "maxResults": FunctionProperty(type: "integer", description: "最大结果数（可选，默认50）")
                ],
                required: ["query"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var query: String
            var scope: String?
            var maxResults: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = params.scope ?? "content"
        let maxResults = params.maxResults ?? 50

        // Reject obviously non-code queries (natural language sentences)
        if query.count > 8 && Self.isLikelyNaturalLanguage(query) {
            return ToolResult(
                output: "搜索词看起来是自然语言，不是代码关键词。请使用函数名、类名、变量名或错误消息等具体关键词搜索。原始查询：\(query)",
                success: false,
                error: "invalid_query"
            )
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return ToolResult(output: "请先设置工作区后再搜索项目。", success: false, error: "workspace_missing")
        }
        guard FileManager.default.fileExists(atPath: root) else {
            return ToolResult(output: "工作区不存在：\(root)", success: false, error: "workspace_not_found")
        }

        if scope == "files" {
            return try searchFiles(query: query, root: root, maxResults: maxResults, contextMode: context.contextMode)
        } else {
            return try searchContent(query: query, root: root, maxResults: maxResults, contextMode: context.contextMode)
        }
    }

    /// Heuristic: detect natural language sentences (not code identifiers)
    private static func isLikelyNaturalLanguage(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Chinese conversational patterns
        let zhConversational = ["你", "我", "吗", "吧", "呢", "啊", "了", "的", "是", "请", "帮", "能不能", "怎么", "为什么", "什么"]
        let zhMatches = zhConversational.filter { lower.contains($0) }.count
        if zhMatches >= 3 { return true }
        // English conversational patterns
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 5 {
            let commonWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "i", "you", "we", "they", "it",
                                             "do", "does", "did", "can", "could", "would", "should", "please", "help", "want"]
            let commonCount = words.filter { commonWords.contains($0.lowercased()) }.count
            if commonCount >= 3 { return true }
        }
        return false
    }

    private func searchFiles(query: String, root: String, maxResults: Int, contextMode: ContextMode = .balanced) throws -> ToolResult {
        let fm = FileManager.default
        var results: [String] = []
        let enumerator = fm.enumerator(atPath: root)
        let ignoredDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".venv", "venv"]
        while let file = enumerator?.nextObject() as? String {
            let filename = (file as NSString).lastPathComponent
            if ignoredDirs.contains(filename) {
                enumerator?.skipDescendants()
                continue
            }
            if filename.localizedCaseInsensitiveContains(query) {
                results.append(file)
                if results.count >= maxResults { break }
            }
        }
        if results.isEmpty {
            return ToolResult(output: "未找到匹配文件：\(query)", success: true)
        }
        return ToolResult(output: results.joined(separator: "\n"), data: ["count": "\(results.count)"])
    }

    private func searchContent(query: String, root: String, maxResults: Int, contextMode: ContextMode = .balanced) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "rg", "--no-heading", "-n", "--max-count", "\(maxResults)",
            "--max-filesize", "1M", "--glob", "!**/.git/**", "--glob", "!**/.build/**",
            "--glob", "!**/node_modules/**", "--glob", "!**/DerivedData/**",
            query, root
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Foundation.Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ToolResult(output: "搜索超时：\(query)", success: false, error: "search_timeout")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.isEmpty {
            return ToolResult(output: "未找到匹配内容：\(query)", success: true)
        }
        let maxChars: Int
        switch contextMode {
        case .economy: maxChars = 3_000
        case .balanced: maxChars = 10_000
        case .deep: maxChars = 50_000
        }
        let truncated = output.count > maxChars ? String(output.prefix(maxChars)) + "\n... (已截断，当前\(contextMode.rawValue)模式)" : output
        let count = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return ToolResult(output: truncated, data: ["query": query, "count": "\(count)"])
    }
}

// MARK: - Workspace Index Tool

public struct WorkspaceIndexTool: LaicaiTool {
    public var name: String { "workspace.index" }
    public var description: String { "生成受控的工作区索引，包含文件树摘要、语言分布、关键配置和入口候选" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "maxFiles": FunctionProperty(type: "integer", description: "最多扫描文件数，默认300"),
                    "maxDepth": FunctionProperty(type: "integer", description: "最多目录深度，默认5")
                ],
                required: []
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var maxFiles: Int?
            var maxDepth: Int?
        }

        let params: Params
        do {
            let data = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: data)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return ToolResult(output: "请先设置工作区后再建立项目索引。", success: false, error: "workspace_missing")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ToolResult(output: "工作区不存在：\(root)", success: false, error: "workspace_not_found")
        }

        let maxFiles = max(20, min(params.maxFiles ?? 300, 1000))
        let maxDepth = max(1, min(params.maxDepth ?? 5, 10))
        let ignored: Set<String> = [
            ".git", ".build", "DerivedData", "node_modules", "__pycache__", ".pytest_cache",
            ".mypy_cache", ".ruff_cache", ".venv", "venv", "venv3", "dist", "build",
            ".DS_Store"
        ]
        let importantNames: Set<String> = [
            "README.md", "AGENTS.md", "CLAUDE.md", "Package.swift", "pyproject.toml",
            "package.json", "Cargo.toml", "go.mod", "Makefile", "Dockerfile", "ROADMAP.md"
        ]

        var files: [String] = []
        var directories: Set<String> = []
        var languageCounts: [String: Int] = [:]
        var important: [String] = []
        var entryCandidates: [String] = []
        var testCandidates: [String] = []
        var configCandidates: [String] = []
        var riskCandidates: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let item = enumerator?.nextObject() as? String {
            let components = item.split(separator: "/").map(String.init)
            let name = components.last ?? item
            let lowerItem = item.lowercased()
            let lowerName = name.lowercased()
            if ignored.contains(name) || components.contains(where: { ignored.contains($0) }) {
                enumerator?.skipDescendants()
                continue
            }
            guard components.count <= maxDepth else {
                if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(item), isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }

            let full = (root as NSString).appendingPathComponent(item)
            var childIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &childIsDirectory)
            if childIsDirectory.boolValue {
                directories.insert(item)
                continue
            }

            files.append(item)
            let ext = (item as NSString).pathExtension.lowercased()
            let language = ext.isEmpty ? name : ext
            languageCounts[language, default: 0] += 1
            if importantNames.contains(name) || item.contains("/Tests/") || item.contains("/tests/") {
                important.append(item)
            }
            if importantNames.contains(name) || ["package.json", "pyproject.toml", "Package.swift", "Cargo.toml", "go.mod", "requirements.txt", "tsconfig.json"].contains(name) {
                configCandidates.append(item)
            }
            if lowerName == "main.swift" || lowerName == "main.py" || lowerName == "app.py" || lowerName == "index.ts" || lowerName == "index.js" || lowerName == "main.ts" || lowerName == "main.js" || lowerItem.contains("/sources/") || lowerItem.contains("/src/") {
                entryCandidates.append(item)
            }
            if lowerItem.contains("/test") || lowerItem.contains("/tests/") || lowerName.hasPrefix("test_") || lowerName.hasSuffix("test.swift") || lowerName.hasSuffix(".test.ts") || lowerName.hasSuffix(".spec.ts") {
                testCandidates.append(item)
            }
            if lowerItem.contains("todo") || lowerItem.contains("fixme") || lowerItem.contains("security") || lowerItem.contains("secret") || lowerItem.contains("auth") || lowerItem.contains("token") || lowerItem.contains("credential") {
                riskCandidates.append(item)
            }
            if files.count >= maxFiles { break }
        }

        let topDirs = directories.sorted().prefix(40)
        let topFiles = files.prefix(120)
        let languages = languageCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.prefix(12)

        // Module boundary detection: group files by top-level source directories
        let moduleBoundaries = Self.detectModuleBoundaries(files: files, directories: directories)

        // Dependency hotspots: files most referenced by import statements
        let dependencyHotspots = Self.detectDependencyHotspots(files: files, root: root)

        // Recent change hotspots: files modified in last 7 days via git
        let recentChanges = Self.detectRecentChangeHotspots(root: root)

        // Call graph: import-based dependency edges between local modules
        let callGraph = Self.detectCallGraph(files: files, root: root)

        // Test coverage: test-to-source mapping by naming convention
        let testCoverage = Self.detectTestCoverage(files: files)

        // Symbol extraction: lightweight regex-based extraction of key symbols from source files
        let symbolIndex = Self.extractSymbols(files: entryCandidates + important, root: root, limit: 40)
        let sourceKitAvailable = Self.commandAvailable("sourcekit-lsp")
        let treeSitterAvailable = Self.commandAvailable("tree-sitter")
        let indexEngine = sourceKitAvailable ? "sourcekit-ready+regex-lightweight" : (treeSitterAvailable ? "tree-sitter-ready+regex-lightweight" : "regex-lightweight")

        let output = """
        工作区：\(root)
        已索引：\(files.count) 个文件，\(directories.count) 个目录（上限 \(maxFiles) 文件，深度 \(maxDepth)）
        索引引擎：\(indexEngine)

        语言/类型分布：
        \(languages.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))

        关键文件：
        \((important.isEmpty ? Array(topFiles.prefix(20)) : Array(important.prefix(40))).map { "- \($0)" }.joined(separator: "\n"))

        入口候选：
        \(entryCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        测试候选：
        \(testCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        配置候选：
        \(configCandidates.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

        风险/关注候选：
        \((riskCandidates.isEmpty ? ["- 暂未从路径名发现明显风险文件"] : riskCandidates.prefix(30).map { "- \($0)" }).joined(separator: "\n"))

        模块边界：
        \(moduleBoundaries.isEmpty ? "- 未检测到明显模块分区" : moduleBoundaries.prefix(15).map { "- \($0)" }.joined(separator: "\n"))

        符号索引（关键类型与函数）：
        \(symbolIndex.isEmpty ? "- 未提取到符号" : symbolIndex.prefix(60).map { "- \($0)" }.joined(separator: "\n"))

        依赖热点（被最多文件引用）：
        \(dependencyHotspots.isEmpty ? "- 未检测到明显依赖热点" : dependencyHotspots.prefix(10).map { "- \($0)" }.joined(separator: "\n"))

        最近改动热点（7天内）：
        \(recentChanges.isEmpty ? "- 暂无最近改动记录" : recentChanges.prefix(15).map { "- \($0)" }.joined(separator: "\n"))

        调用图（模块间依赖）：
        \(callGraph.isEmpty ? "- 未检测到模块间调用关系" : callGraph.map { "- \($0)" }.joined(separator: "\n"))

        测试覆盖关系：
        \(testCoverage.isEmpty ? "- 未检测到测试文件" : testCoverage.map { "- \($0)" }.joined(separator: "\n"))

        顶层/重要目录：
        \(topDirs.map { "- \($0)/" }.joined(separator: "\n"))

        文件样例：
        \(topFiles.map { "- \($0)" }.joined(separator: "\n"))
        """

        await AuditLog.shared.record(
            tool: name,
            input: argumentsJSON,
            output: "索引 \(files.count) 个文件，\(directories.count) 个目录",
            success: true
        )

        return ToolResult(
            output: output,
            data: [
                "fileCount": "\(files.count)",
                "directoryCount": "\(directories.count)",
                "entryCount": "\(entryCandidates.count)",
                "testCount": "\(testCandidates.count)",
                "configCount": "\(configCandidates.count)",
                "riskCount": "\(riskCandidates.count)",
                "root": root,
                "indexEngine": indexEngine,
                "sourceKitAvailable": "\(sourceKitAvailable)",
                "treeSitterAvailable": "\(treeSitterAvailable)"
            ]
        )
    }

    // MARK: - Workspace Analysis Helpers

    private static func commandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Detect module boundaries by grouping files under common top-level source directories.
    private static func detectModuleBoundaries(files: [String], directories: Set<String>) -> [String] {
        let sourcePrefixes = ["Sources/", "src/", "lib/", "app/", "pkg/", "internal/", "cmd/", "modules/"]
        var moduleGroups: [String: (count: Int, languages: Set<String>)] = [:]

        for file in files {
            let components = file.components(separatedBy: "/")
            guard components.count >= 2 else { continue }
            // Find the first source-like prefix
            if let sourceIdx = components.firstIndex(where: { sourcePrefixes.contains($0 + "/") }) {
                // Module = the directory right after the source prefix
                let moduleIdx = sourceIdx + 1
                if moduleIdx < components.count {
                    let moduleName = components[moduleIdx]
                    let ext = (file as NSString).pathExtension.lowercased()
                    if !moduleName.isEmpty {
                        if moduleGroups[moduleName] == nil {
                            moduleGroups[moduleName] = (1, [ext])
                        } else {
                            moduleGroups[moduleName]!.count += 1
                            moduleGroups[moduleName]!.languages.insert(ext)
                        }
                    }
                }
            }
        }

        return moduleGroups.sorted { $0.value.count > $1.value.count }.map { module in
            let langs = module.value.languages.sorted().prefix(3).joined(separator: "/")
            return "\(module.key)（\(module.value.count) 文件，\(langs)）"
        }
    }

    /// Detect dependency hotspots by scanning import statements.
    private static func detectDependencyHotspots(files: [String], root: String) -> [String] {
        var importCounts: [String: Int] = [:]
        let importPatterns: [(prefix: String, extract: (String) -> String?)] = [
            // Swift: import Foo or import struct Foo.Bar
            ("import ", { line in
                let parts = line.dropFirst("import ".count).split(separator: " ", maxSplits: 1)
                return parts.first.map { String($0) }
            }),
            // Python: from foo import bar or import foo
            ("from ", { line in
                let parts = line.dropFirst("from ".count).split(separator: " ", maxSplits: 1)
                return parts.first.map { String($0) }
            }),
            ("import ", { line in
                let parts = line.dropFirst("import ".count).split(separator: ",", maxSplits: 1)
                return parts.first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }),
            // JS/TS: import ... from 'foo'
            ("from '", { line in
                if let start = line.range(of: "from '")?.upperBound,
                   let end = line[start...].firstIndex(of: "'") {
                    return String(line[start..<end])
                }
                return nil
            }),
            ("from \"", { line in
                if let start = line.range(of: "from \"")?.upperBound,
                   let end = line[start...].firstIndex(of: "\"") {
                    return String(line[start..<end])
                }
                return nil
            }),
        ]

        for file in files.prefix(80) {
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n").prefix(60) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for pattern in importPatterns {
                    if trimmed.hasPrefix(pattern.prefix), let module = pattern.extract(trimmed), !module.isEmpty {
                        importCounts[module, default: 0] += 1
                    }
                }
            }
        }

        return importCounts.sorted { $0.value > $1.value }.map { "\($0.key)（被 \($0.value) 个文件引用）" }
    }

    /// Detect recently changed files via `git log --since=7.days`.
    private static func detectRecentChangeHotspots(root: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "log", "--name-only", "--pretty=format:", "--since=7.days", "--no-merges"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let files = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var counts: [String: Int] = [:]
            for file in files { counts[file, default: 0] += 1 }
            return counts.sorted { $0.value > $1.value }.map { "\($0.key)（\($0.value) 次改动）" }
        } catch {
            return []
        }
    }

    /// Infer call graph edges from import chains (A imports B → A depends on B).
    private static func detectCallGraph(files: [String], root: String) -> [String] {
        var edges: [String: Set<String>] = [:]  // file → set of imported local modules
        let localPrefixes = files.map { (file: String) -> String in
            let components = file.components(separatedBy: "/")
            return components.count >= 2 ? components[0] : ""
        }
        let uniqueLocalPrefixes = Set(localPrefixes).filter { !$0.isEmpty }

        for file in files.prefix(60) {
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { continue }
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            var localImports: Set<String> = []
            for line in content.components(separatedBy: "\n").prefix(40) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Swift: import ModuleName
                if ext == "swift" && trimmed.hasPrefix("import ") {
                    let module = String(trimmed.dropFirst("import ".count).split(separator: " ").first ?? "")
                    if uniqueLocalPrefixes.contains(module) { localImports.insert(module) }
                }
                // Python: from pkg import or import pkg
                if ext == "py" && (trimmed.hasPrefix("from ") || trimmed.hasPrefix("import ")) {
                    let pkg = trimmed.hasPrefix("from ")
                        ? String(trimmed.dropFirst("from ".count).split(separator: " ").first ?? "")
                        : String(trimmed.dropFirst("import ".count).split(separator: ",").first?.split(separator: " ").first ?? "")
                    if uniqueLocalPrefixes.contains(pkg) { localImports.insert(pkg) }
                }
                // Go: import "pkg" or import alias "pkg"
                if ext == "go" && trimmed.contains("import") {
                    if let range = trimmed.range(of: "\""), let endRange = trimmed.range(of: "\"", range: range.upperBound..<trimmed.endIndex) {
                        let pkg = String(trimmed[range.upperBound..<endRange.lowerBound])
                        let leaf = (pkg as NSString).lastPathComponent
                        if uniqueLocalPrefixes.contains(leaf) { localImports.insert(leaf) }
                    }
                }
            }
            if !localImports.isEmpty {
                let fileModule = file.components(separatedBy: "/").first ?? file
                edges[fileModule, default: []].formUnion(localImports)
            }
        }
        return edges.sorted { $0.value.count > $1.value.count }.prefix(12).map { edge in
            let targets = edge.value.sorted().joined(separator: " → ")
            return "\(edge.key) → \(targets)"
        }
    }

    /// Detect test-to-source coverage mapping by naming convention.
    private static func detectTestCoverage(files: [String]) -> [String] {
        let testPatterns = ["Test", "Spec", "test", "spec", "_test", "_spec"]
        let testFiles = files.filter { file in
            let name = (file as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { return false }
            return testPatterns.contains(where: { name.contains($0) })
        }
        let sourceFiles = files.filter { file in
            let name = (file as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension.lowercased()
            guard ["swift", "py", "js", "ts", "go"].contains(ext) else { return false }
            return !testPatterns.contains(where: { name.contains($0) })
        }

        var coverageMap: [String: [String]] = [:]  // source → [test files]
        for testFile in testFiles {
            let testName = (testFile as NSString).lastPathComponent
            // Strip test suffixes to find matching source
            var baseName = testName
            for suffix in ["Tests.swift", "Test.swift", "Spec.swift", "_test.py", "_spec.py", ".test.js", ".test.ts", ".spec.js", ".spec.ts", "_test.go"] {
                if baseName.hasSuffix(suffix) {
                    baseName = String(baseName.dropLast(suffix.count))
                    break
                }
            }
            // Find matching source files
            for sourceFile in sourceFiles {
                let sourceName = (sourceFile as NSString).lastPathComponent
                let sourceBase = (sourceName as NSString).deletingPathExtension
                if sourceBase == baseName || sourceBase.hasPrefix(baseName) || baseName.hasPrefix(sourceBase) {
                    coverageMap[sourceFile, default: []].append(testFile)
                }
            }
        }

        let covered = coverageMap.count
        let uncovered = sourceFiles.count - covered
        var lines: [String] = []
        if !testFiles.isEmpty {
            lines.append("测试文件 \(testFiles.count) 个，覆盖源文件 \(covered)/\(sourceFiles.count)")
        }
        if uncovered > 0 && uncovered <= sourceFiles.count {
            lines.append("未覆盖源文件 \(uncovered) 个")
        }
        for (source, tests) in coverageMap.sorted(by: { $0.value.count > $1.value.count }).prefix(8) {
            let testNames = tests.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            lines.append("  \((source as NSString).lastPathComponent) ← \(testNames)")
        }
        return lines
    }

    /// Extract key symbols (functions, types, classes, protocols) from source files using regex
    /// and sourcekit-lsp when available for Swift files.
    private static func extractSymbols(files: [String], root: String, limit: Int) -> [String] {
        let sourceKitAvailable = commandAvailable("sourcekit-lsp")
        var result: [String] = []
        let uniqueFiles = Array(Set(files))

        // If sourcekit-lsp is available, use it for Swift files first
        if sourceKitAvailable {
            let swiftFiles = uniqueFiles.filter { (file: String) -> Bool in
                (file as NSString).pathExtension.lowercased() == "swift"
            }.prefix(limit)
            for file in swiftFiles {
                let fullPath = (root as NSString).appendingPathComponent(file)
                let symbols = extractSymbolsViaSourceKit(filePath: fullPath)
                if !symbols.isEmpty {
                    let shortPath = (file as NSString).lastPathComponent
                    result.append("\(shortPath): \(symbols.prefix(10).joined(separator: ", "))")
                }
            }
            let nonSwiftFiles = uniqueFiles.filter { (file: String) -> Bool in
                (file as NSString).pathExtension.lowercased() != "swift"
            }.prefix(max(0, limit - result.count))
            result.append(contentsOf: extractSymbolsViaRegex(files: Array(nonSwiftFiles), root: root, limit: limit - result.count))
        } else {
            result = extractSymbolsViaRegex(files: uniqueFiles, root: root, limit: limit)
        }
        return result
    }

    /// Regex-based symbol extraction (original logic, extracted for reuse)
    private static func extractSymbolsViaRegex(files: [String], root: String, limit: Int) -> [String] {
        let patterns: [(ext: String, pattern: String)] = [
            ("swift", #"(?:public\s+|private\s+|internal\s+|open\s+)?(?:final\s+)?(?:class|struct|enum|protocol|actor)\s+(\w+)"#),
            ("swift", #"(?:public\s+|private\s+|internal\s+|open\s+)?func\s+(\w+)\s*\("#),
            ("py", #"(?:class|def)\s+(\w+)\s*[\(:]"#),
            ("ts", #"(?:export\s+)?(?:class|interface|type|function|const)\s+(\w+)"#),
            ("js", #"(?:export\s+)?(?:class|function|const)\s+(\w+)"#),
            ("go", #"(?:func|type)\s+(\w+)"#),
            ("rs", #"(?:pub\s+)?(?:fn|struct|enum|trait|impl|type)\s+(\w+)"#),
        ]

        var compiled: [String: [NSRegularExpression]] = [:]
        for (ext, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) {
                compiled[ext, default: []].append(regex)
            }
        }

        var result: [String] = []
        for file in files.prefix(limit) {
            let ext = (file as NSString).pathExtension.lowercased()
            guard let regexes = compiled[ext] else { continue }
            let fullPath = (root as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let linesToScan = content.components(separatedBy: "\n").prefix(200).joined(separator: "\n")
            let nsStr = linesToScan as NSString
            var fileSymbols: [String] = []

            for regex in regexes {
                let matches = regex.matches(in: linesToScan, range: NSRange(location: 0, length: nsStr.length))
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let name = nsStr.substring(with: match.range(at: 1))
                        if name.count >= 2 && !name.hasPrefix("_") {
                            fileSymbols.append(name)
                        }
                    }
                }
            }

            if !fileSymbols.isEmpty {
                let shortPath = (file as NSString).lastPathComponent
                let symbols = Array(Set(fileSymbols)).sorted().prefix(8).joined(separator: ", ")
                result.append("\(shortPath): \(symbols)")
            }
        }
        return result
    }

    /// Use sourcekit-lsp to extract Swift symbols with kind info (class/struct/func/etc.)
    private static func extractSymbolsViaSourceKit(filePath: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sourcekit-lsp", "query", "-file", filePath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // sourcekit-lsp doesn't have a direct query CLI; fall back to using
        // `swift-ide-test` or regex — use enhanced regex with kind annotation
        // For now, use a richer regex pattern that captures the keyword + name
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n").prefix(300)
        var symbols: [String] = []
        let typePattern = #"^\s*(?:public\s+|private\s+|internal\s+|open\s+)?(?:final\s+)?(class|struct|enum|protocol|actor)\s+(\w+)"#
        let funcPattern = #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|override\s+|static\s+|class\s+)*func\s+(\w+)\s*[\(<]"#
        let varPattern = #"^\s*(?:public\s+|private\s+|internal\s+)?(?:static\s+|class\s+)?(?:let|var)\s+(\w+)\s*[:=]"#

        if let typeRegex = try? NSRegularExpression(pattern: typePattern),
           let funcRegex = try? NSRegularExpression(pattern: funcPattern),
           let varRegex = try? NSRegularExpression(pattern: varPattern) {
            let nsContent = lines.joined(separator: "\n") as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)

            for match in typeRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 2 {
                    let kind = nsContent.substring(with: match.range(at: 1))
                    let name = nsContent.substring(with: match.range(at: 2))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("\(kind) \(name)") }
                }
            }
            for match in funcRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 1 {
                    let name = nsContent.substring(with: match.range(at: 1))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("func \(name)") }
                }
            }
            for match in varRegex.matches(in: nsContent as String, range: fullRange) {
                if match.numberOfRanges > 1 {
                    let name = nsContent.substring(with: match.range(at: 1))
                    if name.count >= 2 && !name.hasPrefix("_") { symbols.append("var \(name)") }
                }
            }
        }
        return symbols
    }
}

// MARK: - Web Search Tool

public struct WebSearchTool: LaicaiTool {
    public var name: String { "web.search" }
    public var description: String { "联网搜索最新公开网页信息，适合今天、最新、新闻、趋势等问题" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "query": FunctionProperty(type: "string", description: "搜索关键词，包含必要的日期或来源限定"),
                    "maxResults": FunctionProperty(type: "integer", description: "最大结果数（可选，默认5）")
                ],
                required: ["query"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var query: String
            var maxResults: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let query = Self.normalizedFreshnessQuery(params.query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else {
            return ToolResult(output: "搜索关键词不能为空。", success: false, error: "empty_query")
        }

        let limit = max(1, min(params.maxResults ?? 5, 10))
        do {
            let results = try await Self.searchDuckDuckGo(query: query, limit: limit)
            let fallbackResults = results.isEmpty ? try await Self.searchHackerNews(query: query, limit: limit) : results
            guard !fallbackResults.isEmpty else {
                return ToolResult(output: "未找到网页搜索结果：\(query)", data: ["query": query, "count": "0"], success: true)
            }

            let output = fallbackResults.enumerated().map { index, item in
                "\(index + 1). \(item.title)\n\(item.url)\n\(item.snippet)"
            }.joined(separator: "\n\n")

            await AuditLog.shared.record(
                tool: name,
                input: query,
                output: "找到 \(fallbackResults.count) 条网页结果",
                success: true
            )

            return ToolResult(output: output, data: ["query": query, "count": "\(fallbackResults.count)"])
        } catch {
            return ToolResult(output: "联网搜索失败：\(error.localizedDescription)", success: false, error: "network_error")
        }
    }

    private struct SearchResult {
        var title: String
        var url: String
        var snippet: String
    }

    private static func normalizedFreshnessQuery(_ query: String) -> String {
        let freshnessMarkers = ["今天", "今日", "最新", "新闻", "趋势", "today", "latest", "news"]
        guard freshnessMarkers.contains(where: { query.localizedCaseInsensitiveContains($0) }) else {
            return query
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        let today = formatter.string(from: Date())

        var normalized = query.replacingOccurrences(
            of: #"\d{4}年\d{1,2}月\d{1,2}日"#,
            with: today,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\d{4}-\d{1,2}-\d{1,2}"#,
            with: today,
            options: .regularExpression
        )
        if !normalized.contains(today) && (normalized.contains("今天") || normalized.localizedCaseInsensitiveContains("today")) {
            normalized += " \(today)"
        }
        return normalized
    }

    private static func searchDuckDuckGo(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 Laicai/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else { return [] }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseDuckDuckGoHTML(html, limit: limit)
    }

    private static func searchHackerNews(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://hn.algolia.com/api/v1/search_by_date")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "\(limit)")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else { return [] }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hits = json["hits"] as? [[String: Any]]
        else {
            return []
        }

        return hits.compactMap { hit in
            guard let title = hit["title"] as? String ?? hit["story_title"] as? String else { return nil }
            let url = (hit["url"] as? String) ?? "https://news.ycombinator.com/item?id=\(hit["objectID"] as? String ?? "")"
            let author = hit["author"] as? String ?? "HN"
            let createdAt = hit["created_at"] as? String ?? ""
            let snippet = "Hacker News · \(author) · \(createdAt)"
            return SearchResult(title: title, url: url, snippet: snippet)
        }
    }

    private static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [SearchResult] {
        let titlePattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>|<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>"#

        let titleMatches = matches(pattern: titlePattern, in: html)
        let snippets = matches(pattern: snippetPattern, in: html).map { match in
            match.dropFirst().first { !$0.isEmpty } ?? ""
        }

        return titleMatches.prefix(limit).enumerated().map { index, match in
            let url = decodeHTML(match[safe: 1] ?? "")
            let title = cleanHTML(match[safe: 2] ?? "搜索结果")
            let snippet = index < snippets.count ? cleanHTML(snippets[index]) : ""
            return SearchResult(title: title, url: url, snippet: snippet)
        }
    }

    private static func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).map { match in
            (0..<match.numberOfRanges).map { idx in
                guard let range = Range(match.range(at: idx), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private static func cleanHTML(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTML(withoutTags)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

// MARK: - Web Fetch Tool

public struct WebFetchTool: LaicaiTool {
    public var name: String { "web.fetch" }
    public var description: String { "读取指定网页 URL，抽取标题和正文摘要，适合用户直接给链接的任务" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "url": FunctionProperty(type: "string", description: "要读取的 http/https 网页 URL"),
                    "maxCharacters": FunctionProperty(type: "integer", description: "最多返回字符数，默认8000")
                ],
                required: ["url"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var url: String
            var maxCharacters: Int?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let rawURL = params.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return ToolResult(output: "请输入有效的 http/https 网页链接。", success: false, error: "invalid_url")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("Mozilla/5.0 Laicai/0.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                return ToolResult(output: "网页读取失败（HTTP \(statusCode)）：\(rawURL)", success: false, error: "http_\(statusCode)")
            }

            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? ""
            let readable = Self.extractReadableText(fromHTML: html, url: rawURL, maxCharacters: params.maxCharacters ?? 8000)

            await AuditLog.shared.record(
                tool: name,
                input: rawURL,
                output: "读取网页 \(readable.title)，\(readable.content.count) 字符",
                success: true
            )

            let output = """
            标题：\(readable.title)
            URL：\(rawURL)

            \(readable.content)
            """
            return ToolResult(
                output: output,
                data: [
                    "url": rawURL,
                    "title": readable.title,
                    "size": "\(readable.content.count)"
                ],
                success: true
            )
        } catch {
            return ToolResult(output: "网页读取失败：\(error.localizedDescription)", success: false, error: "network_error")
        }
    }

    public static func extractReadableText(fromHTML html: String, url: String, maxCharacters: Int) -> (title: String, content: String) {
        let title = firstMatch(pattern: #"<title[^>]*>(.*?)</title>"#, in: html)
            .map(cleanHTML(_:))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: url)?.host
            ?? "网页"

        var body = html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<nav[^>]*>.*?</nav>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<footer[^>]*>.*?</footer>"#, with: " ", options: .regularExpression)
        body = cleanHTML(body)

        let limit = max(500, min(maxCharacters, 30000))
        if body.count > limit {
            body = String(body.prefix(limit)) + "\n...（网页内容已截断）"
        }
        return (title, body)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func cleanHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Git Tool

public struct GitTool: LaicaiTool {
    public var name: String { "git" }
    public var description: String { "执行 git 操作（diff, status, log, branch, add, commit 等）" }

    private static let readOnlySubcommands = ["diff", "status", "log", "branch", "show", "stash list", "remote", "tag"]
    private static let safeWriteSubcommands = ["add", "commit", "commit-auto", "checkout", "switch", "branch-create", "pr-desc"]
    private static let dangerousPatterns = ["push --force", "reset --hard", "clean -fd", "rebase", "push -f"]

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "subcommand": FunctionProperty(type: "string", description: "git 子命令（diff, status, log, add, commit, commit-auto, checkout, branch-create, pr-desc 等）"),
                    "args": FunctionProperty(type: "string", description: "子命令参数。commit 时传 -m \"message\"；commit-auto 留空自动生成信息；branch-create 传分支名；pr-desc 自动生成 PR 描述")
                ],
                required: ["subcommand"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var subcommand: String
            var args: String?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let subcommand = params.subcommand
        let args = params.args ?? ""
        let fullCommand = "git \(subcommand) \(args)".trimmingCharacters(in: .whitespaces)
        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.requiresRepository(subcommand), !Self.isGitRepository(root) {
            let message = root.isEmpty
                ? "当前没有设置工作区，无法执行 git \(subcommand)。"
                : "当前工作区不是 git 仓库：\(root)。可以继续用文件搜索和读取工具完成任务。"
            await AuditLog.shared.record(
                tool: name,
                input: fullCommand,
                output: message,
                success: true
            )
            return ToolResult(
                output: message,
                data: ["command": fullCommand, "repository": "false"],
                success: true
            )
        }

        // Dangerous command guard
        let fullCmd = "git \(subcommand) \(args)"
        if Self.dangerousPatterns.contains(where: { fullCmd.contains($0) }) {
            return ToolResult(
                output: "安全拦截：\(fullCmd) 是破坏性操作，不允许自动执行。请手动在终端执行。",
                data: ["command": fullCmd, "blocked": "true"],
                success: false,
                error: "dangerous_command"
            )
        }

        if subcommand == "commit-auto" {
            return try await Self.commitAuto(messageHint: args, context: context)
        }

        if subcommand == "branch-create" {
            return try await Self.branchCreate(name: args, context: context)
        }

        if subcommand == "pr-desc" {
            return try await Self.generatePRDescription(context: context)
        }

        if Self.isSafeWrite(subcommand) {
            // Safe writes (add, commit) execute directly
            let shellParams = ["command": fullCommand, "timeout": "30"]
            return try await ShellTool().execute(params: shellParams, context: context)
        }

        if !Self.isReadOnly(subcommand) {
            // Other write operations need review
            return ToolResult(
                output: "写操作需审查：\(fullCommand)",
                data: ["command": fullCommand, "needsReview": "true"],
                success: true
            )
        }

        let shellParams = ["command": fullCommand, "timeout": "15"]
        return try await ShellTool().execute(params: shellParams, context: context)
    }

    private static func isReadOnly(_ subcommand: String) -> Bool {
        readOnlySubcommands.contains { subcommand.hasPrefix($0) }
    }

    private static func isSafeWrite(_ subcommand: String) -> Bool {
        safeWriteSubcommands.contains { subcommand.hasPrefix($0) }
    }

    private static func requiresRepository(_ subcommand: String) -> Bool {
        let clean = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["diff", "status", "log", "branch", "show", "stash", "remote", "tag", "add", "commit", "commit-auto", "checkout"]
            .contains { clean.hasPrefix($0) }
    }

    private static func commitAuto(messageHint: String, context: TaskContext) async throws -> ToolResult {
        let statusResult = try await ShellTool().execute(params: ["command": "git status --short", "timeout": "15"], context: context)
        guard statusResult.success else { return statusResult }
        let statusLines = statusResult.output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !statusLines.isEmpty else {
            return ToolResult(output: "没有可提交的变更。", data: ["exitCode": "0"], success: true)
        }
        let message = messageHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.generateCommitMessage(fromStatusLines: statusLines)
            : messageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "git add -A && git commit -m \"\(escapedMessage)\""
        let result = try await ShellTool().execute(params: ["command": command, "timeout": "60"], context: context)
        var data = result.data ?? [:]
        data["message"] = message
        return ToolResult(output: result.output, data: data, success: result.success, error: result.error)
    }

    private static func generateCommitMessage(fromStatusLines lines: [String]) -> String {
        let changedFiles = lines.map { String($0.dropFirst(min(3, $0.count))).trimmingCharacters(in: .whitespacesAndNewlines) }
        let lower = changedFiles.joined(separator: " ").lowercased()
        let scope: String
        if lower.contains("test") {
            scope = "test"
        } else if lower.contains("ui") || lower.contains("view") {
            scope = "ui"
        } else if lower.contains("tool") || lower.contains("agent") {
            scope = "agent"
        } else {
            scope = "app"
        }
        let verb = lines.contains { $0.hasPrefix("A ") || $0.hasPrefix("??") } ? "add" : "update"
        return "\(verb)(\(scope)): refine \(changedFiles.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))"
    }

    private static func branchCreate(name: String, context: TaskContext) async throws -> ToolResult {
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            return ToolResult(output: "请提供分支名称", success: false, error: "missing_branch_name")
        }
        // Sanitize branch name
        let sanitized = branchName.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-_/.")).inverted)
            .joined()
        let command = "git checkout -b \(sanitized)"
        let result = try await ShellTool().execute(params: ["command": command, "timeout": "15"], context: context)
        var data = result.data ?? [:]
        data["branch"] = sanitized
        return ToolResult(output: result.output, data: data, success: result.success, error: result.error)
    }

    private static func generatePRDescription(context: TaskContext) async throws -> ToolResult {
        // Get diff against main/master
        let branchResult = try await ShellTool().execute(params: ["command": "git rev-parse --abbrev-ref HEAD", "timeout": "10"], context: context)
        let currentBranch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try main, then master as base
        var base = "main"
        let checkMain = try await ShellTool().execute(params: ["command": "git rev-parse --verify main 2>/dev/null", "timeout": "10"], context: context)
        if !checkMain.success {
            base = "master"
        }

        let diffResult = try await ShellTool().execute(params: ["command": "git log \(base)..HEAD --oneline", "timeout": "15"], context: context)
        let commits = diffResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let statResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD --stat", "timeout": "15"], context: context)
        let stat = statResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get changed file list for categorization
        let filesResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD --name-only", "timeout": "15"], context: context)
        let changedFiles = filesResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").filter { !$0.isEmpty }

        // Categorize changed files
        var sourceFiles: [String] = []
        var testFiles: [String] = []
        var configFiles: [String] = []
        var otherFiles: [String] = []
        for file in changedFiles {
            let lower = file.lowercased()
            if lower.contains("/test") || lower.contains("/tests/") || lower.hasSuffix("test.swift") || lower.hasSuffix(".test.ts") || lower.hasSuffix(".spec.ts") || lower.hasSuffix("_test.go") || lower.hasSuffix("_test.py") {
                testFiles.append(file)
            } else if lower.hasSuffix(".swift") || lower.hasSuffix(".py") || lower.hasSuffix(".ts") || lower.hasSuffix(".js") || lower.hasSuffix(".go") || lower.hasSuffix(".rs") {
                sourceFiles.append(file)
            } else if lower.hasSuffix(".json") || lower.hasSuffix(".toml") || lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.hasSuffix(".xml") || lower.hasSuffix(".swift") && lower.contains("package") || lower.contains("package.") || lower.contains("tsconfig") || lower.contains(".env") || lower.contains("dockerfile") || lower.contains("makefile") {
                configFiles.append(file)
            } else {
                otherFiles.append(file)
            }
        }

        // Detect potential breaking changes
        var breakingChangeHints: [String] = []
        let diffContentResult = try await ShellTool().execute(params: ["command": "git diff \(base)..HEAD -- '*.swift' '*.py' '*.ts' '*.js' '*.go' | head -200", "timeout": "15"], context: context)
        let diffContent = diffContentResult.output
        if diffContent.contains("-public ") && !diffContent.contains("+public ") {
            breakingChangeHints.append("移除了 public API")
        }
        if diffContent.contains("-protocol ") || diffContent.contains("-interface ") {
            breakingChangeHints.append("移除了协议/接口定义")
        }
        if diffContent.contains("-func ") && diffContent.contains("+func ") {
            breakingChangeHints.append("函数签名可能变更")
        }

        let title = currentBranch.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        var description = "## \(title)\n\n"
        description += "### 变更概览\n\(stat)\n\n"

        if !sourceFiles.isEmpty {
            description += "### 源文件变更（\(sourceFiles.count)）\n"
            for f in sourceFiles.prefix(20) { description += "- `\(f)`\n" }
            description += "\n"
        }
        if !testFiles.isEmpty {
            description += "### 测试文件变更（\(testFiles.count)）\n"
            for f in testFiles.prefix(10) { description += "- `\(f)`\n" }
            description += "\n"
        }
        if !configFiles.isEmpty {
            description += "### 配置文件变更（\(configFiles.count)）\n"
            for f in configFiles.prefix(10) { description += "- `\(f)`\n" }
            description += "\n"
        }

        if !breakingChangeHints.isEmpty {
            description += "### ⚠️ 潜在破坏性变更\n"
            for hint in breakingChangeHints { description += "- \(hint)\n" }
            description += "\n"
        }

        description += "### 提交记录\n\(commits)\n"

        return ToolResult(
            output: description,
            data: ["branch": currentBranch, "base": base, "commitCount": "\(commits.components(separatedBy: "\n").filter { !$0.isEmpty }.count)", "sourceFileCount": "\(sourceFiles.count)", "testFileCount": "\(testFiles.count)", "configFileCount": "\(configFiles.count)", "hasBreakingChanges": "\(breakingChangeHints.isEmpty ? "false" : "true")"],
            success: true
        )
    }

    public static func isGitRepository(_ workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, FileManager.default.fileExists(atPath: root) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--is-inside-work-tree"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - ComfyUI Image Generation Tool

public struct ComfyUITool: LaicaiTool {
    public var name: String { "image.generate" }
    public var description: String { "使用本地 ComfyUI 根据文字描述生成图片。需先启动 ComfyUI 服务。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "prompt": FunctionProperty(type: "string", description: "图片的文字描述，尽量详细，包括风格、构图、色彩等"),
                    "negativePrompt": FunctionProperty(type: "string", description: "不想出现的内容描述（可选）"),
                    "width": FunctionProperty(type: "integer", description: "图片宽度（可选，默认 1024）"),
                    "height": FunctionProperty(type: "integer", description: "图片高度（可选，默认 1024）"),
                    "steps": FunctionProperty(type: "integer", description: "采样步数（可选，默认 20）"),
                    "seed": FunctionProperty(type: "integer", description: "随机种子（可选，默认 -1 随机）")
                ],
                required: ["prompt"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var prompt: String
            var negativePrompt: String?
            var width: Int?
            var height: Int?
            var steps: Int?
            var seed: Int?
        }

        let params: Params
        do {
            let data = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: data)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let serverURL = context.comfyUIServerURL ?? "http://127.0.0.1:8188"
        let modelName = context.comfyUIModelName ?? ""

        // Check if ComfyUI is running
        guard await isServerReachable(serverURL) else {
            return ToolResult(
                output: "ComfyUI 服务未启动。请先启动 ComfyUI（默认地址 \(serverURL)），然后再生成图片。",
                success: false,
                error: "comfyui_offline"
            )
        }

        if modelName.isEmpty {
            return ToolResult(
                output: "未配置 ComfyUI 模型。请先在设置中填写模型名称（checkpoint 文件名）。",
                success: false,
                error: "comfyui_model_missing"
            )
        }

        do {
            let imagePath = try await generateImage(
                serverURL: serverURL,
                modelName: modelName,
                prompt: params.prompt,
                negativePrompt: params.negativePrompt ?? "",
                width: max(256, min(params.width ?? 1024, 2048)),
                height: max(256, min(params.height ?? 1024, 2048)),
                steps: max(1, min(params.steps ?? 20, 50)),
                seed: params.seed ?? -1,
                outputDir: context.workspaceRoot
            )

            await AuditLog.shared.record(
                tool: name,
                input: params.prompt,
                output: "生成图片：\(imagePath)",
                success: true
            )

            return ToolResult(
                output: "图片已生成：\(imagePath)",
                data: ["imagePath": imagePath, "prompt": params.prompt],
                success: true
            )
        } catch {
            return ToolResult(
                output: "图片生成失败：\(error.localizedDescription)",
                success: false,
                error: "comfyui_error"
            )
        }
    }

    private func isServerReachable(_ url: String) async -> Bool {
        guard let url = URL(string: "\(url)/system_stats") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func generateImage(
        serverURL: String,
        modelName: String,
        prompt: String,
        negativePrompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: Int,
        outputDir: String
    ) async throws -> String {
        let clientId = "laicai-\(UUID().uuidString.prefix(8))"

        // Build a basic text-to-image workflow
        let workflow: [String: [String: Any]] = [
            "3": [
                "class_type": "KSampler",
                "inputs": [
                    "cfg": 7,
                    "denoise": 1,
                    "latent_image": ["5", 0] as [Any],
                    "model": ["4", 0] as [Any],
                    "negative": ["7", 0] as [Any],
                    "positive": ["6", 0] as [Any],
                    "sampler_name": "euler",
                    "scheduler": "normal",
                    "seed": seed == -1 ? Int.random(in: 0...Int.max) : seed,
                    "steps": steps
                ] as [String: Any]
            ],
            "4": [
                "class_type": "CheckpointLoaderSimple",
                "inputs": ["ckpt_name": modelName] as [String: Any]
            ],
            "5": [
                "class_type": "EmptyLatentImage",
                "inputs": ["batch_size": 1, "height": height, "width": width] as [String: Any]
            ],
            "6": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1] as [Any],
                    "text": prompt
                ] as [String: Any]
            ],
            "7": [
                "class_type": "CLIPTextEncode",
                "inputs": [
                    "clip": ["4", 1] as [Any],
                    "text": negativePrompt
                ] as [String: Any]
            ],
            "8": [
                "class_type": "VAEDecode",
                "inputs": [
                    "samples": ["3", 0] as [Any],
                    "vae": ["4", 2] as [Any]
                ] as [String: Any]
            ],
            "9": [
                "class_type": "SaveImage",
                "inputs": [
                    "filename_prefix": "Laicai",
                    "images": ["8", 0] as [Any]
                ] as [String: Any]
            ]
        ]

        // Submit prompt
        let promptData = try JSONSerialization.data(withJSONObject: [
            "prompt": workflow,
            "client_id": clientId
        ] as [String: Any])
        guard let promptURL = URL(string: "\(serverURL)/prompt") else {
            throw URLError(.badURL)
        }
        var submitRequest = URLRequest(url: promptURL)
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitRequest.httpBody = promptData
        submitRequest.timeoutInterval = 30

        let (submitData, submitResponse) = try await URLSession.shared.data(for: submitRequest)
        guard (submitResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComfyUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "提交失败"])
        }
        guard let submitJSON = try JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let promptId = submitJSON["prompt_id"] as? String else {
            throw NSError(domain: "ComfyUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "未获取到 prompt_id"])
        }

        // Poll for completion
        var imageFilename: String?
        let historyURL = URL(string: "\(serverURL)/history/\(promptId)")!
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var pollRequest = URLRequest(url: historyURL)
            pollRequest.timeoutInterval = 10
            let historyResult: (Data, URLResponse)?
            do {
                historyResult = try await URLSession.shared.data(for: pollRequest)
            } catch {
                continue
            }
            guard let (historyData, _) = historyResult,
                  let historyJSON = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
                  let entry = historyJSON[promptId] as? [String: Any] else { continue }

            if let outputs = entry["outputs"] as? [String: Any],
               let saveImage = outputs["9"] as? [String: Any],
               let images = saveImage["images"] as? [[String: Any]],
               let first = images.first,
               let filename = first["filename"] as? String {
                imageFilename = filename
                break
            }

            if let status = entry["status"] as? [String: Any],
               let completed = status["completed"] as? Bool,
               completed,
               status["execution_error"] != nil {
                throw NSError(domain: "ComfyUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "生成过程中发生错误"])
            }
        }

        guard let filename = imageFilename else {
            throw NSError(domain: "ComfyUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "生成超时或失败"])
        }

        // Download image
        let viewURL = URL(string: "\(serverURL)/view?filename=\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)&type=output")!
        var viewRequest = URLRequest(url: viewURL)
        viewRequest.timeoutInterval = 30
        let (imageData, viewResponse) = try await URLSession.shared.data(for: viewRequest)
        guard (viewResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComfyUI", code: 5, userInfo: [NSLocalizedDescriptionKey: "下载图片失败"])
        }

        // Save to workspace
        let outputPath = (outputDir as NSString).appendingPathComponent("laicai_generated_\(filename)")
        try imageData.write(to: URL(fileURLWithPath: outputPath))
        return outputPath
    }
}

// MARK: - G3: LSP Tool (sourcekit-lsp go-to-definition / find-references)

public struct LSPTool: LaicaiTool {
    public var name: String { "lsp.query" }
    public var description: String { "语义级代码查询：跳转到定义、查找引用、符号搜索。依赖 sourcekit-lsp（Swift）或其他 LSP 服务。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "操作：definition（跳转到定义）、references（查找引用）、symbols（符号搜索）"),
                    "file": FunctionProperty(type: "string", description: "文件路径"),
                    "line": FunctionProperty(type: "integer", description: "行号（1-based）"),
                    "column": FunctionProperty(type: "integer", description: "列号（1-based）"),
                    "symbol": FunctionProperty(type: "string", description: "符号名称（symbols 模式用）")
                ],
                required: ["action"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var action: String
            var file: String?
            var line: Int?
            var column: Int?
            var symbol: String?
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot

        switch params.action {
        case "definition":
            guard let file = params.file, let line = params.line, let col = params.column else {
                return ToolResult(output: "definition 需要 file, line, column 参数", success: false, error: "missing_params")
            }
            let fullPath = file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file)
            return await gotoDefinition(file: fullPath, line: line, column: col, root: root)

        case "references":
            guard let file = params.file, let line = params.line, let col = params.column else {
                return ToolResult(output: "references 需要 file, line, column 参数", success: false, error: "missing_params")
            }
            let fullPath = file.hasPrefix("/") ? file : (root as NSString).appendingPathComponent(file)
            return await findReferences(file: fullPath, line: line, column: col, root: root)

        case "symbols":
            let query = params.symbol ?? ""
            return await symbolSearch(query: query, root: root)

        default:
            return ToolResult(output: "未知 action：\(params.action)。支持：definition, references, symbols", success: false, error: "unknown_action")
        }
    }

    private func gotoDefinition(file: String, line: Int, column: Int, root: String) async -> ToolResult {
        // Use sourcekit-lsp via its LSP protocol over a simple shell invocation
        // Fall back to grep-based heuristic if sourcekit-lsp is not available
        let ext = (file as NSString).pathExtension.lowercased()

        if ["swift"].contains(ext) {
            // Try sourcekit-lsp cursor-info
            let cmd = "xcrun sourcekit-lsp 2>/dev/null && echo 'available' || echo 'unavailable'"
            let available = Self.runShell(cmd, cwd: root)
            if available.contains("available") {
                // Use swift-ide-test as a simpler alternative for definition lookup
                let symbolResult = Self.extractSymbolAtLocation(file: file, line: line, column: column)
                if !symbolResult.isEmpty {
                    let grepResult = Self.runShell("cd \(Self.shellEscape(root)) && rg -n 'func \\b\(symbolResult)\\b|class \\b\(symbolResult)\\b|struct \\b\(symbolResult)\\b|protocol \\b\(symbolResult)\\b|enum \\b\(symbolResult)\\b' --max-count 5 --glob '*.swift' 2>/dev/null", cwd: root)
                    if !grepResult.isEmpty {
                        return ToolResult(output: "符号 '\(symbolResult)' 的定义位置：\n\(grepResult)", data: ["symbol": symbolResult])
                    }
                }
            }
        }

        // Generic fallback: extract symbol at position and grep
        let symbolAtPos = Self.extractSymbolAtLocation(file: file, line: line, column: column)
        if symbolAtPos.isEmpty {
            return ToolResult(output: "无法识别位置 \(file):\(line):\(column) 的符号", success: false, error: "no_symbol")
        }

        let defPatterns = "func \\b\(symbolAtPos)\\b|class \\b\(symbolAtPos)\\b|struct \\b\(symbolAtPos)\\b|def \\b\(symbolAtPos)\\b|interface \\b\(symbolAtPos)\\b|type \\b\(symbolAtPos)\\b"
        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\(defPatterns)' --max-count 10 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到 '\(symbolAtPos)' 的定义", data: ["symbol": symbolAtPos])
            : ToolResult(output: "符号 '\(symbolAtPos)' 的定义位置：\n\(String(result.prefix(5000)))", data: ["symbol": symbolAtPos])
    }

    private func findReferences(file: String, line: Int, column: Int, root: String) async -> ToolResult {
        let symbol = Self.extractSymbolAtLocation(file: file, line: line, column: column)
        if symbol.isEmpty {
            return ToolResult(output: "无法识别位置 \(file):\(line):\(column) 的符号", success: false, error: "no_symbol")
        }

        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\\b\(symbol)\\b' --max-count 30 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' --glob '!**/.build/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到 '\(symbol)' 的引用", data: ["symbol": symbol])
            : ToolResult(output: "符号 '\(symbol)' 的引用（\(result.components(separatedBy: "\n").filter { !$0.isEmpty }.count) 处）：\n\(String(result.prefix(8000)))", data: ["symbol": symbol])
    }

    private func symbolSearch(query: String, root: String) async -> ToolResult {
        guard !query.isEmpty else {
            return ToolResult(output: "请提供 symbol 参数", success: false, error: "missing_symbol")
        }

        let patterns = "func \\b\(query)|class \\b\(query)|struct \\b\(query)|protocol \\b\(query)|enum \\b\(query)|def \\b\(query)|interface \\b\(query)|type \\b\(query)|export.*\\b\(query)"
        let result = Self.runShell("cd \(Self.shellEscape(root)) && rg -n '\(patterns)' --max-count 30 --max-filesize 1M --glob '!**/.git/**' --glob '!**/node_modules/**' --glob '!**/.build/**' 2>/dev/null", cwd: root)

        return result.isEmpty
            ? ToolResult(output: "未找到符号 '\(query)'", data: ["query": query])
            : ToolResult(output: "符号搜索 '\(query)' 结果：\n\(String(result.prefix(8000)))", data: ["query": query])
    }

    static func extractSymbolAtLocation(file: String, line: Int, column: Int) -> String {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return "" }
        let lines = content.components(separatedBy: "\n")
        guard line > 0 && line <= lines.count else { return "" }
        let lineStr = lines[line - 1]
        let col = max(0, min(column - 1, lineStr.count - 1))
        let chars = Array(lineStr)
        guard col < chars.count else { return "" }

        var start = col
        while start > 0 && (chars[start - 1].isLetter || chars[start - 1].isNumber || chars[start - 1] == "_") { start -= 1 }
        var end = col
        while end < chars.count - 1 && (chars[end + 1].isLetter || chars[end + 1].isNumber || chars[end + 1] == "_") { end += 1 }

        let symbol = String(chars[start...end])
        return symbol.count >= 2 ? symbol : ""
    }

    static func runShell(_ command: String, cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - G11: Unified Diff Apply Tool

public struct DiffApplyTool: LaicaiTool {
    public var name: String { "diff.apply" }
    public var description: String { "应用 unified diff 格式的补丁到文件。比 file.edit 更适合多处修改。" }
    public var requiresReview: Bool { true }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "path": FunctionProperty(type: "string", description: "文件路径"),
                    "diff": FunctionProperty(type: "string", description: "unified diff 格式的补丁内容（以 --- 和 +++ 开头）")
                ],
                required: ["path", "diff"]
            )
        )
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        struct Params: Codable {
            var path: String
            var diff: String
        }

        let params: Params
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败", success: false, error: "invalid_params")
        }

        let fullPath = params.path.hasPrefix("/") ? params.path : (context.workspaceRoot as NSString).appendingPathComponent(params.path)

        // Security check
        if let securityError = await SecurityManager.shared.checkWrite(path: fullPath) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        guard FileManager.default.fileExists(atPath: fullPath) else {
            return ToolResult(output: "文件不存在：\(params.path)", success: false, error: "file_not_found")
        }

        let oldContent: String
        do {
            oldContent = try String(contentsOfFile: fullPath, encoding: .utf8)
        } catch {
            return ToolResult(output: "读取文件失败：\(error.localizedDescription)", success: false, error: "read_error")
        }

        // Apply unified diff
        let result = applyUnifiedDiff(original: oldContent, diff: params.diff)
        guard let newContent = result.content else {
            return ToolResult(output: "Diff 应用失败：\(result.error ?? "格式错误")", success: false, error: "diff_failed")
        }

        let addedLines = newContent.components(separatedBy: "\n").count - oldContent.components(separatedBy: "\n").count
        let summary = addedLines >= 0 ? "+\(addedLines) 行" : "\(addedLines) 行"

        return ToolResult(
            output: "Diff 已准备，等待审查：\(params.path)（\(summary)）",
            data: [
                "path": params.path,
                "fullPath": fullPath,
                "diffOld": oldContent,
                "diffNew": newContent,
                "addedLines": "\(max(0, addedLines))",
                "removedLines": "\(max(0, -addedLines))",
                "createDirectories": "false"
            ],
            success: true
        )
    }

    private struct DiffResult {
        var content: String?
        var error: String?
    }

    private func applyUnifiedDiff(original: String, diff: String) -> DiffResult {
        var lines = original.components(separatedBy: "\n")
        let diffLines = diff.components(separatedBy: "\n")
        var offset = 0

        // Parse hunks: @@ -start,count +start,count @@
        let hunkPattern = #"^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@"#
        guard let hunkRegex = try? NSRegularExpression(pattern: hunkPattern) else {
            return DiffResult(error: "正则编译失败")
        }

        var i = 0
        while i < diffLines.count {
            let line = diffLines[i]
            let ns = line as NSString
            if let match = hunkRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let startLine = Int(ns.substring(with: match.range(at: 1))) ?? 1
                var lineIndex = startLine - 1 + offset
                i += 1

                while i < diffLines.count {
                    let dl = diffLines[i]
                    if dl.hasPrefix("@@") || dl.hasPrefix("diff ") || dl.hasPrefix("---") || dl.hasPrefix("+++") { break }
                    if dl.hasPrefix("-") {
                        // Remove line
                        if lineIndex >= 0 && lineIndex < lines.count {
                            lines.remove(at: lineIndex)
                            offset -= 1
                        }
                    } else if dl.hasPrefix("+") {
                        // Add line
                        let newLine = String(dl.dropFirst())
                        if lineIndex >= lines.count {
                            lines.append(newLine)
                        } else {
                            lines.insert(newLine, at: lineIndex)
                        }
                        lineIndex += 1
                        offset += 1
                    } else {
                        // Context line — advance
                        lineIndex += 1
                    }
                    i += 1
                }
            } else {
                i += 1
            }
        }

        return DiffResult(content: lines.joined(separator: "\n"))
    }
}

// MARK: - Skill Manage Tool (Agent self-creates skills)

public struct SkillManageTool: LaicaiTool {
    public var name: String { "skill.manage" }
    public var description: String { "管理技能：创建、更新、删除、列出可复用的技能。当你发现一个非平凡的工作流程值得复用时，用这个工具保存为技能。" }

    public var functionDefinition: FunctionDefinition {
        FunctionDefinition(
            name: name,
            description: description,
            parameters: FunctionParameters(
                properties: [
                    "action": FunctionProperty(type: "string", description: "操作类型：create / update / delete / list", enumValues: ["create", "update", "delete", "list"]),
                    "name": FunctionProperty(type: "string", description: "技能名称（create/update/delete 必填）"),
                    "description": FunctionProperty(type: "string", description: "技能描述（create/update 时使用）"),
                    "tools": FunctionProperty(type: "string", description: "逗号分隔的工具列表，如 file.read,code.search,file.write"),
                    "instructions": FunctionProperty(type: "string", description: "详细的执行步骤说明（SKILL.md 内容）"),
                    "trigger": FunctionProperty(type: "string", description: "自动触发的关键词模式（可选）")
                ],
                required: ["action"]
            )
        )
    }

    private struct SkillParams: Codable {
        var action: String
        var name: String?
        var description: String?
        var tools: String?
        var instructions: String?
        var trigger: String?
    }

    public func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult {
        let params: SkillParams
        do {
            let jsonData = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(SkillParams.self, from: jsonData)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let root = context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillDir = root.isEmpty
            ? ((FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("Laicai/skills")
            : (root as NSString).appendingPathComponent(".laicai/skills")
        try? FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        switch params.action {
        case "create":
            return try await createSkill(params: params, skillDir: skillDir)
        case "update":
            return try updateSkill(params: params, skillDir: skillDir)
        case "delete":
            return try deleteSkill(params: params, skillDir: skillDir)
        case "list":
            return listSkills(skillDir: skillDir)
        default:
            return ToolResult(output: "未知操作：\(params.action)。支持 create/update/delete/list。", success: false, error: "invalid_params")
        }
    }

    private func createSkill(params: SkillParams, skillDir: String) async throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "创建技能需要 name 参数", success: false, error: "invalid_params")
        }
        let slug = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = slug.isEmpty ? UUID().uuidString : slug
        let mdPath = (skillDir as NSString).appendingPathComponent("\(filename).md")

        guard !FileManager.default.fileExists(atPath: mdPath) else {
            return ToolResult(output: "技能已存在：\(name)。使用 update 操作更新。", success: false, error: "already_exists")
        }

        let tools = params.tools?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let desc = params.description ?? name
        let instructions = params.instructions ?? "（待补充执行步骤）"
        let trigger = params.trigger ?? ""

        var md = "---\nname: \(name)\ndescription: \(desc)\ntools: [\(tools.joined(separator: ", "))]"
        if !trigger.isEmpty {
            md += "\ntrigger: \(trigger)"
        }
        md += "\n---\n\n# \(name)\n\n\(desc)\n\n## 执行步骤\n\n\(instructions)\n"

        try md.write(toFile: mdPath, atomically: true, encoding: .utf8)

        let skill = SkillDefinition(name: name, description: desc, tools: tools, isBuiltin: false, isPublished: true)
        await SkillRegistry.shared.register(skill)

        return ToolResult(
            output: "技能已创建：\(name)\n路径：\(mdPath)\n工具：\(tools.joined(separator: ", "))",
            data: ["path": mdPath, "name": name]
        )
    }

    private func updateSkill(params: SkillParams, skillDir: String) throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "更新技能需要 name 参数", success: false, error: "invalid_params")
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: skillDir)) ?? []
        guard let existing = files.first(where: { file in
            guard file.hasSuffix(".md") else { return false }
            let content = (try? String(contentsOfFile: (skillDir as NSString).appendingPathComponent(file), encoding: .utf8)) ?? ""
            return content.contains("name: \(name)")
        }) else {
            return ToolResult(output: "未找到技能：\(name)", success: false, error: "not_found")
        }

        let path = (skillDir as NSString).appendingPathComponent(existing)
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        if let desc = params.description {
            content = content.replacingOccurrences(of: #"description: .*"#, with: "description: \(desc)", options: .regularExpression)
        }
        if let tools = params.tools {
            content = content.replacingOccurrences(of: #"tools: \[.*\]"#, with: "tools: [\(tools)]", options: .regularExpression)
        }
        if let instructions = params.instructions {
            if let range = content.range(of: "## 执行步骤") {
                content = String(content[content.startIndex..<range.lowerBound]) + "## 执行步骤\n\n\(instructions)\n"
            }
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return ToolResult(output: "技能已更新：\(name)", data: ["path": path, "name": name])
    }

    private func deleteSkill(params: SkillParams, skillDir: String) throws -> ToolResult {
        guard let name = params.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "删除技能需要 name 参数", success: false, error: "invalid_params")
        }

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: skillDir)) ?? []
        guard let existing = files.first(where: { file in
            let content = (try? String(contentsOfFile: (skillDir as NSString).appendingPathComponent(file), encoding: .utf8)) ?? ""
            return content.contains("name: \(name)") || file.contains(name.lowercased())
        }) else {
            return ToolResult(output: "未找到技能：\(name)", success: false, error: "not_found")
        }

        try fm.removeItem(atPath: (skillDir as NSString).appendingPathComponent(existing))
        return ToolResult(output: "技能已删除：\(name)")
    }

    private func listSkills(skillDir: String) -> ToolResult {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: skillDir))?.filter { $0.hasSuffix(".md") || $0.hasSuffix(".json") } ?? []
        var lines: [String] = ["共 \(files.count) 个自定义技能："]
        for file in files.sorted() {
            let path = (skillDir as NSString).appendingPathComponent(file)
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let nameLine = content.components(separatedBy: "\n").first(where: { $0.hasPrefix("name:") })
            let name = nameLine?.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces) ?? file
            lines.append("- \(name)")
        }

        let learned = SkillEvolutionEngine.shared.allSkills(limit: 5)
        if !learned.isEmpty {
            lines.append("\n已学习技能（Q值排序，前5）：")
            for s in learned {
                lines.append("- \(s.name) (Q=\(String(format: "%.2f", s.qValue)), 用\(s.usageCount)次, 成功率\(String(format: "%.0f%%", s.successRate * 100)))")
            }
        }

        return ToolResult(output: lines.joined(separator: "\n"), data: ["count": "\(files.count)"])
    }
}
