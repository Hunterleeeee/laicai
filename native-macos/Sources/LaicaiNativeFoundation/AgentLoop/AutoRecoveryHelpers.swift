import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    struct AutoRecoveryRequest {
        let toolName: String
        let callStep: TaskStep
        let argumentsJSON: String
        let currentResult: ToolResult
        let validation: ValidationEngine.ValidationResult
        let taskContext: TaskContext
        let config: Config
        let toolRegistry: ToolRegistry
    }

    static func attemptCircuitBreakerRepair(
        toolName: String,
        callStep: TaskStep,
        taskContext: TaskContext,
        toolRegistry: ToolRegistry
    ) async -> ToolResult {
        if toolName == "file.edit" {
            return ToolResult(
                output: "🔴 已熔断：file.edit 连续失败。为避免把局部 newText 误追加或覆盖整个文件，编排层不会自动改写；请重新读取目标文件并提交精确、可审查的完整 diff。",
                success: false,
                error: "file_edit_circuit_broken"
            )
        }

        if toolName == "code.search",
            let query = callStep.toolParams?["query"],
            let shellTool = toolRegistry.tool(named: "shell_exec")
        {
            let safeQuery = shellSingleQuoted(query)
            let grepCmd =
                "grep -rn --include='*.swift' --include='*.md' --include='*.py' --include='*.js' --include='*.ts' -- \(safeQuery) . | head -30"
            let shellJSON = jsonString(["command": grepCmd])
            let shellResult = try? await shellTool.execute(argumentsJSON: shellJSON, context: taskContext)
            if let shellResultValue = shellResult, shellResultValue.success {
                return ToolResult(
                    output: "🔴→✅ 熔断自动修复：code.search 连续失败，编排层改用 grep 搜索。\n\(shellResultValue.output)",
                    data: shellResultValue.data,
                    success: true
                )
            }
        }

        if toolName == "document.transform" {
            let sourcePath =
                callStep.toolParams?["sourcePath"] ?? callStep.toolParams?["path"] ?? callStep.toolParams?["outputPath"] ?? "目标文档"
            return ToolResult(
                output: "🔴 已熔断：document.transform 对 \(sourcePath) 已连续失败。不要再用相同参数重试；请改用 shell.exec 调系统工具/脚本生成交付物，或明确说明当前缺少可用的文档转换路径。",
                success: false,
                error: "document_transform_circuit_broken"
            )
        }

        return ToolResult(
            output: "🔴 已熔断：`\(toolName)` 对该目标已连续失败多次且自动修复失败。请使用其他工具完成此操作。",
            success: false,
            error: "circuit_broken"
        )
    }

    static func attemptAutoRecovery(
        _ request: AutoRecoveryRequest,
        recoveryPlan: inout RecoveryPlan?
    ) async -> ToolResult {
        let toolName = request.toolName
        var toolResult = request.currentResult

        switch toolName {
        case "file.read":
            toolResult = await recoverFileRead(request, recoveryPlan: &recoveryPlan)
        case "file.write":
            toolResult = await recoverFileWrite(request)
        case "file.edit":
            toolResult = await recoverFileEdit(request)
        case "verify.build":
            toolResult = recoverVerifyBuild(request)
        case "code.search":
            toolResult = await recoverCodeSearch(request)
        case "shell.exec":
            toolResult = await recoverShellExec(request)
        default:
            break
        }

        return toolResult
    }

    private static func recoverFileRead(
        _ request: AutoRecoveryRequest,
        recoveryPlan: inout RecoveryPlan?
    ) async -> ToolResult {
        var toolResult = request.currentResult
        guard let path = request.callStep.toolParams?["path"] else { return toolResult }
        if toolResult.error == "unsupported_binary_file",
            let extractTool = request.toolRegistry.tool(named: "file_extract") ?? request.toolRegistry.tool(named: "file.extract")
        {
            if let extracted = await autoExtractUnsupportedRead(path: path, extractTool: extractTool, context: request.taskContext) {
                return ToolResult(output: "file.read 检测到表格/文档，编排层自动改用 file.extract 提取成功：\n\(extracted.output)", data: extracted.data)
            }
            recoveryPlan = ErrorRecoveryEngine.planRecoveryJSON(
                error: "unsupported_binary_file：\(toolResult.output)",
                toolName: request.toolName,
                argumentsJSON: request.argumentsJSON,
                attemptCount: request.validation.retryCount
            )
        } else if toolResult.error == "file_not_found" || toolResult.output.contains("不存在") {
            toolResult = await recoverMissingReadPath(path: path, request: request)
        }
        return toolResult
    }

    private static func recoverMissingReadPath(path: String, request: AutoRecoveryRequest) async -> ToolResult {
        guard let searchTool = request.toolRegistry.tool(named: "code_search") else { return request.currentResult }
        let filename = (path as NSString).lastPathComponent
        let searchResult = try? await searchTool.execute(
            argumentsJSON: jsonString(["query": filename]),
            context: request.taskContext
        )
        guard let searchResult, searchResult.success, !searchResult.output.hasPrefix("未找到") else { return request.currentResult }
        let suggestion = String(searchResult.output.prefix(500))
        return ToolResult(
            output: "\(request.currentResult.output)\n\n编排层自动搜索近似文件：\n\(suggestion)\n请从以上结果中选择正确的文件路径。",
            data: request.currentResult.data,
            success: false,
            error: request.currentResult.error
        )
    }

    private static func recoverFileWrite(_ request: AutoRecoveryRequest) async -> ToolResult {
        guard request.currentResult.error == "security_denied",
            let path = request.callStep.toolParams?["path"]
        else { return request.currentResult }
        let dir = (path as NSString).deletingLastPathComponent
        let canAutoAllow =
            !dir.isEmpty
            && dir != "/"
            && !WorkspaceSandbox.isOverlyBroadWorkspace(dir)
            && WorkspaceSandbox.shared.allowedPaths.count < 5
        guard canAutoAllow, let tool = request.toolRegistry.tool(named: "file_write") else { return request.currentResult }
        WorkspaceSandbox.shared.addAllowedPath(dir)
        let retryResult = try? await tool.execute(argumentsJSON: request.argumentsJSON, context: request.taskContext)
        guard let retryResult, retryResult.success else { return request.currentResult }
        return ToolResult(output: "编排层自动授权路径后重试成功：\(retryResult.output)", data: retryResult.data)
    }

    private static func recoverFileEdit(_ request: AutoRecoveryRequest) async -> ToolResult {
        if request.currentResult.error != "file_not_found" && request.currentResult.error != "security_denied" {
            return await attemptFileEditFallback(
                callStep: request.callStep,
                currentResult: request.currentResult,
                taskContext: request.taskContext,
                toolRegistry: request.toolRegistry
            )
        }
        guard request.currentResult.error == "file_not_found" || request.currentResult.output.contains("不存在") else {
            return request.currentResult
        }
        return await createMissingFileFromEdit(request)
    }

    private static func createMissingFileFromEdit(_ request: AutoRecoveryRequest) async -> ToolResult {
        guard let path = request.callStep.toolParams?["path"],
            let content = request.callStep.toolParams?["content"] ?? request.callStep.toolParams?["new_content"],
            let writeTool = request.toolRegistry.tool(named: "file_write")
        else { return request.currentResult }
        let writeJSON =
            (try? JSONSerialization.data(withJSONObject: ["path": path, "content": content]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let writeResult = try? await writeTool.execute(argumentsJSON: writeJSON, context: request.taskContext)
        guard let writeResult, writeResult.success else { return request.currentResult }
        return ToolResult(output: "文件不存在，编排层自动改用 file.write 创建：\(writeResult.output)", data: writeResult.data)
    }

    private static func recoverVerifyBuild(_ request: AutoRecoveryRequest) -> ToolResult {
        let errorLines = request.currentResult.output.components(separatedBy: .newlines).filter { line in
            let lowercasedLine = line.lowercased()
            return lowercasedLine.contains("error:") || lowercasedLine.contains("错误") || lowercasedLine.contains("fatal")
        }.prefix(5)
        guard !errorLines.isEmpty else { return request.currentResult }
        let errorSummary = errorLines.joined(separator: "\n")
        return ToolResult(
            output: request.currentResult.output + "\n\n编排层提取关键错误：\n\(errorSummary)\n\n请直接 file_edit 修复以上错误行，然后再次 verify_build。",
            data: request.currentResult.data,
            success: false,
            error: request.currentResult.error
        )
    }

    private static func recoverCodeSearch(_ request: AutoRecoveryRequest) async -> ToolResult {
        guard let query = request.callStep.toolParams?["query"],
            request.currentResult.output.hasPrefix("未找到") || request.currentResult.output.contains("0 个匹配"),
            query.count > 4,
            let searchTool = request.toolRegistry.tool(named: "code_search")
        else { return request.currentResult }
        let words = query.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "._")).inverted)
            .filter { $0.count > 2 }
        guard let simpler = words.last, simpler != query else { return request.currentResult }
        let retryResult = try? await searchTool.execute(
            argumentsJSON: jsonString(["query": simpler]),
            context: request.taskContext
        )
        guard let retryResult, retryResult.success, !retryResult.output.hasPrefix("未找到") else { return request.currentResult }
        return ToolResult(output: "原查询「\(query)」无结果，编排层自动简化为「\(simpler)」重搜：\n\(retryResult.output)", data: retryResult.data)
    }

    private static func recoverShellExec(_ request: AutoRecoveryRequest) async -> ToolResult {
        var toolResult = await retryFixedShellCommand(request)
        let output = request.currentResult.output.lowercased()
        if !toolResult.success && output.contains("permission denied") {
            toolResult = ToolResult(
                output: toolResult.output + "\n\n⚠️ 权限不足。建议：1) 检查文件权限 chmod  2) 换一个有权限的路径  3) 如果是系统命令，提示用户手动执行。",
                data: toolResult.data,
                success: false,
                error: toolResult.error
            )
        }
        if !toolResult.success && (output.contains("no such file or directory") || output.contains("not a directory")) {
            toolResult = await retryShellFromWorkspaceRoot(request, currentResult: toolResult)
        }
        return toolResult
    }

    private static func retryFixedShellCommand(_ request: AutoRecoveryRequest) async -> ToolResult {
        let output = request.currentResult.output.lowercased()
        let command = request.callStep.toolParams?["command"] ?? ""
        guard output.contains("command not found") || output.contains("no such file"),
            let fixedCommand = autoFixShellCommand(command: command),
            fixedCommand != command,
            let shellTool = request.toolRegistry.tool(named: "shell_exec")
        else { return request.currentResult }
        let fixedJSON =
            (try? JSONSerialization.data(withJSONObject: ["command": fixedCommand]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let retryResult = try? await shellTool.execute(argumentsJSON: fixedJSON, context: request.taskContext)
        guard let retryResult, retryResult.success else { return request.currentResult }
        return ToolResult(output: "原命令失败，编排层自动修正为 `\(fixedCommand)` 后成功：\n\(retryResult.output)", data: retryResult.data)
    }

    private static func retryShellFromWorkspaceRoot(
        _ request: AutoRecoveryRequest,
        currentResult: ToolResult
    ) async -> ToolResult {
        let output = request.currentResult.output.lowercased()
        let command = request.callStep.toolParams?["command"] ?? ""
        guard output.contains("no such file or directory") || output.contains("not a directory"),
            !request.config.workspaceRoot.isEmpty,
            request.taskContext.workspaceRoot != request.config.workspaceRoot,
            let shellTool = request.toolRegistry.tool(named: "shell_exec")
        else { return currentResult }
        let fixedJSON =
            (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var retryContext = request.taskContext
        retryContext.workspaceRoot = request.config.workspaceRoot
        let retryResult = try? await shellTool.execute(argumentsJSON: fixedJSON, context: retryContext)
        guard let retryResult, retryResult.success else { return currentResult }
        return ToolResult(output: "目录不存在，编排层使用工作区根目录重试成功：\n\(retryResult.output)", data: retryResult.data)
    }

    private static func autoFixShellCommand(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let pathFixes: [String: String] = [
            "python": "/usr/bin/env python3",
            "pip": "/usr/bin/env pip3",
            "node": "/usr/bin/env node",
            "npm": "/usr/bin/env npm",
            "npx": "/usr/bin/env npx",
            "yarn": "/usr/bin/env yarn",
            "cargo": "/usr/bin/env cargo",
            "rustc": "/usr/bin/env rustc",
            "go": "/usr/bin/env go",
            "swift": "/usr/bin/env swift",
            "swiftc": "/usr/bin/env swiftc",
        ]
        if let fix = pathFixes[firstWord] {
            return trimmed.replacingOccurrences(of: "^\(firstWord)", with: fix, options: .regularExpression)
        }
        if trimmed.hasPrefix("./") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func attemptFileEditFallback(
        callStep: TaskStep,
        currentResult: ToolResult,
        taskContext: TaskContext,
        toolRegistry: ToolRegistry
    ) async -> ToolResult {
        guard
            let request = fallbackEditRequest(
                callStep: callStep,
                currentResult: currentResult,
                toolRegistry: toolRegistry
            )
        else {
            return resultWithFileEditHintIfNeeded(currentResult)
        }
        guard let readResult = await readFallbackEditFile(request: request, taskContext: taskContext) else {
            return resultWithFileEditHintIfNeeded(currentResult)
        }

        let edits = fallbackEdits(from: request.editsJSON)
        if let result = await writeFuzzyFallbackIfChanged(
            request: request,
            readResult: readResult,
            edits: edits,
            taskContext: taskContext
        ) {
            return result
        }
        return resultWithFileEditHintIfNeeded(currentResult)
    }

    private struct FallbackEditRequest {
        let path: String
        let editsJSON: String
        let readTool: any LaicaiTool
        let writeTool: any LaicaiTool
    }

    private struct FallbackEdit {
        let oldText: String
        let newText: String
    }

    private static func fallbackEditRequest(
        callStep: TaskStep,
        currentResult: ToolResult,
        toolRegistry: ToolRegistry
    ) -> FallbackEditRequest? {
        guard currentResult.error == "all_edits_failed",
            let editPath = callStep.toolParams?["path"],
            let editsJSON = callStep.toolParams?["edits"],
            let readTool = toolRegistry.tool(named: "file_read"),
            let writeTool = toolRegistry.tool(named: "file_write")
        else {
            return nil
        }
        return FallbackEditRequest(path: editPath, editsJSON: editsJSON, readTool: readTool, writeTool: writeTool)
    }

    private static func readFallbackEditFile(
        request: FallbackEditRequest,
        taskContext: TaskContext
    ) async -> ToolResult? {
        let readJSON = jsonString(["path": request.path])
        guard let readResult = try? await request.readTool.execute(argumentsJSON: readJSON, context: taskContext),
            readResult.success
        else {
            return nil
        }
        return readResult
    }

    private static func fallbackEdits(from editsJSON: String) -> [FallbackEdit] {
        guard let editsData = editsJSON.data(using: .utf8),
            let editsArr = try? JSONSerialization.jsonObject(with: editsData) as? [[String: Any]]
        else {
            return []
        }
        return editsArr.compactMap { editItem in
            guard let oldText = editItem["oldText"] as? String,
                let newText = editItem["newText"] as? String,
                !oldText.isEmpty
            else {
                return nil
            }
            return FallbackEdit(oldText: oldText, newText: newText)
        }
    }

    private static func writeFuzzyFallbackIfChanged(
        request: FallbackEditRequest,
        readResult: ToolResult,
        edits: [FallbackEdit],
        taskContext: TaskContext
    ) async -> ToolResult? {
        let fallbackContent = edits.reduce(readResult.output) { content, edit in
            applyFallbackEdit(oldText: edit.oldText, newText: edit.newText, to: content)
        }
        guard fallbackContent != readResult.output else { return nil }
        return await writeFallbackContent(
            path: request.path,
            content: fallbackContent,
            writeTool: request.writeTool,
            taskContext: taskContext,
            successPrefix: "file.edit 匹配失败，编排层自动降级：读取文件 → 模糊匹配替换 → file.write 写回成功"
        )
    }

    private static func writeFallbackContent(
        path: String,
        content: String,
        writeTool: any LaicaiTool,
        taskContext: TaskContext,
        successPrefix: String
    ) async -> ToolResult? {
        let writeJSON = jsonString(["path": path, "content": content])
        guard let writeResultValue = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext),
            writeResultValue.success
        else {
            return nil
        }
        return ToolResult(
            output: "\(successPrefix)\n\(writeResultValue.output)",
            data: writeResultValue.data,
            success: true,
            error: nil
        )
    }

    private static func resultWithFileEditHintIfNeeded(_ result: ToolResult) -> ToolResult {
        guard !result.success else { return result }
        let hint = "\n\n⚠️ file.edit 失败，oldText 匹配不上文件内容。" + "\n请改用 file.write 全量写入（先 file.read 读取完整内容，修改后 file.write 写回）。"
        return ToolResult(
            output: result.output + hint,
            data: result.data,
            success: false,
            error: result.error
        )
    }

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func applyFallbackEdit(oldText: String, newText: String, to content: String) -> String {
        let oldNorm = oldText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        let contentNorm = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        let lines = content.components(separatedBy: "\n")
        let oldLines = oldText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        if contentNorm.contains(oldNorm) {
            for startIdx in 0...(max(0, lines.count - oldLines.count)) {
                let window = lines[startIdx..<min(startIdx + oldLines.count, lines.count)]
                let windowNorm = window.map { $0.trimmingCharacters(in: .whitespaces) }
                if Array(windowNorm) == oldLines {
                    var newLines = Array(lines[0..<startIdx])
                    newLines.append(contentsOf: newText.components(separatedBy: "\n"))
                    newLines.append(contentsOf: lines[(startIdx + oldLines.count)...])
                    return newLines.joined(separator: "\n")
                }
            }
        }

        return content
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
