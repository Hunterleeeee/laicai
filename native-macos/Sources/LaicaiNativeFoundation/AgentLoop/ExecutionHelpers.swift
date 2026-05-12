import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    /// Parse JSON arguments into [String: String] for display
    func parseParamsFromJSON(_ json: String) -> [String: String] {
        Self.displayParamsFromJSON(json)
    }

    static func displayParamsFromJSON(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { value in
            if let str = value as? String {
                return String(str.prefix(100))
            }
            return "\(value)"
        }
    }

    nonisolated static var fileChangeTools: Set<String> {
        ["file.write", "file.edit", "diff.apply"]
    }

    nonisolated static var explicitApprovalSideEffectTools: Set<String> {
        ["browser.real", "computer"]
    }

    nonisolated static func isFileChangeTool(_ toolName: String) -> Bool {
        fileChangeTools.contains(ToolNameCodec.canonicalName(toolName))
    }

    nonisolated static func isExplicitApprovalSideEffectTool(_ toolName: String) -> Bool {
        explicitApprovalSideEffectTools.contains(ToolNameCodec.canonicalName(toolName))
    }

    nonisolated static func isFileChangeTool(toolName: String, tool: (any LaicaiTool)?) -> Bool {
        if tool?.executionPolicy == .fileChangeReview { return true }
        return isFileChangeTool(toolName)
    }

    nonisolated static func requiresExplicitUserApprovalBeforeExecution(toolName: String, tool: any LaicaiTool) -> Bool {
        switch tool.executionPolicy {
        case .explicitUserApproval:
            return true
        case .fileChangeReview, .immediate:
            return false
        }
    }

    nonisolated static func canonicalToolSet(_ names: Set<String>?) -> Set<String>? {
        names.map { Set($0.map(ToolNameCodec.canonicalName)) }
    }

    nonisolated static func allowsTool(_ toolName: String, allowedTools: Set<String>?) -> Bool {
        guard let allowedTools, !allowedTools.isEmpty else { return true }
        return canonicalToolSet(allowedTools)?.contains(ToolNameCodec.canonicalName(toolName)) ?? false
    }

    nonisolated static func approvalRequiredToolResult(toolName: String) -> ToolResult {
        ToolResult(
            output: "已阻止工具调用：\(toolName)。该工具会影响真实系统或外部应用，必须由用户显式确认后才能执行。",
            data: ["approvalRequired": "true"],
            success: false,
            error: "approval_required"
        )
    }

    nonisolated static func pathForFileChange(callStep: TaskStep, toolResult: ToolResult? = nil) -> String {
        toolResult?.data?["path"] ?? callStep.toolParams?["path"] ?? ""
    }

    // G9: Allow file edits on DIFFERENT files to run in parallel
    static func scheduledToolCallBatches(
        _ calls: [(Int, TaskStep, String, String, String, [String: String])]
    ) -> [[(Int, TaskStep, String, String, String, [String: String])]] {
        var batches: [[(Int, TaskStep, String, String, String, [String: String])]] = []
        var currentBatch: [(Int, TaskStep, String, String, String, [String: String])] = []
        var currentBatchPaths: Set<String> = []
        var currentBatchIsReadOnly = true

        for call in calls {
            let toolName = call.1.toolName ?? call.2
            let params = call.5
            let exclusivity = toolExclusivity(toolName: toolName, params: params)

            switch exclusivity {
            case .fullyExclusive:
                // shell.exec, git write — must run alone
                if !currentBatch.isEmpty {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                batches.append([call])
            case .fileExclusive(let path):
                // File change tools can parallel if they target different files.
                if currentBatchPaths.contains(path) || (!currentBatchIsReadOnly && !currentBatchPaths.isEmpty) {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                currentBatch.append(call)
                currentBatchPaths.insert(path)
                currentBatchIsReadOnly = false
            case .notExclusive:
                // read-only tools — always batch together
                if !currentBatchIsReadOnly {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                currentBatch.append(call)
            }
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        return batches
    }

    private enum ToolExclusivity {
        case notExclusive
        case fileExclusive(String)  // exclusive per-file path
        case fullyExclusive         // must run alone
    }

    private static func toolExclusivity(toolName: String, params: [String: String]) -> ToolExclusivity {
        if toolName == "shell.exec" { return .fullyExclusive }
        if isFileChangeTool(toolName) {
            let path = params["path"] ?? "unknown"
            return .fileExclusive(path)
        }
        if toolName == "git" {
            let subcommand = params["subcommand"] ?? ""
            let isWrite = ["add", "commit", "commit-auto", "checkout", "switch", "branch-create"].contains {
                subcommand.hasPrefix($0)
            }
            return isWrite ? .fullyExclusive : .notExclusive
        }
        return .notExclusive
    }

    static func usesOllamaChat(_ connector: ConnectorProfile) -> Bool {
        LiveChatRuntime.usesOllamaNativeProtocol(endpoint: connector.endpoint, kind: connector.kind)
    }

    static func meetsCompletionCriteria(
        task: AgentTask,
        intent: UserIntent,
        didComplete: Bool,
        hadFailure: Bool,
        wasTruncated: Bool,
        isReadOnlyRun: Bool = false
    ) -> Bool {
        guard didComplete, !wasTruncated else { return false }
        let successfulResults = task.steps.filter { $0.kind == .toolResult && !$0.isFailure }
        let failedResults = task.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let hasFinalOutput = task.steps.contains { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let message = task.steps.filter { $0.kind == .userInput }.map(\.text).joined(separator: "\n").lowercased()
        let hasWrite = Self.hasSuccessfulWrite(in: task)
        let hasSavedWiki = Self.hasSavedWiki(in: task)
        let expectsWikiOutput = Self.expectsWikiOutput(message)
        let hasUnrecoveredFailure = !failedResults.isEmpty && !Self.hasRecoveryAfterLastFailure(task)
        let hasVerificationFailure = task.steps.contains { $0.toolName == "verify.build" && $0.isFailure }

        if Self.hasSatisfiedImageGenerationRequest(task) {
            return !hasVerificationFailure
        }
        if expectsWikiOutput {
            return hasFinalOutput && (hasSavedWiki || hasWrite) && !hasUnrecoveredFailure
        }
        if hasUnrecoveredFailure && !isReadOnlyRun {
            return false
        }

        switch intent {
        case .chat:
            return hasFinalOutput
        case .research:
            let hasSearch = task.steps.contains { $0.kind == .toolCall && $0.toolName == "web.search" }
            let hasFetch = task.steps.contains { $0.kind == .toolCall && $0.toolName == "web.fetch" }
            return hasFinalOutput && hasSearch && hasFetch && failedResults.isEmpty
        case .task, .workflow:
            if isReadOnlyRun {
                return hasFinalOutput
            }
            if hasVerificationFailure { return false }
            if hadFailure && failedResults.count >= successfulResults.count { return false }
            if hasWrite {
                return hasFinalOutput || successfulResults.contains { isFileChangeTool($0.toolName ?? "") }
            }
            return hasFinalOutput && (!hadFailure || successfulResults.count >= 2)
        }
    }

    static func hasRecoveryAfterLastFailure(_ task: AgentTask) -> Bool {
        guard let lastFailureIndex = task.steps.lastIndex(where: { $0.kind == .toolResult && $0.isFailure }) else {
            return false
        }
        let later = task.steps.dropFirst(lastFailureIndex + 1)
        return later.contains { step in
            if step.kind == .toolResult, !step.isFailure {
                let recoveryTools: Set<String> = ["file.extract", "file.read", "wiki.build", "file.write", "file.edit", "diff.apply", "workspace.index", "code.search", "shell.exec", "web.fetch", "web.search"]
                return recoveryTools.contains(step.toolName ?? "")
            }
            if step.kind == .reviewRequest, step.approved == true {
                return true
            }
            return false
        }
    }

    static func resultStepParams(toolName: String, arguments: [String: String], result: ToolResult) -> [String: String] {
        guard toolName == "image.generate", let data = result.data else {
            return arguments
        }
        return arguments.merging(data) { _, resultValue in resultValue }
    }

    static func hasSuccessfulWrite(in task: AgentTask) -> Bool {
        return task.steps.contains { step in
            guard isFileChangeTool(step.toolName ?? "") else { return false }
            if step.kind == .reviewRequest, step.approved == true { return true }
            return step.kind == .toolResult && !step.isFailure
        }
    }

    static func hasSatisfiedImageGenerationRequest(_ task: AgentTask) -> Bool {
        let message = task.steps
            .filter { $0.kind == .userInput }
            .map(\.text)
            .joined(separator: "\n")
        guard expectsImageGeneration(message) else { return false }
        guard let deliveredIndex = task.steps.firstIndex(where: { isSuccessfulGeneratedImageResult($0) }) else { return false }
        let laterFailures = task.steps.dropFirst(deliveredIndex + 1).filter { $0.kind == .toolResult && $0.isFailure }
        return laterFailures.allSatisfy { $0.toolName == "image.generate" }
    }

    static func isSuccessfulGeneratedImageResult(_ step: TaskStep) -> Bool {
        guard step.kind == .toolResult, step.toolName == "image.generate", !step.isFailure else { return false }
        if let path = step.toolParams?["imagePath"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return step.text.contains("图片已生成") || step.text.contains("生成图片：")
    }

    static func expectsImageGeneration(_ message: String) -> Bool {
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        let actionMarkers = [
            "生成", "创建", "做一张", "做张", "做个", "画一张", "画张", "画个",
            "设计", "出一张", "出张", "出个", "来一张", "来张", "来个", "制作",
            "generate", "create", "draw", "design", "make"
        ]
        let imageMarkers = [
            "图片", "图像", "图", "配图", "插图", "海报", "封面", "主图", "介绍图",
            "宣传图", "商品图", "产品图", "详情图", "页面图", "生图", "banner", "logo", "头像", "壁纸",
            "poster", "image", "illustration", "cover", "thumbnail", "visual"
        ]
        let hasAction = actionMarkers.contains { lower.localizedCaseInsensitiveContains($0) }
        let hasImage = imageMarkers.contains { lower.localizedCaseInsensitiveContains($0) }
        guard hasAction && hasImage else { return false }
        let negativeContext = ["代码图", "架构图", "流程图", "类图", "mermaid", "截图", "看图", "读图", "图片里"]
        return !negativeContext.contains { lower.localizedCaseInsensitiveContains($0) }
    }

    static func hasSavedWiki(in task: AgentTask) -> Bool {
        task.steps.contains { step in
            step.kind == .toolResult
                && step.toolName == "wiki.build"
                && !step.isFailure
                && (step.toolParams?["save"] == "true" || step.text.contains("已保存 Wiki"))
        }
    }

    static func needsWikiSaveNudge(message: String, task: AgentTask, isReadOnlyRun: Bool, hasWritten: Bool) -> Bool {
        expectsWikiOutput(message)
            && !isReadOnlyRun
            && !hasSavedWiki(in: task)
            && !hasWritten
    }

    static func completionQualityIssues(
        task: AgentTask,
        message: String,
        workspaceRoot: String,
        hasWritten: Bool,
        expectsWiki: Bool
    ) -> [String] {
        var issues: [String] = []
        let failedWrites = task.steps.filter { $0.kind == .toolResult && $0.isFailure == true && isFileChangeTool($0.toolName ?? "") }
        if !failedWrites.isEmpty {
            issues.append("有 \(failedWrites.count) 次文件写入失败")
        }

        let wroteCode = task.steps.contains { step in
            guard step.kind == .toolCall, isFileChangeTool(step.toolName ?? "") else { return false }
            let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
            return codeExts.contains((pathForFileChange(callStep: step) as NSString).pathExtension.lowercased())
        }
        let hadVerify = task.steps.contains { $0.kind == .toolCall && $0.toolName == "verify.build" }
        if wroteCode && !hadVerify && ValidationEngine.suggestVerificationCommand(workspaceRoot: workspaceRoot) != nil {
            issues.append("写了代码但没有 verify_build 验证编译")
        }

        let lower = message.lowercased()
        let expectsWrite = lower.contains("创建") || lower.contains("写入") || lower.contains("新建") || lower.contains("修改") || lower.contains("修复")
        if expectsWrite && !hasWritten {
            issues.append("用户要求创建/修改文件，但没有任何写入操作")
        }
        if expectsWiki && !hasSavedWiki(in: task) && !hasWritten {
            issues.append("用户要求整理到 Wiki/知识库，但没有保存任何 Wiki 笔记")
        }
        return issues
    }

    func runFallbackWikiBuildIfNeeded(
        message: String,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        emitMissingMaterialFailure: Bool = false,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool? {
        guard Self.expectsWikiOutput(message),
              !Self.hasSavedWiki(in: task),
              !Self.hasSuccessfulWrite(in: task) else {
            return nil
        }

        guard let source = Self.fallbackWikiSource(message: message, taskContext: taskContext) else {
            guard emitMissingMaterialFailure else { return nil }
            let noMaterialStep = TaskStep(
                kind: .error,
                text: "Wiki 任务没有可落盘的已读材料；请先读取或提取附件后继续。",
                isFailure: true,
                recoverable: true,
                retryAction: "继续处理"
            )
            task.steps.append(noMaterialStep)
            onStep(noMaterialStep)
            return false
        }

        guard isToolAllowed("wiki.build") else {
            let blockedStep = TaskStep(
                kind: .error,
                text: "Wiki 任务必须保存笔记，但当前 Agent 工具权限不包含 wiki.build，无法完成落盘。",
                isFailure: true,
                recoverable: true,
                retryAction: "允许 wiki.build 后重试"
            )
            task.steps.append(blockedStep)
            onStep(blockedStep)
            return false
        }
        guard let wikiTool = toolRegistry.tool(named: "wiki_build") ?? toolRegistry.tool(named: "wiki.build") else {
            let missingStep = TaskStep(
                kind: .error,
                text: "Wiki 任务必须保存笔记，但工具注册表中没有 wiki.build。",
                isFailure: true,
                recoverable: true
            )
            task.steps.append(missingStep)
            onStep(missingStep)
            return false
        }

        let gateStep = TaskStep(
            kind: .aiThinking,
            text: "编排层兜底：模型未完成 Wiki 保存，正在基于已提取材料自动调用 wiki_build(save=true)。",
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(gateStep)
        onStep(gateStep)

        let topic = Self.fallbackWikiTopic(message: message, sourcePath: source.path)
        guard let atomicResult = await executeFallbackWikiBuild(
            tool: wikiTool,
            topic: topic,
            mode: "atomic",
            source: source,
            taskContext: taskContext,
            task: &task,
            onStep: onStep
        ) else {
            return false
        }
        guard atomicResult.success else {
            return false
        }

        taskContext.memory.appendDecision("已保存 Wiki：\(topic)")

        if let mocResult = await executeFallbackWikiBuild(
            tool: wikiTool,
            topic: topic,
            mode: "moc",
            source: source,
            taskContext: taskContext,
            task: &task,
            onStep: onStep,
            emitFailure: false
        ), mocResult.success {
            taskContext.memory.appendDecision("已保存 Wiki 索引：\(topic)")
        }

        let savedPath = atomicResult.data?["path"] ?? "02 Atomic/\(topic).md"
        let doneStep = TaskStep(
            kind: .textOutput,
            text: "已基于已提取材料保存 Wiki 笔记：\(topic) → \(savedPath)。",
            isCollapsible: false,
            isCollapsed: false
        )
        task.steps.append(doneStep)
        onStep(doneStep)
        return true
    }

    private func executeFallbackWikiBuild(
        tool: any LaicaiTool,
        topic: String,
        mode: String,
        source: FallbackWikiSource,
        taskContext: TaskContext,
        task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void,
        emitFailure: Bool = true
    ) async -> ToolResult? {
        let args: [String: Any] = [
            "topic": topic,
            "mode": mode,
            "save": true,
            "topK": 8,
            "sourceTitle": source.title,
            "sourcePath": source.path,
            "sourceText": String(source.text.prefix(40_000))
        ]
        let argumentsJSON = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let params = Self.displayParamsFromJSON(argumentsJSON)
        let callId = "call_fallback_wiki_\(mode)_\(UUID().uuidString.prefix(8))"
        let callStep = TaskStep(
            kind: .toolCall,
            text: "编排层兜底：" + ToolStepFormatter.callText(toolName: "wiki.build", arguments: params),
            toolName: "wiki.build",
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (result, _) = await ValidationEngine.executeWithValidationJSON(
            tool: tool,
            argumentsJSON: argumentsJSON,
            context: taskContext,
            maxRetries: 1
        )
        if result.success || emitFailure {
            let resultText = ToolResultFormatter.displayText(
                toolName: "wiki.build",
                arguments: params,
                result: result
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: resultText,
                toolName: "wiki.build",
                toolParams: params,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !result.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)
        }
        return result
    }

    private struct FallbackWikiSource {
        var path: String
        var title: String
        var text: String
    }

    private static func fallbackWikiSource(message: String, taskContext: TaskContext) -> FallbackWikiSource? {
        var candidates: [String] = []
        if let path = firstLocalPath(in: message) {
            candidates.append(path)
        }
        candidates.append(contentsOf: taskContext.memory.readFiles)
        candidates.append(contentsOf: taskContext.memory.fileContentCache.keys.sorted())

        var seen: Set<String> = []
        for rawPath in candidates {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let variants = [
                path,
                path.hasPrefix("/") ? path : (taskContext.workspaceRoot as NSString).appendingPathComponent(path)
            ]
            for variant in variants {
                guard let content = taskContext.memory.fileContentCache[variant] ?? taskContext.memory.fileContentCache[path] else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 20 else { continue }
                return FallbackWikiSource(
                    path: variant,
                    title: URL(fileURLWithPath: variant).lastPathComponent,
                    text: trimmed
                )
            }
        }
        return nil
    }

    private static func fallbackWikiTopic(message: String, sourcePath: String) -> String {
        if let path = firstLocalPath(in: message) ?? (sourcePath.isEmpty ? nil : sourcePath) {
            let url = URL(fileURLWithPath: path)
            var parts = url.pathComponents
            let fileBase = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"[\s_-]?(20\d{2}|[01]?\d[0-3]?\d)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !parts.isEmpty { parts.removeLast() }
            let parentNames = parts.suffix(2).filter { part in
                !["Desktop", "Downloads", "Documents", "文件"].contains(part)
            }
            let prefix = parentNames.joined()
            let topic = prefix.isEmpty || fileBase.contains(prefix) ? fileBase : prefix + fileBase
            let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return String(cleaned.prefix(80)) }
        }
        let compact = message
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .replacingOccurrences(of: "整理到", with: "")
            .replacingOccurrences(of: "wiki", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact?.isEmpty == false ? String(compact!.prefix(80)) : "整理资料"
    }

    static func autoExtractUnsupportedRead(path: String, extractTool: any LaicaiTool, context: TaskContext) async -> ToolResult? {
        let extractArgs: [String: Any] = ["path": path, "limit": 60_000]
        let extractJSON = (try? JSONSerialization.data(withJSONObject: extractArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let extractResult = try? await extractTool.execute(argumentsJSON: extractJSON, context: context)
        guard let extractResult, extractResult.success else { return nil }
        return extractResult
    }

    static func runBootstrapFileExtract(
        path: String,
        extractTool: any LaicaiTool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        callId: String = "call_bootstrap_file_extract",
        maxTokens: Int,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> ChatMessage {
        let argumentsJSON = bootstrapExtractArgumentsJSON(for: path)
        let toolParams = displayParamsFromJSON(argumentsJSON)
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: "file.extract", arguments: toolParams),
            toolName: "file.extract",
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
            tool: extractTool,
            argumentsJSON: argumentsJSON,
            context: taskContext
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: ToolResultFormatter.displayText(toolName: "file.extract", arguments: toolParams, result: toolResult),
            toolName: "file.extract",
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !toolResult.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)
        if toolResult.success {
            taskContext.memory.readFiles.append(path)
            taskContext.memory.fileContentCache[path] = toolResult.output
        }

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "file.extract",
            result: toolResult,
            limit: maxTokens
        )
        let instruction = toolResult.success
            ? "我已直接提取用户提供的表格/文档。请基于真实提取结果继续完成任务；如果用户要求整理到 Wiki，必须调用 wiki_build(save=true) 保存笔记。"
            : "我尝试提取用户提供的表格/文档但失败。请明确说明失败原因，不能编造文件内容。"
        return ChatMessage(
            role: "user",
            content: """
            \(instruction)

            \(resultContent)
            """
        )
    }

    static func runBootstrapFileRead(
        path: String,
        readTool: any LaicaiTool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        callId: String = "call_bootstrap_file_read",
        maxTokens: Int,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        let argumentsJSON = bootstrapReadArgumentsJSON(for: path)
        let toolParams = displayParamsFromJSON(argumentsJSON)
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: "file.read", arguments: toolParams),
            toolName: "file.read",
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
            tool: readTool,
            argumentsJSON: argumentsJSON,
            context: taskContext
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: ToolResultFormatter.displayText(toolName: "file.read", arguments: toolParams, result: toolResult),
            toolName: "file.read",
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !toolResult.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)

        let readContent = ToolResultFormatter.modelContent(
            toolName: "file.read",
            result: toolResult,
            limit: maxTokens
        )
        return """

        自动读取的首个高相关文件片段（\(path)）：
        \(readContent)
        """
    }

    static func shouldBootstrapExtract(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["xlsx", "xlsm", "csv", "tsv"].contains(ext)
    }

    /// Send a lightweight no-tools LLM call to produce an execution plan.
    /// Returns nil if planning fails or times out (non-blocking: agent proceeds without plan).
    @MainActor
    static func generatePlan(
        message: String,
        intent: UserIntent,
        context: TaskContext,
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        maxTokens: Int = 1024
    ) async throws -> String? {
        let modeLabel: String
        switch intent {
        case .task: modeLabel = "任务"
        case .research: modeLabel = "研究"
        case .workflow(let name): modeLabel = "工作流(\(name))"
        default: return nil
        }

        let fileContext: String
        if !context.relevantFiles.isEmpty {
            let list = context.relevantFiles.prefix(10)
                .map { "- \($0.path)" }
                .joined(separator: "\n")
            fileContext = "\n已知工作区文件：\n\(list)"
        } else {
            fileContext = ""
        }

        let planPrompt = """
        你是执行计划生成器。用户的\(modeLabel)请求如下：

        「\(message)」
        \(fileContext)

        请用 3-6 行输出一个精简的执行计划，格式：
        1. [具体动作] — [目标文件或工具]
        2. …

        规则：
        - 每步必须是具体可执行的动作（读取X文件、搜索Y、编辑Z函数、运行命令W）
        - 不要写"理解需求"、"制定计划"这类废话
        - 优先 file_edit 而非 file_write
        - 最后一步必须是验证或总结
        """

        let planMessages = [
            ChatMessage(role: "system", content: "你是计划生成器，只输出执行步骤，不要解释。"),
            ChatMessage(role: "user", content: planPrompt)
        ]

        let request = SendMessageRequest(
            sessionID: UUID(),
            message: planPrompt,
            connector: connector,
            modeLabel: "计划",
            systemPrompt: "你是计划生成器，只输出执行步骤，不要解释。",
            tools: [],
            messages: planMessages,
            maxOutputTokens: maxTokens
        )

        let response: SendMessageResponse = try await withThrowingTaskGroup(of: SendMessageResponse.self) { group in
            group.addTask {
                try await runtime.sendMessage(request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000) // 8s timeout
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let plan = response.assistantText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !plan.isEmpty, plan.count > 10 else { return nil }
        return String(plan.prefix(800))
    }

    // Legacy static plan (kept for backward compat with stagePlan references)
    static func stagePlan(for message: String, intent: UserIntent) -> String {
        // Planning is now done by generatePlan() via LLM call
        return ""
    }

    static func stageSummaryStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool) -> TaskStep {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let failedTools = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let readFiles = Set(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        var lines = ["阶段总结"]
        lines.append("Plan：已建立执行路径。")
        lines.append("Execute：执行 \(toolCalls) 次工具调用，读取 \(readFiles.count) 个文件。")
        if wasTruncated {
            lines.append("Verify：输出被截断，已进入续写保护。")
        } else if hadFailure || failedTools > 0 {
            lines.append("Verify：发现 \(failedTools) 个失败工具，需要继续恢复或换路径。")
        } else if didComplete {
            lines.append("Verify：已形成回复，未发现未恢复的失败工具。")
        } else {
            lines.append("Verify：尚未形成完整最终回复。")
        }
        lines.append("Summarize：\(didComplete && !hadFailure && !wasTruncated ? "本轮可视为完成。" : "本轮仍需继续。")")
        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: true,
            isFailure: hadFailure
        )
    }

    static func shouldEmitStageSummary(for task: AgentTask, hasPlan: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> Bool {
        if hasPlan || hadFailure || wasTruncated {
            return true
        }
        if isReadOnlyRun {
            return false
        }
        return task.steps.contains { step in
            isFileChangeTool(step.toolName ?? "") || ["shell.exec", "verify.build"].contains(step.toolName ?? "") || step.kind == .error
        }
    }

    static func evidenceChecklistStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> TaskStep? {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }
        guard !toolCalls.isEmpty || hadFailure || wasTruncated else { return nil }
        let hasWriteOrCommand = toolCalls.contains {
            isFileChangeTool($0.toolName ?? "") || ["shell.exec", "verify.build"].contains($0.toolName ?? "")
        }
        guard hadFailure || wasTruncated || hasWriteOrCommand || (!isReadOnlyRun && toolCalls.count >= 4) else { return nil }

        let readFiles = uniqueValues(task.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchQueries = uniqueValues(toolCalls
            .filter { $0.toolName == "code.search" || $0.toolName == "web.search" }
            .compactMap { $0.toolParams?["query"] })
        let indexed = task.steps.contains { $0.kind == .toolResult && $0.toolName == "workspace.index" && !$0.isFailure }
        let commands = uniqueValues(toolCalls
            .filter { $0.toolName == "shell.exec" || $0.toolName == "verify.build" }
            .compactMap { $0.toolParams?["command"] })
        let writeReviews = task.steps.filter { $0.kind == .reviewRequest }.compactMap(\.diffFilePath)
        let failedTools = Dictionary(grouping: task.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted()

        var lines = ["证据清单"]
        lines.append("状态：\(didComplete && !hadFailure && !wasTruncated ? "已形成结果" : "仍需继续")")
        if indexed { lines.append("已建立项目索引：是") }
        if !readFiles.isEmpty { lines.append("已读文件：\(readFiles.prefix(12).joined(separator: "、"))") }
        if !searchQueries.isEmpty { lines.append("已搜索：\(searchQueries.prefix(8).joined(separator: "、"))") }
        if !commands.isEmpty { lines.append("已运行命令：\(commands.prefix(6).joined(separator: "、"))") }
        if !writeReviews.isEmpty { lines.append("待审查/已审查文件：\(uniqueValues(writeReviews).prefix(8).joined(separator: "、"))") }
        if !failedTools.isEmpty { lines.append("失败工具：\(failedTools.joined(separator: "、"))") }
        if wasTruncated { lines.append("未验证：输出仍可能被截断，需要沿用本任务继续。") }
        if hadFailure { lines.append("未验证：存在未恢复失败，需要重试或换路径。") }
        if lines.count == 2 && !indexed {
            lines.append("已调用工具：\(uniqueValues(toolCalls.compactMap(\.toolName)).joined(separator: "、"))")
        }

        return TaskStep(
            kind: .aiThinking,
            text: lines.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: false,
            isFailure: hadFailure
        )
    }

    static func shouldContinueTruncatedOutputOnly(message: String, priorSteps: [TaskStep]) -> Bool {
        guard hasTruncatedOutput(in: priorSteps) else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let markers = [
            "继续", "接着说", "继续输出", "继续说", "接着输出", "没发完", "没写完",
            "没说完", "没结束", "被截断", "截断了", "断了", "后面呢", "剩下的", "接上"
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func hasTruncatedOutput(in steps: [TaskStep]) -> Bool {
        steps.contains { step in
            step.text.contains("输出达到当前上限")
                || step.text.contains("回复已被截断")
                || step.text.contains("回复仍被截断")
                || step.text.contains("内容可能被截断")
                || step.text.contains("输出上限截断")
        }
    }

    static func lastTextOutput(in steps: [TaskStep]) -> String? {
        steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func continueTruncatedOutput(
        taskID: UUID,
        originalMessage: String,
        previousText: String,
        messages: [ChatMessage],
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        maxOutputTokens: Int,
        originalStepID: UUID? = nil
    ) async throws -> TaskStep? {
        var continuationMessages = messages
        continuationMessages.append(ChatMessage(role: "assistant", content: previousText))
        continuationMessages.append(ChatMessage(
            role: "user",
            content: """
            上一条回复因为输出上限被截断。请从截断处无缝继续，直接输出剩余内容：
            - 不要重写开头
            - 不要总结已经写过的部分
            - 不要重新调用工具
            - 如果确实已经完成，只输出最后缺失的收尾

            原始用户目标：\(originalMessage)
            """
        ))

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: taskID,
            message: "继续输出被截断的上一段",
            connector: connector,
            modeLabel: "任务",
            history: [],
            systemPrompt: nil,
            tools: nil,
            messages: continuationMessages,
            maxOutputTokens: maxOutputTokens
        ))
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksLikeProviderError(text) else { return nil }
        let finalText = response.finishReason == "length"
            ? text + "\n\n（回复仍被截断，可以继续在本任务里发送“接着说”。）"
            : text
        return TaskStep(
            kind: .textOutput,
            text: finalText,
            isCollapsible: false,
            isCollapsed: false,
            metrics: response.metrics,
            continuationOf: originalStepID
        )
    }

    func executeRecoveryTool(
        displayName: String,
        argumentsJSON: String,
        task: inout AgentTask,
        messages: inout [ChatMessage],
        context: TaskContext,
        usesOllamaChat: Bool,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        let canonicalName = ToolNameCodec.canonicalName(displayName)
        guard isToolAllowed(canonicalName) else {
            let blockedStep = TaskStep(
                kind: .toolResult,
                text: "已跳过自动恢复工具：\(canonicalName)。当前执行级别不允许该工具；不会为了恢复而升级权限。",
                toolName: canonicalName,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: false
            )
            task.steps.append(blockedStep)
            onStep(blockedStep)
            return false
        }
        guard let tool = toolRegistry.tool(named: displayName) else {
            return false
        }

        let params = parseParamsFromJSON(argumentsJSON)
        let callId = "call_recovery_\(ToolNameCodec.apiName(canonicalName))_\(UUID().uuidString.prefix(8))"
        let callStep = TaskStep(
            kind: .toolCall,
            text: "自动恢复：" + ToolStepFormatter.callText(toolName: canonicalName, arguments: params),
            toolName: canonicalName,
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let result: ToolResult
        if Self.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) {
            result = Self.approvalRequiredToolResult(toolName: canonicalName)
        } else {
            let validated = await ValidationEngine.executeWithValidationJSON(
                tool: tool,
                argumentsJSON: argumentsJSON,
                context: context,
                maxRetries: 1
            )
            result = validated.result
        }
        let resultText = ToolResultFormatter.displayText(
            toolName: canonicalName,
            arguments: params,
            result: result
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: result.success ? "自动恢复成功：\(resultText)" : "自动恢复失败：\(resultText)",
            toolName: canonicalName,
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !result.success
        )
        task.steps.append(resultStep)
        onStep(resultStep)

        let resultContent = ToolResultFormatter.modelContent(
            toolName: canonicalName,
            result: result,
            limit: config.maxTokensPerTurn
        )
        messages.append(ChatMessage(
            role: "user",
            content: """
            自动恢复工具 \(canonicalName) 执行结果如下。请基于这些真实结果继续完成用户任务，不要重复已经失败的工具路径。

            \(resultContent)
            """
        ))
        return result.success
    }

    static func executeShellStreamingViaNotification(
        argumentsJSON: String,
        context: TaskContext,
        resultStepID: UUID,
        callID: String,
        command: String
    ) async -> ToolResult {
        struct Params: Codable {
            var command: String
            var timeout: Int?
        }
        let params: Params
        do {
            let data = argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: data)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let cmd = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let policySnapshot = SecurityManager.shared.policySnapshot
        if let securityError = ShellSecurityCheck(command: cmd, policy: policySnapshot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        if !context.workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: context.workspaceRoot)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return await withCheckedContinuation { continuation in
            let streamState = AgentShellStreamState()

            @Sendable func postUpdate(_ text: String, isFinal: Bool = false, isFailure: Bool = false) {
                NotificationCenter.default.post(
                    name: .shellStreamUpdate,
                    object: nil,
                    userInfo: [
                        "stepID": resultStepID,
                        "callID": callID,
                        "command": cmd,
                        "text": text.isEmpty ? "命令运行中…" : text,
                        "isFinal": isFinal,
                        "isFailure": isFailure
                    ]
                )
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                let snapshot = streamState.append(chunk)
                postUpdate(snapshot)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                let snapshot = streamState.append(chunk)
                postUpdate(snapshot)
            }

            do {
                try process.run()
                postUpdate("$ \(cmd)\n")
            } catch {
                continuation.resume(returning: ToolResult(output: "无法启动命令：\(error.localizedDescription)", success: false, error: "launch_failed"))
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Double(params.timeout ?? 30))
            timer.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            timer.resume()

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                timer.cancel()
                let (captured, shouldResume) = streamState.finish()
                guard shouldResume else { return }
                let exitCode = process.terminationStatus
                let body = captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "命令无输出" : captured
                let finalText = exitCode == 0 ? body : "命令失败（退出码 \(exitCode)）：\n\(body)"
                postUpdate(finalText, isFinal: true, isFailure: exitCode != 0)
                continuation.resume(returning: ToolResult(
                    output: finalText,
                    data: ["exitCode": "\(exitCode)", "streamed": "true"],
                    success: exitCode == 0,
                    error: exitCode == 0 ? nil : "exit_\(exitCode)"
                ))
            }
        }
    }

    static func extractHunks(from params: [String: String]) -> [DiffHunk] {
        guard let countStr = params["hunkCount"], let count = Int(countStr), count > 0 else { return [] }
        var hunks: [DiffHunk] = []
        for i in 0..<count {
            let oldText = params["hunk\(i).oldText"] ?? ""
            let newText = params["hunk\(i).newText"] ?? ""
            let summary = params["hunk\(i).summary"] ?? "Hunk \(i + 1)"
            hunks.append(DiffHunk(index: i, oldText: oldText, newText: newText, summary: summary))
        }
        return hunks
    }

    static func fileChangeReviewSteps(
        data: [String: String],
        toolName: String,
        toolParams: [String: String],
        callId: String,
        workspaceRoot: String
    ) -> [TaskStep] {
        var steps: [TaskStep] = []

        if let batchCountString = data["batchCount"], let batchCount = Int(batchCountString) {
            for batchIndex in 0..<batchCount {
                let prefix = "batch\(batchIndex)"
                guard let filePath = data["\(prefix).path"],
                      let oldContent = data["\(prefix).diffOld"],
                      let newContent = data["\(prefix).diffNew"],
                      !newContent.isEmpty else { continue }

                let fullPath = data["\(prefix).fullPath"] ?? resolvedFileChangePath(filePath, workspaceRoot: workspaceRoot)
                let createDirectories = data["\(prefix).createDirectories"] != "false"
                do {
                    try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
                } catch {
                    // Keep surfacing the attempted diff through the review step.
                }

                var reviewParams = toolParams
                for (key, value) in data where key.hasPrefix(prefix + ".") {
                    reviewParams[String(key.dropFirst(prefix.count + 1))] = value
                }
                reviewParams["batchIndex"] = "\(batchIndex + 1)"
                reviewParams["batchCount"] = "\(batchCount)"

                steps.append(fileChangeReviewStep(
                    text: "已写入文件（可回滚）（\(batchIndex + 1)/\(batchCount)）：\(filePath)",
                    toolName: toolName,
                    toolParams: reviewParams,
                    callId: callId,
                    filePath: filePath,
                    oldContent: oldContent,
                    newContent: newContent
                ))
            }
            return steps
        }

        guard let filePath = data["path"] ?? toolParams["path"],
              let oldContent = data["diffOld"],
              let newContent = data["diffNew"],
              !newContent.isEmpty else { return steps }

        let fullPath = data["fullPath"] ?? resolvedFileChangePath(filePath, workspaceRoot: workspaceRoot)
        let createDirectories = data["createDirectories"] != "false"
        var writeSucceeded = false
        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
            if let written = try? String(contentsOfFile: fullPath, encoding: .utf8),
               !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                writeSucceeded = true
            }
        } catch {
            // Surface the failure through a tool result step below.
        }

        if !writeSucceeded {
            steps.append(TaskStep(
                kind: .toolResult,
                text: "⚠️ 文件写入验证失败：\(filePath) 写入后为空。请检查工具参数并重试（确保 content 参数包含完整内容）。",
                toolName: toolName,
                toolCallId: callId,
                isFailure: true
            ))
        }

        var reviewParams = toolParams
        for (key, value) in data {
            reviewParams[key] = value
        }
        steps.append(fileChangeReviewStep(
            text: writeSucceeded ? "已写入文件（可回滚）：\(filePath)" : "写入失败（文件为空）：\(filePath)",
            toolName: toolName,
            toolParams: reviewParams,
            callId: callId,
            filePath: filePath,
            oldContent: oldContent,
            newContent: newContent
        ))
        return steps
    }

    private static func fileChangeReviewStep(
        text: String,
        toolName: String,
        toolParams: [String: String],
        callId: String,
        filePath: String,
        oldContent: String,
        newContent: String
    ) -> TaskStep {
        let hunks = extractHunks(from: toolParams)
        return TaskStep(
            kind: .reviewRequest,
            text: text,
            toolName: toolName,
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: false,
            isCollapsed: false,
            diffFilePath: filePath,
            diffOldContent: oldContent,
            diffNewContent: newContent,
            approved: true,
            diffHunks: hunks.isEmpty ? nil : hunks
        )
    }

    private static func resolvedFileChangePath(_ path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }

    static func completionCheckStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool = false, isReadOnlyRun: Bool = false) -> TaskStep {
        let toolFailures = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let hasRecoverySuccess = task.steps.contains {
            $0.kind == .toolResult && !$0.isFailure && $0.text.contains("自动恢复成功")
        }
        let hasOutput = task.steps.contains {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasApprovedWrite = task.steps.contains { $0.kind == .reviewRequest && $0.approved == true }
        let hasVerificationFailure = task.steps.contains {
            ["shell.exec", "verify.build"].contains($0.toolName ?? "") && $0.kind == .toolResult && $0.isFailure
        }
        let hasSatisfiedImageGeneration = Self.hasSatisfiedImageGenerationRequest(task)

        let text: String
        let isFailure: Bool
        if wasTruncated {
            text = "完成检查：回复被输出上限截断，尚未形成完整最终回复。请继续输出时沿用本任务上下文。"
            isFailure = false
        } else if hasSatisfiedImageGeneration {
            text = toolFailures > 0
                ? "完成检查：图片已成功生成；后续重复生图失败已记录，不影响本次图片交付。"
                : "完成检查：图片已成功生成。"
            isFailure = false
        } else if isReadOnlyRun && didComplete && hasOutput {
            text = toolFailures > 0
                ? "完成检查：已形成只读结论；\(toolFailures) 个工具失败被作为证据记录，不再自动升级为执行或重试。"
                : "完成检查：已形成只读结论，未发现失败工具。"
            isFailure = false
        } else if hasApprovedWrite && hasVerificationFailure {
            text = "完成检查：已批准写入但验证失败，建议根据错误信息生成修正 patch 并重新审查。"
            isFailure = true
        } else if (hadFailure || toolFailures > 0) && !(didComplete && hasRecoverySuccess) {
            text = "完成检查：发现 \(toolFailures) 个工具失败或模型错误，建议根据错误步骤重试或换一个执行路径。"
            isFailure = true
        } else if toolFailures > 0 && hasRecoverySuccess {
            text = "完成检查：发现 \(toolFailures) 个工具失败，但已自动降级恢复并形成最终回复。"
            isFailure = false
        } else if !didComplete || !hasOutput {
            text = "完成检查：任务没有形成明确输出，建议继续追问或补充目标。"
            isFailure = false
        } else {
            text = "完成检查：已形成最终回复，未发现失败工具。"
            isFailure = false
        }
        return TaskStep(
            kind: .aiThinking,
            text: text,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: isFailure
        )
    }

    static func finalizeFromCollectedEvidence(
        task: AgentTask,
        originalMessage: String,
        connector: ConnectorProfile,
        runtime: any ChatRuntimeClient,
        systemPrompt: String,
        maxOutputTokens: Int
    ) async throws -> TaskStep? {
        let evidence = task.steps
            .filter { $0.kind == .toolResult || $0.kind == .textOutput || $0.kind == .error }
            .suffix(12)
            .map { step -> String in
                let label: String
                switch step.kind {
                case .toolResult:
                    label = "工具结果\(step.toolName.map { "(\($0))" } ?? "")"
                case .textOutput:
                    label = "中间输出"
                case .error:
                    label = step.isFailure ? "错误" : "提示"
                default:
                    label = "记录"
                }
                return "- \(label)：\(compactSummaryText(step.text, limit: 700))"
            }
            .joined(separator: "\n")

        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Check if any real execution happened
        let hasExecution = task.steps.contains { step in
            step.kind == .toolCall && (isFileChangeTool(step.toolName ?? "") || step.toolName == "shell.exec")
        }

        let prompt: String
        if hasExecution {
            prompt = """
            本轮处理已结束，不要再调用工具。
            请基于下面已收集的真实结果，给用户一个简明最终回复：
            1. 已经执行了什么操作，结果如何
            2. 还没完成什么，为什么
            3. 用户接下来应该怎么做

            用户原始目标：
            \(originalMessage)

            已收集结果：
            \(evidence)
            """
        } else {
            prompt = """
            本轮处理已结束，不要再调用工具，也不要写研究报告。
            你只做了搜索和读取，没有真正执行任何操作。请直接告诉用户：
            1. 根据你收集的信息，用户应该运行什么具体命令来完成目标
            2. 给出可直接复制粘贴的命令（如 npm install、pip install、git clone 等）
            3. 如果需要创建文件，给出文件内容

            不要长篇分析。给出行动方案。

            用户原始目标：
            \(originalMessage)

            已收集结果：
            \(evidence)
            """
        }

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: prompt)
        ]

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: task.id,
            message: "",
            connector: connector,
            modeLabel: "收尾",
            systemPrompt: systemPrompt,
            tools: nil,
            messages: messages,
            maxOutputTokens: min(maxOutputTokens, 2000)
        ))
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksLikeProviderError(text) else { return nil }
        return TaskStep(
            kind: .textOutput,
            text: text,
            isCollapsible: false,
            isCollapsed: false,
            metrics: response.metrics
        )
    }

    public static func toolDefinitions(for intent: UserIntent, phase: TaskPhase = .explore, registry: ToolRegistry = .shared) -> [ToolDefinition] {
        let allDefs = registry.toolDefinitions
        let phaseDefs: [ToolDefinition]
        switch intent {
        case .chat:
            // Chat still gets tools so the model can read files, search, or write
            // when the user asks. Iteration cap keeps it from running away.
            let chatAllowed: Set<String> = [
                "file.read", "file.extract", "file.write", "file.edit", "diff.apply",
                "code.search", "web.search", "web.fetch",
                "wiki.build", "memory", "shell.exec", "skill.manage"
            ]
            phaseDefs = allDefs.filter { def in
                chatAllowed.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .research:
            let allowed: Set<String> = [
                "web.search", "web.fetch", "file.read", "file.extract",
                "code.search", "workspace.index"
            ]
            phaseDefs = allDefs.filter { def in
                allowed.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .task, .workflow:
            let allowed = phase.allowedTools
            phaseDefs = allDefs.filter { def in
                let canonical = ToolNameCodec.canonicalName(def.function.name)
                return allowed.contains(canonical)
            }
        }
        return phaseDefs.sorted { lhs, rhs in
            let lhsPriority = toolPriority(lhs.function.name, intent: intent, phase: phase)
            let rhsPriority = toolPriority(rhs.function.name, intent: intent, phase: phase)
            if lhsPriority == rhsPriority {
                return lhs.function.name < rhs.function.name
            }
            return lhsPriority < rhsPriority
        }
    }

    private static func toolPriority(_ name: String, intent: UserIntent, phase: TaskPhase) -> Int {
        let canonical = ToolNameCodec.canonicalName(name)
        switch intent {
        case .research:
            return [
                "web.search": 0,
                "web.fetch": 1,
                "file.read": 2,
                "file.extract": 3,
                "code.search": 4,
                "workspace.index": 5
            ][canonical] ?? 20
        case .chat:
            return [
                "file.read": 0,
                "file.extract": 1,
                "code.search": 2,
                "web.search": 3,
                "web.fetch": 4,
                "workspace.index": 5
            ][canonical] ?? 20
        case .task, .workflow:
            let base: [String: Int]
            switch phase {
            case .explore:
                base = [
                    "workspace.index": 0,
                    "code.search": 1,
                    "file.read": 2,
                    "file.extract": 3,
                    "web.search": 4,
                    "web.fetch": 5,
                    "wiki.build": 6
                ]
            case .execute:
                base = [
                    "file.edit": 0,
                    "file.write": 1,
                    "diff.apply": 2,
                    "shell.exec": 3,
                    "file.read": 4,
                    "file.extract": 5,
                    "code.search": 6,
                    "wiki.build": 7,
                    "web.fetch": 8,
                    "web.search": 9
                ]
            case .verify:
                base = [
                    "verify.build": 0,
                    "shell.exec": 1,
                    "file.read": 2,
                    "file.extract": 3,
                    "code.search": 4,
                    "file.edit": 5,
                    "diff.apply": 6,
                    "git": 7
                ]
            case .summarize:
                base = [
                    "git": 0,
                    "file.read": 1,
                    "file.extract": 2,
                    "verify.build": 3,
                    "code.search": 4
                ]
            }
            return base[canonical] ?? 20
        }
    }

    /// Infer current task phase from accumulated steps.
    nonisolated public static func inferPhase(from steps: [TaskStep]) -> TaskPhase {
        // If there's been a file.write, we're past explore
        let hasWrite = steps.contains { isFileChangeTool($0.toolName ?? "") }
        // If there's been a verify/complete check, we're in verify or summarize
        let hasVerifyCheck = steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("完成检查") }
        // If there's been a final text output after verify, we're summarizing
        let hasFinalOutput = steps.last?.kind == .textOutput && hasVerifyCheck

        if hasFinalOutput { return .summarize }
        if hasVerifyCheck { return .verify }
        if hasWrite { return .verify }
        // If we've read/searched enough, move to execute
        let readCount = steps.filter { $0.toolName == "file.read" && $0.kind == .toolResult && !$0.isFailure }.count
        let searchCount = steps.filter { $0.toolName == "code.search" && $0.kind == .toolCall }.count
        if readCount + searchCount >= 3 { return .execute }
        return .explore
    }

}
