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
        emitDebugSteps: Bool = false,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> TemplateResult {
        var result = TemplateResult()
        let lowerMsg = message.lowercased()
        let mentionedPaths = extractAbsolutePaths(from: message)
        let hasPaths = !mentionedPaths.isEmpty
        let isWikiTask = expectsWikiOutput(message)

        if isDocumentDeliveryTask(message, paths: mentionedPaths),
           let documentTool = toolRegistry.tool(named: "document_transform") ?? toolRegistry.tool(named: "document.transform"),
           let sourcePath = mentionedPaths.first(where: { isSupportedOfficeDocument($0) }) {
            result.templateName = "文档交付"
            let outputPath = inferredDocumentOutputPath(from: message, sourcePath: sourcePath)
            let workspaceArgs: [String: Any] = [
                "action": "workspace",
                "sourcePath": sourcePath,
                "outputPath": outputPath,
                "onlyChinese": shouldPreferChineseTextOnly(message),
                "granularity": preferredDocumentGranularity(for: sourcePath)
            ]
            let workspaceJSON = (try? JSONSerialization.data(withJSONObject: workspaceArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let workspaceParams = workspaceArgs.mapValues { "\($0)" }
            let workspaceCallId = "call_template_document_transform_workspace"
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "document.transform", arguments: workspaceParams),
                toolName: "document.transform",
                toolParams: workspaceParams,
                toolCallId: workspaceCallId,
                isCollapsible: true,
                isCollapsed: true
            )
            if emitDebugSteps {
                task.steps.append(callStep)
                onStep(callStep)
            }

            let workspaceResult = try? await documentTool.execute(argumentsJSON: workspaceJSON, context: taskContext)
            if let workspaceResult {
                let display = ToolResultFormatter.displayText(toolName: "document.transform", arguments: workspaceParams, result: workspaceResult)
                let resultStep = TaskStep(
                    kind: .toolResult,
                    text: display,
                    toolName: "document.transform",
                    toolParams: AgentLoop.resultStepParams(toolName: "document.transform", arguments: workspaceParams, result: workspaceResult),
                    toolCallId: workspaceCallId,
                    isCollapsible: true,
                    isCollapsed: true,
                    isFailure: !workspaceResult.success
                )
                if emitDebugSteps || !workspaceResult.success {
                    task.steps.append(resultStep)
                    onStep(resultStep)
                }
                if workspaceResult.success {
                    result.executedSteps += 1
                    taskContext.memory.readFiles.append(sourcePath)
                    taskContext.memory.fileContentCache[sourcePath] = workspaceResult.output
                    if let workflowPath = workspaceResult.data?["workflowPath"] {
                        taskContext.memory.appendDecision("文档交付工作区：\(workflowPath)")
                    }
                }
            }

            let prepareArgs: [String: Any] = [
                "action": "prepare",
                "sourcePath": sourcePath,
                "outputPath": outputPath,
                "workflowPath": workspaceResult?.data?["workflowPath"] ?? "",
                "chunkIndex": 0,
                "chunkSize": 60,
                "onlyChinese": shouldPreferChineseTextOnly(message),
                "granularity": preferredDocumentGranularity(for: sourcePath)
            ]
            let prepareJSON = (try? JSONSerialization.data(withJSONObject: prepareArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let prepareParams = prepareArgs.mapValues { "\($0)" }
            let prepareCallId = "call_template_document_transform_prepare_0"
            let prepareCall = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "document.transform", arguments: prepareParams),
                toolName: "document.transform",
                toolParams: prepareParams,
                toolCallId: prepareCallId,
                isCollapsible: true,
                isCollapsed: true
            )
            if emitDebugSteps {
                task.steps.append(prepareCall)
                onStep(prepareCall)
            }

            let prepared = try? await documentTool.execute(argumentsJSON: prepareJSON, context: taskContext)
            if let prepared {
                let display = ToolResultFormatter.displayText(toolName: "document.transform", arguments: prepareParams, result: prepared)
                let resultStep = TaskStep(
                    kind: .toolResult,
                    text: display,
                    toolName: "document.transform",
                    toolParams: AgentLoop.resultStepParams(toolName: "document.transform", arguments: prepareParams, result: prepared),
                    toolCallId: prepareCallId,
                    isCollapsible: true,
                    isCollapsed: true,
                    isFailure: !prepared.success
                )
                if emitDebugSteps || !prepared.success {
                    task.steps.append(resultStep)
                    onStep(resultStep)
                }
                if prepared.success {
                    result.executedSteps += 1
                    taskContext.memory.fileContentCache["\(sourcePath)#prepare"] = prepared.output
                }
            }

            result.directive = documentDeliveryDirective(
                message: message,
                sourcePath: sourcePath,
                outputPath: outputPath,
                workflowOutput: workspaceResult?.output ?? "",
                preparedOutput: prepared?.output ?? ""
            )
            return result
        }

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
                    if emitDebugSteps {
                        task.steps.append(callStep)
                        onStep(callStep)
                    }
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
                        if emitDebugSteps || !extracted.success {
                            task.steps.append(resultStep)
                            onStep(resultStep)
                        }
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
                已为 Wiki Agent 预读/提取附件内容：

                \(collected.joined(separator: "\n\n"))

                用户目标是整理到 Wiki/知识库。禁止只输出计划。请基于上面的真实材料拆出 2-6 个独立主题，逐个调用 wiki_build(mode="atomic", save=true)，最后调用一次 wiki_build(mode="moc", save=true) 创建索引。只有 wiki_build 保存成功后，才能说 Agent 完成。
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
                result.directive = "已预读所有目标文件：\n\n\(readContent.joined(separator: "\n\n"))\n\n请直接用 file_edit 修改，不需要先 file_read。修改后需要 verify_build。"
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
                let searchStep = TaskStep(kind: .toolCall, text: "预搜索：\(keywords)", toolName: "code.search", isCollapsible: true, isCollapsed: true)
                if emitDebugSteps {
                    task.steps.append(searchStep)
                    onStep(searchStep)
                }
                let searchJSON = (try? JSONSerialization.data(withJSONObject: ["query": keywords])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let sr = try? await searchTool.execute(argumentsJSON: searchJSON, context: taskContext), sr.success {
                    let resultStep = TaskStep(kind: .toolResult, text: String(sr.output.prefix(500)), toolName: "code.search", isCollapsible: true, isCollapsed: true)
                    if emitDebugSteps {
                        task.steps.append(resultStep)
                        onStep(resultStep)
                    }
                    taskContext.memory.searchedQueries.append(keywords)
                    result.executedSteps += 1

                    // Pre-read the best result file
                    if let bestPath = firstReadablePath(inSearchOutput: sr.output, workspaceRoot: taskContext.workspaceRoot),
                       !taskContext.memory.readFiles.contains(bestPath) {
                        if let content = try? String(contentsOfFile: bestPath, encoding: .utf8) {
                            taskContext.memory.readFiles.append(bestPath)
                            taskContext.memory.fileContentCache[bestPath] = content
                            let truncated = content.count > 8000 ? String(content.prefix(8000)) : content
                            result.directive = "已预搜索「\(keywords)」并预读最相关文件 \(bestPath)：\n```\n\(truncated)\n```\n\n请基于这些真实信息继续完成用户目标；如果目标需要修改、生成、验证或交付，继续调用相应工具，不要停在建议层。"
                            result.executedSteps += 1
                        }
                    } else {
                        result.directive = "已预搜索「\(keywords)」，结果：\n\(String(sr.output.prefix(2000)))\n\n请基于搜索结果继续完成用户目标；需要落地时继续读文件、修改或验证。"
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
                result.directive = "已预读文件：\n\n\(readContent.joined(separator: "\n\n"))\n\n请基于以上代码继续完成用户目标；如果只是解释就直接说明，如果需要修复/优化/生成，请继续调用工具落地。"
            }
            return result
        }

        // Template 4: "运行/执行 COMMAND" — pre-execute shell command
        let isRunTask = lowerMsg.contains("运行") || lowerMsg.contains("执行") || lowerMsg.contains("跑一下")
        if isRunTask {
            if let cmdMatch = firstLocalPath(in: message),
               let shellTool = toolRegistry.tool(named: "shell_exec") ?? toolRegistry.tool(named: "shell.exec") {
                result.templateName = "执行命令"
                let shellStep = TaskStep(kind: .toolCall, text: "预执行：\(cmdMatch)", toolName: "shell.exec", isCollapsible: true, isCollapsed: true)
                if emitDebugSteps {
                    task.steps.append(shellStep)
                    onStep(shellStep)
                }
                let shellJSON = (try? JSONSerialization.data(withJSONObject: ["command": cmdMatch])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let sr = try? await shellTool.execute(argumentsJSON: shellJSON, context: taskContext) {
                    let truncatedOutput = String(sr.output.prefix(3000))
                    result.directive = "已预执行命令 `\(cmdMatch)`，结果：\n```\n\(truncatedOutput)\n```\n\n\(sr.success ? "执行成功。" : "执行失败。")请基于结果继续。"
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
                    let idxStep = TaskStep(kind: .toolCall, text: "预索引工作区", toolName: "workspace.index", isCollapsible: true, isCollapsed: true)
                    if emitDebugSteps {
                        task.steps.append(idxStep)
                        onStep(idxStep)
                    }
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
                    result.directive = "已索引工作区并预搜索「\(keywords)」，结果：\n\(String(sr.output.prefix(2000)))\n\n请基于这些信息继续完成用户目标；需要落地时继续读关键文件、修改或验证。"
                }
            }
            if result.directive.isEmpty && result.executedSteps > 0 {
                let indexContent = taskContext.memory.userDecisions.first(where: { $0.hasPrefix("工作区索引：") }) ?? ""
                result.directive = "已索引工作区：\n\(String(indexContent.prefix(2000)))\n\n请基于索引信息继续完成用户目标；不要把仍需执行的事项只写成计划。"
            }
            return result
        }

        return result
    }

    private static func isDocumentDeliveryTask(_ message: String, paths: [String]) -> Bool {
        guard paths.contains(where: isSupportedOfficeDocument) else { return false }
        let markers = [
            "翻译", "英文", "english", "转换", "转化", "改写", "替换", "修改",
            "输出", "导出", "保存", "存到", "生成", "副本", "交付"
        ]
        return markers.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func isSupportedOfficeDocument(_ path: String) -> Bool {
        ["pptx", "docx", "xlsx", "xlsm"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func shouldPreferChineseTextOnly(_ message: String) -> Bool {
        message.contains("中文") || message.contains("英文") || message.contains("翻译") || message.localizedCaseInsensitiveContains("english")
    }

    private static func preferredDocumentGranularity(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["pptx", "docx"].contains(ext) ? "paragraph" : "text"
    }

    private static func inferredDocumentOutputPath(from message: String, sourcePath: String) -> String {
        let explicitNames = [
            #"([^\s\n，。；;：:「」"'`]+(?:_English|_EN)[^\s\n，。；;：:「」"'`]*)"#,
            #"([^\s\n，。；;：:「」"'`]*(?:英文版|English)[^\s\n，。；;：:「」"'`]*)"#
        ]
        for pattern in explicitNames {
            if let name = firstDocumentFileName(in: message, pattern: pattern) {
                if name.hasPrefix("/") { return name }
                if message.contains("桌面") || message.localizedCaseInsensitiveContains("desktop") {
                    return (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/\(name)")
                }
                return ((sourcePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            }
        }

        let url = URL(fileURLWithPath: sourcePath)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = (message.contains("英文") || message.localizedCaseInsensitiveContains("english")) ? "_English" : "_Laicai"
        let fileName = "\(base)\(suffix).\(ext)"
        if message.contains("桌面") || message.localizedCaseInsensitiveContains("desktop") {
            return (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/\(fileName)")
        }
        return url.deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    private static func firstDocumentFileName(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[swiftRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;：:）)]}>\"'`"))
            guard isSupportedOfficeDocument(name), !name.contains("/") else { continue }
            return name
        }
        return nil
    }

    private static func documentDeliveryDirective(
        message: String,
        sourcePath: String,
        outputPath: String,
        workflowOutput: String,
        preparedOutput: String
    ) -> String {
        let wantsTranslation = message.contains("翻译") || message.contains("英文") || message.localizedCaseInsensitiveContains("english")
        let operation = wantsTranslation ? "翻译/本地化" : "改写/转换"
        let imageTextWarning = message.contains("图片") || message.localizedCaseInsensitiveContains("ocr")
            ? "\n- 用户提到了图片文字/OCR：document_transform 只处理可编辑文本。图片中文字必须另行使用 OCR/视觉工具；未处理前不能声称图片文字已完成。"
            : ""
        return """
        已为 Office 文档交付 Agent 预处理源文档：
        - 源文件：\(sourcePath)
        - 目标文件：\(outputPath)
        - Agent 类型：\(operation)

        预处理结果：
        \(String(workflowOutput.prefix(8000)))

        首块可编辑内容：
        \(String(preparedOutput.prefix(20000)))

        执行规则：
        - 不要只输出计划。必须用 document_transform 完成真实文件产出；必要时在 workflowPath 下沉淀中间文件和脚本。
        - 如果 entries 非空：把本块 entries 逐条\(wantsTranslation ? "翻译成英文" : "改写为目标内容")，然后调用 document_transform(action="apply", sourcePath, outputPath, translationsJSON, granularity="paragraph") 写回。
        - translationsJSON 优先使用数组格式：[{"id":"entry.id","text":"处理后的文本"}]，保留数字、专有名词和格式含义。
        - document_transform(action="apply") 会基于已经存在的 outputPath 累积写回；继续分块时仍使用同一个 outputPath，不能换成新的临时文件。
        - 如果 totalChunks 大于 1，需要继续调用 document_transform(action="prepare", chunkIndex=下一块, granularity="paragraph") 处理剩余块，再 apply 到同一个 outputPath。
        - 每次 apply 后调用 document_transform(action="verify", sourcePath=outputPath, outputPath=outputPath)。如果 remainingCJK 仍大于 0 且 Agent 目标要求全量翻译，继续 prepare/apply，不能声称完成。
        - 可编辑文本完成后，尽量调用 document_transform(action="render", sourcePath=outputPath, outputPath=outputPath) 生成 PDF 作为视觉检查证据；若缺少 LibreOffice，明确说明只完成可编辑文本验证。
        - 只有目标文件真实存在且 verify 结果满足任务目标，才能对用户说已完成。\(imageTextWarning)
        """
    }
}
