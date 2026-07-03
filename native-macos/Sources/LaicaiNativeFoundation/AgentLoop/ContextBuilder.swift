import Foundation
import LaicaiNativeDomain

// MARK: - Context Builder
// Extracts system prompt composition from the monolithic run() method.
// Three-layer architecture:
//   Layer 1 — Base system prompt (role + workspace)
//   Layer 2 — Enrichment (memory, skills, patterns, tool hints)
//   Layer 3 — Guardrails (tool availability, execution discipline)

@MainActor
struct ContextBuilder {

    // MARK: - Build Result

    struct Result {
        var systemPrompt: String
        var toolDefs: [ToolDefinition]
        var initialPhase: TaskPhase
        var injectedPatternHashes: [String]
    }

    // MARK: - Token Budget

    /// Estimate token count from text (CJK ~2.5 chars/token, English ~4 chars/token).
    static func estimateTokens(_ text: String) -> Int {
        let cjkCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let nonCJK = text.count - cjkCount
        return Int(Double(cjkCount) / 2.5) + Int(Double(nonCJK) / 4.0)
    }

    // MARK: - Public Entry Point

    static func build(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry
    ) -> Result {
        // Token budget: base prompt + enrichment must fit within context window
        // Reserve 60% for tool results and conversation, 40% for system prompt
        let contextWindow = config.contextWindow
        let maxPromptTokens = max(1500, Int(Double(contextWindow) * 0.25))
        var prompt = buildBasePrompt(state: &state, config: config)
        var usedTokens = estimateTokens(prompt)
        var injectedPatternHashes: [String] = []

        // Layer 2: Enrichment — priority order, skip low-priority when over budget
        // Priority 1 (important): persistent memory, execution discipline, custom prompt
        usedTokens += enrichWithPersistentMemory(prompt: &prompt, state: state, config: config)
        usedTokens += enrichWithCustomPrompt(prompt: &prompt, config: config)
        usedTokens += enrichWithExecutionDiscipline(prompt: &prompt, state: state)

        // Priority 2 (useful): memory engine, failure patterns
        if usedTokens < maxPromptTokens {
            usedTokens += enrichWithMemoryEngine(prompt: &prompt, message: state.message)
        }
        if usedTokens < maxPromptTokens {
            usedTokens += enrichWithFailurePatterns(prompt: &prompt, state: &state, config: config, injectedHashes: &injectedPatternHashes)
        }

        // Priority 3 (optional): skill guidance, workflow contract, tool hints
        if usedTokens < maxPromptTokens {
            usedTokens += enrichWithSkillGuidance(prompt: &prompt, state: &state, config: config)
        }
        if usedTokens < maxPromptTokens {
            usedTokens += enrichWithAdaptiveWorkflowContract(prompt: &prompt, state: state)
        }
        if usedTokens < maxPromptTokens {
            usedTokens += enrichWithToolHints(prompt: &prompt, state: state)
        }

        // Token budget (context trimming)
        let budget = TokenBudget.estimate(context: state.taskContext, userInput: state.message, mode: config.contextMode)
        if !budget.trimDetails.isEmpty {
            state.taskContext.memory.trimDetails = budget.trimDetails
            state.taskContext.memory.updatedAt = .now
        }

        // Layer 3: Tool definitions + guardrails (always included — critical)
        let initialPhase = state.priorSteps.isEmpty ? TaskPhase.explore : AgentLoop.inferPhase(from: state.priorSteps)
        var toolDefs = buildToolDefinitions(
            state: state,
            config: config,
            intent: state.intent,
            phase: initialPhase,
            toolRegistry: toolRegistry
        )
        reorderToolsByEffectiveness(toolDefs: &toolDefs, prompt: &prompt)
        injectToolAvailabilityGuardrail(prompt: &prompt, config: config, toolDefs: toolDefs)

        return Result(
            systemPrompt: prompt,
            toolDefs: toolDefs,
            initialPhase: initialPhase,
            injectedPatternHashes: injectedPatternHashes
        )
    }

    // MARK: - Layer 1: Base Prompt

    private static func buildBasePrompt(state: inout PipelineState, config: AgentLoop.Config) -> String {
        PromptComposer.composeSystemPrompt(context: state.taskContext, intent: state.intent)
    }

    // MARK: - Layer 2: Enrichment

    @discardableResult
    private static func enrichWithPersistentMemory(prompt: inout String, state: PipelineState, config: AgentLoop.Config) -> Int {
        guard !state.taskContext.workspaceRoot.isEmpty, let repo = AgentLoop.sharedRepository else { return 0 }
        let memories = repo.loadMemories(workspace: state.taskContext.workspaceRoot, limit: 20)
        guard !memories.isEmpty else { return 0 }
        let memoryBlock = memories.map { "- [\($0.category)] \($0.key): \($0.value)" }.joined(separator: "\n")
        let injection = "\n\n## 项目记忆（跨会话持久化）\n\(memoryBlock)"
        prompt += injection
        return estimateTokens(injection)
    }

    @discardableResult
    private static func enrichWithMemoryEngine(prompt: inout String, message: String) -> Int {
        if let memoryContext = MemoryEngine.shared.buildMemoryContext(for: message, maxTokens: 1500) {
            let injection = "\n\n\(memoryContext)"
            prompt += injection
            return estimateTokens(injection)
        }
        return 0
    }

    @discardableResult
    private static func enrichWithSkillGuidance(prompt: inout String, state: inout PipelineState, config: AgentLoop.Config) -> Int {
        guard state.intent != .chat else { return 0 }
        guard
            let learnedSkill = SkillEvolutionEngine.shared.bestSkill(
                intent: state.intentString,
                modelName: config.modelName,
                message: state.message
            )
        else { return 0 }

        let toolSequence = learnedSkill.toolSequence.map { ToolNameCodec.canonicalName($0) }.joined(separator: " → ")
        let skillInjection = """

            ## 已学技能提示（仅供参考）
            此类任务曾使用策略「\(learnedSkill.strategy)」，工具序列：\(toolSequence)（成功率 \(Int(learnedSkill.successRate * 100))%）
            请根据当前实际情况决定是否采用，不匹配时自行组合工具。
            """
        prompt += skillInjection
        state.task.context.metadata["learnedSkillID"] = "\(learnedSkill.id)"

        let skillStep = TaskStep(
            kind: .aiThinking,
            text: "已加载学习技能：\(learnedSkill.name)（Q=\(String(format: "%.2f", learnedSkill.qValue))）",
            isCollapsible: true,
            isCollapsed: false
        )
        state.task.steps.append(skillStep)
        return estimateTokens(skillInjection)
    }

    @discardableResult
    private static func enrichWithAdaptiveWorkflowContract(prompt: inout String, state: PipelineState) -> Int {
        guard state.intent != .chat else { return 0 }
        let injection = """

            ## 自适应工作流
            - 为当前目标生成临时工作流，每次工具结果后重新评估，工作流是假设不是脚本。
            - 根据当前证据决定下一步：有足够证据就动手，证据不足就先探索，失败就换路径。
            - 最终答案只报告交付物、验证结果和残余风险。
            """
        prompt += injection
        return estimateTokens(injection)
    }

    @discardableResult
    private static func enrichWithFailurePatterns(
        prompt: inout String,
        state: inout PipelineState,
        config: AgentLoop.Config,
        injectedHashes: inout [String]
    ) -> Int {
        guard state.intent != .chat else { return 0 }
        let matchedPatterns = FailurePatternDB.shared.matches(
            intent: state.intentString,
            recentTools: [],
            message: state.message,
            modelName: config.modelName
        )
        guard !matchedPatterns.isEmpty else { return 0 }

        guard let topPattern = matchedPatterns.first else { return 0 }
        injectedHashes.append(topPattern.patternHash)
        let injection = """

            ## 历史经验提醒
            上次类似任务因「\(topPattern.rootCause)」导致失败。本次策略：\(topPattern.preemptiveInstruction)
            """
        prompt += injection

        let patternStep = TaskStep(
            kind: .aiThinking,
            text: "已注入历史失败经验：\(topPattern.rootCause) → \(topPattern.preemptiveInstruction)",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(patternStep)
        return estimateTokens(injection)
    }

    @discardableResult
    private static func enrichWithCustomPrompt(prompt: inout String, config: AgentLoop.Config) -> Int {
        if let customSystemPrompt = config.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !customSystemPrompt.isEmpty {
            let injection = "\n\n## 用户自定义指令\n\(customSystemPrompt)"
            prompt += injection
            return estimateTokens(injection)
        }
        return 0
    }

    @discardableResult
    private static func enrichWithExecutionDiscipline(prompt: inout String, state: PipelineState) -> Int {
        // Only inject plan-specific discipline (the general discipline is in the base prompt)
        let hasPlan = state.taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("执行计划：") })
        if hasPlan {
            let injection = "\n\n## 计划执行纪律\n严格按照执行计划推进，每轮只做下一步。继续/追问沿用断点，不重新开始。"
            prompt += injection
            return estimateTokens(injection)
        }
        return 0
    }

    @discardableResult
    private static func enrichWithToolHints(prompt: inout String, state: PipelineState) -> Int {
        guard state.intent != .chat else { return 0 }
        var toolHints: [String] = []
        let lowerMsg = state.message.lowercased()
        let isFileCreation =
            lowerMsg.contains("创建") || lowerMsg.contains("写入") || lowerMsg.contains("新建") || lowerMsg.contains("create") || lowerMsg.contains("write")
        if isFileCreation {
            toolHints.append("创建文件：用 file_write，不要用 wiki_build（wiki_build 只用于 Obsidian 知识库整理）")
        }
        if lowerMsg.contains("修改") || lowerMsg.contains("改") || lowerMsg.contains("fix") || lowerMsg.contains("修复") {
            toolHints.append("修改文件：先 file_read 看完整内容，再 file_edit 精确修改，最后 verify_build 验证")
        }
        if !toolHints.isEmpty {
            let injection = "\n\n## 工具使用提示\n" + toolHints.joined(separator: "\n")
            prompt += injection
            return estimateTokens(injection)
        }
        return 0
    }

    // MARK: - Layer 3: Tool Definitions & Guardrails

    static func buildToolDefinitions(
        state: PipelineState,
        config: AgentLoop.Config,
        intent: UserIntent,
        phase: TaskPhase,
        toolRegistry: ToolRegistry
    ) -> [ToolDefinition] {
        guard config.supportsToolCalling else { return [] }
        let allDefs = AgentLoop.toolDefinitions(for: intent, phase: phase, registry: toolRegistry)
        return filterToolDefinitions(allDefs, allowedTools: config.allowedTools)
    }

    /// Static filtering — avoids needing an AgentLoop instance.
    static func filterToolDefinitions(_ definitions: [ToolDefinition], allowedTools: Set<String>?) -> [ToolDefinition] {
        guard let allowedTools, !allowedTools.isEmpty else { return definitions }
        let canonicalAllowedTools = AgentLoop.canonicalToolSet(allowedTools) ?? []
        return definitions.filter { definition in
            canonicalAllowedTools.contains(ToolNameCodec.canonicalName(definition.function.name))
        }
    }

    static func reorderToolsByEffectiveness(toolDefs: inout [ToolDefinition], prompt: inout String) {
        let tStats = toolDefs.isEmpty ? [] : TaskOutcomeRecorder.shared.toolStats(days: 14)
        guard !tStats.isEmpty else { return }

        let successMap = Dictionary(grouping: tStats, by: \.toolName)
            .mapValues { rows -> Double in
                let total = rows.reduce(0) { $0 + $1.total }
                let successes = rows.reduce(0) { $0 + $1.successes }
                return total >= 3 ? Double(successes) / Double(total) : 1.0
            }
        toolDefs.sort { lhs, rhs in
            let rateA = successMap[lhs.function.name] ?? 1.0
            let rateB = successMap[rhs.function.name] ?? 1.0
            return rateA > rateB
        }

        let problemTools = successMap.filter { entry in
            entry.value < 0.4 && (tStats.filter { $0.toolName == entry.key }.reduce(0) { $0 + $1.total }) >= 5
        }
        if !problemTools.isEmpty {
            let warnings = problemTools.map { "\($0.key)（成功率\(Int($0.value * 100))%）" }.joined(separator: "、")
            prompt += "\n\n## 工具效率提示\n以下工具近期成功率较低，请优先使用替代方案或仔细检查参数：\(warnings)"
        }
    }

    static func injectToolAvailabilityGuardrail(prompt: inout String, config: AgentLoop.Config, toolDefs: [ToolDefinition]) {
        if config.supportsToolCalling, !toolDefs.isEmpty {
            let names = toolDefs.map(\.function.name).sorted()
            prompt += """

                ## 当前真实可用工具（由 App 编排层强制声明，不要自行判断或否认）
                \(names.map { "- \($0)" }.joined(separator: "\n"))

                约束：
                - 这是当前轮次实际暴露给你的工具完整列表，不能凭空声称"没有 file_read / file_edit"等。
                - 如某工具不在列表里，请直接说"当前未启用 X，建议改用 Y"，不要编造。
                - 历史记录里出现过的工具名（即使本轮未启用）不代表当前可用，以本列表为准。
                """
        } else if !config.supportsToolCalling {
            prompt += "\n\n## 当前真实可用工具\n本轮未启用任何工具（纯文本姿态）。如需文件读写/搜索/执行，请提示用户切换到支持工具调用的连接器后重试。"
        }
    }
}
