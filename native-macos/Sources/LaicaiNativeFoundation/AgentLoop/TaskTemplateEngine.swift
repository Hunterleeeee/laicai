import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    // MARK: - G1: Task Template Engine

    struct TemplateResult {
        var executedSteps: Int = 0
        var templateName: String = ""
        var directive: String = ""
    }

    /// G1: Detect task type and pre-execute the optimal tool sequence.
    static func executeTaskTemplate(
        message: String,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        messages: inout [ChatMessage],
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> TemplateResult {
        var result = TemplateResult()
        let lowerMsg = message.lowercased()
        let mentionedPaths = extractAbsolutePaths(from: message)
        let hasPaths = !mentionedPaths.isEmpty
        let isWikiTask = expectsWikiOutput(message)

        if isWikiTask && hasPaths {
            result.templateName = "整理到 Wiki"
            var collected: [String] = []
            if let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract"),
               let readTool = toolRegistry.tool(named: "file_read") ?? toolRegistry.tool(named: "file.read") {
                for path in mentionedPaths.prefix(5) {
                    if let cached = taskContext.memory.fileContentCache[path] {
                        collected.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n\(String(cached.prefix(12000)))")
                        result.executedSteps += 1
                        continue
                    }
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    let ext = (path as NSString).pathExtension.lowercased()
                    let useExtract = ["xlsx", "xlsm", "csv", "tsv"].contains(ext)
                    let tool = useExtract ? extractTool : readTool
                    let canonicalName = useExtract ? "file.extract" : "file.read"
                    let args: [String: Any] = ["path": path, "limit": useExtract ? 60_000 : 500]
                    let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let params = ["path": path, "limit": "\(args["limit"] ?? "")"]
                    let callId = "call_template_\(ToolNameCodec.apiName(canonicalName))_\(result.executedSteps)"
                    let callStep = TaskStep(
                        kind: .toolCall,
                        text: ToolStepFormatter.callText(toolName: canonicalName, arguments: params),
                        toolName: canonicalName,
                        toolParams: params,
                        toolCallId: callId,
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(callStep)
                    onStep(callStep)
                    let extracted = try? await tool.execute(argumentsJSON: json, context: taskContext)
                    if let extracted {
                        let display = ToolResultFormatter.displayText(toolName: canonicalName, arguments: params, result: extracted)
                        let resultStep = TaskStep(
                            kind: .toolResult,
                            text: display,
                            toolName: canonicalName,
                            toolParams: params,
                            toolCallId: callId,
                            isCollapsible: true,
                            isCollapsed: true,
                            isFailure: !extracted.success
                        )
                        task.steps.append(resultStep)
                        onStep(resultStep)
                        if extracted.success {
                            taskContext.memory.readFiles.append(path)
                            taskContext.memory.fileContentCache[path] = extracted.output
                            collected.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n\(String(extracted.output.prefix(12000)))")
                            result.executedSteps += 1
                        } else if isDirectory.boolValue {
                            collected.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n\(extracted.output)")
                        }
                    }
                }
            }
            if !collected.isEmpty {
                result.directive = """
                编排层已为 Wiki 任务预读/提取附件内容：

                \(collected.joined(separator: "\n\n"))

                用户目标是整理到 Wiki/知识库。禁止只输出计划。请基于上面的真实材料拆出 2-6 个独立主题，逐个调用 wiki_build(mode="atomic", save=true)，最后调用一次 wiki_build(mode="moc", save=true) 创建索引。只有 wiki_build 保存成功后，才能说任务完成。
                """
            }
            return result
        }

        // Template 1: "修改/修复/改 文件X 做Y" — search, read, then let LLM edit
        let isModifyTask = (lowerMsg.contains("修改") || lowerMsg.contains("修复") || lowerMsg.contains("改一下") || lowerMsg.contains("fix") || lowerMsg.contains("修") || lowerMsg.contains("改"))
            && (hasPaths || lowerMsg.contains("文件"))
        if isModifyTask && hasPaths {
            result.templateName = "修改文件"
            // Files already pre-read by E1, just verify and add context
            var readContent: [String] = []
            for path in mentionedPaths.prefix(3) {
                if let cached = taskContext.memory.fileContentCache[path] {
                    let truncated = cached.count > 12000 ? String(cached.prefix(12000)) + "\n…（\(cached.count)字符）" : cached
                    readContent.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n```\n\(truncated)\n```")
                    result.executedSteps += 1
                } else if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    taskContext.memory.readFiles.append(path)
                    taskContext.memory.fileContentCache[path] = content
                    let truncated = content.count > 12000 ? String(content.prefix(12000)) : content
                    readContent.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n```\n\(truncated)\n```")
                    result.executedSteps += 1
                }
            }
            if !readContent.isEmpty {
                result.directive = "编排层已预读所有目标文件：\n\n\(readContent.joined(separator: "\n\n"))\n\n请直接用 file_edit 修改，不需要先 file_read。修改后编排层会自动 verify_build。"
            }
            return result
        }

        // Template 2: "搜索/查找/找 KEYWORD" — search + pre-read best result
        let isSearchTask = (lowerMsg.contains("搜索") || lowerMsg.contains("查找") || lowerMsg.contains("找一下") || lowerMsg.contains("grep") || lowerMsg.contains("search") || lowerMsg.contains("找"))
            && !lowerMsg.contains("创建") && !lowerMsg.contains("修改") && !lowerMsg.contains("写入")
        if isSearchTask {
            let searchKeywords = extractSearchKeywords(from: message)
            if let keywords = searchKeywords, !keywords.isEmpty,
               let searchTool = toolRegistry.tool(named: "code_search") ?? toolRegistry.tool(named: "code.search") {
                result.templateName = "搜索代码"
                let searchStep = TaskStep(kind: .toolCall, text: "编排层预搜索：\(keywords)", toolName: "code.search", isCollapsible: true, isCollapsed: true)
                task.steps.append(searchStep)
                onStep(searchStep)
                let searchJSON = (try? JSONSerialization.data(withJSONObject: ["query": keywords])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let sr = try? await searchTool.execute(argumentsJSON: searchJSON, context: taskContext), sr.success {
                    let resultStep = TaskStep(kind: .toolResult, text: String(sr.output.prefix(500)), toolName: "code.search", isCollapsible: true, isCollapsed: true)
                    task.steps.append(resultStep)
                    onStep(resultStep)
                    taskContext.memory.searchedQueries.append(keywords)
                    result.executedSteps += 1

                    // Pre-read the best result file
                    if let bestPath = firstReadablePath(inSearchOutput: sr.output, workspaceRoot: taskContext.workspaceRoot),
                       !taskContext.memory.readFiles.contains(bestPath) {
                        if let content = try? String(contentsOfFile: bestPath, encoding: .utf8) {
                            taskContext.memory.readFiles.append(bestPath)
                            taskContext.memory.fileContentCache[bestPath] = content
                            let truncated = content.count > 8000 ? String(content.prefix(8000)) : content
                            result.directive = "编排层已预搜索「\(keywords)」并预读最相关文件 \(bestPath)：\n```\n\(truncated)\n```\n\n请直接基于这些信息回答或执行。"
                            result.executedSteps += 1
                        }
                    } else {
                        result.directive = "编排层已预搜索「\(keywords)」，结果：\n\(String(sr.output.prefix(2000)))\n\n请直接基于搜索结果继续。"
                    }
                }
            }
            return result
        }

        // Template 3: "解释/看看/分析 文件X" — just read and ask LLM to analyze
        let isExplainTask = (lowerMsg.contains("解释") || lowerMsg.contains("分析") || lowerMsg.contains("看看") || lowerMsg.contains("说明") || lowerMsg.contains("explain") || lowerMsg.contains("what does") || lowerMsg.contains("这是什么"))
        if isExplainTask && hasPaths {
            result.templateName = "解释代码"
            var readContent: [String] = []
            for path in mentionedPaths.prefix(3) {
                if let cached = taskContext.memory.fileContentCache[path] {
                    let truncated = cached.count > 12000 ? String(cached.prefix(12000)) : cached
                    readContent.append("### \(URL(fileURLWithPath: path).lastPathComponent)\n```\n\(truncated)\n```")
                    result.executedSteps += 1
                }
            }
            if !readContent.isEmpty {
                result.directive = "编排层已预读文件：\n\n\(readContent.joined(separator: "\n\n"))\n\n请直接分析以上代码内容，不需要调用任何工具。"
            }
            return result
        }

        // Template 4: "运行/执行 COMMAND" — pre-execute shell command
        let isRunTask = lowerMsg.contains("运行") || lowerMsg.contains("执行") || lowerMsg.contains("跑一下")
        if isRunTask {
            if let cmdMatch = firstLocalPath(in: message),
               let shellTool = toolRegistry.tool(named: "shell_exec") ?? toolRegistry.tool(named: "shell.exec") {
                result.templateName = "执行命令"
                let shellStep = TaskStep(kind: .toolCall, text: "编排层预执行：\(cmdMatch)", toolName: "shell.exec", isCollapsible: true, isCollapsed: true)
                task.steps.append(shellStep)
                onStep(shellStep)
                let shellJSON = (try? JSONSerialization.data(withJSONObject: ["command": cmdMatch])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let sr = try? await shellTool.execute(argumentsJSON: shellJSON, context: taskContext) {
                    let truncatedOutput = String(sr.output.prefix(3000))
                    result.directive = "编排层已预执行命令 `\(cmdMatch)`，结果：\n```\n\(truncatedOutput)\n```\n\n\(sr.success ? "执行成功。" : "执行失败。")请基于结果继续。"
                    result.executedSteps += 1
                }
            }
            return result
        }

        // Template 5: Codebase exploration — no specific path, needs workspace index + search
        let isExploreTask = (lowerMsg.contains("哪") || lowerMsg.contains("怎么") || lowerMsg.contains("where") || lowerMsg.contains("how") || lowerMsg.contains("有没有") || lowerMsg.contains("什么"))
            && !hasPaths
            && message.count > 10
        if isExploreTask {
            // Auto-index workspace if not done yet
            if !taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("工作区索引：") }) {
                if let indexTool = toolRegistry.tool(named: "workspace_index") ?? toolRegistry.tool(named: "workspace.index") {
                    result.templateName = "探索项目"
                    let idxStep = TaskStep(kind: .toolCall, text: "编排层预索引工作区", toolName: "workspace.index", isCollapsible: true, isCollapsed: true)
                    task.steps.append(idxStep)
                    onStep(idxStep)
                    let ir = try? await indexTool.execute(argumentsJSON: "{}", context: taskContext)
                    if let ir, ir.success {
                        taskContext.memory.appendDecision("工作区索引：\(String(ir.output.prefix(2000)))")
                        result.executedSteps += 1
                    }
                }
            }
            // Then try a targeted search
            let searchKeywords = extractSearchKeywords(from: message)
            if let keywords = searchKeywords, !keywords.isEmpty,
               let searchTool = toolRegistry.tool(named: "code_search") ?? toolRegistry.tool(named: "code.search") {
                let searchJSON = (try? JSONSerialization.data(withJSONObject: ["query": keywords])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let sr = try? await searchTool.execute(argumentsJSON: searchJSON, context: taskContext), sr.success {
                    taskContext.memory.searchedQueries.append(keywords)
                    result.executedSteps += 1
                    result.directive = "编排层已索引工作区并预搜索「\(keywords)」，结果：\n\(String(sr.output.prefix(2000)))\n\n请直接基于这些信息回答。"
                }
            }
            if result.directive.isEmpty && result.executedSteps > 0 {
                let indexContent = taskContext.memory.userDecisions.first(where: { $0.hasPrefix("工作区索引：") }) ?? ""
                result.directive = "编排层已索引工作区：\n\(String(indexContent.prefix(2000)))\n\n请基于索引信息回答。"
            }
            return result
        }

        return result
    }
}
