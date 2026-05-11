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

    static func hasSuccessfulWrite(in task: AgentTask) -> Bool {
        return task.steps.contains { step in
            guard isFileChangeTool(step.toolName ?? "") else { return false }
            if step.kind == .reviewRequest, step.approved == true { return true }
            return step.kind == .toolResult && !step.isFailure
        }
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

        let text: String
        let isFailure: Bool
        if wasTruncated {
            text = "完成检查：回复被输出上限截断，尚未形成完整最终回复。请继续输出时沿用本任务上下文。"
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

    // MARK: - Model-Specific Tool Schema Adaptation

    /// Simplify tool definitions for models that struggle with complex schemas.
    /// Some models (especially local Ollama models, older DeepSeek versions) have trouble
    /// with too many tools or complex parameter descriptions.
    static func adaptToolDefsForModel(_ defs: [ToolDefinition], modelName: String) -> [ToolDefinition] {
        let model = modelName.lowercased()
        let isLocalOllama = model.contains("ollama") || model.contains("local")
        let isDeepSeek = model.contains("deepseek")
        let isQwen = model.contains("qwen")

        // Local models: limit to core tools, simplify descriptions
        if isLocalOllama {
            let coreTools: Set<String> = [
                "file_read", "file_write", "file_edit", "code_search",
                "shell_exec", "workspace_index"
            ]
            return defs
                .filter { coreTools.contains($0.function.name) }
                .map { simplifyDescription($0) }
        }

        // DeepSeek: keep all tools but shorten descriptions (sensitive to long schemas)
        if isDeepSeek {
            return defs.map { simplifyDescription($0) }
        }

        // Qwen: sometimes wraps tool calls in markdown — add strict formatting note
        // (handled in system prompt, not schema)
        if isQwen {
            return defs
        }

        return defs
    }

    private static func simplifyDescription(_ def: ToolDefinition) -> ToolDefinition {
        var d = def
        // Truncate long descriptions to 100 chars
        if d.function.description.count > 100 {
            d.function.description = String(d.function.description.prefix(97)) + "..."
        }
        // Truncate parameter descriptions
        var props = d.function.parameters.properties
        for (key, prop) in props {
            if let desc = prop.description, desc.count > 60 {
                props[key] = FunctionProperty(
                    type: prop.type,
                    description: String(desc.prefix(57)) + "...",
                    enumValues: prop.enumValues
                )
            }
        }
        d.function.parameters.properties = props
        return d
    }

    static func shouldBootstrapWebSearch(for message: String, intent: UserIntent) -> Bool {
        guard intent != .chat else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Research intent always bootstraps with web search
        if intent == .research { return true }

        let freshnessMarkers = [
            "今天", "今日", "最新", "新闻", "资讯", "趋势", "热点", "实时",
            "价格", "股价", "汇率", "天气", "版本", "发布", "更新",
            "today", "latest", "news", "current", "recent"
        ]
        if freshnessMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        if looksLikeCurrentModelComparison(text) {
            return true
        }

        // Market survey / recommendation patterns
        let explorationMarkers = [
            "市面上", "市场上", "有什么好用", "有什么有用", "有哪些好的", "有哪些有用",
            "都有什么", "都有哪些", "推荐", "哪个好", "选哪个", "用哪个"
        ]
        if explorationMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        let webActionMarkers = [
            "搜索一下", "搜一下", "搜搜", "查一下", "查找", "联网搜索", "上网查", "网页资料",
            "访问一下", "打开这个", "看看这个链接", "site:", "http://", "https://"
        ]
        return webActionMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func looksLikeCurrentModelComparison(_ text: String) -> Bool {
        let comparisonMarkers = ["对比", "比较", "强多少", "能力", "发布", "最新"]
        guard comparisonMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { return false }
        let modelMarkers = ["qwen", "gpt", "glm", "kimi", "claude", "deepseek", "llama", "gemini", "模型"]
        if modelMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return text.range(of: #"[a-zA-Z\u{4e00}-\u{9fff}]+[0-9]+(\.[0-9]+)?"#, options: .regularExpression) != nil
    }

    static func shouldRetryWithoutTools(
        response: SendMessageResponse,
        requestedTools: [ToolDefinition],
        hasRetriedWithoutTools: Bool
    ) -> Bool {
        guard !requestedTools.isEmpty, !hasRetriedWithoutTools else { return false }
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("请求格式不被")
                || text.hasPrefix("请求被拒绝")
                || text.localizedCaseInsensitiveContains("HTTP 400")
                || text.localizedCaseInsensitiveContains("HTTP 403") else { return false }
        let detail = ([text] + response.toolActivities.map { "\($0.summary) \($0.statusLine)" })
            .joined(separator: " ")
            .lowercased()
        return detail.contains("tool")
            || detail.contains("function")
            || detail.contains("schema")
            || detail.contains("400")
            || detail.contains("422")
            || detail.contains("兼容")
    }

    static func applyToolCompatibilityFallbackInstruction(to messages: inout [ChatMessage]) {
        let instruction = "\n\n## 工具兼容限制\n当前连接器不兼容工具调用。后续禁止再调用任何工具，也不要声称已经读取文件、搜索项目、联网、运行命令或写入文件。只能基于当前已知上下文直接回答；如果完成任务必须依赖工具，请明确说明当前连接器暂不兼容工具调用，并建议用户切换支持工具的连接器后重试。"
        if !messages.isEmpty, messages[0].role == "system" {
            messages[0].content = (messages[0].content ?? "") + instruction
            return
        }
        messages.insert(
            ChatMessage(role: "system", content: instruction.trimmingCharacters(in: .whitespacesAndNewlines)),
            at: 0
        )
    }

    static func isPureContinuationCommand(_ message: String) -> Bool {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 20 else { return false }
        let continuations = [
            "继续", "接着", "接着说", "继续输出", "继续说",
            "没发完", "没写完", "没说完", "被截断", "后面呢", "剩下的",
            "接着写", "接着输出", "说完", "写完", "继续吧", "go on",
            "continue", "keep going"
        ]
        return continuations.contains(where: { cleaned.localizedCaseInsensitiveContains($0) })
    }

    static func shouldBootstrapWorkspaceSearch(for message: String, intent: UserIntent, context: TaskContext) -> Bool {
        guard intent != .chat else { return false }
        guard !context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !shouldBootstrapWebSearch(for: message, intent: intent) else { return false }
        guard firstURL(in: message) == nil else { return false }
        guard !shouldBootstrapWorkspaceIndex(for: message, intent: intent) else { return false }
        return !bootstrapWorkspaceSearchQuery(for: message).isEmpty
    }

    static func shouldBootstrapWorkspaceIndex(for message: String, intent: UserIntent) -> Bool {
        guard intent != .chat else { return false }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, firstURL(in: text) == nil, firstLocalPath(in: text) == nil else { return false }
        let projectMarkers = ["项目", "工作区", "代码库", "工程", "repo", "repository"]
        // Only trigger full workspace indexing for explicit structural scan requests.
        // '优化', '改写', '找问题', '审查' etc. don't need full index first.
        let indexMarkers = ["全量", "全部", "整个", "整体", "结构", "架构", "扫描", "全面了解"]
        return projectMarkers.contains { text.localizedCaseInsensitiveContains($0) }
            && indexMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func bootstrapWebSearchArgumentsJSON(for message: String) -> String {
        let query = bootstrapWebSearchQuery(for: message)
        let payload: [String: Any] = [
            "query": query,
            "maxResults": 5
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"query":"\#(query)","maxResults":5}"#
        }
        return json
    }

    static func bootstrapWebSearchMessage(for message: String, priorSteps: [TaskStep]) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGenericWebFollowUp(cleaned),
              let subject = priorSteps
                .filter({ $0.kind == .userInput })
                .map(\.text)
                .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) != message.trimmingCharacters(in: .whitespacesAndNewlines) })?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            return message
        }
        return "\(subject) \(cleaned)"
    }

    static func bootstrapWorkspaceSearchArgumentsJSON(for message: String) -> String {
        let query = bootstrapWorkspaceSearchQuery(for: message)
        let payload: [String: Any] = [
            "query": query,
            "scope": "content",
            "maxResults": 8
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"query":"\#(query)","scope":"content","maxResults":8}"#
        }
        return json
    }

    static func bootstrapWorkspaceIndexArgumentsJSON(maxFiles: Int = 300, maxDepth: Int = 5) -> String {
        #"{"maxFiles":\#(maxFiles),"maxDepth":\#(maxDepth)}"#
    }

    static func bootstrapReadArgumentsJSON(for path: String) -> String {
        let payload: [String: Any] = [
            "path": path,
            "offset": 1,
            "limit": 160
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"path":"\#(path)","offset":1,"limit":160}"#
        }
        return json
    }

    static func bootstrapExtractArgumentsJSON(for path: String) -> String {
        let payload: [String: Any] = [
            "path": path,
            "limit": 60_000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"path":"\#(path)","limit":60000}"#
        }
        return json
    }

    static func firstReadablePath(inSearchOutput output: String, workspaceRoot: String) -> String? {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignoredExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "pdf", "zip", "gz", "dmg", "app",
                                               "ico", "svg", "woff", "woff2", "ttf", "eot", "map"]
        // Skip auto-generated, minified, vendor, and HTML-resource files
        let ignoredPatterns = ["_files/", "node_modules/", ".min.js", ".min.css", ".bundle.js",
                               "vendor/", "dist/", "DerivedData/", ".build/", "target/debug/", "target/release/"]
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("未找到") else { continue }
            let candidate = line.components(separatedBy: ":").first ?? line
            let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t`\"'"))
            guard !cleaned.isEmpty else { continue }
            let ext = (cleaned as NSString).pathExtension.lowercased()
            if ignoredExtensions.contains(ext) { continue }
            let lower = cleaned.lowercased()
            if ignoredPatterns.contains(where: { lower.contains($0) }) { continue }
            if !root.isEmpty, cleaned.hasPrefix(root + "/") {
                let relative = String(cleaned.dropFirst(root.count + 1))
                if !relative.isEmpty { return relative }
            }
            if !cleaned.hasPrefix("/") {
                return cleaned
            }
        }
        return nil
    }

    static func bootstrapWorkspaceSearchQuery(for message: String) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let genericContinuations = ["继续", "接着", "接着说", "继续输出", "继续说", "没发完", "没写完", "没说完", "被截断", "后面呢", "剩下的"]
        if genericContinuations.contains(where: { cleaned.localizedCaseInsensitiveContains($0) }) && cleaned.count <= 12 {
            return ""
        }
        if looksLikeBroadProjectImprovement(cleaned) {
            return #"TODO|FIXME|fatalError|print\(|mock|demo|Direct|直连|selectedTask|selectedSession|ChatSession|AgentTask"#
        }

        if let backtick = firstMatch(in: cleaned, pattern: #"`([^`]{2,80})`"#) {
            return backtick
        }
        if let fileLike = firstMatch(in: cleaned, pattern: #"[A-Za-z0-9_./-]+\.(swift|py|ts|tsx|js|jsx|md|json|yaml|yml|toml|txt)"#) {
            return fileLike
        }
        if let symbol = firstMatch(in: cleaned, pattern: #"[A-Za-z_][A-Za-z0-9_]{2,}"#) {
            return symbol
        }

        let stopWords: Set<String> = [
            "请", "帮我", "帮忙", "继续", "一下", "这个", "那个", "代码", "项目",
            "实现", "修复", "修改", "重构", "搜索", "查找", "看看", "解释", "说明"
        ]
        let normalized = cleaned
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .replacingOccurrences(of: "?", with: " ")
        let candidates = normalized
            .split(whereSeparator: { $0.isWhitespace || "/\\:：,.;；()[]{}<>「」『』".contains($0) })
            .map(String.init)
            .map { token in stopWords.reduce(token) { $0.replacingOccurrences(of: $1, with: "") } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        return candidates.first.map { String($0.prefix(40)) } ?? String(cleaned.prefix(40))
    }

    private static func looksLikeBroadProjectImprovement(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let projectMarkers = ["本地项目", "当前项目", "整个项目", "项目", "工作区"]
        let actionMarkers = ["优化", "改写", "改进", "重构", "看看问题", "找问题"]
        return projectMarkers.contains { lowered.localizedCaseInsensitiveContains($0) }
            && actionMarkers.contains { lowered.localizedCaseInsensitiveContains($0) }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        let targetRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let range = Range(targetRange, in: text) else { return nil }
        return String(text[range])
    }

    static func firstURL(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              let range = Range(match.range, in: message) else {
            return nil
        }
        return String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}"))
    }

    // MARK: - G2: Speculative Pre-Fetch

    struct SpeculativeResult {
        var cachedFiles: [String: String] = [:]   // path → content
        var summaries: [String: String] = [:]      // path → summary
    }

    /// While LLM is thinking, predict what it'll need next and pre-read files.
    /// Returns data to merge into taskContext after the LLM call completes.
    @MainActor
    static func speculativePreFetch(
        iteration: Int,
        taskContext: TaskContext,
        task: AgentTask,
        toolRegistry: ToolRegistry
    ) async -> SpeculativeResult {
        var result = SpeculativeResult()
        let recentSteps = task.steps.suffix(10)

        // After code.search → pre-read top 2 result files
        if let lastSearch = recentSteps.last(where: { $0.toolName == "code.search" && $0.kind == .toolResult }),
           !lastSearch.text.hasPrefix("未找到") {
            let paths = Self.extractReadablePaths(fromSearchOutput: lastSearch.text, workspaceRoot: taskContext.workspaceRoot, limit: 2)
            for path in paths where !taskContext.memory.readFiles.contains(path) {
                guard !Task.isCancelled else { return result }
                if let content = try? String(contentsOfFile: path, encoding: .utf8), content.count < 100_000 {
                    result.cachedFiles[path] = content
                    let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
                    let sigs = content.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
                        .prefix(8).joined(separator: "; ")
                    if !sigs.isEmpty { result.summaries[path] = String(sigs.prefix(300)) }
                }
            }
        }

        // After file.read → pre-read sibling files in same directory
        if let lastRead = recentSteps.last(where: { $0.toolName == "file.read" && $0.kind == .toolCall }),
           let path = lastRead.toolParams?["path"] {
            let dir = (path as NSString).deletingLastPathComponent
            guard !dir.isEmpty, !Task.isCancelled else { return result }
            let ext = (path as NSString).pathExtension.lowercased()
            if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                let sameType = siblings.filter { (($0 as NSString).pathExtension.lowercased()) == ext }.prefix(3)
                for sibling in sameType {
                    guard !Task.isCancelled else { return result }
                    let sibPath = (dir as NSString).appendingPathComponent(sibling)
                    if !taskContext.memory.readFiles.contains(sibPath),
                       taskContext.memory.fileContentCache[sibPath] == nil,
                       let content = try? String(contentsOfFile: sibPath, encoding: .utf8),
                       content.count < 50_000 {
                        result.cachedFiles[sibPath] = content
                    }
                }
            }
        }

        // After file.write/edit failure → pre-read the target file
        if let lastFail = recentSteps.last(where: { $0.isFailure == true && isFileChangeTool($0.toolName ?? "") }) {
            let path = pathForFileChange(callStep: lastFail)
            if !path.isEmpty,
               !taskContext.memory.readFiles.contains(path),
               !Task.isCancelled,
               let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.count < 100_000 {
                result.cachedFiles[path] = content
            }
        }

        // After verify.build failure → pre-read files mentioned in error output
        if let lastVerify = recentSteps.last(where: { $0.toolName == "verify.build" && $0.isFailure == true && $0.kind == .toolResult }) {
            let errorPaths = lastVerify.text.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Match "file.swift:123: error:" pattern
                    guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
                    let candidate = String(trimmed[..<colonIdx])
                    if candidate.hasPrefix("/") && FileManager.default.fileExists(atPath: candidate) { return candidate }
                    let absolute = (taskContext.workspaceRoot as NSString).appendingPathComponent(candidate)
                    if FileManager.default.fileExists(atPath: absolute) { return absolute }
                    return nil
                }
            for path in Set(errorPaths).prefix(3) {
                guard !Task.isCancelled else { return result }
                if !taskContext.memory.readFiles.contains(path) && result.cachedFiles[path] == nil {
                    if let content = try? String(contentsOfFile: path, encoding: .utf8), content.count < 100_000 {
                        result.cachedFiles[path] = content
                    }
                }
            }
        }

        // After file.edit success → pre-read nearby import/header files for verify context
        if let lastEdit = recentSteps.last(where: { $0.toolName == "file.edit" && $0.kind == .toolResult && !$0.isFailure }),
           let path = recentSteps.last(where: { $0.toolName == "file.edit" && $0.kind == .toolCall })?.toolParams?["path"] {
            let ext = (path as NSString).pathExtension.lowercased()
            let headerExts: [String: String] = ["swift": "swift", "c": "h", "cpp": "h", "m": "h", "mm": "h"]
            if let headerExt = headerExts[ext], headerExt != ext {
                let dir = (path as NSString).deletingLastPathComponent
                if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    for sibling in siblings.filter({ ($0 as NSString).pathExtension == headerExt }).prefix(2) {
                        guard !Task.isCancelled else { return result }
                        let sibPath = (dir as NSString).appendingPathComponent(sibling)
                        if !taskContext.memory.readFiles.contains(sibPath) && result.cachedFiles[sibPath] == nil {
                            if let content = try? String(contentsOfFile: sibPath, encoding: .utf8), content.count < 50_000 {
                                result.cachedFiles[sibPath] = content
                            }
                        }
                    }
                }
            }
            _ = lastEdit // silence unused warning
        }

        return result
    }

    /// Extract multiple readable paths from search output
    static func extractReadablePaths(fromSearchOutput output: String, workspaceRoot: String, limit: Int) -> [String] {
        var paths: [String] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard paths.count < limit else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var candidate: String?
            if trimmed.hasPrefix("/") {
                candidate = trimmed.components(separatedBy: ":").first
            } else if trimmed.contains(".") && !trimmed.hasPrefix("http") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if let first = parts.first, first.contains("/") {
                    candidate = (workspaceRoot as NSString).appendingPathComponent(first.components(separatedBy: ":").first ?? first)
                }
            }
            if let c = candidate, FileManager.default.fileExists(atPath: c), !paths.contains(c) {
                paths.append(c)
            }
        }
        return paths
    }

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

    /// User asked for a write/save/edit operation. Used by completion-claim guard.
    static func expectsWriteOutput(_ message: String) -> Bool {
        if expectsWikiOutput(message) { return true }
        let writeMarkers = [
            "写入", "写到", "保存", "存到", "落地", "记录到", "追加到",
            "修改", "改一下", "改成", "更新", "替换", "重写", "插入",
            "新建", "创建文件", "生成文件", "添加到",
            "整理到", "归档到", "导出到"
        ]
        return writeMarkers.contains { message.contains($0) }
    }

    /// Detect if model output claims completion of a write/save action.
    /// Used by the completion-claim guard to append a correction when no write actually succeeded.
    static func containsFalseCompletionClaim(_ text: String) -> Bool {
        let claims = [
            "已修改", "已经修改", "修改完成", "改完了", "改好了",
            "已写入", "已经写入", "写入完成",
            "已保存", "已经保存", "保存完成", "保存好了",
            "已落地", "已经落地",
            "已更新", "已经更新", "更新完成",
            "已添加", "已新增",
            "已创建", "已经创建",
            "已整理到", "已归档",
            "已完成"
        ]
        return claims.contains { text.contains($0) }
    }

    static func expectsWikiOutput(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("wiki")
            || lower.contains("知识库")
            || lower.contains("整理到")
            || lower.contains("整理成笔记")
            || lower.contains("obsidian")
    }

    /// F2: Rewrite tool arguments to fix common model mistakes before execution
    static func rewriteToolArguments(toolName: String, argumentsJSON: String, workspaceRoot: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return argumentsJSON
        }
        var changed = false

        // Fix 1: Relative paths → absolute paths for file tools
        if ["file.read", "file.write", "file.edit", "diff.apply"].contains(toolName),
           let path = dict["path"] as? String,
           !path.hasPrefix("/") && !workspaceRoot.isEmpty {
            dict["path"] = (workspaceRoot as NSString).appendingPathComponent(path)
            changed = true
        }

        // Fix 2: shell.exec — ensure 'command' param exists (some models use 'cmd')
        if toolName == "shell.exec" {
            if dict["command"] == nil, let cmd = dict["cmd"] as? String {
                dict["command"] = cmd
                dict.removeValue(forKey: "cmd")
                changed = true
            }
        }

        // Fix 3: code.search — ensure 'query' param (some models use 'keyword' or 'search')
        if toolName == "code.search" {
            if dict["query"] == nil {
                let alt = dict["keyword"] as? String ?? dict["search"] as? String ?? dict["pattern"] as? String
                if let alt {
                    dict["query"] = alt
                    changed = true
                }
            }
        }

        // Fix 4: file.write — ensure both path and content exist
        if toolName == "file.write" {
            if dict["content"] == nil, let text = dict["text"] as? String ?? dict["data"] as? String {
                dict["content"] = text
                changed = true
            }
        }

        guard changed, let rewritten = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: rewritten, encoding: .utf8) else {
            return argumentsJSON
        }
        return json
    }

    /// E2: Extract search keywords from user messages like "搜索 XXX" / "查找 XXX"
    static func extractSearchKeywords(from message: String) -> String? {
        let patterns = [
            #"(?:搜索|查找|找一下|search\s+(?:for\s+)?|grep\s+)[\s：:]*(.+)"#,
            #"(?:搜|找|查)\s*[\s：:][\s]*(.+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: message) {
                let keywords = String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !keywords.isEmpty && keywords.count < 100 { return keywords }
            }
        }
        return nil
    }

    /// Extract newText values from a file.edit edits JSON string.
    /// Used by circuit breaker auto-repair to salvage content from failed edits.
    static func extractNewTexts(from editsJSON: String) -> [String] {
        guard let data = editsJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["newText"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Extract all absolute paths from user message (for granting write access)
    static func extractAbsolutePaths(from message: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/(?:Users|home|tmp|var|opt|mnt)[^\n\r\t\s，。、；;）)\]}>\"']*"#) else {
            return []
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        let matches = regex.matches(in: message, options: [], range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range, in: message) else { return nil }
            let path = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}"))
            return path.count > 3 ? path : nil
        }
    }

    static func firstLocalPath(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/[^\n\r\t ]+"#) else {
            return nil
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: nsRange),
              let range = Range(match.range, in: message) else {
            return nil
        }
        return String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;）)]}>\"'"))
    }

    static func bootstrapWebFetchArgumentsJSON(for url: String) -> String {
        let payload: [String: Any] = [
            "url": url,
            "maxCharacters": 8000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"url":"\#(url)","maxCharacters":8000}"#
        }
        return json
    }

    static func bootstrapWebSearchQuery(for message: String) -> String {
        let cleaned = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsDate = ["今天", "今日", "最新", "新闻", "趋势", "today", "latest", "news"]
            .contains { cleaned.localizedCaseInsensitiveContains($0) }
        guard needsDate else { return cleaned }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        let today = formatter.string(from: Date())
        return cleaned.contains(today) ? cleaned : "\(cleaned) \(today)"
    }

    private static func isGenericWebFollowUp(_ message: String) -> Bool {
        let normalized = message
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: "。", with: " ")
            .replacingOccurrences(of: "！", with: " ")
            .replacingOccurrences(of: "？", with: " ")
            .lowercased()
        let words = normalized.split(whereSeparator: { $0.isWhitespace || ",.;；:：()[]{}".contains($0) }).map(String.init)
        guard !words.isEmpty else { return false }
        let genericMarkers = [
            "联网", "搜索", "搜", "搜一下", "搜搜", "查", "查一下", "上网",
            "另外", "如果", "可以", "输出", "一条", "两条", "不完", "直接", "继续"
        ]
        let topicLike = words.filter { word in
            !genericMarkers.contains(where: { word.contains($0) })
                && word.count >= 3
                && !word.localizedCaseInsensitiveContains("token")
        }
        return normalized.contains("联网") || normalized.contains("搜") || normalized.contains("查")
            ? topicLike.isEmpty
            : false
    }
}
