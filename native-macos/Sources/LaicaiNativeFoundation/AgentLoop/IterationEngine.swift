import Foundation
import LaicaiNativeDomain

// MARK: - Iteration Engine
// Runs a single iteration of the agent loop: context refresh, LLM call,
// tool execution, post-tool analysis. Extracted from the inner while-loop
// of the monolithic run() method.

@MainActor
struct IterationEngine {

    /// Result of a single iteration.
    enum IterationResult {
        case continueLoop
        case breakLoop
    }

    // MARK: - Pre-Iteration Context Management

    /// Refresh tools on phase change, compress history, inject progress state.
    static func prepareIteration(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        allConnectors: [ConnectorProfile]
    ) {
        refreshPhaseIfNeeded(
            state: &state,
            config: config,
            toolRegistry: toolRegistry,
            allConnectors: allConnectors
        )
        compressOldToolResultsIfNeeded(state: &state)

        let tokenLimit = config.contextWindow
        let messageThreshold = max(20, tokenLimit / 5000)
        compressMessageCountIfNeeded(state: &state, messageThreshold: messageThreshold)
        compressTokenBudgetIfNeeded(state: &state, tokenLimit: tokenLimit, messageThreshold: messageThreshold)
        injectWorkingSetIfNeeded(state: &state)

        if state.iteration > 0 && state.iteration % 3 == 0 && state.intent != .chat {
            injectProgressState(state: &state, config: config)
        }
        if state.iteration == state.effectiveMaxIterations - 2 && state.iteration > 3 {
            state.messages.append(ChatMessage(role: "system", content: "即将结束本轮处理，请尽快给出结论或完成执行。"))
        }
    }

    private static func refreshPhaseIfNeeded(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        allConnectors: [ConnectorProfile]
    ) {
        guard config.supportsToolCalling, state.intent != .chat else { return }
        let newPhase = AgentLoop.inferPhase(from: state.task.steps)
        guard newPhase != state.currentPhase else { return }

        let oldPhase = state.currentPhase
        state.currentPhase = newPhase
        state.toolDefs = ContextBuilder.filterToolDefinitions(
            AgentLoop.toolDefinitions(for: state.intent, phase: state.currentPhase, registry: toolRegistry),
            allowedTools: config.allowedTools
        )
        appendToolAvailabilityUpdate(state: &state)
        compressPhaseTransitionIfNeeded(state: &state, oldPhase: oldPhase)
        routePhaseModelIfNeeded(state: &state, config: config, allConnectors: allConnectors)
    }

    private static func appendToolAvailabilityUpdate(state: inout PipelineState) {
        let names = state.toolDefs.map(\.function.name).sorted().joined(separator: "、")
        state.messages.append(ChatMessage(
            role: "system",
            content: "[工具可用性更新] 阶段切换到「\(state.currentPhase.title)」，当前真实可用工具：\(names)。以这份为准，不要引用更早的工具列表。"
        ))
    }

    private static func compressPhaseTransitionIfNeeded(state: inout PipelineState, oldPhase: TaskPhase) {
        guard state.messages.count > 10 else { return }
        let beforeCount = state.messages.count
        state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: 8)
        let compressedCount = beforeCount - state.messages.count
        let transitionSummary = "阶段转换：\(oldPhase.title) → \(state.currentPhase.title)。已压缩前序会话。继续执行计划中的下一步。"
        state.messages.append(ChatMessage(role: "system", content: transitionSummary))
        guard compressedCount > 0 else { return }
        let compressionStep = TaskStep(
            kind: .aiThinking,
            text: "已压缩前 \(compressedCount) 条消息以释放上下文空间（\(oldPhase.title) → \(state.currentPhase.title)）",
            isCollapsible: true,
            isCollapsed: false
        )
        state.task.steps.append(compressionStep)
    }

    private static func routePhaseModelIfNeeded(
        state: inout PipelineState,
        config: AgentLoop.Config,
        allConnectors: [ConnectorProfile]
    ) {
        guard !allConnectors.isEmpty,
              let routed = ModelRouter.selectModel(
                forPhase: state.currentPhase,
                connectors: allConnectors,
                activeConnectorID: state.connector.id
              ),
              routed.id != state.connector.id else { return }
        state.connector = routed
        state.task.connectorID = routed.id
        state.usesOllamaChat = AgentLoop.usesOllamaChat(routed)
        guard config.emitDebugSteps else { return }
        let routingStep = TaskStep(
            kind: .aiThinking,
            text: "已调整处理策略，继续执行。",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(routingStep)
    }

    private static func compressOldToolResultsIfNeeded(state: inout PipelineState) {
        guard state.iteration > 1 else { return }
        let recentKeep = state.messages.count > 6 ? state.messages.count - 6 : 0
        for index in 0..<recentKeep {
            guard let content = state.messages[index].content, content.count > 800 else { continue }
            guard isCompressibleToolResult(role: state.messages[index].role, content: content) else { continue }
            state.messages[index].content = String(content.prefix(500)) + "\n…（历史工具结果已压缩，原\(content.count)字符）"
        }
    }

    private static func isCompressibleToolResult(role: String, content: String) -> Bool {
        role == "tool"
            || (role == "user" && ["工具", "[TOOL_RESULT]", "✅", "编排层"].contains { content.hasPrefix($0) })
    }

    private static func compressMessageCountIfNeeded(state: inout PipelineState, messageThreshold: Int) {
        guard state.messages.count > messageThreshold else { return }
        let beforeCount = state.messages.count
        state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: max(15, messageThreshold - 5))
        let compressedCount = beforeCount - state.messages.count
        guard compressedCount > 0 else { return }
        let compressionStep = TaskStep(
            kind: .aiThinking,
            text: "上下文较长（\(beforeCount) 条消息），已压缩前 \(compressedCount) 条以释放空间",
            isCollapsible: true,
            isCollapsed: false
        )
        state.task.steps.append(compressionStep)
    }

    private static func compressTokenBudgetIfNeeded(
        state: inout PipelineState,
        tokenLimit: Int,
        messageThreshold: Int
    ) {
        let estimatedTokens = estimateTokens(state.messages, includeReasoning: true)
        let safeLimit = Int(Double(tokenLimit) * 0.8)
        guard estimatedTokens > safeLimit else { return }

        let beforeCount = state.messages.count
        state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: max(10, messageThreshold / 2))
        let compressedCount = beforeCount - state.messages.count
        if compressedCount > 0 {
            let tokenStep = TaskStep(
                kind: .aiThinking,
                text: "上下文 token 接近上限（约 \(estimatedTokens)/\(tokenLimit)），已压缩 \(compressedCount) 条消息",
                isCollapsible: true,
                isCollapsed: false
            )
            state.task.steps.append(tokenStep)
        }
        if estimateTokens(state.messages, includeReasoning: false) > safeLimit {
            state.messages = AgentLoop.truncateToolResults(state.messages, maxTokens: safeLimit)
        }
    }

    private static func estimateTokens(_ messages: [ChatMessage], includeReasoning: Bool) -> Int {
        messages.reduce(0) { sum, message in
            let reasoning = includeReasoning ? (message.reasoningContent ?? "") : ""
            return sum + estimatedTokens(for: (message.content ?? "") + reasoning)
        }
    }

    private static func estimatedTokens(for content: String) -> Int {
        let cjkCount = content.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let charsPerToken: Double = cjkCount > content.count / 3 ? 2.5 : 4.0
        return Int(Double(content.count) / charsPerToken)
    }

    private static func injectWorkingSetIfNeeded(state: inout PipelineState) {
        guard state.iteration > 1,
              !state.taskContext.memory.readFiles.isEmpty,
              !state.didInjectWorkingSet else { return }
        let workingSet = state.taskContext.memory.readFiles.prefix(8).map { path -> String in
            let name = URL(fileURLWithPath: path).lastPathComponent
            if let summary = state.taskContext.memory.fileSummaries[path], !summary.isEmpty {
                return "- \(name)：\(summary)"
            }
            return "- \(name)"
        }.joined(separator: "\n")
        if !workingSet.isEmpty {
            state.messages.append(ChatMessage(role: "system", content: "已读文件摘要（可直接 file_edit，无需再 file_read）：\n\(workingSet)"))
            state.didInjectWorkingSet = true
        }
    }

    // MARK: - Build Effective System Prompt

    /// After initial iterations, strip verbose guidance to free context window.
    static func effectiveSystemPrompt(basePrompt: String, iteration: Int) -> String {
        guard iteration >= 3 else { return basePrompt }
        var sections = basePrompt.components(separatedBy: "\n## ")
        let stripPrefixes = ["历史经验", "工具效率", "已学技能", "工具使用提示", "项目记忆"]
        sections = sections.filter { section in
            !stripPrefixes.contains(where: { section.hasPrefix($0) })
        }
        var result = sections.joined(separator: "\n## ")
        result += "\n\n[第\(iteration)轮] 直接行动，不要计划或解释。用最少步骤推进当前会话目标。"
        return result
    }

    // MARK: - Post-Tool-Call Analysis

    /// Analyze tool results and inject corrective guidance.
    static func analyzeToolResults(
        callSteps: [ToolCallEntry],
        toolCallResults: [ToolCallExecutionResult],
        state: inout PipelineState,
        config: AgentLoop.Config
    ) {
        var orchestrationNotes = individualToolResultNotes(callSteps: callSteps, toolCallResults: toolCallResults)
        orchestrationNotes.append(contentsOf: repeatedToolCallNotes(steps: state.task.steps))
        orchestrationNotes.append(contentsOf: applyCircuitBreakers(state: &state, config: config))
        if !orchestrationNotes.isEmpty {
            state.messages.append(ChatMessage(role: "system", content: "编排层提示：\n" + orchestrationNotes.joined(separator: "\n")))
        }

        appendPostToolNudges(callSteps: callSteps, toolCallResults: toolCallResults, state: &state, config: config)
    }

    private static func individualToolResultNotes(
        callSteps: [ToolCallEntry],
        toolCallResults: [ToolCallExecutionResult]
    ) -> [String] {
        toolCallResults.compactMap { entry in
            let step = callSteps[entry.responseIndex].callStep
            return noteForToolResult(step: step, result: entry.result)
        }
    }

    private static func noteForToolResult(step: TaskStep, result: ToolResult) -> String? {
        let toolName = step.toolName ?? ""
        if toolName == "verify.build", !result.success {
            return verifyFailureNote(result)
        }
        if toolName == "code.search", result.success, result.output.contains("未找到") {
            return "code.search 未找到结果。改用 shell_exec 的 find 或 grep 命令搜索，或检查关键词是否正确。"
        }
        if toolName == "file.read", !result.success, result.output.contains("是目录"), let path = step.toolParams?["path"] {
            return "\(path) 是目录不是文件。用 shell_exec ls 或 workspace_index 查看目录内容。"
        }
        if ["file.read", "file.extract"].contains(toolName),
           !result.success,
           ["unsupported_binary_file", "unsupported_file_type"].contains(result.error ?? "") {
            let target = step.toolParams?["path"] ?? "目标文件"
            return "`\(toolName)` 对 `\(target)` 是确定性失败，不要重复同参数调用。请换成受支持的提取方式或 shell_exec/系统工具；如果用户要求生成交付文件，必须真实创建目标文件后再总结。"
        }
        return nil
    }

    private static func verifyFailureNote(_ result: ToolResult) -> String? {
        let output = result.output.lowercased()
        if output.contains("command not found") || output.contains("no such file") {
            let badCommand = result.data?["command"] ?? "unknown"
            return "verify.build 失败原因是命令 `\(badCommand)` 不存在，不是代码问题。不要重试相同命令。如果是 npm/cargo/go 等构建工具不存在，跳过验证直接继续。"
        }
        if output.contains("不是 git 仓库") || output.contains("not a git repository") {
            return "当前工作区不是 git 仓库，git 相关操作会失败。跳过 git 操作。"
        }
        return nil
    }

    private static func repeatedToolCallNotes(steps: [TaskStep]) -> [String] {
        let signatures = steps.filter { $0.kind == .toolCall }.suffix(30).compactMap(toolSignature)
        let counts = Dictionary(grouping: signatures, by: { $0 }).mapValues(\.count)
        return counts.compactMap { signature, count in
            guard count >= 3 else { return nil }
            let parts = splitToolSignature(signature)
            return "⚠️ 循环检测：`\(parts.tool)` 对 `\(parts.target)` 已重复 \(count) 次。必须立即换一种完全不同的方法。不要再对同一目标重复相同操作。"
        }
    }

    private static func applyCircuitBreakers(state: inout PipelineState, config: AgentLoop.Config) -> [String] {
        let allToolResults = state.task.steps.filter { $0.kind == .toolResult }
        let failedCounts = Dictionary(grouping: allToolResults.compactMap(failedToolSignature), by: { $0 }).mapValues(\.count)
        var notes: [String] = []
        for (signature, count) in failedCounts where count >= 3 && !state.circuitBrokenTools.contains(signature) {
            state.circuitBrokenTools.insert(signature)
            notes.append(recordCircuitBreaker(signature: signature, count: count, allToolResults: allToolResults, state: state, config: config))
        }
        return notes
    }

    private static func recordCircuitBreaker(
        signature: String,
        count: Int,
        allToolResults: [TaskStep],
        state: PipelineState,
        config: AgentLoop.Config
    ) -> String {
        let parts = splitToolSignature(signature)
        let lastError = allToolResults.filter { $0.isFailure && $0.toolName == parts.tool }.last?.text ?? "unknown"
        let rootCause = "\(parts.tool) 对 \(parts.target) 连续失败 \(count) 次: \(String(lastError.prefix(200)))"
        FailurePatternDB.shared.record(
            intent: String(describing: state.intent),
            triggerTools: [parts.tool],
            triggerKeywords: [String(parts.target.prefix(30))],
            rootCause: rootCause,
            preemptiveInstruction: preemptiveInstruction(for: parts.tool),
            modelName: config.modelName
        )
        return "🔴 熔断：`\(parts.tool)` 对 `\(parts.target)` 已失败 \(count) 次。编排层将自动降级修复（file.edit→file.write, code.search→grep）。" +
            "\n后续如果再调用该组合，编排层会直接拦截并自动执行替代方案。" +
            "\n你只需告诉编排层要做什么（目标文件+内容），不必关心用什么工具。"
    }

    private static func preemptiveInstruction(for toolName: String) -> String {
        switch toolName {
        case "file.edit":
            return "历史已知：file.edit 对此类目标容易失败（参数格式/匹配问题），直接使用 file.write 全量写入更可靠"
        case "code.search":
            return "历史已知：code.search 对此类查询容易失败，优先使用 shell_exec grep 搜索"
        default:
            return "历史已知：\(toolName) 对此类目标容易失败，请使用替代工具"
        }
    }

    private static func toolSignature(step: TaskStep) -> String? {
        guard let name = step.toolName else { return nil }
        let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? step.toolParams?["command"] ?? ""
        return "\(name):\(target.prefix(60))"
    }

    private static func failedToolSignature(step: TaskStep) -> String? {
        guard step.isFailure, let name = step.toolName else { return nil }
        let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? ""
        return "\(name):\(target.prefix(60))"
    }

    private static func splitToolSignature(_ signature: String) -> (tool: String, target: String) {
        let parts = signature.split(separator: ":", maxSplits: 1)
        return (parts.first.map(String.init) ?? "unknown", parts.count > 1 ? String(parts[1]) : "")
    }

    private static func appendPostToolNudges(
        callSteps: [ToolCallEntry],
        toolCallResults: [ToolCallExecutionResult],
        state: inout PipelineState,
        config: AgentLoop.Config
    ) {
        let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
        let batchHadCodeWrite = toolCallResults.contains { entry in
            let step = callSteps[entry.responseIndex].callStep
            guard entry.result.success, AgentLoop.isFileChangeTool(step.toolName ?? "") else { return false }
            let path = AgentLoop.pathForFileChange(callStep: step, toolResult: entry.result)
            let ext = (path as NSString).pathExtension.lowercased()
            return codeExtensions.contains(ext)
        }
        let batchHadVerify = callSteps.contains { $0.callStep.toolName == "verify.build" }
        let hasBuildSystem = ValidationEngine.suggestVerificationCommand(workspaceRoot: state.taskContext.workspaceRoot) != nil
        // Only nudge verify when: code was written, no verify yet, build system exists,
        // AND we haven't already had verify failures (0% success rate indicates broken setup)
        let previousVerifyFailed = state.task.steps.contains { $0.toolName == "verify.build" && $0.isFailure == true }
        if batchHadCodeWrite && !batchHadVerify && isToolAllowed("verify.build", config: config) && hasBuildSystem && !previousVerifyFailed {
            let verifyNudge = "代码文件已修改。建议调用 verify_build 验证编译是否通过。如果失败，根据错误信息修复。"
            state.messages.append(ChatMessage(role: "user", content: verifyNudge))
        }

        // Early task completion detection
        let batchVerifyPassed = toolCallResults.contains { entry in
            callSteps[entry.responseIndex].callStep.toolName == "verify.build" && entry.result.success
        }
        let batchHadWrite = toolCallResults.contains { entry in
            let step = callSteps[entry.responseIndex].callStep
            if AgentLoop.isFileChangeTool(step.toolName ?? "") && entry.result.success { return true }
            return entry.result.success
                && step.toolName == "document.transform"
                && ["apply", "copy", "render"].contains(entry.result.data?["action"] ?? "")
        }
        let batchHadNonCodeWrite = toolCallResults.contains { entry in
            let step = callSteps[entry.responseIndex].callStep
            guard entry.result.success else { return false }
            if step.toolName == "document.transform" {
                return ["apply", "copy", "render"].contains(entry.result.data?["action"] ?? "")
            }
            guard AgentLoop.isFileChangeTool(step.toolName ?? "") else { return false }
            let path = AgentLoop.pathForFileChange(callStep: step, toolResult: entry.result)
            let ext = (path as NSString).pathExtension.lowercased()
            return !codeExtensions.contains(ext) && !ext.isEmpty
        }
        if (batchHadWrite && batchVerifyPassed) || (batchHadNonCodeWrite && !hasBuildSystem) {
            state.messages.append(ChatMessage(role: "system", content: "会话目标已完成：文件已成功写入\(batchVerifyPassed ? "且编译验证通过" : "")。请输出简短的完成总结，不要调用更多工具。"))
        }
    }

    // MARK: - Progress State Injection

    private static func injectProgressState(state: inout PipelineState, config: AgentLoop.Config) {
        var stateLines: [String] = []

        let readFiles = state.taskContext.memory.readFiles
        if !readFiles.isEmpty {
            let fileList = readFiles.suffix(10).map { "  \(URL(fileURLWithPath: $0).lastPathComponent)" }.joined(separator: "\n")
            stateLines.append("📖 已读文件（\(readFiles.count)个，可直接 file_edit）：\n\(fileList)")
        }

        let writtenPaths = state.taskContext.memory.userDecisions.compactMap { decision -> String? in
            decision.hasPrefix("已写入：") ? String(decision.dropFirst(4)) : nil
        }
        if !writtenPaths.isEmpty {
            stateLines.append("✏️ 已写入：\(writtenPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))")
        }

        let queries = state.taskContext.memory.searchedQueries
        if !queries.isEmpty {
            stateLines.append("🔍 已搜索：\(queries.joined(separator: "、"))（不要重复搜索这些词）")
        }

        let failedTools = state.taskContext.memory.failedTools
        if !failedTools.isEmpty {
            let failCounts = Dictionary(grouping: failedTools, by: { $0 }).mapValues(\.count)
            let failSummary = failCounts.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            stateLines.append("❌ 失败：\(failSummary)（不要用相同参数重试已失败的操作）")
        }

        let lastVerify = state.task.steps.last(where: { $0.toolName == "verify.build" })
        if let lastVerify {
            stateLines.append(lastVerify.isFailure == true ? "🔴 最近编译：失败" : "🟢 最近编译：通过")
        }

        let remaining = state.effectiveMaxIterations - state.iteration
        stateLines.append("⏱ 迭代预算：已用 \(state.iteration)/\(state.effectiveMaxIterations)，剩余 \(remaining)")

        if !stateLines.isEmpty {
            state.messages.append(ChatMessage(role: "system", content: "##会话状态（第 \(state.iteration) 轮）\n" + stateLines.joined(separator: "\n")))
        }
    }

    // MARK: - Utility

    private static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        AgentLoop.allowsTool(name, allowedTools: config.allowedTools)
    }
}
