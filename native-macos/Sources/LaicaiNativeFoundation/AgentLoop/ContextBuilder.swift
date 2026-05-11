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

    // MARK: - Public Entry Point

    static func build(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry
    ) -> Result {
        var prompt = buildBasePrompt(state: &state, config: config)
        var injectedPatternHashes: [String] = []

        // Layer 2: Enrichment
        enrichWithPersistentMemory(prompt: &prompt, state: state, config: config)
        enrichWithMemoryEngine(prompt: &prompt, message: state.message)
        enrichWithSkillGuidance(prompt: &prompt, state: &state, config: config)
        enrichWithFailurePatterns(prompt: &prompt, state: &state, config: config, injectedHashes: &injectedPatternHashes)
        enrichWithCustomPrompt(prompt: &prompt, config: config)
        enrichWithExecutionDiscipline(prompt: &prompt, state: state)
        enrichWithToolHints(prompt: &prompt, state: state)

        // Token budget
        let budget = TokenBudget.estimate(context: state.taskContext, userInput: state.message, mode: config.contextMode)
        if !budget.trimDetails.isEmpty {
            state.taskContext.memory.trimDetails = budget.trimDetails
            state.taskContext.memory.updatedAt = .now
        }

        // Layer 3: Tool definitions + guardrails
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

    private static func enrichWithPersistentMemory(prompt: inout String, state: PipelineState, config: AgentLoop.Config) {
        guard !state.taskContext.workspaceRoot.isEmpty, let repo = AgentLoop.sharedRepository else { return }
        let memories = repo.loadMemories(workspace: state.taskContext.workspaceRoot, limit: 20)
        guard !memories.isEmpty else { return }
        let memoryBlock = memories.map { "- [\($0.category)] \($0.key): \($0.value)" }.joined(separator: "\n")
        prompt += "\n\n## 项目记忆（跨会话持久化）\n\(memoryBlock)"
    }

    private static func enrichWithMemoryEngine(prompt: inout String, message: String) {
        if let memoryContext = MemoryEngine.shared.buildMemoryContext(for: message, maxTokens: 1500) {
            prompt += "\n\n\(memoryContext)"
        }
    }

    private static func enrichWithSkillGuidance(prompt: inout String, state: inout PipelineState, config: AgentLoop.Config) {
        guard state.intent != .chat else { return }
        guard let learnedSkill = SkillEvolutionEngine.shared.bestSkill(
            intent: state.intentString,
            modelName: config.modelName,
            message: state.message
        ) else { return }

        let toolSequence = learnedSkill.toolSequence.map { ToolNameCodec.canonicalName($0) }.joined(separator: " → ")
        let skillInjection = """

## 已学技能提示
此类任务曾成功使用策略「\(learnedSkill.strategy)」，推荐工具序列：\(toolSequence)
（成功率 \(Int(learnedSkill.successRate * 100))%，Q值 \(String(format: "%.2f", learnedSkill.qValue))）
"""
        prompt += skillInjection
        state.task.context.metadata["learnedSkillID"] = "\(learnedSkill.id)"

        let skillStep = TaskStep(
            kind: .aiThinking,
            text: "已加载学习技能：\(learnedSkill.name)（Q=\(String(format: "%.2f", learnedSkill.qValue))）",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(skillStep)
    }

    private static func enrichWithFailurePatterns(
        prompt: inout String,
        state: inout PipelineState,
        config: AgentLoop.Config,
        injectedHashes: inout [String]
    ) {
        guard state.intent != .chat else { return }
        let matchedPatterns = FailurePatternDB.shared.matches(
            intent: state.intentString,
            recentTools: [],
            message: state.message,
            modelName: config.modelName
        )
        guard !matchedPatterns.isEmpty else { return }

        let topPattern = matchedPatterns.first!
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
    }

    private static func enrichWithCustomPrompt(prompt: inout String, config: AgentLoop.Config) {
        if let customSystemPrompt = config.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customSystemPrompt.isEmpty {
            prompt += "\n\n## 当前指定 Agent\n\(customSystemPrompt)"
        }
    }

    private static func enrichWithExecutionDiscipline(prompt: inout String, state: PipelineState) {
        let hasPlan = state.taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("执行计划：") })
        if hasPlan {
            prompt += "\n\n## 执行纪律\n严格按照上面的执行计划推进。每轮只做计划中的下一步。最终回复必须说明已验证什么、未验证什么。"
        }
    }

    private static func enrichWithToolHints(prompt: inout String, state: PipelineState) {
        guard state.intent != .chat else { return }
        var toolHints: [String] = []
        let lowerMsg = state.message.lowercased()
        let isFileCreation = lowerMsg.contains("创建") || lowerMsg.contains("写入") || lowerMsg.contains("新建") || lowerMsg.contains("create") || lowerMsg.contains("write")
        if isFileCreation {
            toolHints.append("创建文件：用 file_write，不要用 wiki_build（wiki_build 只用于 Obsidian 知识库整理）")
        }
        if lowerMsg.contains("修改") || lowerMsg.contains("改") || lowerMsg.contains("fix") || lowerMsg.contains("修复") {
            toolHints.append("修改文件：先 file_read 看完整内容，再 file_edit 精确修改，最后 verify_build 验证")
        }
        if !toolHints.isEmpty {
            prompt += "\n\n## 工具使用提示\n" + toolHints.joined(separator: "\n")
        }
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
        toolDefs.sort { a, b in
            let rateA = successMap[a.function.name] ?? 1.0
            let rateB = successMap[b.function.name] ?? 1.0
            return rateA > rateB
        }

        let problemTools = successMap.filter { kv in kv.value < 0.4 && (tStats.filter { $0.toolName == kv.key }.reduce(0) { $0 + $1.total }) >= 5 }
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
            prompt += "\n\n## 当前真实可用工具\n本轮未启用任何工具（纯文本模式）。如需文件读写/搜索/执行，请提示用户切换到任务模式或换支持 function calling 的连接器。"
        }
    }
}
