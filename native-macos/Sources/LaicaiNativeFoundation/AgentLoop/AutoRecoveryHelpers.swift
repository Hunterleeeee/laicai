import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func attemptCircuitBreakerRepair(
        toolName: String,
        callStep: TaskStep,
        taskContext: TaskContext,
        toolRegistry: ToolRegistry
    ) async -> ToolResult {
        if toolName == "file.edit",
           let editPath = callStep.toolParams?["path"],
           let readTool = toolRegistry.tool(named: "file_read"),
           let writeTool = toolRegistry.tool(named: "file_write") {
            let readJSON = (try? JSONSerialization.data(withJSONObject: ["path": editPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: taskContext)
            if let rr = readResult, rr.success {
                let editsStr = callStep.toolParams?["edits"] ?? "[]"
                let newTexts = extractNewTexts(from: editsStr)
                if !newTexts.isEmpty {
                    let separator = rr.output.hasSuffix("\n") ? "" : "\n"
                    let merged = rr.output + separator + newTexts.joined(separator: "\n")
                    let writeDict: [String: Any] = ["path": editPath, "content": merged]
                    let writeJSON = (try? JSONSerialization.data(withJSONObject: writeDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let writeResult = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext)
                    if let wr = writeResult, wr.success {
                        return ToolResult(
                            output: "🔴→✅ 熔断自动修复：file.edit 连续失败，编排层改用 file.read + file.write 完成。\n\(wr.output)",
                            data: wr.data,
                            success: true
                        )
                    }
                }
            }
        }

        if toolName == "code.search",
           let query = callStep.toolParams?["query"],
           let shellTool = toolRegistry.tool(named: "shell_exec") {
            let safeQuery = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
            let grepCmd = "grep -rn '\(safeQuery)' . --include='*.swift' --include='*.md' --include='*.py' --include='*.js' --include='*.ts' | head -30"
            let shellJSON = (try? JSONSerialization.data(withJSONObject: ["command": grepCmd])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let shellResult = try? await shellTool.execute(argumentsJSON: shellJSON, context: taskContext)
            if let sr = shellResult, sr.success {
                return ToolResult(
                    output: "🔴→✅ 熔断自动修复：code.search 连续失败，编排层改用 grep 搜索。\n\(sr.output)",
                    data: sr.data,
                    success: true
                )
            }
        }

        if toolName == "document.transform" {
            let sourcePath = callStep.toolParams?["sourcePath"] ?? callStep.toolParams?["path"] ?? callStep.toolParams?["outputPath"] ?? "目标文档"
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
        toolName: String,
        callStep: TaskStep,
        argumentsJSON: String,
        currentResult: ToolResult,
        recoveryPlan: inout RecoveryPlan?,
        validation: ValidationEngine.ValidationResult,
        taskContext: TaskContext,
        config: Config,
        toolRegistry: ToolRegistry
    ) async -> ToolResult {
        var toolResult = currentResult

        switch toolName {
        case "file.read":
            if let path = callStep.toolParams?["path"] {
                if toolResult.error == "unsupported_binary_file",
                   let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract") {
                    if let er = await autoExtractUnsupportedRead(path: path, extractTool: extractTool, context: taskContext) {
                        toolResult = ToolResult(
                            output: "file.read 检测到表格/文档，编排层自动改用 file.extract 提取成功：\n\(er.output)",
                            data: er.data,
                            success: true
                        )
                    } else {
                        recoveryPlan = ErrorRecoveryEngine.planRecoveryJSON(
                            error: "unsupported_binary_file：\(toolResult.output)",
                            toolName: toolName,
                            argumentsJSON: argumentsJSON,
                            attemptCount: validation.retryCount
                        )
                    }
                } else if (toolResult.error == "file_not_found" || toolResult.output.contains("不存在")),
                          let searchTool = toolRegistry.tool(named: "code_search") {
                    let filename = (path as NSString).lastPathComponent
                    let searchJSON = "{\"query\":\"\(filename)\"}"
                    let searchResult = try? await searchTool.execute(argumentsJSON: searchJSON, context: taskContext)
                    if let sr = searchResult, sr.success, !sr.output.hasPrefix("未找到") {
                        let suggestion = String(sr.output.prefix(500))
                        toolResult = ToolResult(
                            output: "\(toolResult.output)\n\n编排层自动搜索近似文件：\n\(suggestion)\n请从以上结果中选择正确的文件路径。",
                            data: toolResult.data,
                            success: false,
                            error: toolResult.error
                        )
                    }
                }
            }

        case "file.write":
            if toolResult.error == "security_denied", let path = callStep.toolParams?["path"] {
                let dir = (path as NSString).deletingLastPathComponent
                let maxAutoAllowed = 5
                if !dir.isEmpty && dir != "/" && !WorkspaceSandbox.isOverlyBroadWorkspace(dir)
                    && WorkspaceSandbox.shared.allowedPaths.count < maxAutoAllowed {
                    WorkspaceSandbox.shared.addAllowedPath(dir)
                    if let tool = toolRegistry.tool(named: "file_write") {
                        let retryResult = try? await tool.execute(argumentsJSON: argumentsJSON, context: taskContext)
                        if let rr = retryResult, rr.success {
                            toolResult = ToolResult(
                                output: "编排层自动授权路径后重试成功：\(rr.output)",
                                data: rr.data,
                                success: true
                            )
                        }
                    }
                }
            }

        case "file.edit":
            if toolResult.error != "file_not_found" && toolResult.error != "security_denied" {
                toolResult = await attemptFileEditFallback(
                    callStep: callStep,
                    currentResult: toolResult,
                    taskContext: taskContext,
                    toolRegistry: toolRegistry
                )
            } else if toolResult.error == "file_not_found" || toolResult.output.contains("不存在") {
                if let path = callStep.toolParams?["path"],
                   let content = callStep.toolParams?["content"] ?? callStep.toolParams?["new_content"],
                   let writeTool = toolRegistry.tool(named: "file_write") {
                    let writeJSON = (try? JSONSerialization.data(withJSONObject: ["path": path, "content": content])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let writeResult = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext)
                    if let wr = writeResult, wr.success {
                        toolResult = ToolResult(
                            output: "文件不存在，编排层自动改用 file.write 创建：\(wr.output)",
                            data: wr.data,
                            success: true
                        )
                    }
                }
            }

        case "verify.build":
            let errorLines = toolResult.output.components(separatedBy: .newlines).filter { line in
                let l = line.lowercased()
                return l.contains("error:") || l.contains("错误") || l.contains("fatal")
            }.prefix(5)
            if !errorLines.isEmpty {
                let errorSummary = errorLines.joined(separator: "\n")
                toolResult = ToolResult(
                    output: toolResult.output + "\n\n编排层提取关键错误：\n\(errorSummary)\n\n请直接 file_edit 修复以上错误行，然后再次 verify_build。",
                    data: toolResult.data,
                    success: false,
                    error: toolResult.error
                )
            }

        case "code.search":
            if let query = callStep.toolParams?["query"],
               (toolResult.output.hasPrefix("未找到") || toolResult.output.contains("0 个匹配")),
               query.count > 4 {
                let words = query.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "._")).inverted).filter { $0.count > 2 }
                if let simpler = words.last, simpler != query,
                   let searchTool = toolRegistry.tool(named: "code_search") {
                    let retryJSON = "{\"query\":\"\(simpler)\"}"
                    let retryResult = try? await searchTool.execute(argumentsJSON: retryJSON, context: taskContext)
                    if let rr = retryResult, rr.success, !rr.output.hasPrefix("未找到") {
                        toolResult = ToolResult(
                            output: "原查询「\(query)」无结果，编排层自动简化为「\(simpler)」重搜：\n\(rr.output)",
                            data: rr.data,
                            success: true
                        )
                    }
                }
            }

        case "shell.exec":
            let output = toolResult.output.lowercased()
            let command = callStep.toolParams?["command"] ?? ""
            if output.contains("command not found") || output.contains("no such file") {
                let fixed = autoFixShellCommand(command: command)
                if let fixedCommand = fixed, fixedCommand != command,
                   let shellTool = toolRegistry.tool(named: "shell_exec") {
                    let fixedJSON = (try? JSONSerialization.data(withJSONObject: ["command": fixedCommand])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let retryResult = try? await shellTool.execute(argumentsJSON: fixedJSON, context: taskContext)
                    if let rr = retryResult, rr.success {
                        toolResult = ToolResult(
                            output: "原命令失败，编排层自动修正为 `\(fixedCommand)` 后成功：\n\(rr.output)",
                            data: rr.data,
                            success: true
                        )
                    }
                }
            }
            if !toolResult.success && output.contains("permission denied") {
                toolResult = ToolResult(
                    output: toolResult.output + "\n\n⚠️ 权限不足。建议：1) 检查文件权限 chmod  2) 换一个有权限的路径  3) 如果是系统命令，提示用户手动执行。",
                    data: toolResult.data,
                    success: false,
                    error: toolResult.error
                )
            }
            if !toolResult.success && (output.contains("no such file or directory") || output.contains("not a directory")),
               !command.contains("cd ") {
                let fixedCommand = "cd '\(config.workspaceRoot)' && \(command)"
                if let shellTool = toolRegistry.tool(named: "shell_exec") {
                    let fixedJSON = (try? JSONSerialization.data(withJSONObject: ["command": fixedCommand])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let retryResult = try? await shellTool.execute(argumentsJSON: fixedJSON, context: taskContext)
                    if let rr = retryResult, rr.success {
                        toolResult = ToolResult(
                            output: "目录不存在，编排层自动切换到工作区根目录后成功：\n\(rr.output)",
                            data: rr.data,
                            success: true
                        )
                    }
                }
            }

        default:
            break
        }

        return toolResult
    }

    private static func autoFixShellCommand(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let pathFixes: [String: String] = [
            "python": "/usr/bin/env python3",
            "pip": "/usr/bin/env pip3",
            "node": "/usr/local/bin/node",
            "npm": "/usr/local/bin/npm",
            "npx": "/usr/local/bin/npx",
            "yarn": "/usr/local/bin/yarn",
            "cargo": "$HOME/.cargo/bin/cargo",
            "rustc": "$HOME/.cargo/bin/rustc",
            "go": "/usr/local/go/bin/go",
            "swift": "/usr/bin/swift",
            "swiftc": "/usr/bin/swiftc",
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
        var toolResult = currentResult
        if toolResult.error == "all_edits_failed",
           let editPath = callStep.toolParams?["path"],
           let editsJSON = callStep.toolParams?["edits"],
           let readTool = toolRegistry.tool(named: "file_read"),
           let writeTool = toolRegistry.tool(named: "file_write") {
            let readJSON = (try? JSONSerialization.data(withJSONObject: ["path": editPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: taskContext),
               readResult.success {
                var fallbackContent = readResult.output
                if let editsData = editsJSON.data(using: .utf8),
                   let editsArr = try? JSONSerialization.jsonObject(with: editsData) as? [[String: Any]] {
                    for editItem in editsArr {
                        if let oldText = editItem["oldText"] as? String,
                           let newText = editItem["newText"] as? String,
                           !oldText.isEmpty {
                            fallbackContent = applyFallbackEdit(oldText: oldText, newText: newText, to: fallbackContent)
                        }
                    }
                }
                if fallbackContent != readResult.output {
                    let writeJSON = (try? JSONSerialization.data(withJSONObject: ["path": editPath, "content": fallbackContent])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    if let wr = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext), wr.success {
                        toolResult = ToolResult(
                            output: "file.edit 匹配失败，编排层自动降级：读取文件 → 模糊匹配替换 → file.write 写回成功\n\(wr.output)",
                            data: wr.data,
                            success: true,
                            error: nil
                        )
                    }
                } else if let editsData = editsJSON.data(using: .utf8),
                          let editsArr = try? JSONSerialization.jsonObject(with: editsData) as? [[String: Any]] {
                    let allNewTexts = editsArr.compactMap { $0["newText"] as? String }
                    if allNewTexts.count == 1,
                       let newContent = allNewTexts.first,
                       newContent.count >= readResult.output.count / 2 {
                        let writeJSON = (try? JSONSerialization.data(withJSONObject: ["path": editPath, "content": newContent])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        if let wr = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext), wr.success {
                            toolResult = ToolResult(
                                output: "file.edit 匹配失败但 newText 覆盖了文件大部分内容，编排层直接 file.write 写入\n\(wr.output)",
                                data: wr.data,
                                success: true,
                                error: nil
                            )
                        }
                    }
                }
            }
        }

        if !toolResult.success {
            let hint = "\n\n⚠️ file.edit 失败，oldText 匹配不上文件内容。" +
                "\n请改用 file.write 全量写入（先 file.read 读取完整内容，修改后 file.write 写回）。"
            toolResult = ToolResult(
                output: toolResult.output + hint,
                data: toolResult.data,
                success: false,
                error: toolResult.error
            )
        }
        return toolResult
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

        let matchThreshold = max(1, oldLines.count / 5)
        var bestStart = -1
        var bestMismatches = Int.max
        for startIdx in 0...(max(0, lines.count - oldLines.count)) {
            let window = lines[startIdx..<min(startIdx + oldLines.count, lines.count)]
            let windowNorm = window.map { $0.trimmingCharacters(in: .whitespaces) }
            let mismatches = zip(Array(windowNorm), oldLines).filter { $0.0 != $0.1 }.count
            if mismatches < bestMismatches {
                bestMismatches = mismatches
                bestStart = startIdx
            }
        }
        if bestStart >= 0 && bestMismatches <= matchThreshold && bestMismatches > 0 {
            var newLines = Array(lines[0..<bestStart])
            newLines.append(contentsOf: newText.components(separatedBy: "\n"))
            newLines.append(contentsOf: lines[(bestStart + oldLines.count)...])
            return newLines.joined(separator: "\n")
        }
        if oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let separator = content.hasSuffix("\n") ? "" : "\n"
            return content + separator + newText
        }
        return content
    }
}
