import Foundation
import LaicaiNativeDomain

// MARK: - Structured Context
// Three-layer context abstraction that replaces direct string concatenation of TaskMemory fields.
// Each layer produces structured fragments that are budget-aware and can be serialized
// to the system prompt OR injected as individual messages.
//
//   Layer 1: WorkspaceContext (static facts: workspace root, git branch, relevant files, .claude.md)
//   Layer 2: RuntimeContext   (live session state: read files, searched queries, decisions, failures)
//   Layer 3: KnowledgeContext (cross-session learning: persistent memory, skills, failure patterns)

// MARK: - Context Fragment

/// A single context fragment with priority, estimated token cost, and content.
/// Fragments are assembled in priority order until the token budget is exhausted.
public struct ContextFragment: Sendable {
    public enum Priority: Int, Comparable, Sendable {
        case critical = 0    // always include (role, workspace root)
        case high = 1        // include unless severely constrained
        case medium = 2      // include if budget allows
        case low = 3         // first to drop

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let tag: String           // e.g. "workspace.root", "memory.persistent", "skill.guidance"
    public let priority: Priority
    public let estimatedTokens: Int
    public let content: String
    public let heading: String?      // optional markdown heading for grouping

    public init(tag: String, priority: Priority, content: String, heading: String? = nil) {
        self.tag = tag
        self.priority = priority
        self.content = content
        self.heading = heading
        // Rough CJK-aware token estimation
        let cjkCount = content.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let charsPerToken: Double = cjkCount > content.count / 3 ? 2.5 : 4.0
        self.estimatedTokens = max(1, Int(Double(content.count) / charsPerToken))
    }
}

// MARK: - Structured Context Assembler

/// Assembles context fragments into a system prompt within a token budget.
public struct ContextAssembler: Sendable {
    public let tokenBudget: Int

    public init(tokenBudget: Int) {
        self.tokenBudget = tokenBudget
    }

    /// Assemble fragments into a single prompt string, respecting the token budget.
    /// Fragments are sorted by priority (critical first), then by order added.
    /// Returns the assembled prompt and the tags of included fragments.
    public func assemble(_ fragments: [ContextFragment]) -> (prompt: String, includedTags: [String], droppedTags: [String]) {
        let sorted = fragments.enumerated().sorted { a, b in
            if a.element.priority != b.element.priority {
                return a.element.priority < b.element.priority
            }
            return a.offset < b.offset
        }

        var usedTokens = 0
        var included: [ContextFragment] = []
        var droppedTags: [String] = []

        for (_, fragment) in sorted {
            if fragment.priority == .critical || usedTokens + fragment.estimatedTokens <= tokenBudget {
                included.append(fragment)
                usedTokens += fragment.estimatedTokens
            } else {
                droppedTags.append(fragment.tag)
            }
        }

        // Rebuild in original priority/insertion order for coherent reading
        let prompt = included.map { fragment in
            if let heading = fragment.heading {
                return "\n\n## \(heading)\n\(fragment.content)"
            }
            return fragment.content
        }.joined()

        return (prompt, included.map(\.tag), droppedTags)
    }
}

// MARK: - Layer 1: Workspace Context

@MainActor
struct WorkspaceContextProvider {

    static func fragments(from context: TaskContext, intent: UserIntent) -> [ContextFragment] {
        var result: [ContextFragment] = []

        // Base system prompt (critical — always included)
        let basePrompt = PromptComposer.composeSystemPrompt(context: context, intent: intent)
        result.append(ContextFragment(tag: "base.system_prompt", priority: .critical, content: basePrompt))

        // .claude.md / project instructions
        if let claudeMD = context.claudeMD, !claudeMD.isEmpty {
            result.append(ContextFragment(
                tag: "workspace.claude_md",
                priority: .high,
                content: claudeMD,
                heading: "项目指令 (.claude.md)"
            ))
        }

        // Git context
        if let branch = context.gitBranch, !branch.isEmpty {
            var gitInfo = "当前分支：\(branch)"
            if let diff = context.gitDiff, !diff.isEmpty {
                let lines = diff.components(separatedBy: "\n")
                let truncated = lines.count > 50 ? lines.prefix(50).joined(separator: "\n") + "\n…（截断）" : diff
                gitInfo += "\n\n近期变更：\n```\n\(truncated)\n```"
            }
            result.append(ContextFragment(
                tag: "workspace.git",
                priority: .medium,
                content: gitInfo,
                heading: "Git 状态"
            ))
        }

        // Relevant files summary
        if !context.relevantFiles.isEmpty {
            let summaries = context.relevantFiles.prefix(20).map { file in
                let lang = file.language.isEmpty ? "" : " (\(file.language))"
                let summary = file.summary.isEmpty ? "" : " — \(file.summary)"
                return "- \(URL(fileURLWithPath: file.path).lastPathComponent)\(lang)\(summary)"
            }.joined(separator: "\n")
            result.append(ContextFragment(
                tag: "workspace.relevant_files",
                priority: .medium,
                content: summaries,
                heading: "相关文件"
            ))
        }

        return result
    }
}

// MARK: - Layer 2: Runtime Context

@MainActor
struct RuntimeContextProvider {

    static func fragments(from memory: TaskMemory, iteration: Int, intent: UserIntent) -> [ContextFragment] {
        var result: [ContextFragment] = []

        // Read files summary (high priority — model needs to know what it already read)
        if !memory.readFiles.isEmpty {
            let fileList = memory.readFiles.suffix(15).map { path -> String in
                let name = URL(fileURLWithPath: path).lastPathComponent
                if let summary = memory.fileSummaries[path], !summary.isEmpty {
                    return "- \(name)：\(String(summary.prefix(100)))"
                }
                return "- \(name)"
            }.joined(separator: "\n")
            result.append(ContextFragment(
                tag: "runtime.read_files",
                priority: .high,
                content: "已读取 \(memory.readFiles.count) 个文件（可直接 file_edit，无需再 file_read）：\n\(fileList)",
                heading: "已读文件"
            ))
        }

        // Searched queries (prevent re-search)
        if !memory.searchedQueries.isEmpty {
            let queries = memory.searchedQueries.suffix(10).joined(separator: "、")
            result.append(ContextFragment(
                tag: "runtime.searched_queries",
                priority: .medium,
                content: "已搜索：\(queries)（不要重复搜索这些词）"
            ))
        }

        // Failed tools (prevent repeated failures)
        if !memory.failedTools.isEmpty {
            let failCounts = Dictionary(grouping: memory.failedTools, by: { $0 }).mapValues(\.count)
            let failSummary = failCounts.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            result.append(ContextFragment(
                tag: "runtime.failed_tools",
                priority: .high,
                content: "失败记录：\(failSummary)（不要用相同参数重试已失败的操作）",
                heading: "工具失败"
            ))
        }

        // User decisions / write history
        if !memory.userDecisions.isEmpty {
            let decisions = memory.userDecisions.suffix(10).joined(separator: "\n")
            result.append(ContextFragment(
                tag: "runtime.decisions",
                priority: .medium,
                content: decisions,
                heading: "执行记录"
            ))
        }

        // Stage conclusions
        if !memory.stageConclusions.isEmpty {
            let conclusions = memory.stageConclusions.suffix(5).joined(separator: "\n")
            result.append(ContextFragment(
                tag: "runtime.stage_conclusions",
                priority: .medium,
                content: conclusions,
                heading: "阶段结论"
            ))
        }

        // Verification status
        if let status = memory.verificationStatus, !status.isEmpty {
            result.append(ContextFragment(
                tag: "runtime.verification",
                priority: .high,
                content: "验证状态：\(status)"
            ))
        }

        // Trim details (meta: what was dropped from context)
        if !memory.trimDetails.isEmpty {
            result.append(ContextFragment(
                tag: "runtime.trim_details",
                priority: .low,
                content: "上下文裁剪：" + memory.trimDetails.joined(separator: "；")
            ))
        }

        return result
    }
}

// MARK: - Layer 3: Knowledge Context (cross-session)

@MainActor
struct KnowledgeContextProvider {

    static func fragments(
        workspaceRoot: String,
        message: String,
        intent: UserIntent,
        intentString: String,
        modelName: String
    ) -> [ContextFragment] {
        var result: [ContextFragment] = []

        // Persistent memory
        if !workspaceRoot.isEmpty, let repo = AgentLoop.sharedRepository {
            let memories = repo.loadMemories(workspace: workspaceRoot, limit: 20)
            if !memories.isEmpty {
                let memoryBlock = memories.map { "- [\($0.category)] \($0.key): \($0.value)" }.joined(separator: "\n")
                result.append(ContextFragment(
                    tag: "knowledge.persistent_memory",
                    priority: .high,
                    content: memoryBlock,
                    heading: "项目记忆（跨会话持久化）"
                ))
            }
        }

        // MemoryEngine (semantic memory)
        if let memoryContext = MemoryEngine.shared.buildMemoryContext(for: message, maxTokens: 1500) {
            result.append(ContextFragment(
                tag: "knowledge.semantic_memory",
                priority: .medium,
                content: memoryContext
            ))
        }

        // Learned skills
        guard intent != .chat else { return result }
        if let skill = SkillEvolutionEngine.shared.bestSkill(intent: intentString, modelName: modelName, message: message) {
            let toolSequence = skill.toolSequence.map { ToolNameCodec.canonicalName($0) }.joined(separator: " → ")
            result.append(ContextFragment(
                tag: "knowledge.learned_skill",
                priority: .medium,
                content: "此类任务曾成功使用策略「\(skill.strategy)」，推荐工具序列：\(toolSequence)（成功率 \(Int(skill.successRate * 100))%，Q值 \(String(format: "%.2f", skill.qValue))）",
                heading: "已学技能提示"
            ))
        }

        // Failure patterns
        let matchedPatterns = FailurePatternDB.shared.matches(
            intent: intentString,
            recentTools: [],
            message: message,
            modelName: modelName
        )
        if let topPattern = matchedPatterns.first {
            result.append(ContextFragment(
                tag: "knowledge.failure_pattern",
                priority: .high,
                content: "上次类似任务因「\(topPattern.rootCause)」导致失败。本次策略：\(topPattern.preemptiveInstruction)",
                heading: "历史经验提醒"
            ))
        }

        return result
    }
}

// MARK: - Convenience: Build Full Context

@MainActor
extension ContextBuilder {

    /// Build system prompt using the structured three-layer abstraction.
    /// This is the new path that replaces direct string concatenation.
    static func buildStructured(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry
    ) -> Result {
        // Gather fragments from all three layers
        var fragments: [ContextFragment] = []
        fragments += WorkspaceContextProvider.fragments(from: state.taskContext, intent: state.intent)
        fragments += RuntimeContextProvider.fragments(from: state.taskContext.memory, iteration: state.iteration, intent: state.intent)
        fragments += KnowledgeContextProvider.fragments(
            workspaceRoot: state.taskContext.workspaceRoot,
            message: state.message,
            intent: state.intent,
            intentString: state.intentString,
            modelName: config.modelName
        )

        // Custom prompt
        if let customPrompt = config.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPrompt.isEmpty {
            fragments.append(ContextFragment(
                tag: "custom.system_prompt",
                priority: .high,
                content: customPrompt,
                heading: "当前指定 Agent"
            ))
        }

        // Execution discipline
        if state.taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("执行计划：") }) {
            fragments.append(ContextFragment(
                tag: "discipline.execution_plan",
                priority: .high,
                content: "严格按照上面的执行计划推进。每轮只做计划中的下一步。最终回复必须说明已验证什么、未验证什么。",
                heading: "执行纪律"
            ))
        }

        // Tool hints
        let toolHintFragments = buildToolHintFragments(message: state.message, intent: state.intent)
        fragments += toolHintFragments

        // Token budget
        let budget = TokenBudget.estimate(context: state.taskContext, userInput: state.message, mode: config.contextMode)
        if !budget.trimDetails.isEmpty {
            state.taskContext.memory.trimDetails = budget.trimDetails
            state.taskContext.memory.updatedAt = .now
        }

        // Assemble within budget (reserve 30% for tool defs + conversation)
        let promptBudget = Int(Double(config.contextWindow) * 0.3)
        let assembler = ContextAssembler(tokenBudget: promptBudget)
        let (basePrompt, _, droppedTags) = assembler.assemble(fragments)

        if !droppedTags.isEmpty {
            state.taskContext.memory.trimDetails.append("上下文裁剪：已丢弃 \(droppedTags.joined(separator: "、"))")
        }

        // Emit skill/pattern steps
        emitKnowledgeSteps(fragments: fragments, state: &state)

        // Tool definitions + guardrails
        var prompt = basePrompt
        let initialPhase = state.priorSteps.isEmpty ? TaskPhase.explore : AgentLoop.inferPhase(from: state.priorSteps)
        var toolDefs = buildToolDefinitions(state: state, config: config, intent: state.intent, phase: initialPhase, toolRegistry: toolRegistry)
        reorderToolsByEffectiveness(toolDefs: &toolDefs, prompt: &prompt)
        injectToolAvailabilityGuardrail(prompt: &prompt, config: config, toolDefs: toolDefs)

        var injectedPatternHashes: [String] = []
        let matchedPatterns = FailurePatternDB.shared.matches(
            intent: state.intentString,
            recentTools: [],
            message: state.message,
            modelName: config.modelName
        )
        if let topPattern = matchedPatterns.first {
            injectedPatternHashes.append(topPattern.patternHash)
        }

        return Result(
            systemPrompt: prompt,
            toolDefs: toolDefs,
            initialPhase: initialPhase,
            injectedPatternHashes: injectedPatternHashes
        )
    }

    private static func buildToolHintFragments(message: String, intent: UserIntent) -> [ContextFragment] {
        guard intent != .chat else { return [] }
        var hints: [ContextFragment] = []
        let lowerMsg = message.lowercased()
        if lowerMsg.contains("创建") || lowerMsg.contains("写入") || lowerMsg.contains("新建") || lowerMsg.contains("create") || lowerMsg.contains("write") {
            hints.append(ContextFragment(tag: "hints.file_creation", priority: .low, content: "创建文件：用 file_write，不要用 wiki_build（wiki_build 只用于 Obsidian 知识库整理）"))
        }
        if lowerMsg.contains("修改") || lowerMsg.contains("改") || lowerMsg.contains("fix") || lowerMsg.contains("修复") {
            hints.append(ContextFragment(tag: "hints.file_modify", priority: .low, content: "修改文件：先 file_read 看完整内容，再 file_edit 精确修改，最后 verify_build 验证"))
        }
        return hints
    }

    private static func emitKnowledgeSteps(fragments: [ContextFragment], state: inout PipelineState) {
        if fragments.contains(where: { $0.tag == "knowledge.learned_skill" }) {
            if let skill = SkillEvolutionEngine.shared.bestSkill(
                intent: state.intentString,
                modelName: "",
                message: state.message
            ) {
                state.task.context.metadata["learnedSkillID"] = "\(skill.id)"
                let step = TaskStep(
                    kind: .aiThinking,
                    text: "已加载学习技能：\(skill.name)（Q=\(String(format: "%.2f", skill.qValue))）",
                    isCollapsible: true,
                    isCollapsed: true
                )
                state.task.steps.append(step)
            }
        }
        if let patternFrag = fragments.first(where: { $0.tag == "knowledge.failure_pattern" }) {
            let step = TaskStep(
                kind: .aiThinking,
                text: "已注入历史失败经验：\(patternFrag.content.prefix(200))",
                isCollapsible: true,
                isCollapsed: true
            )
            state.task.steps.append(step)
        }
    }
}
