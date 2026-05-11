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
        // Re-infer phase and update tool definitions
        if config.supportsToolCalling && state.intent != .chat {
            let newPhase = AgentLoop.inferPhase(from: state.task.steps)
            if newPhase != state.currentPhase {
                let oldPhase = state.currentPhase
                state.currentPhase = newPhase
                state.toolDefs = ContextBuilder.filterToolDefinitions(
                    AgentLoop.toolDefinitions(for: state.intent, phase: state.currentPhase, registry: toolRegistry),
                    allowedTools: config.allowedTools
                )
                // Re-anchor ground truth
                let names = state.toolDefs.map(\.function.name).sorted().joined(separator: "、")
                state.messages.append(ChatMessage(
                    role: "system",
                    content: "[工具可用性更新] 阶段切换到「\(state.currentPhase.title)」，当前真实可用工具：\(names)。以这份为准，不要引用更早的工具列表。"
                ))

                // Phase transition → compress old messages
                if state.messages.count > 10 {
                    state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: 8)
                    let transitionSummary = "阶段转换：\(oldPhase.title) → \(state.currentPhase.title)。已压缩前序会话。继续执行计划中的下一步。"
                    state.messages.append(ChatMessage(role: "system", content: transitionSummary))
                }

                // Phase-based model routing
                if !allConnectors.isEmpty {
                    if let routed = ModelRouter.selectModel(forPhase: state.currentPhase, connectors: allConnectors, activeConnectorID: state.connector.id),
                       routed.id != state.connector.id {
                        let routingStep = TaskStep(
                            kind: .aiThinking,
                            text: "切换到\(routed.modelName.isEmpty ? routed.name : routed.modelName)处理\(state.currentPhase.title)阶段",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        state.task.steps.append(routingStep)
                    }
                }
            }
        }

        // Proactive tool result compression
        if state.iteration > 1 {
            let recentKeep = state.messages.count > 6 ? state.messages.count - 6 : 0
            for i in 0..<recentKeep {
                guard let content = state.messages[i].content, content.count > 800 else { continue }
                let isToolResult = state.messages[i].role == "tool"
                    || (state.messages[i].role == "user" && (content.hasPrefix("工具") || content.hasPrefix("[TOOL_RESULT]") || content.hasPrefix("✅") || content.hasPrefix("编排层")))
                if isToolResult {
                    state.messages[i].content = String(content.prefix(500)) + "\n…（历史工具结果已压缩，原\(content.count)字符）"
                }
            }
        }

        // Mid-task context compression
        let tokenLimit = config.contextWindow
        let messageThreshold = max(20, tokenLimit / 5000)
        if state.messages.count > messageThreshold {
            state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: max(15, messageThreshold - 5))
        }

        // Token-based compression
        let estimatedTokens = state.messages.reduce(0) { sum, msg in
            let content = (msg.content ?? "") + (msg.reasoningContent ?? "")
            let cjkCount = content.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            let charsPerToken: Double = cjkCount > content.count / 3 ? 2.5 : 4.0
            return sum + Int(Double(content.count) / charsPerToken)
        }
        let safeLimit = Int(Double(tokenLimit) * 0.8)
        if estimatedTokens > safeLimit {
            state.messages = AgentLoop.compressMidTaskHistory(state.messages, maxMessages: max(10, messageThreshold / 2))
            if state.messages.reduce(0, { sum, msg in
                let c = msg.content ?? ""
                let cjk = c.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                return sum + Int(Double(c.count) / (cjk > c.count / 3 ? 2.5 : 4.0))
            }) > safeLimit {
                state.messages = AgentLoop.truncateToolResults(state.messages, maxTokens: safeLimit)
            }
        }

        // Working Set injection
        if state.iteration > 1 && !state.taskContext.memory.readFiles.isEmpty {
            let workingSet = state.taskContext.memory.readFiles.prefix(8).compactMap { path -> String? in
                if let summary = state.taskContext.memory.fileSummaries[path], !summary.isEmpty {
                    return "- \(URL(fileURLWithPath: path).lastPathComponent)：\(summary)"
                }
                return "- \(URL(fileURLWithPath: path).lastPathComponent)"
            }.joined(separator: "\n")
            if !workingSet.isEmpty && !state.didInjectWorkingSet {
                state.messages.append(ChatMessage(role: "system", content: "已读文件摘要（可直接 file_edit，无需再 file_read）：\n\(workingSet)"))
                state.didInjectWorkingSet = true
            }
        }

        // Progress state injection
        if state.iteration > 0 && state.iteration % 3 == 0 && state.intent != .chat {
            injectProgressState(state: &state, config: config)
        }

        // Budget warning
        if state.iteration == state.effectiveMaxIterations - 2 && state.iteration > 3 {
            state.messages.append(ChatMessage(role: "system", content: "即将结束本轮处理，请尽快给出结论或完成执行。"))
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
        result += "\n\n[第\(iteration)轮] 直接行动，不要计划或解释。用最少步骤完成任务。"
        return result
    }

    // MARK: - Post-Tool-Call Analysis

    /// Analyze tool results and inject corrective guidance.
    static func analyzeToolResults(
        callSteps: [(Int, TaskStep, String, String, String, [String: String])],
        toolCallResults: [(Int, ToolResult, RecoveryPlan?)],
        state: inout PipelineState,
        config: AgentLoop.Config
    ) {
        var orchestrationNotes: [String] = []

        // Check individual tool results
        for (idx, toolResult, _) in toolCallResults {
            let step = callSteps[idx].1
            let tn = step.toolName ?? ""

            if tn == "verify.build" && !toolResult.success {
                let output = toolResult.output.lowercased()
                if output.contains("command not found") || output.contains("no such file") {
                    let badCmd = toolResult.data?["command"] ?? "unknown"
                    orchestrationNotes.append("verify.build 失败原因是命令 `\(badCmd)` 不存在，不是代码问题。不要重试相同命令。如果是 npm/cargo/go 等构建工具不存在，跳过验证直接继续。")
                } else if output.contains("不是 git 仓库") || output.contains("not a git repository") {
                    orchestrationNotes.append("当前工作区不是 git 仓库，git 相关操作会失败。跳过 git 操作。")
                }
            }
            if tn == "code.search" && toolResult.success && toolResult.output.contains("未找到") {
                orchestrationNotes.append("code.search 未找到结果。改用 shell_exec 的 find 或 grep 命令搜索，或检查关键词是否正确。")
            }
            if tn == "file.read" && !toolResult.success && toolResult.output.contains("是目录") {
                if let path = step.toolParams?["path"] {
                    orchestrationNotes.append("\(path) 是目录不是文件。用 shell_exec ls 或 workspace_index 查看目录内容。")
                }
            }
        }

        // Loop detector
        let allToolCalls = state.task.steps.filter { $0.kind == .toolCall }
        let recentToolCalls = allToolCalls.suffix(30)
        let recentSignatures = recentToolCalls.compactMap { step -> String? in
            guard let name = step.toolName else { return nil }
            let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? step.toolParams?["command"] ?? ""
            return "\(name):\(target.prefix(60))"
        }
        let signatureCounts = Dictionary(grouping: recentSignatures, by: { $0 }).mapValues(\.count)
        for (loopSig, count) in signatureCounts where count >= 3 {
            let parts = loopSig.split(separator: ":", maxSplits: 1)
            let loopTool = parts.first.map(String.init) ?? "unknown"
            let loopTarget = parts.count > 1 ? String(parts[1]) : ""
            orchestrationNotes.append("⚠️ 循环检测：`\(loopTool)` 对 `\(loopTarget)` 已重复 \(count) 次。必须立即换一种完全不同的方法。不要再对同一目标重复相同操作。")
        }

        // Hard circuit breaker
        let allToolResults = state.task.steps.filter { $0.kind == .toolResult }
        let failedSignatures = allToolResults.compactMap { step -> String? in
            guard step.isFailure, let name = step.toolName else { return nil }
            let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? ""
            return "\(name):\(target.prefix(60))"
        }
        let failedCounts = Dictionary(grouping: failedSignatures, by: { $0 }).mapValues(\.count)
        for (failSig, count) in failedCounts where count >= 3 {
            if !state.circuitBrokenTools.contains(failSig) {
                state.circuitBrokenTools.insert(failSig)
                let parts = failSig.split(separator: ":", maxSplits: 1)
                let brokenTool = parts.first.map(String.init) ?? "unknown"
                let brokenTarget = parts.count > 1 ? String(parts[1]) : ""

                let lastError = allToolResults
                    .filter { $0.isFailure && $0.toolName == brokenTool }
                    .last?.text ?? "unknown"
                let rootCause = "\(brokenTool) 对 \(brokenTarget) 连续失败 \(count) 次: \(String(lastError.prefix(200)))"
                let preemptive: String
                switch brokenTool {
                case "file.edit":
                    preemptive = "历史已知：file.edit 对此类目标容易失败（参数格式/匹配问题），直接使用 file.write 全量写入更可靠"
                case "code.search":
                    preemptive = "历史已知：code.search 对此类查询容易失败，优先使用 shell_exec grep 搜索"
                default:
                    preemptive = "历史已知：\(brokenTool) 对此类目标容易失败，请使用替代工具"
                }
                FailurePatternDB.shared.record(
                    intent: String(describing: state.intent),
                    triggerTools: [brokenTool],
                    triggerKeywords: [String(brokenTarget.prefix(30))],
                    rootCause: rootCause,
                    preemptiveInstruction: preemptive,
                    modelName: config.modelName
                )

                orchestrationNotes.append("🔴 熔断：`\(brokenTool)` 对 `\(brokenTarget)` 已失败 \(count) 次。编排层将自动降级修复（file.edit→file.write, code.search→grep）。" +
                    "\n后续如果再调用该组合，编排层会直接拦截并自动执行替代方案。" +
                    "\n你只需告诉编排层要做什么（目标文件+内容），不必关心用什么工具。")
            }
        }

        if !orchestrationNotes.isEmpty {
            state.messages.append(ChatMessage(role: "system", content: "编排层提示：\n" + orchestrationNotes.joined(separator: "\n")))
        }

        // Auto-fix loop: verify nudge after code writes
        let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
        let writeTools: Set<String> = ["file.write", "file.edit"]
        let batchHadCodeWrite = toolCallResults.contains { entry in
            let step = callSteps[entry.0].1
            guard entry.1.success, writeTools.contains(step.toolName ?? "") else { return false }
            let path = step.toolParams?["path"] ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            return codeExtensions.contains(ext)
        }
        let batchHadVerify = callSteps.contains { $0.1.toolName == "verify.build" }
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
            callSteps[entry.0].1.toolName == "verify.build" && entry.1.success
        }
        let batchHadWrite = toolCallResults.contains { entry in
            writeTools.contains(callSteps[entry.0].1.toolName ?? "") && entry.1.success
        }
        let batchHadNonCodeWrite = toolCallResults.contains { entry in
            let step = callSteps[entry.0].1
            guard entry.1.success, writeTools.contains(step.toolName ?? "") else { return false }
            let path = step.toolParams?["path"] ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            return !codeExtensions.contains(ext) && !ext.isEmpty
        }
        if (batchHadWrite && batchVerifyPassed) || (batchHadNonCodeWrite && !hasBuildSystem) {
            state.messages.append(ChatMessage(role: "system", content: "任务已完成：文件已成功写入\(batchVerifyPassed ? "且编译验证通过" : "")。请输出简短的完成总结，不要调用更多工具。"))
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

        let writtenPaths = state.taskContext.memory.userDecisions.compactMap { d -> String? in
            d.hasPrefix("已写入：") ? String(d.dropFirst(4)) : nil
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
        if let lv = lastVerify {
            stateLines.append(lv.isFailure == true ? "🔴 最近编译：失败" : "🟢 最近编译：通过")
        }

        let remaining = state.effectiveMaxIterations - state.iteration
        stateLines.append("⏱ 迭代预算：已用 \(state.iteration)/\(state.effectiveMaxIterations)，剩余 \(remaining)")

        if !stateLines.isEmpty {
            state.messages.append(ChatMessage(role: "system", content: "## 任务状态（第 \(state.iteration) 轮）\n" + stateLines.joined(separator: "\n")))
        }
    }

    // MARK: - Utility

    private static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        guard let allowedTools = config.allowedTools, !allowedTools.isEmpty else { return true }
        return allowedTools.contains(ToolNameCodec.canonicalName(name))
    }
}
