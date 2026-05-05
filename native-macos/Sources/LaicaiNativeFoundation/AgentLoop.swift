import Foundation
import LaicaiNativeDomain

// MARK: - Agent Loop

private final class AgentShellStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var didResume = false

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        output += chunk
        return output
    }

    func finish() -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if didResume {
            return (output, false)
        }
        didResume = true
        return (output, true)
    }
}

extension Notification.Name {
    static let shellStreamUpdate = Notification.Name("laicai.shellStreamUpdate")
}

/// Runs a local task by asking the model, executing requested tools, and feeding results back.
@MainActor
public final class AgentLoop: ObservableObject {
    public struct Config: Sendable {
        public var maxIterations: Int
        public var maxTokensPerTurn: Int
        public var workspaceRoot: String
        public var supportsToolCalling: Bool
        public var contextMode: ContextMode
        public var contextWindow: Int
        public var customSystemPrompt: String?
        public var allowedTools: Set<String>?
        public var modelName: String

        public init(
            maxIterations: Int = 50,
            maxTokensPerTurn: Int = 4096,
            workspaceRoot: String = "",
            supportsToolCalling: Bool = true,
            contextMode: ContextMode = .balanced,
            contextWindow: Int = 200_000,
            customSystemPrompt: String? = nil,
            allowedTools: Set<String>? = nil,
            modelName: String = ""
        ) {
            self.maxIterations = maxIterations
            self.maxTokensPerTurn = maxTokensPerTurn
            self.workspaceRoot = workspaceRoot
            self.supportsToolCalling = supportsToolCalling
            self.contextMode = contextMode
            self.contextWindow = contextWindow
            self.customSystemPrompt = customSystemPrompt
            self.allowedTools = allowedTools
            self.modelName = modelName
        }
    }

    // G1: Shared repository for persistent memory access
    public static var sharedRepository: SQLiteRepository?

    static let toolCompatibilityFallbackAction = "connector.disableToolCalling"

    public enum LoopEvent: Sendable {
        case step(TaskStep)
        case streamDelta(String)
        case completed(AgentTask)
        case failed(Error)
    }

    private let config: Config
    private let runtime: any ChatRuntimeClient
    private let toolRegistry: ToolRegistry

    public init(
        config: Config,
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry = .shared
    ) {
        self.config = config
        self.runtime = runtime
        self.toolRegistry = toolRegistry
    }

    private func filteredToolDefinitions(_ definitions: [ToolDefinition]) -> [ToolDefinition] {
        guard let allowedTools = config.allowedTools, !allowedTools.isEmpty else {
            return definitions
        }
        return definitions.filter { definition in
            allowedTools.contains(ToolNameCodec.canonicalName(definition.function.name))
        }
    }

    private func isToolAllowed(_ name: String) -> Bool {
        guard let allowedTools = config.allowedTools, !allowedTools.isEmpty else {
            return true
        }
        return allowedTools.contains(ToolNameCodec.canonicalName(name))
    }

    /// Run the agent loop for a user message.
    /// Returns the completed AgentTask with all steps.
    public func run(
        taskID: UUID? = nil,
        message: String,
        intent: UserIntent,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile] = [],
        context: TaskContext?,
        priorSteps: [TaskStep] = [],
        summaryCache: String? = nil,
        imageAttachments: [ImageAttachment] = [],
        onStep: @MainActor (TaskStep) -> Void = { _ in },
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async throws -> AgentTask {
        let startTime = CFAbsoluteTimeGetCurrent()
        var wasCancelled = false
        // PERF-3: Chat fast path — skip heavy file scan and git diff for simple chat
        var taskContext: TaskContext
        if let ctx = context {
            taskContext = ctx
        } else if intent == .chat {
            taskContext = AutoContextEngine.buildContext(
                workspaceRoot: config.workspaceRoot,
                userInput: message,
                fileLimit: 0  // chat doesn't need file index
            )
        } else {
            taskContext = AutoContextEngine.buildContext(
                workspaceRoot: config.workspaceRoot,
                userInput: message
            )
        }
        taskContext.contextMode = config.contextMode

        // Merge persisted cross-session memory
        let persisted = TaskMemoryStore.load(workspaceRoot: config.workspaceRoot)
        if !persisted.isEmpty {
            taskContext.memory = TaskMemoryStore.merge(persisted, into: taskContext.memory)
        }

        var task = AgentTask(
            id: taskID ?? UUID(),
            title: String(message.prefix(50)),
            status: .running,
            connectorID: connector.id,
            context: taskContext
        )

        // Emit user input step
        if !priorSteps.contains(where: { $0.kind == .userInput && $0.text == message }) {
            let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
            task.steps.append(userStep)
            onStep(userStep)
        }

        // Inline planning: instead of a separate LLM call, instruct the model
        // to think-then-act in its first turn. This saves one full API roundtrip.
        let needsPlanning = intent != .chat
            && priorSteps.isEmpty
            && !Self.isPureContinuationCommand(message)
            && message.count > 10
        if intent != .chat, !priorSteps.contains(where: { $0.kind == .aiThinking }) {
            let startStep = TaskStep(
                kind: .aiThinking,
                text: "正在理解任务并准备执行。",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(startStep)
            onStep(startStep)
        }

        // Build system prompt
        var systemPrompt = PromptComposer.composeSystemPrompt(context: taskContext, intent: intent)

        // G1: Inject persistent cross-session memory
        if !taskContext.workspaceRoot.isEmpty, let repo = Self.sharedRepository {
            let memories = repo.loadMemories(workspace: taskContext.workspaceRoot, limit: 20)
            if !memories.isEmpty {
                let memoryBlock = memories.map { "- [\($0.category)] \($0.key): \($0.value)" }.joined(separator: "\n")
                systemPrompt += "\n\n## 项目记忆（跨会话持久化）\n\(memoryBlock)"
            }
        }

        // FTS5 persistent memory recall (MemoryEngine)
        if let memoryContext = MemoryEngine.shared.buildMemoryContext(for: message, maxTokens: 1500) {
            systemPrompt += "\n\n\(memoryContext)"
        }

        // Inject preemptive instructions from historical failure patterns
        let intentString: String = {
            switch intent {
            case .chat: return "chat"
            case .research: return "research"
            case .task: return "task"
            case .workflow(let name): return "workflow:\(name)"
            }
        }()
        // PERF: Skip pattern/skill queries for chat — only task/workflow need self-evolution hints
        let matchedPatterns = intent == .chat ? [] : FailurePatternDB.shared.matches(
            intent: intentString,
            recentTools: [],
            message: message,
            modelName: config.modelName
        )
        // Inject learned skill guidance if available
        if intent != .chat, let learnedSkill = SkillEvolutionEngine.shared.bestSkill(intent: intentString, modelName: config.modelName) {
            let skillInjection = """

## 已学技能提示
此类任务曾成功使用策略「\(learnedSkill.strategy)」，推荐工具序列：\(learnedSkill.toolSequence.joined(separator: " → "))
（成功率 \(Int(learnedSkill.successRate * 100))%，Q值 \(String(format: "%.2f", learnedSkill.qValue))）
"""
            systemPrompt += skillInjection
            task.context.metadata["learnedSkillID"] = "\(learnedSkill.id)"
            let skillStep = TaskStep(
                kind: .aiThinking,
                text: "已加载学习技能：\(learnedSkill.name)（Q=\(String(format: "%.2f", learnedSkill.qValue))）",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(skillStep)
            onStep(skillStep)
        }

        var injectedPatternHashes: [String] = []
        if !matchedPatterns.isEmpty {
            let topPattern = matchedPatterns.first!
            injectedPatternHashes.append(topPattern.patternHash)
            let injection = """

## 历史经验提醒
上次类似任务因「\(topPattern.rootCause)」导致失败。本次策略：\(topPattern.preemptiveInstruction)
"""
            systemPrompt += injection
            let patternStep = TaskStep(
                kind: .aiThinking,
                text: "已注入历史失败经验：\(topPattern.rootCause) → \(topPattern.preemptiveInstruction)",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(patternStep)
            onStep(patternStep)
        }

        if let customSystemPrompt = config.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customSystemPrompt.isEmpty {
            systemPrompt += "\n\n## 当前指定 Agent\n\(customSystemPrompt)"
        }
        let hasPlan = taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("执行计划：") })
        if hasPlan {
            systemPrompt += "\n\n## 执行纪律\n严格按照上面的执行计划推进。每轮只做计划中的下一步。最终回复必须说明已验证什么、未验证什么。"
        } else if needsPlanning {
            systemPrompt += "\n\n## 首轮规划\n第一次回复时，先用1-2句话说明计划（做什么、改哪些文件），然后立即调用工具执行第一步。不要只输出计划不行动。"
        }

        // Persist trim details from token budget estimation
        let budget = TokenBudget.estimate(context: taskContext, userInput: message, mode: config.contextMode)
        if !budget.trimDetails.isEmpty {
            taskContext.memory.trimDetails = budget.trimDetails
            taskContext.memory.updatedAt = .now
        }

        // Build tool definitions. Plain chat intentionally avoids tool schemas so
        // small questions stay fast and provider payloads stay minimal.
        // Phase-aware: infer current phase from prior steps to dynamically open/close tools.
        let initialPhase = priorSteps.isEmpty ? TaskPhase.explore : Self.inferPhase(from: priorSteps)
        var toolDefs = config.supportsToolCalling ? filteredToolDefinitions(Self.toolDefinitions(for: intent, phase: initialPhase, registry: toolRegistry)) : []
        // W1+A3: Reorder tools by historical effectiveness and annotate low-success tools
        let tStats = toolDefs.isEmpty ? [] : TaskOutcomeRecorder.shared.toolStats(days: 14)
        if !tStats.isEmpty {
            let successMap = Dictionary(grouping: tStats, by: \.toolName)
                .mapValues { rows -> Double in
                    let total = rows.reduce(0) { $0 + $1.total }
                    let successes = rows.reduce(0) { $0 + $1.successes }
                    return total >= 3 ? Double(successes) / Double(total) : 1.0
                }
            // Sort: higher success rate tools appear first in the list
            toolDefs.sort { a, b in
                let rateA = successMap[a.function.name] ?? 1.0
                let rateB = successMap[b.function.name] ?? 1.0
                return rateA > rateB
            }
            // Inject warning into system prompt for chronically failing tools
            let problemTools = successMap.filter { kv in kv.value < 0.4 && (tStats.filter { $0.toolName == kv.key }.reduce(0) { $0 + $1.total }) >= 5 }
            if !problemTools.isEmpty {
                let warnings = problemTools.map { "\($0.key)（成功率\(Int($0.value * 100))%）" }.joined(separator: "、")
                systemPrompt += "\n\n## 工具效率提示\n以下工具近期成功率较低，请优先使用替代方案或仔细检查参数：\(warnings)"
            }
        }
        var currentPhase = initialPhase
        var usedToolCompatibilityFallback = false
        let isReadOnlyRun = config.allowedTools != nil
            && !isToolAllowed("file.write")
            && !isToolAllowed("file.edit")
            && !isToolAllowed("shell.exec")
            && !isToolAllowed("verify.build")

        // Build initial messages, carrying compact prior thread context when the
        // user continues an existing agent thread.
        var messages = Self.initialMessages(
            systemPrompt: systemPrompt,
            message: message,
            priorSteps: priorSteps,
            summaryCache: summaryCache,
            context: taskContext,
            imageAttachments: imageAttachments
        )

        if intent != .chat, !config.supportsToolCalling {
            let disabledStep = TaskStep(
                kind: .aiThinking,
                text: "当前连接器已关闭工具调用，本轮将只基于已有上下文继续；如果需要读取文件、搜索项目、联网、运行命令或写入内容，请切换支持工具调用的连接器后重试。",
                isCollapsible: true,
                isCollapsed: false
            )
            task.steps.append(disabledStep)
            onStep(disabledStep)
            Self.applyToolCompatibilityFallbackInstruction(to: &messages)
        }

        if Self.shouldContinueTruncatedOutputOnly(message: message, priorSteps: priorSteps),
           let previousText = Self.lastTextOutput(in: priorSteps) {
            let thinkingStep = TaskStep(
                kind: .aiThinking,
                text: "检测到上一条回复被截断，正在从截断处继续输出；本轮不会搜索、读取文件或调用工具。",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(thinkingStep)
            onStep(thinkingStep)

            var didComplete = false
            var wasTruncated = true
            let originalStepID = priorSteps.last(where: { $0.kind == .textOutput })?.id
            if let continuationStep = try? await Self.continueTruncatedOutput(
                taskID: task.id,
                originalMessage: message,
                previousText: previousText,
                messages: messages,
                connector: connector,
                runtime: runtime,
                maxOutputTokens: config.maxTokensPerTurn,
                originalStepID: originalStepID
            ) {
                task.steps.append(continuationStep)
                onStep(continuationStep)
                wasTruncated = continuationStep.text.contains("回复仍被截断")
                didComplete = !wasTruncated
            }
            if wasTruncated {
                let stillTruncatedStep = TaskStep(
                    kind: .error,
                    text: "续写仍被截断。请继续在这条任务里发送“接着说”，我会继续沿用当前上下文。",
                    isFailure: false,
                    recoverable: true,
                    retryAction: "接着说"
                )
                task.steps.append(stillTruncatedStep)
                onStep(stillTruncatedStep)
            }
            let checkStep = Self.completionCheckStep(
                for: task,
                didComplete: didComplete,
                hadFailure: false,
                wasTruncated: wasTruncated
            )
            task.steps.append(checkStep)
            onStep(checkStep)
            task.status = didComplete ? .completed : .failed
            task.updatedAt = .now
            return task
        }

        // Pure continuation commands ("继续", "接着说", etc.) should NOT trigger
        // any bootstrap tool calls. The model should simply resume from prior context.
        let isPureContinuation = Self.isPureContinuationCommand(message)

        if !isPureContinuation, !toolDefs.isEmpty, isToolAllowed("web.fetch"), let url = Self.firstURL(in: message),
           let fetchTool = toolRegistry.tool(named: "web_fetch") {
            let argumentsJSON = Self.bootstrapWebFetchArgumentsJSON(for: url)
            let toolParams = parseParamsFromJSON(argumentsJSON)
            let callId = "call_bootstrap_web_fetch"
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "web.fetch", arguments: toolParams),
                toolName: "web.fetch",
                toolParams: toolParams,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(callStep)
            onStep(callStep)

            let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
                tool: fetchTool,
                argumentsJSON: argumentsJSON,
                context: taskContext
            )
            let displayText = ToolResultFormatter.displayText(
                toolName: "web.fetch",
                arguments: toolParams,
                result: toolResult
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: displayText,
                toolName: "web.fetch",
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !toolResult.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)

            let resultContent = ToolResultFormatter.modelContent(
                toolName: "web.fetch",
                result: toolResult,
                limit: config.maxTokensPerTurn
            )
            let instruction = toolResult.success
                ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWebFetch, baseline: "我已读取用户提供的网页。请基于网页正文和当前任务继续工作，必要时再搜索或读取项目文件；不要声称无法访问该链接。")
                : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWebFetch + "_fail", baseline: "我尝试读取用户提供的网页但失败。请明确说明失败原因，不能编造网页内容。")
            messages.append(ChatMessage(
                role: "user",
                content: """
                \(instruction)

                \(resultContent)
                """
            ))
        } else if !isPureContinuation, !toolDefs.isEmpty, isToolAllowed("file.read"), let localPath = Self.firstLocalPath(in: message),
                  let readTool = toolRegistry.tool(named: "file_read") {
            let argumentsJSON = Self.bootstrapReadArgumentsJSON(for: localPath)
            let toolParams = parseParamsFromJSON(argumentsJSON)
            let callId = "call_bootstrap_file_read"
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
            let displayText = ToolResultFormatter.displayText(
                toolName: "file.read",
                arguments: toolParams,
                result: toolResult
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: displayText,
                toolName: "file.read",
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !toolResult.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)

            let resultContent = ToolResultFormatter.modelContent(
                toolName: "file.read",
                result: toolResult,
                limit: config.maxTokensPerTurn
            )
            let instruction = toolResult.success
                ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapFileRead, baseline: "我已直接读取用户提供的本地路径。请基于真实读取结果继续完成任务；如果这是目录，先根据目录清单判断下一步该读哪些文件。")
                : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapFileRead + "_fail", baseline: "我尝试读取用户提供的本地路径但失败。请明确说明失败原因，不能编造文件内容。")
            messages.append(ChatMessage(
                role: "user",
                content: """
                \(instruction)

                \(resultContent)
                """
            ))
        } else if !isPureContinuation, !toolDefs.isEmpty, isToolAllowed("workspace.index"), Self.shouldBootstrapWorkspaceIndex(for: message, intent: intent),
                  let indexTool = toolRegistry.tool(named: "workspace_index") {
            let argumentsJSON = Self.bootstrapWorkspaceIndexArgumentsJSON()
            let toolParams = parseParamsFromJSON(argumentsJSON)
            let callId = "call_bootstrap_workspace_index"
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "workspace.index", arguments: toolParams),
                toolName: "workspace.index",
                toolParams: toolParams,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(callStep)
            onStep(callStep)

            let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
                tool: indexTool,
                argumentsJSON: argumentsJSON,
                context: taskContext
            )
            let displayText = ToolResultFormatter.displayText(
                toolName: "workspace.index",
                arguments: toolParams,
                result: toolResult
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: displayText,
                toolName: "workspace.index",
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !toolResult.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)

            let resultContent = ToolResultFormatter.modelContent(
                toolName: "workspace.index",
                result: toolResult,
                limit: config.maxTokensPerTurn
            )
            let instruction = toolResult.success
                ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceIndex, baseline: "我已先建立工作区索引。请基于索引里的入口候选、测试候选、配置候选和风险候选判断项目结构；下一步优先读取 README/项目指令/配置/入口/测试文件，必要时用 code_search 精确补充，不要自由拼 shell find。")
                : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceIndex + "_fail", baseline: "我尝试建立工作区索引但失败。请说明失败原因，必要时再使用 code_search 或 file_read 降级。")
            messages.append(ChatMessage(
                role: "user",
                content: """
                \(instruction)

                \(resultContent)
                """
            ))
        } else if !isPureContinuation, !toolDefs.isEmpty, isToolAllowed("code.search"), Self.shouldBootstrapWorkspaceSearch(for: message, intent: intent, context: taskContext),
                  let searchTool = toolRegistry.tool(named: "code_search") {
            let argumentsJSON = Self.bootstrapWorkspaceSearchArgumentsJSON(for: message)
            let toolParams = parseParamsFromJSON(argumentsJSON)
            let callId = "call_bootstrap_code_search"
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "code.search", arguments: toolParams),
                toolName: "code.search",
                toolParams: toolParams,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(callStep)
            onStep(callStep)

            let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
                tool: searchTool,
                argumentsJSON: argumentsJSON,
                context: taskContext
            )
            let displayText = ToolResultFormatter.displayText(
                toolName: "code.search",
                arguments: toolParams,
                result: toolResult
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: displayText,
                toolName: "code.search",
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !toolResult.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)

            let resultContent = ToolResultFormatter.modelContent(
                toolName: "code.search",
                result: toolResult,
                limit: config.maxTokensPerTurn
            )
            var autoReadBlock = ""
            if toolResult.success,
               let readTool = toolRegistry.tool(named: "file_read"),
               let path = Self.firstReadablePath(inSearchOutput: toolResult.output, workspaceRoot: taskContext.workspaceRoot) {
                let readArgumentsJSON = Self.bootstrapReadArgumentsJSON(for: path)
                let readParams = parseParamsFromJSON(readArgumentsJSON)
                let readCallId = "call_bootstrap_file_read"
                let readCallStep = TaskStep(
                    kind: .toolCall,
                    text: ToolStepFormatter.callText(toolName: "file.read", arguments: readParams),
                    toolName: "file.read",
                    toolParams: readParams,
                    toolCallId: readCallId,
                    isCollapsible: true,
                    isCollapsed: true
                )
                task.steps.append(readCallStep)
                onStep(readCallStep)

                let (readResult, _) = await ValidationEngine.executeWithValidationJSON(
                    tool: readTool,
                    argumentsJSON: readArgumentsJSON,
                    context: taskContext
                )
                let readDisplayText = ToolResultFormatter.displayText(
                    toolName: "file.read",
                    arguments: readParams,
                    result: readResult
                )
                let readResultStep = TaskStep(
                    kind: .toolResult,
                    text: readDisplayText,
                    toolName: "file.read",
                    toolCallId: readCallId,
                    isCollapsible: true,
                    isCollapsed: true,
                    isFailure: !readResult.success
                )
                task.steps.append(readResultStep)
                onStep(readResultStep)

                let readContent = ToolResultFormatter.modelContent(
                    toolName: "file.read",
                    result: readResult,
                    limit: max(1200, config.maxTokensPerTurn / 2)
                )
                autoReadBlock = """

                自动读取的首个高相关文件片段（\(path)）：
                \(readContent)
                """
            }
            let fileHints = taskContext.relevantFiles.prefix(12).map { "- \($0.path) (\($0.language))" }.joined(separator: "\n")
            let hintBlock = fileHints.isEmpty ? "" : "\n\n自动相关文件线索：\n\(fileHints)"
            let instruction = toolResult.success
                ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceSearch, baseline: "我已先搜索工作区，并尽量自动读取首个高相关文件片段。请基于这些真实线索继续完成任务；如果线索不足，再调用 file_read/code_search 等工具，不要凭空猜文件内容。")
                : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceSearch + "_fail", baseline: "我尝试先搜索工作区但失败。请明确说明失败原因，必要时让用户检查工作区路径。")
            messages.append(ChatMessage(
                role: "user",
                content: """
                \(instruction)

                \(resultContent)\(autoReadBlock)\(hintBlock)
                """
            ))
        } else if !isPureContinuation, !toolDefs.isEmpty, isToolAllowed("web.search"), Self.shouldBootstrapWebSearch(for: message, intent: intent),
           let webTool = toolRegistry.tool(named: "web_search") {
            let searchMessage = Self.bootstrapWebSearchMessage(for: message, priorSteps: priorSteps)
            let argumentsJSON = Self.bootstrapWebSearchArgumentsJSON(for: searchMessage)
            let toolParams = parseParamsFromJSON(argumentsJSON)
            let callId = "call_bootstrap_web_search"
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: "web.search", arguments: toolParams),
                toolName: "web.search",
                toolParams: toolParams,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(callStep)
            onStep(callStep)

            let (toolResult, _) = await ValidationEngine.executeWithValidationJSON(
                tool: webTool,
                argumentsJSON: argumentsJSON,
                context: taskContext
            )
            let displayText = ToolResultFormatter.displayText(
                toolName: "web.search",
                arguments: toolParams,
                result: toolResult
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: displayText,
                toolName: "web.search",
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !toolResult.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)

            let resultContent = ToolResultFormatter.modelContent(
                toolName: "web.search",
                result: toolResult,
                limit: config.maxTokensPerTurn
            )
            let instruction = toolResult.success
                ? "我已先执行联网搜索。请只基于下面的真实搜索结果回答用户问题，并尽量给出来源标题或链接；不要编造未搜索到的信息。"
                : "我已先尝试联网搜索，但搜索失败。请明确告知用户搜索失败，不能编造实时信息。"
            messages.append(ChatMessage(
                role: "user",
                content: """
                \(instruction)

                \(resultContent)
                """
            ))
        }

        var iteration = 0
        var didComplete = false
        var hadFailure = false
        var wasTruncated = false
        var nudgeCount = 0
        let maxNudges = 2
        var consecutiveEmptyResponses = 0
        let maxConsecutiveEmpty = 2
        var transientRetryCount = 0
        let maxTransientRetries = isReadOnlyRun ? 1 : 2
        var toolFailureCounts: [String: Int] = [:]  // "toolName:target" → count
        var didInjectWorkingSet = false
        let maxRepeatedFailures = 3
        let usesOllamaChat = Self.usesOllamaChat(connector)
        // A4: Dynamic iteration budget — learn from historical average
        var effectiveMaxIterations = config.maxIterations
        if let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentString) {
            // Set budget to 1.5× historical average, clamped between 3 and config.maxIterations
            let learned = Int(ceil(avgIter * 1.5))
            effectiveMaxIterations = max(3, min(learned, config.maxIterations))
        }
        while iteration < effectiveMaxIterations {
            iteration += 1

            // Re-infer phase from accumulated steps and update tool definitions
            if config.supportsToolCalling && intent != .chat {
                let newPhase = Self.inferPhase(from: task.steps)
                if newPhase != currentPhase {
                    let oldPhase = currentPhase
                    currentPhase = newPhase
                    toolDefs = filteredToolDefinitions(Self.toolDefinitions(for: intent, phase: currentPhase, registry: toolRegistry))

                    // Phase transition → aggressively compress old messages for context isolation
                    // Keep only system prompt + first user + last 6 messages
                    if messages.count > 10 {
                        messages = Self.compressMidTaskHistory(messages, maxMessages: 8)
                        // Inject phase transition marker so model knows what happened
                        let transitionSummary = "阶段转换：\(oldPhase.title) → \(currentPhase.title)。已压缩前序会话。继续执行计划中的下一步。"
                        messages.append(ChatMessage(role: "system", content: transitionSummary))
                    }

                    // Phase-based model routing: switch to best connector for current phase
                    if !allConnectors.isEmpty {
                        if let routed = ModelRouter.selectModel(forPhase: currentPhase, connectors: allConnectors, activeConnectorID: connector.id),
                           routed.id != connector.id {
                            let routingStep = TaskStep(
                                kind: .aiThinking,
                                text: "切换到\(routed.modelName.isEmpty ? routed.name : routed.modelName)处理\(currentPhase.title)阶段",
                                isCollapsible: true,
                                isCollapsed: true
                            )
                            task.steps.append(routingStep)
                            onStep(routingStep)
                        }
                    }
                }
            }

            // Mid-task context compression: when conversation grows too long,
            // compress early tool results to prevent token overflow.
            // Use connector-specific contextWindow instead of one-size-fits-all.
            let tokenLimit = config.contextWindow
            let messageThreshold = max(20, tokenLimit / 5000)  // ~5000 tokens/msg average
            if messages.count > messageThreshold {
                messages = Self.compressMidTaskHistory(messages, maxMessages: max(15, messageThreshold - 5))
            }
            // Token-based compression: CJK averages ~2.5 chars/token, English ~4 chars/token
            let estimatedTokens = messages.reduce(0) { sum, msg in
                let content = (msg.content ?? "") + (msg.reasoningContent ?? "")
                let cjkCount = content.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                let charsPerToken: Double = cjkCount > content.count / 3 ? 2.5 : 4.0
                return sum + Int(Double(content.count) / charsPerToken)
            }
            // Compress when approaching context window limit (leave 20% headroom for response)
            let safeLimit = Int(Double(tokenLimit) * 0.8)
            if estimatedTokens > safeLimit {
                messages = Self.compressMidTaskHistory(messages, maxMessages: max(10, messageThreshold / 2))
                if messages.reduce(0, { sum, msg in
                    let c = msg.content ?? ""
                    let cjk = c.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                    return sum + Int(Double(c.count) / (cjk > c.count / 3 ? 2.5 : 4.0))
                }) > safeLimit {
                    messages = Self.truncateToolResults(messages, maxTokens: safeLimit)
                }
            }

            // Working Set injection: remind model about files it already read
            // so it can directly file_edit without re-reading
            if iteration > 1 && !taskContext.memory.readFiles.isEmpty {
                let workingSet = taskContext.memory.readFiles.prefix(8).compactMap { path -> String? in
                    if let summary = taskContext.memory.fileSummaries[path], !summary.isEmpty {
                        return "- \(URL(fileURLWithPath: path).lastPathComponent)：\(summary)"
                    }
                    return "- \(URL(fileURLWithPath: path).lastPathComponent)"
                }.joined(separator: "\n")
                if !workingSet.isEmpty && !didInjectWorkingSet {
                    messages.append(ChatMessage(role: "system", content: "已读文件摘要（可直接 file_edit，无需再 file_read）：\n\(workingSet)"))
                    didInjectWorkingSet = true
                }
            }

            // No proactive nudge: Claude Code insight — let the model decide.
            // Only inject a budget warning when truly running low.
            if iteration == effectiveMaxIterations - 2 && iteration > 3 {
                messages.append(ChatMessage(role: "system", content: "剩余 2 轮迭代预算。请尽快给出结论或完成执行。"))
            }

            // Send to LLM with tools
            let intentModeLabel: String = {
                switch intent {
                case .chat: return "思考"
                case .research: return "研究"
                case .task: return isReadOnlyRun ? "分析" : "执行"
                case .workflow: return "工作流"
                }
            }()
            let request = SendMessageRequest(
                sessionID: task.id,
                message: "",
                connector: connector,
                modeLabel: intentModeLabel,
                systemPrompt: systemPrompt,
                tools: toolDefs.isEmpty ? nil : toolDefs,
                messages: messages,
                maxOutputTokens: config.maxTokensPerTurn
            )

            let response: SendMessageResponse
            do {
                response = try await runtime.sendMessageStream(request, onChunk: onStreamDelta)
            } catch {
                // Auto-retry on transient errors (network, timeout, rate limit)
                let isTransient = Self.isTransientError(error)
                if isTransient, transientRetryCount < maxTransientRetries, iteration < effectiveMaxIterations {
                    transientRetryCount += 1
                    let retryStep = TaskStep(
                        kind: .aiThinking,
                        text: "模型请求失败（\(error.localizedDescription)），自动重试（\(transientRetryCount)/\(maxTransientRetries)）…",
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(retryStep)
                    onStep(retryStep)
                    try? await Task.sleep(for: .milliseconds(UInt64(min(pow(2.0, Double(transientRetryCount)), 8)) * 1000))
                    continue
                }
                let errorStep = TaskStep(
                    kind: .error,
                    text: "模型请求失败：\(error.localizedDescription)",
                    isFailure: true,
                    recoverable: true
                )
                task.steps.append(errorStep)
                onStep(errorStep)
                task.status = .failed
                return task
            }

            if response.toolActivities.contains(where: { $0.isFailure }) {
                if Self.shouldRetryWithoutTools(
                    response: response,
                    requestedTools: toolDefs,
                    hasRetriedWithoutTools: usedToolCompatibilityFallback
                ) {
                    let fallbackStep = TaskStep(
                        kind: .aiThinking,
                        text: "检测到当前连接器不兼容工具调用请求，已自动切换为无工具模式继续；后续不会伪造搜索、读取、联网或写入结果。",
                        isCollapsible: true,
                        isCollapsed: false,
                        retryAction: Self.toolCompatibilityFallbackAction
                    )
                    task.steps.append(fallbackStep)
                    onStep(fallbackStep)
                    toolDefs = []
                    usedToolCompatibilityFallback = true
                    Self.applyToolCompatibilityFallbackInstruction(to: &messages)
                    continue
                }
                let errorText = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorStep = TaskStep(
                    kind: .error,
                    text: errorText.isEmpty ? "模型请求失败，请检查连接器配置。" : errorText,
                    isFailure: true,
                    recoverable: true,
                    retryAction: "检查端点、模型名和请求兼容性后重试"
                )
                task.steps.append(errorStep)
                onStep(errorStep)
                hadFailure = true
                didComplete = false
                break
            }

            // Process response
            if response.hasToolCalls {
                // LLM wants to call tools
                // First, emit any text the assistant said alongside the tool calls
                if !response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || response.reasoningContent != nil {
                    let thinkingStep = TaskStep(
                        kind: .aiThinking,
                        text: response.assistantText,
                        isCollapsible: true,
                        reasoningContent: response.reasoningContent
                    )
                    task.steps.append(thinkingStep)
                    onStep(thinkingStep)
                }

                // Add assistant message with tool calls to conversation. Ollama accepts
                // tool definitions, but some local models reject OpenAI-style follow-up
                // messages with role=tool/tool_call_id, so their tool results are fed
                // back as plain conversation text below.
                if usesOllamaChat {
                    let toolNames = response.toolCalls
                        .map { ToolNameCodec.canonicalName($0.function.name) }
                        .joined(separator: ", ")
                    messages.append(ChatMessage(
                        role: "assistant",
                        content: "我将调用这些工具：\(toolNames)"
                    ))
                } else {
                    messages.append(ChatMessage(
                        role: "assistant",
                        content: response.assistantText.isEmpty ? nil : response.assistantText,
                        reasoningContent: response.reasoningContent,
                        toolCalls: response.toolCalls
                    ))
                }

                // Emit toolCall steps immediately so user sees tools running in real-time
                var callSteps: [(Int, TaskStep, String, String, String, [String: String])] = []
                for (index, toolCall) in response.toolCalls.enumerated() {
                    let apiToolName = toolCall.function.name
                    let toolName = ToolNameCodec.canonicalName(apiToolName)
                    let argumentsJSON = toolCall.function.arguments
                    let callId = toolCall.id ?? "call_\(apiToolName)_\(iteration)"
                    let toolParams = parseParamsFromJSON(argumentsJSON)
                    let callStep = TaskStep(
                        kind: .toolCall,
                        text: ToolStepFormatter.callText(toolName: toolName, arguments: toolParams),
                        toolName: toolName,
                        toolParams: toolParams,
                        toolCallId: callId,
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(callStep)
                    onStep(callStep)
                    callSteps.append((index, callStep, apiToolName, argumentsJSON, callId, toolParams))
                }

                var toolCallResults: [(Int, ToolResult, RecoveryPlan?)] = []
                for batch in Self.scheduledToolCallBatches(callSteps) {
                    let batchResults = await withTaskGroup(of: (Int, ToolResult, RecoveryPlan?).self) { group in
                        for (index, callStep, apiToolName, argumentsJSON, _, _) in batch {
                            let toolName = callStep.toolName ?? apiToolName
                            group.addTask { @MainActor in
                                let toolResult: ToolResult
                                var recoveryPlan: RecoveryPlan?

                                // Dedup: if file.read for same path was already cached, return cache
                                if toolName == "file.read",
                                   let readPath = callStep.toolParams?["path"],
                                   callStep.toolParams?["offset"] == nil,
                                   let cached = taskContext.memory.fileContentCache[readPath] ?? taskContext.memory.fileContentCache[(taskContext.workspaceRoot as NSString).appendingPathComponent(readPath)] {
                                    // Return summary instead of full content to save tokens
                                    let summary = taskContext.memory.fileSummaries[readPath] ?? String(cached.prefix(500))
                                    let cacheNote = "✅ 已缓存（\(cached.count)字符）。摘要：\(summary)\n如需完整内容可再次 file_read 加 offset 参数，或直接 file_edit。"
                                    toolResult = ToolResult(
                                        output: cacheNote,
                                        data: ["path": readPath, "size": "\(cached.count)", "cached": "true"]
                                    )
                                    return (index, toolResult, nil as RecoveryPlan?)
                                }

                                // Dedup: if code_search with identical query was already done, skip
                                if toolName == "code.search",
                                   let query = callStep.toolParams?["query"],
                                   taskContext.memory.searchedQueries.contains(query) {
                                    toolResult = ToolResult(
                                        output: "此查询已搜索过，结果见上方历史。请基于已有结果继续，不要重复搜索。",
                                        data: ["query": query, "cached": "true"]
                                    )
                                    return (index, toolResult, nil as RecoveryPlan?)
                                }

                                // Pre-hook
                                let preHookOutput = await HookEngine.shared.runPreHooks(
                                    toolName: toolName,
                                    params: callStep.toolParams ?? [:],
                                    context: taskContext
                                )
                                if let preOut = preHookOutput, preOut.contains("⚠️") {
                                    toolResult = ToolResult(output: preOut, success: false, error: "pre_hook_failed")
                                } else if !self.isToolAllowed(toolName) {
                                    toolResult = ToolResult(
                                        output: "已阻止工具调用：\(toolName)。当前执行级别只允许理解意图和只读分析；如果要运行命令、构建、测试或修改文件，请切换到「执行」。",
                                        success: false,
                                        error: "tool_not_allowed"
                                    )
                                } else if let tool = self.toolRegistry.tool(named: apiToolName) {
                                    if tool.requiresReview || ["file.write", "file.edit"].contains(toolName) {
                                        Self.gitCheckpoint(workspaceRoot: self.config.workspaceRoot)
                                    }

                                    let validation: ValidationEngine.ValidationResult
                                    if toolName == "shell.exec" {
                                        let streamStepID = UUID()
                                        let callID = callStep.toolCallId ?? "call_\(index)"
                                        let result = await Self.executeShellStreamingViaNotification(
                                            argumentsJSON: argumentsJSON,
                                            context: taskContext,
                                            resultStepID: streamStepID,
                                            callID: callID,
                                            command: callStep.toolParams?["command"] ?? ""
                                        )
                                        toolResult = result
                                        validation = ValidationEngine.ValidationResult(
                                            isValid: tool.validate(result: result),
                                            error: result.error,
                                            retryCount: 0
                                        )
                                    } else {
                                        let validated = await ValidationEngine.executeWithValidationJSON(
                                            tool: tool,
                                            argumentsJSON: argumentsJSON,
                                            context: taskContext
                                        )
                                        toolResult = validated.result
                                        validation = validated.validation
                                    }

                                    if !validation.isValid {
                                        let recoveryError = [toolResult.error, toolResult.output]
                                            .compactMap { $0 }
                                            .joined(separator: "：")
                                        recoveryPlan = ErrorRecoveryEngine.planRecoveryJSON(
                                            error: recoveryError.isEmpty ? "验证失败" : recoveryError,
                                            toolName: toolName,
                                            argumentsJSON: argumentsJSON,
                                            attemptCount: validation.retryCount
                                        )
                                    }
                                } else {
                                    toolResult = ToolResult(
                                        output: "未知工具：\(toolName)",
                                        success: false,
                                        error: "unknown_tool"
                                    )
                                }

                                // Post-hook
                                let _ = await HookEngine.shared.runPostHooks(
                                    toolName: toolName,
                                    params: callStep.toolParams ?? [:],
                                    result: toolResult,
                                    context: taskContext
                                )

                                return (index, toolResult, recoveryPlan)
                            }
                        }

                        var results: [(Int, ToolResult, RecoveryPlan?)] = []
                        for await result in group {
                            results.append(result)
                        }
                        return results.sorted { $0.0 < $1.0 }
                    }
                    toolCallResults.append(contentsOf: batchResults)
                }
                toolCallResults.sort { $0.0 < $1.0 }

                // Process results in order — callStep already emitted above
                for (index, toolResult, recoveryPlan) in toolCallResults {
                    let callStep = callSteps[index].1
                    let toolName = callStep.toolName ?? "tool"
                    let toolParams = callStep.toolParams ?? [:]
                    let callId = callStep.toolCallId ?? "call_\(index)"

                    let displayText = ToolResultFormatter.displayText(
                        toolName: toolName,
                        arguments: toolParams,
                        result: toolResult
                    )
                    if toolResult.success,
                       ["file.write", "file.edit"].contains(toolName),
                       let data = toolResult.data {
                        if let batchCountString = data["batchCount"], let batchCount = Int(batchCountString) {
                            for batchIndex in 0..<batchCount {
                                let prefix = "batch\(batchIndex)"
                                guard let filePath = data["\(prefix).path"],
                                      let oldContent = data["\(prefix).diffOld"],
                                      let newContent = data["\(prefix).diffNew"] else { continue }
                                var reviewParams = toolParams
                                for (key, value) in data where key.hasPrefix(prefix + ".") {
                                    reviewParams[String(key.dropFirst(prefix.count + 1))] = value
                                }
                                reviewParams["batchIndex"] = "\(batchIndex + 1)"
                                reviewParams["batchCount"] = "\(batchCount)"
                                let hunks = Self.extractHunks(from: reviewParams)
                                let reviewStep = TaskStep(
                                    kind: .reviewRequest,
                                    text: "批量文件变更等待审查（\(batchIndex + 1)/\(batchCount)）：\(filePath)",
                                    toolName: toolName,
                                    toolParams: reviewParams,
                                    toolCallId: callId,
                                    isCollapsible: false,
                                    isCollapsed: false,
                                    diffFilePath: filePath,
                                    diffOldContent: oldContent,
                                    diffNewContent: newContent,
                                    diffHunks: hunks.isEmpty ? nil : hunks
                                )
                                task.steps.append(reviewStep)
                                onStep(reviewStep)
                            }
                        } else if let filePath = data["path"] ?? toolParams["path"],
                                  let oldContent = data["diffOld"],
                                  let newContent = data["diffNew"] {
                            var reviewParams = toolParams
                            for (key, value) in data {
                                reviewParams[key] = value
                            }
                            let hunks = Self.extractHunks(from: reviewParams)
                            let reviewStep = TaskStep(
                                kind: .reviewRequest,
                                text: "文件变更等待审查：\(filePath)",
                                toolName: toolName,
                                toolParams: reviewParams,
                                toolCallId: callId,
                                isCollapsible: false,
                                isCollapsed: false,
                                diffFilePath: filePath,
                                diffOldContent: oldContent,
                                diffNewContent: newContent,
                                diffHunks: hunks.isEmpty ? nil : hunks
                            )
                            task.steps.append(reviewStep)
                            onStep(reviewStep)
                        }
                    }
                    if toolResult.data?["streamed"] != "true" {
                        let shouldShowFullOutput = ["shell.exec", "verify.build"].contains(toolName)
                        let resultStep = TaskStep(
                            kind: .toolResult,
                            text: shouldShowFullOutput ? toolResult.output : displayText,
                            toolName: toolName,
                            toolCallId: callId,
                            isCollapsible: true,
                            isCollapsed: !shouldShowFullOutput,
                            isFailure: !toolResult.success
                        )
                        task.steps.append(resultStep)
                        onStep(resultStep)
                    }

                    // Record tool-level outcome for per-tool effectiveness analysis
                    TaskOutcomeRecorder.shared.recordToolOutcome(
                        taskID: task.id.uuidString,
                        toolName: toolName,
                        modelName: config.modelName,
                        success: toolResult.success,
                        durationSeconds: toolResult.data?["durationSeconds"].flatMap(Double.init) ?? 0,
                        wasRetry: recoveryPlan != nil
                    )

                    // Handle recovery
                    if !toolResult.success, let recoveryPlan {
                        switch recoveryPlan.action {
                        case .fallbackTool(let fallbackName, let fallbackArgumentsJSON):
                            let _ = await executeRecoveryTool(
                                displayName: fallbackName,
                                argumentsJSON: fallbackArgumentsJSON,
                                task: &task,
                                messages: &messages,
                                context: taskContext,
                                usesOllamaChat: usesOllamaChat,
                                onStep: onStep
                            )
                        case .retryWithModifiedJSON(let modifiedArgumentsJSON):
                            let _ = await executeRecoveryTool(
                                displayName: toolName,
                                argumentsJSON: modifiedArgumentsJSON,
                                task: &task,
                                messages: &messages,
                                context: taskContext,
                                usesOllamaChat: usesOllamaChat,
                                onStep: onStep
                            )
                        default:
                            break
                        }
                    }
                    if !toolResult.success {
                        hadFailure = true
                        // Circuit breaker: track repeated failures on same tool+target
                        let target = callStep.toolParams?["path"] ?? callStep.toolParams?["command"] ?? "unknown"
                        let failKey = "\(toolName):\(target)"
                        toolFailureCounts[failKey, default: 0] += 1
                        if toolFailureCounts[failKey]! >= maxRepeatedFailures {
                            let circuitMsg = "工具 \(toolName) 对 \(target) 已连续失败 \(toolFailureCounts[failKey]!) 次。请换一种方法：用 file.write 全量写入代替 file.edit，或用不同的命令。不要重复同样的操作。"
                            messages.append(ChatMessage(role: "user", content: circuitMsg))
                        }
                    } else {
                        // Reset failure count on success
                        let target = callStep.toolParams?["path"] ?? callStep.toolParams?["command"] ?? "unknown"
                        toolFailureCounts["\(toolName):\(target)"] = 0
                    }

                    // Update task memory
                    if toolResult.success {
                        switch toolName {
                        case "file.read":
                            if let path = callStep.toolParams?["path"] {
                                if !taskContext.memory.readFiles.contains(path) {
                                    taskContext.memory.readFiles.append(path)
                                }
                                // Extract structural summary: function/class/struct signatures
                                let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
                                let signatures = toolResult.output
                                    .components(separatedBy: "\n")
                                    .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
                                    .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
                                    .prefix(8)
                                    .joined(separator: "; ")
                                let summary = signatures.isEmpty
                                    ? toolResult.output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).joined(separator: " … ")
                                    : signatures
                                if !summary.isEmpty {
                                    taskContext.memory.fileSummaries[path] = String(summary.prefix(300))
                                }
                                // Cache full content for dedup
                                if toolResult.output.count < 100_000 {
                                    taskContext.memory.fileContentCache[path] = toolResult.output
                                }
                            }
                        case "code.search":
                            if let query = callStep.toolParams?["query"] {
                                taskContext.memory.searchedQueries.append(query)
                            }
                        default:
                            break
                        }
                    } else {
                        taskContext.memory.failedTools.append(callStep.toolName ?? "unknown")
                    }
                    if ["file.write", "file.edit"].contains(callStep.toolName ?? ""), toolResult.success {
                        if let path = callStep.toolParams?["path"] {
                            taskContext.memory.userDecisions.append("准备审查写入：\(path)")
                            // Invalidate read cache — file content changed
                            taskContext.memory.fileContentCache.removeValue(forKey: path)
                            let fullPath = (taskContext.workspaceRoot as NSString).appendingPathComponent(path)
                            taskContext.memory.fileContentCache.removeValue(forKey: fullPath)
                        }
                    }

                    // Feed tool result back to conversation
                    let resultContent = ToolResultFormatter.modelContent(
                        toolName: callStep.toolName ?? "tool",
                        result: toolResult,
                        limit: config.maxTokensPerTurn
                    )
                    if usesOllamaChat {
                        messages.append(ChatMessage(
                            role: "user",
                            content: "工具 \(callStep.toolName ?? "tool") 执行结果：\n\(resultContent)"
                        ))
                    } else {
                        messages.append(ChatMessage(
                            role: "tool",
                            content: resultContent,
                            toolCallId: callStep.toolCallId
                        ))
                    }
                }

                // Auto-fix loop: if we wrote files but didn't verify in this batch, nudge to verify
                let writeTools: Set<String> = ["file.write", "file.edit"]
                let batchHadWrite = toolCallResults.contains { entry in
                    let step = callSteps[entry.0].1
                    return entry.1.success && writeTools.contains(step.toolName ?? "")
                }
                let batchHadVerify = callSteps.contains { $0.1.toolName == "verify.build" }
                if batchHadWrite && !batchHadVerify && isToolAllowed("verify.build") {
                    let verifyNudge = "文件已修改。下一步必须调用 verify_build 验证编译是否通过。如果失败，立即 file_edit 修复后再次 verify_build。"
                    messages.append(ChatMessage(role: "user", content: verifyNudge))
                }
            } else {
                // LLM returned text only — check if it gave up too early
                let rawText = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                let isEmptyResponse = rawText.isEmpty
                let text = isEmptyResponse ? "（空响应）" : rawText

                // Empty / thinking-only responses: retry with a counter to prevent infinite loops
                if isEmptyResponse && !toolDefs.isEmpty && iteration < effectiveMaxIterations - 1 {
                    consecutiveEmptyResponses += 1
                    if consecutiveEmptyResponses >= maxConsecutiveEmpty {
                        let stopStep = TaskStep(
                            kind: .aiThinking,
                            text: "模型连续 \(consecutiveEmptyResponses) 次返回空响应/纯思考内容，停止重试。建议换用非思考模型或简化任务描述。",
                            isCollapsible: false,
                            isCollapsed: false
                        )
                        task.steps.append(stopStep)
                        onStep(stopStep)
                        break
                    }
                    let thinkStep = TaskStep(
                        kind: .aiThinking,
                        text: (response.reasoningContent ?? "").isEmpty
                            ? "模型没有返回可显示内容。请检查模型是否可用，或换一个模型重试。"
                            : "模型只返回了思考内容，没有给出最终答案。已隐藏思考过程以降低本机负载，请重试一个更短的问题，或换用非思考模型。",
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(thinkStep)
                    onStep(thinkStep)
                    if isReadOnlyRun || intent == .chat {
                        break
                    }
                    messages.append(ChatMessage(role: "assistant", content: text))
                    messages.append(ChatMessage(role: "user", content: "继续执行任务，使用工具完成目标。"))
                    continue
                }
                // Reset empty counter on non-empty response
                consecutiveEmptyResponses = 0

                let toolCallCount = task.steps.filter({ $0.kind == .toolCall }).count
                let hasFakeToolCalls = Self.containsFakeToolCallSyntax(text)
                let researchNeedsFetch = intent == .research
                    && task.steps.contains(where: { $0.kind == .toolCall && $0.toolName == "web.search" })
                    && !task.steps.contains(where: { $0.kind == .toolCall && $0.toolName == "web.fetch" })
                    && iteration < effectiveMaxIterations - 1
                    && !Self.looksLikeProviderError(text)
                    && !usedToolCompatibilityFallback
                    && !hasFakeToolCalls
                if researchNeedsFetch {
                    nudgeCount += 1
                    messages.append(ChatMessage(role: "assistant", content: text))
                    messages.append(ChatMessage(role: "user", content: "你已经完成搜索，但还没有读取任何来源详情。请至少调用 web_fetch 读取 1-2 个最关键来源后再总结，不要只基于搜索摘要回答。"))
                    let nudgeStep = TaskStep(
                        kind: .aiThinking,
                        text: "研究模式需要读取关键来源详情。正在引导模型调用 web_fetch 后再总结（第 \(nudgeCount)/\(maxNudges) 次）。",
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(nudgeStep)
                    onStep(nudgeStep)
                    continue
                }
                // Only file.write/file.edit count as real writes — shell.exec is often
                // used for read-like ops (npm view, pwd, ls) and must NOT disable nudge
                let writeTools: Set<String> = ["file.write", "file.edit"]
                let hasWritten = task.steps.contains(where: { $0.kind == .toolCall && writeTools.contains($0.toolName ?? "") })

                // Detect model malfunction: outputting "I will call: tool, tool, tool..." × 10+
                if Self.looksLikeToolSpam(text) {
                    let spamStep = TaskStep(
                        kind: .aiThinking,
                        text: "模型输出了异常的工具列表文本（非实际工具调用），已自动跳过。建议换用支持 function calling 的模型。",
                        isCollapsible: false,
                        isCollapsed: false
                    )
                    task.steps.append(spamStep)
                    onStep(spamStep)
                    // Don't mark as complete — this is a malfunction, not success
                    break
                }
                // Nudge logic (minimal): Claude Code never nudges — model gives text = done.
                // We only nudge as last resort: 5+ reads, 0 writes, past half budget, in act mode.
                let isActMode = !isReadOnlyRun && isToolAllowed("shell.exec") && isToolAllowed("file.write")
                let allReadNoWrite = isActMode && toolCallCount >= 5 && !hasWritten
                let pastHalfBudget = iteration > effectiveMaxIterations / 2
                let shouldNudge = allReadNoWrite && pastHalfBudget
                    && intent != .chat && intent != .research
                    && nudgeCount < 1  // max 1 nudge ever
                    && !Self.looksLikeProviderError(text)
                    && !hasFakeToolCalls

                if shouldNudge {
                    nudgeCount += 1
                    messages.append(ChatMessage(role: "assistant", content: text))
                    messages.append(ChatMessage(role: "user", content: "已调研\(toolCallCount)次但0次执行。请执行或给出结论。"))
                    continue
                }

                // If model is writing fake tool calls, it can't do real function calling — warn user
                if hasFakeToolCalls && !usedToolCompatibilityFallback {
                    let warningStep = TaskStep(
                        kind: .aiThinking,
                        text: "检测到模型将工具调用写成了文本，说明该模型不兼容函数调用。建议切换到支持 function calling 的云端模型（如 GPT-4o/5.5、Claude）来执行复杂任务。",
                        isCollapsible: false,
                        isCollapsed: false
                    )
                    task.steps.append(warningStep)
                    onStep(warningStep)
                }

                if Self.looksLikeProviderError(text) {
                    let errorStep = TaskStep(
                        kind: .error,
                        text: text,
                        isFailure: true,
                        recoverable: true,
                        retryAction: "检查端点、模型名和请求兼容性后重试"
                    )
                    task.steps.append(errorStep)
                    onStep(errorStep)
                    hadFailure = true
                    didComplete = false
                    break
                }
                let outputStep = TaskStep(
                    kind: .textOutput,
                    text: text,
                    isCollapsible: false,
                    isCollapsed: false,
                    metrics: response.metrics
                )
                task.steps.append(outputStep)
                onStep(outputStep)
                if response.finishReason == "length" {
                    wasTruncated = true
                    let limitStep = TaskStep(
                        kind: .aiThinking,
                        text: "输出达到当前上限（\(config.maxTokensPerTurn) 词元），正在自动续写下一段。",
                        isFailure: false,
                        recoverable: true,
                        retryAction: "接着说"
                    )
                    task.steps.append(limitStep)
                    onStep(limitStep)

                    if let continuationStep = try? await Self.continueTruncatedOutput(
                        taskID: task.id,
                        originalMessage: message,
                        previousText: text,
                        messages: messages,
                        connector: connector,
                        runtime: runtime,
                        maxOutputTokens: config.maxTokensPerTurn,
                        originalStepID: outputStep.id
                    ) {
                        task.steps.append(continuationStep)
                        onStep(continuationStep)
                        if continuationStep.text.contains("回复仍被截断") {
                            let stillTruncatedStep = TaskStep(
                                kind: .error,
                                text: "第二段回复仍被截断。请继续在这条任务里发送“接着说”，我会继续沿用当前上下文。",
                                isFailure: false,
                                recoverable: true,
                                retryAction: "接着说"
                            )
                            task.steps.append(stillTruncatedStep)
                            onStep(stillTruncatedStep)
                        } else {
                            wasTruncated = false
                        }
                    }
                }
                didComplete = !wasTruncated

                // Completion check is emitted at loop end — no need to duplicate here
                break
            }
        }

        // Try to finalize even with minor failures — the agent may have gathered
        // enough evidence from successful tools to produce a useful result.
        if !didComplete && !wasTruncated {
            if let summaryStep = try? await Self.finalizeFromCollectedEvidence(
                task: task,
                originalMessage: message,
                connector: connector,
                runtime: runtime,
                systemPrompt: systemPrompt,
                maxOutputTokens: config.maxTokensPerTurn
            ) {
                task.steps.append(summaryStep)
                onStep(summaryStep)
                didComplete = true
            }
        }

        if !didComplete && !hadFailure && !wasTruncated {
            // Auto-continuation: instead of hard-stopping, add a continuation step
            // so the user can keep going without losing context
            let continueStep = TaskStep(
                kind: .error,
                text: "已达到本轮处理上限（\(effectiveMaxIterations)）。可以点击「继续」沿用当前上下文继续处理；系统会优先总结现有证据，避免重复读取或搜索。",
                isFailure: false,
                recoverable: true,
                retryAction: "继续处理"
            )
            task.steps.append(continueStep)
            onStep(continueStep)
        }

        // Only emit detailed diagnostics for non-trivial tasks with issues
        let toolCallCount = task.steps.filter { $0.kind == .toolCall }.count
        let needsDiagnostics = hadFailure || wasTruncated || (!didComplete && toolCallCount > 0)
        if needsDiagnostics {
            let checkStep = Self.completionCheckStep(for: task, didComplete: didComplete, hadFailure: hadFailure, wasTruncated: wasTruncated, isReadOnlyRun: isReadOnlyRun)
            task.steps.append(checkStep)
            onStep(checkStep)
            if Self.shouldEmitStageSummary(for: task, hasPlan: hasPlan, hadFailure: hadFailure, wasTruncated: wasTruncated, isReadOnlyRun: isReadOnlyRun) {
                let summaryStep = Self.stageSummaryStep(for: task, didComplete: didComplete, hadFailure: hadFailure, wasTruncated: wasTruncated)
                task.steps.append(summaryStep)
                onStep(summaryStep)
            }
            if let evidenceStep = Self.evidenceChecklistStep(for: task, didComplete: didComplete, hadFailure: hadFailure, wasTruncated: wasTruncated, isReadOnlyRun: isReadOnlyRun) {
                task.steps.append(evidenceStep)
                onStep(evidenceStep)
            }
        }

        let finalStatus: TaskStatus = Self.meetsCompletionCriteria(task: task, intent: intent, didComplete: didComplete, hadFailure: hadFailure, wasTruncated: wasTruncated, isReadOnlyRun: isReadOnlyRun)
            ? .completed
            : .failed
        task.status = finalStatus
        task.updatedAt = .now

        // Suggested next actions: after successful completion, suggest follow-ups
        if finalStatus == .completed && !isReadOnlyRun && intent != .chat {
            let hasFileEdits = task.steps.contains { ["file.write", "file.edit"].contains($0.toolName ?? "") && !$0.isFailure }
            let hasVerify = task.steps.contains { $0.toolName == "verify.build" }
            let hasGitCommit = task.steps.contains { $0.toolName == "git" && ($0.toolParams?["subcommand"] ?? "").contains("commit") }

            var suggestions: [String] = []
            if hasFileEdits && !hasVerify {
                suggestions.append("运行构建验证（verify_build）确认无编译错误")
            }
            if hasFileEdits && !hasGitCommit {
                suggestions.append("git commit 提交本次变更")
            }
            if hasFileEdits {
                suggestions.append("编写或运行相关测试")
            }

            if !suggestions.isEmpty {
                let nextStep = TaskStep(
                    kind: .aiThinking,
                    text: "建议下一步：\n" + suggestions.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                    isCollapsible: true,
                    isCollapsed: false
                )
                task.steps.append(nextStep)
                onStep(nextStep)
            }
        }

        // G1: Persist key learnings for cross-session memory
        if finalStatus == .completed, !taskContext.workspaceRoot.isEmpty, let repo = Self.sharedRepository {
            // Save file summaries as persistent project knowledge
            for (path, summary) in taskContext.memory.fileSummaries.prefix(10) {
                repo.saveMemory(workspace: taskContext.workspaceRoot, category: "file_structure", key: path, value: String(summary.prefix(200)))
            }
            // Save build command if discovered
            if let verifyStep = task.steps.first(where: { $0.toolName == "verify.build" && !$0.isFailure }),
               let cmd = verifyStep.toolParams?["command"] ?? verifyStep.text.components(separatedBy: "命令：").last?.components(separatedBy: "\n").first {
                repo.saveMemory(workspace: taskContext.workspaceRoot, category: "build", key: "build_command", value: String(cmd.prefix(200)))
            }
        }

        // Record outcome for self-evolution analytics
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let toolCalls = task.steps.filter { $0.kind == .toolCall }.count
        let toolFailures = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let userFollowups = task.steps.filter { $0.kind == .userInput && $0.text != message }.count
        let promptTag = PromptRegistry.shared.versionTag(for: PromptRegistry.tagContinueTask)
        TaskOutcomeRecorder.shared.record(
            taskID: task.id.uuidString,
            intent: intentString,
            routeLabel: "task",
            executionMode: isReadOnlyRun ? "inspect" : (intent == .chat ? "ask" : "act"),
            iterations: iteration,
            status: finalStatus,
            hadFailure: hadFailure,
            wasCancelled: wasCancelled,
            wasTruncated: wasTruncated,
            toolCalls: toolCalls,
            toolFailures: toolFailures,
            durationSeconds: Double(duration),
            userFollowupCount: userFollowups,
            promptTag: promptTag,
            modelName: config.modelName
        )

        // Record failure patterns for proactive strategy learning
        // Learning gate: only record if the outcome reward is clearly negative
        let outcomeScore = ResultEvaluator.score(
            status: finalStatus,
            iterations: iteration,
            maxIterations: effectiveMaxIterations,
            hadFailure: hadFailure,
            wasCancelled: wasCancelled,
            wasTruncated: wasTruncated,
            durationSeconds: Double(duration),
            userFollowupCount: userFollowups
        )
        let rewardThreshold = 55 // only learn from clearly poor outcomes
        let shouldLearn = (hadFailure || finalStatus == .failed || wasCancelled) && outcomeScore < rewardThreshold
        if shouldLearn {
            let recentTools = task.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName }
            let failedToolNamesRaw = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.compactMap { $0.toolName }
            // Deduplicate and count occurrences
            var failedCounts: [String: Int] = [:]
            for t in failedToolNamesRaw { failedCounts[t, default: 0] += 1 }
            let failedSummary = failedCounts.sorted(by: { $0.value > $1.value })
                .prefix(5)
                .map { $0.value > 1 ? "\($0.key)(\($0.value)次)" : $0.key }
                .joined(separator: "、")
            let rootCauseText: String
            let instructionText: String
            if wasCancelled {
                if iteration <= 1 {
                    rootCauseText = "用户在首轮即取消，路由或bootstrap可能错误"
                    instructionText = "类似请求先确认是否需要工具，简单问题直接回答，不要自动触发工具。"
                } else if iteration > 6 {
                    rootCauseText = "用户在\(iteration)轮后取消，任务可能陷入循环"
                    instructionText = "类似请求控制在5轮内完成，避免反复搜索或读取相同内容。"
                } else {
                    rootCauseText = "用户在\(iteration)轮后取消"
                    instructionText = "类似请求需更高效，减少不必要的工具调用。"
                }
            } else if !failedCounts.isEmpty {
                rootCauseText = "\(failedSummary)工具执行失败"
                instructionText = "类似请求中\(failedSummary)曾失败，请预先检查参数有效性或使用替代方案。"
            } else if hadFailure {
                rootCauseText = "工具执行中出现错误"
                instructionText = "类似请求曾出错，请更谨慎地验证工具参数和前置条件。"
            } else {
                rootCauseText = "任务未能完成"
                instructionText = "遇到类似意图时，优先确认用户需求范围，避免过度执行。"
            }
            FailurePatternDB.shared.record(
                intent: intentString,
                triggerTools: Array(Set(recentTools)),
                triggerKeywords: [message],
                rootCause: rootCauseText,
                preemptiveInstruction: instructionText,
                modelName: config.modelName
            )
        }

        // Close the loop: if patterns were injected and task succeeded, mark them as effective
        if finalStatus == .completed && !injectedPatternHashes.isEmpty {
            for hash in injectedPatternHashes {
                FailurePatternDB.shared.markSuccess(patternHash: hash)
            }
        }

        // Skill evolution: extract reusable skill from successful tasks
        if finalStatus == .completed && outcomeScore >= 70 {
            let usedTools = task.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName }
            let uniqueTools = Array(Set(usedTools))
            // A2: Extract actual tool call sequence instead of hardcoded templates
            let orderedTools = task.steps
                .filter { $0.kind == .toolCall }
                .compactMap { $0.toolName }
            let dedupedSequence: [String] = {
                var seen = Set<String>()
                return orderedTools.filter { seen.insert($0).inserted }
            }()
            let strategy = dedupedSequence.isEmpty ? "工具辅助完成" : dedupedSequence.prefix(8).joined(separator: " → ")
            SkillEvolutionEngine.shared.extractSkill(
                taskTitle: task.title,
                intent: intentString,
                toolsUsed: uniqueTools,
                modelName: config.modelName,
                outcomeScore: outcomeScore,
                strategy: strategy
            )
        }

        // Skill evolution: update Q-value if a learned skill was used
        if let usedSkillID = task.context.metadata["learnedSkillID"].flatMap(Int.init) {
            if finalStatus == .completed {
                SkillEvolutionEngine.shared.updateQ(
                    skillID: usedSkillID,
                    outcomeScore: outcomeScore,
                    succeeded: true
                )
            } else {
                // Penalize skill on failure/cancel — faster decay for bad skills
                SkillEvolutionEngine.shared.penalize(skillID: usedSkillID)
            }
        }

        // Store compact execution trace for future GEPA-style analysis
        let traceEntries = task.steps.filter { $0.kind == .toolCall || $0.kind == .toolResult }
            .map { step -> [String: String] in
                var entry: [String: String] = [
                    "kind": step.kind == .toolCall ? "call" : "result",
                    "tool": step.toolName ?? "",
                    "text": String(step.text.prefix(200))
                ]
                if step.isFailure { entry["failure"] = "true" }
                return entry
            }
        if let traceData = try? JSONSerialization.data(withJSONObject: traceEntries),
           let traceJSON = String(data: traceData, encoding: .utf8) {
            TaskOutcomeRecorder.shared.storeTrace(taskID: task.id.uuidString, traceJSON: traceJSON)
        }

        // Persist task memory for cross-session continuity
        TaskMemoryStore.save(taskContext.memory, workspaceRoot: config.workspaceRoot)
        TaskMemoryStore.appendHistory(memory: taskContext.memory, workspaceRoot: config.workspaceRoot, taskDescription: task.title)

        return task
    }

    // MARK: - Helpers

    /// Parse JSON arguments into [String: String] for display
    private func parseParamsFromJSON(_ json: String) -> [String: String] {
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

    // G9: Allow file edits on DIFFERENT files to run in parallel
    private static func scheduledToolCallBatches(
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
                // file.edit / file.write — can parallel if different files
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
        if ["file.write", "file.edit"].contains(toolName) {
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

    private static func usesOllamaChat(_ connector: ConnectorProfile) -> Bool {
        connector.kind == "ollama" || connector.endpoint.contains(":11434")
    }

    private static func meetsCompletionCriteria(
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
        let hasWrite = task.steps.contains { $0.kind == .toolCall && ["file.write", "file.edit"].contains($0.toolName ?? "") }
        let hasVerificationFailure = task.steps.contains { $0.toolName == "verify.build" && $0.isFailure }

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
                return hasFinalOutput || successfulResults.contains { $0.toolName == "file.write" || $0.toolName == "file.edit" }
            }
            return hasFinalOutput && (!hadFailure || successfulResults.count >= 2)
        }
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

    private static func stageSummaryStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool) -> TaskStep {
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

    private static func shouldEmitStageSummary(for task: AgentTask, hasPlan: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> Bool {
        if hasPlan || hadFailure || wasTruncated {
            return true
        }
        if isReadOnlyRun {
            return false
        }
        return task.steps.contains { step in
            ["file.write", "file.edit", "shell.exec", "verify.build"].contains(step.toolName ?? "") || step.kind == .error
        }
    }

    private static func evidenceChecklistStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool, isReadOnlyRun: Bool = false) -> TaskStep? {
        let toolCalls = task.steps.filter { $0.kind == .toolCall }
        guard !toolCalls.isEmpty || hadFailure || wasTruncated else { return nil }
        let hasWriteOrCommand = toolCalls.contains {
            ["file.write", "file.edit", "shell.exec", "verify.build"].contains($0.toolName ?? "")
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

    private static func lastTextOutput(in steps: [TaskStep]) -> String? {
        steps.reversed().first {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func continueTruncatedOutput(
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

    private func executeRecoveryTool(
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

        let (result, _) = await ValidationEngine.executeWithValidationJSON(
            tool: tool,
            argumentsJSON: argumentsJSON,
            context: context,
            maxRetries: 1
        )
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

    private static func executeShellStreamingViaNotification(
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
        let policySnapshot = await SecurityManager.shared.policySnapshot
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

    private static func extractHunks(from params: [String: String]) -> [DiffHunk] {
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

    private static func completionCheckStep(for task: AgentTask, didComplete: Bool, hadFailure: Bool, wasTruncated: Bool = false, isReadOnlyRun: Bool = false) -> TaskStep {
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

    private static func finalizeFromCollectedEvidence(
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
        let execTools: Set<String> = ["file.write", "file.edit", "shell.exec"]
        let hasExecution = task.steps.contains(where: { $0.kind == .toolCall && execTools.contains($0.toolName ?? "") })

        let prompt: String
        if hasExecution {
            prompt = """
            工具迭代预算已用完。不要再调用工具。
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
            工具迭代预算已用完。不要再调用工具，也不要写研究报告。
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

    private static func compactSummaryText(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    static func initialMessages(systemPrompt: String, message: String, priorSteps: [TaskStep], summaryCache: String? = nil, context: TaskContext = TaskContext(), imageAttachments: [ImageAttachment] = []) -> [ChatMessage] {
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
        if let memory = structuredTaskMemory(from: priorSteps, context: context) {
            messages.append(ChatMessage(
                role: "user",
                content: """
                下面是同一任务的结构化记忆。请优先使用它判断哪些文件已经读过、哪些工具失败过、目前阶段结论是什么；不要重复已经成功的读取或搜索。

                \(memory)
                """
            ))
        }
        if UserFrustrationDetector.isFrustrated(message) {
            messages.append(ChatMessage(
                role: "user",
                content: "用户当前在纠错或表达不满。\n\(UserFrustrationDetector.guidance)"
            ))
        }
        // Positive feedback reinforcement: boost learned skill Q-value when user praises
        if UserFrustrationDetector.isPositive(message),
           let skillID = context.metadata["learnedSkillID"].flatMap(Int.init) {
            SkillEvolutionEngine.shared.updateQ(skillID: skillID, outcomeScore: 90, succeeded: true)
        }
        // Use summary cache for early steps if available, otherwise compact full history
        if let cache = summaryCache, !cache.isEmpty {
            messages.append(ChatMessage(
                role: "user",
                content: """
                下面是同一任务早期步骤的摘要缓存，省略了详细内容。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。

                \(cache)
                """
            ))
            // Still include recent steps for precise context
            let recentHistory = compactHistoryMessages(from: Array(priorSteps.suffix(14)), contextMode: context.contextMode)
            if !recentHistory.isEmpty {
                messages.append(contentsOf: recentHistory)
            }
        } else {
            let history = compactHistoryMessages(from: priorSteps, contextMode: context.contextMode)
            if !history.isEmpty {
                messages.append(ChatMessage(
                    role: "user",
                    content: "下面是同一任务之前的关键上下文。请把本轮当作续接，不要重新开始，不要重复已经完成的搜索、读取或解释；只在证据不足时继续调用工具。"
                ))
                messages.append(contentsOf: history)
            }
        }
        // G12: Detect image file paths and convert to vision content parts
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]
        let imagePathPattern = #"(?:^|\s|：)(/[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp|tiff))"#
        var imageParts: [ContentPart] = []
        if let regex = try? NSRegularExpression(pattern: imagePathPattern, options: .caseInsensitive) {
            let ns = message as NSString
            let matches = regex.matches(in: message, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let path = ns.substring(with: match.range(at: 1))
                if FileManager.default.fileExists(atPath: path),
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   data.count < 20_000_000 {  // Skip files > 20MB
                    let ext = (path as NSString).pathExtension.lowercased()
                    let mediaType = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
                    imageParts.append(.imageBase64(data: data, mediaType: mediaType))
                }
            }
        }

        // Merge user-pasted images from UI
        for img in imageAttachments {
            imageParts.append(img.toContentPart())
        }

        if !imageParts.isEmpty {
            var parts: [ContentPart] = [.text(message)]
            parts.append(contentsOf: imageParts)
            messages.append(ChatMessage(role: "user", contentParts: parts))
        } else {
            messages.append(ChatMessage(role: "user", content: message))
        }
        return messages
    }

    static func structuredTaskMemory(from steps: [TaskStep], context: TaskContext = TaskContext()) -> String? {
        let readFiles = uniqueValues(
            steps
                .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        ) + context.memory.readFiles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let searchedQueries = uniqueValues(
            steps
                .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        ) + context.memory.searchedQueries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let indexedWorkspace = steps.contains {
            $0.toolName == "workspace.index" && $0.kind == .toolResult && !$0.isFailure
        }
        let failedTools = steps.filter { $0.kind == .toolResult && $0.isFailure }
        let failureGroups = Dictionary(grouping: failedTools, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted() + context.memory.failedTools
        let recentConclusions = steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) } + context.memory.stageConclusions
        let checkpoints = steps
            .filter { $0.kind == .aiThinking && $0.text.hasPrefix("任务检查点") }
            .suffix(1)
            .map { compactSummaryText($0.text, limit: 520) } + context.memory.checkpoints

        var lines = ["结构化任务记忆"]
        if indexedWorkspace {
            lines.append("- 已建立工作区索引：是")
        }
        if !readFiles.isEmpty {
            lines.append("- 已读文件：\(uniqueValues(readFiles).prefix(12).joined(separator: "、"))")
        }
        if !searchedQueries.isEmpty {
            lines.append("- 已搜索：\(uniqueValues(searchedQueries).prefix(8).joined(separator: "、"))")
        }
        if !failureGroups.isEmpty {
            lines.append("- 失败工具：\(uniqueValues(failureGroups).joined(separator: "、"))")
        }
        if let lastFailure = failedTools.last?.text.trimmingCharacters(in: .whitespacesAndNewlines), !lastFailure.isEmpty {
            lines.append("- 最近失败：\(compactSummaryText(lastFailure, limit: 260))")
        }
        if !recentConclusions.isEmpty {
            lines.append("- 阶段结论：\(recentConclusions.joined(separator: " / "))")
        }
        if !checkpoints.isEmpty {
            lines.append("- 最近检查点：\(uniqueValues(checkpoints).joined(separator: " / "))")
        }
        if let verification = context.memory.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !verification.isEmpty {
            lines.append("- 验证状态：\(verification)")
        }
        if !context.memory.pendingFiles.isEmpty {
            lines.append("- 未读候选：\(uniqueValues(context.memory.pendingFiles).prefix(12).joined(separator: "、"))")
        }
        if !context.memory.userDecisions.isEmpty {
            lines.append("- 用户决策：\(uniqueValues(context.memory.userDecisions).prefix(8).joined(separator: " / "))")
        }

        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func compactHistoryMessages(from steps: [TaskStep], contextMode: ContextMode = .balanced) -> [ChatMessage] {
        let history = steps
            .filter { step in
                switch step.kind {
                case .userInput, .textOutput, .toolCall, .toolResult, .error, .reviewResult:
                    return !step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .aiThinking, .reviewRequest:
                    return false
                }
            }
            .suffix(14)

        // Budget-aware compression: allocate character budget per step kind
        let totalBudget: Int
        switch contextMode {
        case .economy: totalBudget = 4_000
        case .balanced: totalBudget = 9_000
        case .deep: totalBudget = 18_000
        }
        var remainingBudget = totalBudget

        return history.map { step in
            let role: String = step.kind == .userInput ? "user" : "assistant"
            let prefix: String
            let stepBudget: Int
            switch step.kind {
            case .toolCall:
                prefix = "上一轮工具调用："
                stepBudget = min(600, max(200, remainingBudget / 4))
            case .toolResult:
                prefix = step.isFailure ? "上一轮工具失败：" : "上一轮工具结果："
                stepBudget = min(800, max(200, remainingBudget / 3))
            case .error:
                prefix = "上一轮出现错误："
                stepBudget = min(600, max(200, remainingBudget / 4))
            case .reviewResult:
                prefix = "上一轮审查结果："
                stepBudget = min(400, max(150, remainingBudget / 5))
            case .userInput:
                prefix = ""
                stepBudget = min(1_400, max(400, remainingBudget / 2))
            default:
                prefix = ""
                stepBudget = min(2_000, max(400, remainingBudget / 2))
            }
            let content = prefix + compactHistoryText(step.text, limit: stepBudget)
            remainingBudget = max(0, remainingBudget - content.count)
            return ChatMessage(role: role, content: content)
        }
    }

    /// Compress mid-task conversation history when it grows too long.
    /// Keeps the system prompt, first user message, and recent messages intact;
    /// replaces older messages with a compressed summary.
    private static func compressMidTaskHistory(_ messages: [ChatMessage], maxMessages: Int = 16) -> [ChatMessage] {
        guard messages.count > maxMessages else { return messages }

        // Always keep: system prompt (index 0), first user message, last N messages
        var result: [ChatMessage] = []
        var compressedBlock: [String] = []

        // Keep system prompt
        if let first = messages.first, first.role == "system" {
            result.append(first)
        }

        // Identify the first user message (keep it for task context)
        let firstUserIdx = messages.firstIndex(where: { $0.role == "user" }) ?? 1

        // Collect messages to compress (between first user and last N)
        let keepRecent = maxMessages - result.count - 1 // -1 for first user
        let compressEnd = max(messages.count - keepRecent, firstUserIdx + 1)

        // Keep first user message
        if firstUserIdx < messages.count {
            result.append(messages[firstUserIdx])
        }

        // Compress middle messages into a summary block
        for i in (firstUserIdx + 1)..<compressEnd {
            let msg = messages[i]
            let preview = String((msg.content ?? "").prefix(120))
            let label = msg.role == "assistant" ? "助手" : msg.role == "user" ? "用户" : msg.role
            compressedBlock.append("[\(label)] \(preview)")
        }

        if !compressedBlock.isEmpty {
            let summary = compressedBlock.joined(separator: "\n")
            result.append(ChatMessage(
                role: "user",
                content: "以下是之前会话的压缩摘要（已完成步骤）：\n\(summary)\n\n请基于以上摘要继续任务。"
            ))
        }

        // Keep recent messages intact
        for i in compressEnd..<messages.count {
            result.append(messages[i])
        }

        return result
    }

    private static func compactHistoryText(_ text: String, limit: Int = 1400) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        let head = cleaned.prefix(Int(Double(limit) * 0.65))
        let tail = cleaned.suffix(Int(Double(limit) * 0.25))
        return "\(head)\n... 历史内容已压缩 ...\n\(tail)"
    }

    /// Truncate tool result messages to fit within token budget.
    /// Keeps tool call messages intact, only truncates long tool result content.
    private static func truncateToolResults(_ messages: [ChatMessage], maxTokens: Int) -> [ChatMessage] {
        var result = messages
        var totalChars = result.reduce(0) { $0 + (($1.content ?? "").count) + (($1.reasoningContent ?? "").count) }
        let charBudget = maxTokens * 4

        // Truncate from oldest tool results first
        for i in 0..<result.count {
            guard totalChars > charBudget else { break }
            let msg = result[i]
            guard let content = msg.content, content.count > 2000 else { continue }
            // Tool results have role "tool" or contain tool result patterns
            if msg.role == "tool" || msg.role == "assistant" && msg.toolCalls != nil && !msg.toolCalls!.isEmpty {
                continue // Don't truncate tool call messages
            }
            if msg.role == "tool" || content.hasPrefix("[TOOL_RESULT]") || content.hasPrefix("工具结果") {
                let truncated = String(content.prefix(800)) + "\n... [内容过长已截断，原始长度 \(content.count) 字符] ..."
                let saved = content.count - truncated.count
                totalChars -= saved
                result[i] = ChatMessage(
                    role: msg.role,
                    content: truncated,
                    reasoningContent: msg.reasoningContent,
                    toolCalls: msg.toolCalls
                )
            }
        }
        return result
    }

    /// Unified detection: model writing tool calls as text instead of using function calling API.
    /// Covers both fake syntax patterns and tool name spam.
    private static func containsFakeToolCallSyntax(_ text: String) -> Bool {
        // Pattern 1: explicit tool call syntax in text
        let syntaxPatterns = [
            "[tool:", "[TOOL:", "tool:web_search", "tool:file_read", "tool:code_search",
            "tool:workspace_index", "tool:shell_exec",
            "<file_read", "<code_search", "<web_search", "<shell_exec",
            "web_search(query=", "file_read(path=", "code_search(query=",
            "workspace_index(path=", "shell_exec(command="
        ]
        let syntaxMatches = syntaxPatterns.filter { text.contains($0) }.count
        if syntaxMatches >= 2 { return true }
        // Pattern 2: spam list of tool names (10+ mentions)
        let toolNames = ["shell.exec", "file.read", "file.write", "file.edit",
                         "web.search", "web.fetch", "code.search", "workspace.index",
                         "shell_exec", "file_read", "file_write", "file_edit",
                         "web_search", "web_fetch", "code_search", "workspace_index"]
        let totalMentions = toolNames.reduce(0) { count, name in
            count + text.components(separatedBy: name).count - 1
        }
        return totalMentions >= 10
    }

    /// Alias for backward compat — same as containsFakeToolCallSyntax
    private static func looksLikeToolSpam(_ text: String) -> Bool {
        containsFakeToolCallSyntax(text)
    }

    private static func looksLikeProviderError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // Only match if text is short (error messages are typically brief, not full answers)
        let isShort = text.count < 500
        let hasErrorPrefix = text.hasPrefix("请求格式不被")
            || text.hasPrefix("请求失败")
            || text.hasPrefix("无法连接")
        let hasErrorKeyword = lowered.contains("invalid_request_error")
            || lowered.contains("provider returned")
        // URL pattern only counts as error if at start of text (error format: "...URL: http://...")
        let hasErrorURL = isShort && (text.contains("URL: http://") || text.contains("URL: https://"))
            && (lowered.contains("返回") || lowered.contains("failed") || lowered.contains("error"))
        return hasErrorPrefix || hasErrorKeyword || hasErrorURL
    }

    private static func isTransientError(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        // Network / connection errors
        if desc.contains("timeout") || desc.contains("超时") { return true }
        if desc.contains("connection") || desc.contains("连接") { return true }
        if desc.contains("network") || desc.contains("网络") { return true }
        if desc.contains("reset") || desc.contains("broken pipe") { return true }
        // Rate limiting
        if desc.contains("429") || desc.contains("rate limit") || desc.contains("限流") { return true }
        if desc.contains("too many requests") { return true }
        // Server errors (5xx)
        if desc.contains("500") || desc.contains("502") || desc.contains("503") || desc.contains("504") { return true }
        if desc.contains("server error") || desc.contains("服务不可用") { return true }
        // URLSession specific
        if desc.contains("urLError") || desc.contains("not connected") { return true }
        if desc.contains("cannot find host") { return true }
        return false
    }

    /// Auto-checkpoint: `git add -A && git commit` before destructive operations.
    /// This creates a safety net the user can roll back to with `git reset HEAD~1`.
    /// Using commit instead of stash because stash hides all uncommitted changes,
    /// while commit preserves them in history for easy inspection and rollback.
    private static func gitCheckpoint(workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        // Only checkpoint if it's a git repo
        let gitDir = root + "/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else { return }

        // Stage all changes
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        addProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        addProcess.arguments = ["git", "add", "-A"]
        let pipe = Pipe()
        addProcess.standardOutput = pipe
        addProcess.standardError = pipe
        try? addProcess.run()
        addProcess.waitUntilExit()

        // Check if there are staged changes to commit
        let statusProcess = Process()
        statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        statusProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        statusProcess.arguments = ["git", "diff", "--cached", "--quiet"]
        let statusPipe = Pipe()
        statusProcess.standardOutput = statusPipe
        statusProcess.standardError = statusPipe
        try? statusProcess.run()
        statusProcess.waitUntilExit()

        // If there are staged changes (exit code 1 = differences exist), commit them
        if statusProcess.terminationStatus != 0 {
            let commitProcess = Process()
            commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            commitProcess.currentDirectoryURL = URL(fileURLWithPath: root)
            commitProcess.arguments = ["git", "commit", "-m", "来财自动检查点", "--allow-empty-message"]
            commitProcess.standardOutput = pipe
            commitProcess.standardError = pipe
            try? commitProcess.run()
            commitProcess.waitUntilExit()
        }
    }

    public static func toolDefinitions(for intent: UserIntent, phase: TaskPhase = .explore, registry: ToolRegistry = .shared) -> [ToolDefinition] {
        switch intent {
        case .chat:
            // Provide basic read tools so model CAN use them if needed (e.g. user asks about code)
            let chatTools: Set<String> = ["file.read", "code.search", "workspace.index", "web.search", "web.fetch"]
            return registry.toolDefinitions.filter { def in
                chatTools.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .research:
            let allowed: Set<String> = ["web.search", "web.fetch", "code.search", "workspace.index", "file.read"]
            return registry.toolDefinitions.filter { def in
                allowed.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .task, .workflow:
            let allDefs = registry.toolDefinitions
            let allowed = phase.allowedTools
            return allDefs.filter { def in
                let canonical = ToolNameCodec.canonicalName(def.function.name)
                return allowed.contains(canonical)
            }
        }
    }

    /// Infer current task phase from accumulated steps.
    nonisolated public static func inferPhase(from steps: [TaskStep]) -> TaskPhase {
        // If there's been a file.write, we're past explore
        let hasWrite = steps.contains { $0.toolName == "file.write" }
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

    private static func shouldRetryWithoutTools(
        response: SendMessageResponse,
        requestedTools: [ToolDefinition],
        hasRetriedWithoutTools: Bool
    ) -> Bool {
        guard !requestedTools.isEmpty, !hasRetriedWithoutTools else { return false }
        let text = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("请求格式不被") || text.localizedCaseInsensitiveContains("HTTP 400") else { return false }
        let detail = ([text] + response.toolActivities.map { "\($0.summary) \($0.statusLine)" })
            .joined(separator: " ")
            .lowercased()
        return detail.contains("tool")
            || detail.contains("function")
            || detail.contains("400")
            || detail.contains("兼容")
    }

    private static func applyToolCompatibilityFallbackInstruction(to messages: inout [ChatMessage]) {
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

    static func firstReadablePath(inSearchOutput output: String, workspaceRoot: String) -> String? {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignoredExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "pdf", "zip", "gz", "dmg", "app"]
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("未找到") else { continue }
            let candidate = line.components(separatedBy: ":").first ?? line
            let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t`\"'"))
            guard !cleaned.isEmpty else { continue }
            let ext = (cleaned as NSString).pathExtension.lowercased()
            if ignoredExtensions.contains(ext) { continue }
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

enum ToolResultFormatter {
    static func displayText(toolName: String, arguments: [String: String], result: ToolResult) -> String {
        guard result.success else {
            return compact("失败：\(result.error ?? result.output)", limit: 360)
        }

        switch toolName {
        case "file.read":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            let size = result.data?["size"].flatMap(Int.init) ?? result.output.count
            let lines = result.output.components(separatedBy: .newlines).count
            let suffix = result.output.contains("已截断") ? "，内容已截断" : ""
            return "已读取 \(path) · \(lines) 行 · \(size) 字符\(suffix)"

        case "code.search":
            let query = result.data?["query"] ?? arguments["query"] ?? ""
            let count = result.data?["count"].flatMap(Int.init) ?? nonEmptyLines(result.output).count
            if count == 0 || result.output.hasPrefix("未找到") {
                return query.isEmpty ? "未找到匹配结果" : "未找到匹配结果：\(query)"
            }
            let sample = nonEmptyLines(result.output).prefix(3).joined(separator: "，")
            return sample.isEmpty ? "找到 \(count) 个匹配结果" : "找到 \(count) 个匹配结果：\(sample)"

        case "workspace.index":
            let fileCount = result.data?["fileCount"] ?? "0"
            let directoryCount = result.data?["directoryCount"] ?? "0"
            return "已建立项目索引 · \(fileCount) 个文件 · \(directoryCount) 个目录"

        case "file.edit":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            let applied = result.data?["appliedEdits"] ?? "0"
            let total = result.data?["totalEdits"] ?? applied
            return "已准备精准编辑 · \(path) · \(applied)/\(total) 条变更"

        case "file.write":
            let path = result.data?["path"] ?? arguments["path"] ?? "文件"
            return "已准备文件写入 · \(path)"

        case "verify.build":
            let command = result.data?["command"] ?? arguments["command"] ?? "自动检测"
            let exitCode = result.data?["exitCode"] ?? "0"
            return "验证完成 · 退出码 \(exitCode) · \(command)"

        case "web.search":
            let query = result.data?["query"] ?? arguments["query"] ?? ""
            let count = result.data?["count"].flatMap(Int.init) ?? nonEmptyLines(result.output).count
            if count == 0 || result.output.hasPrefix("未找到") {
                return query.isEmpty ? "未找到网页结果" : "未找到网页结果：\(query)"
            }
            let titles = nonEmptyLines(result.output)
                .filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
                .prefix(3)
                .joined(separator: "；")
            return titles.isEmpty
                ? "联网搜索完成 · \(count) 条结果：\(query)"
                : "联网搜索完成 · \(count) 条结果：\(titles)"

        case "web.fetch":
            let title = result.data?["title"] ?? "网页"
            let size = result.data?["size"] ?? "\(result.output.count)"
            return "已读取网页：\(title) · \(size) 字符"

        case "wiki.build":
            let topic = result.data?["topic"] ?? arguments["topic"] ?? "主题"
            let path = result.data?["path"] ?? "03 Topics"
            let count = result.data?["sourceCount"] ?? "0"
            let saved = result.data?["saved"] == "true"
            return saved
                ? "已保存 Wiki：\(topic) → \(path) · \(count) 条来源"
                : "已生成 Wiki 预览：\(topic) → \(path) · \(count) 条来源"

        case "shell.exec":
            let exitCode = result.data?["exitCode"] ?? "0"
            let firstLine = nonEmptyLines(result.output).first ?? "命令已完成"
            return "命令完成 · 退出码 \(exitCode) · \(compact(firstLine, limit: 180))"

        case "git":
            if result.data?["repository"] == "false" {
                return compact(result.output, limit: 220)
            }
            let firstLine = nonEmptyLines(result.output).first ?? "Git 操作已完成"
            return compact(firstLine, limit: 220)

        default:
            return compact(result.output, limit: 360)
        }
    }

    static func modelContent(toolName: String, result: ToolResult, limit: Int) -> String {
        if !result.success {
            var errorContent = compact("Error: \(result.error ?? result.output)", limit: max(500, limit))
            if toolName == "code.search" {
                errorContent += "\n\n提示：本地搜索未找到结果。如果这是一个外部工具、库或概念，请调用 web_search 联网搜索了解它是什么。"
            }
            return errorContent
        }

        if toolName == "code.search" && (result.output.hasPrefix("未找到") || result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return (result.output.isEmpty ? "未找到匹配结果。" : result.output) + "\n\n提示：本地搜索未找到结果。如果这是一个外部工具、库或概念，请调用 web_search 联网搜索了解它是什么，不要直接放弃。"
        }

        // Dynamic cap: scale with model's context window. 1M-class models can handle much more.
        let boundedLimit = max(2000, min(limit, 100_000))
        if result.output.count <= boundedLimit {
            return result.output
        }

        // Smart truncation for code files: keep structural signatures
        if toolName == "file.read" {
            let smartResult = smartTruncateCode(result.output, limit: boundedLimit)
            if !smartResult.isEmpty { return smartResult }
        }

        let headCount = max(1000, Int(Double(boundedLimit) * 0.6))
        let tailCount = max(500, Int(Double(boundedLimit) * 0.3))
        let omitted = result.output.count - headCount - tailCount
        let head = result.output.prefix(headCount)
        let tail = result.output.suffix(tailCount)
        return """
        \(head)

        ... 省略 \(omitted) 字符 ...

        \(tail)
        """
    }

    /// Smart truncation for code: keep imports, class/struct/func signatures, skip function bodies
    private static func smartTruncateCode(_ content: String, limit: Int) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.count > 80 else { return "" } // only for large files

        var kept: [String] = []
        var keptChars = 0
        let signaturePatterns = [
            "import ", "func ", "class ", "struct ", "enum ", "protocol ",
            "public ", "private ", "internal ", "extension ", "typealias ",
            "var ", "let ", "case ", "// MARK:", "/// ", "def ", "async ",
            "interface ", "export ", "const ", "type ", "from "
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSignature = signaturePatterns.contains { trimmed.hasPrefix($0) }
            let isShortLine = line.count < 120

            if isSignature || trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
                kept.append(line)
                keptChars += line.count + 1
            } else if isShortLine && keptChars < limit / 2 {
                kept.append(line)
                keptChars += line.count + 1
            }

            if keptChars >= limit { break }
        }

        guard kept.count >= 10 else { return "" }
        let result = kept.joined(separator: "\n")
        return "\(result)\n\n[结构摘要：保留了 \(kept.count)/\(lines.count) 行签名和关键代码]"
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum ToolStepFormatter {
    static func callText(toolName: String, arguments: [String: String]) -> String {
        switch toolName {
        case "file.read":
            return "正在读取文件：\(arguments["path"] ?? "目标文件")"
        case "code.search":
            let query = arguments["query"] ?? "相关内容"
            let scope = arguments["scope"] == "content" ? "内容" : "文件"
            return "正在搜索项目\(scope)：\(query)"
        case "workspace.index":
            return "正在建立项目索引"
        case "file.edit":
            return "正在精准编辑文件：\(arguments["path"] ?? "目标文件")"
        case "verify.build":
            return "正在验证构建/测试"
        case "shell.exec":
            return "正在执行命令：\(arguments["command"] ?? "命令")"
        case "web.search":
            return "正在联网搜索：\(arguments["query"] ?? "最新信息")"
        case "web.fetch":
            return "正在读取网页：\(arguments["url"] ?? "链接")"
        case "wiki.build":
            return "正在整理 Wiki：\(arguments["topic"] ?? "主题")"
        case "file.write":
            return "准备写入文件：\(arguments["path"] ?? "目标文件")"
        case "git":
            return "正在检查 Git：\(arguments["subcommand"] ?? "status")"
        default:
            return "正在执行工具：\(toolName)"
        }
    }
}

// MARK: - Cross-Session Task Memory Store

public enum TaskMemoryStore {
    private static let fileName = ".laicai-memory.json"
    private static let historyFileName = ".laicai-memory-history.json"
    private static let maxReadFiles = 50
    private static let maxSearchedQueries = 30
    private static let maxConclusions = 10
    private static let maxHistoryEntries = 20

    // MARK: - Keyword Index

    /// Build a keyword → filePaths index from file summaries for fast retrieval
    public static func buildKeywordIndex(from memory: TaskMemory) -> [String: [String]] {
        var index: [String: [String]] = [:]
        let stopWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "need", "dare", "ought", "used",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as", "into",
            "through", "during", "before", "after", "above", "below", "between", "out",
            "off", "over", "under", "again", "further", "then", "once", "and", "but",
            "or", "nor", "not", "so", "yet", "both", "either", "neither", "each",
            "every", "all", "any", "few", "more", "most", "other", "some", "such",
            "no", "only", "own", "same", "than", "too", "very", "just", "because",
            "if", "when", "where", "how", "what", "which", "who", "this", "that",
            "these", "those", "的", "了", "在", "是", "我", "有", "和", "就", "不",
            "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你",
            "会", "着", "没有", "看", "好", "自己", "这"]

        for (filePath, summary) in memory.fileSummaries {
            let words = summary.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in words {
                index[word, default: []].append(filePath)
            }
        }
        // Also index conclusions
        for conclusion in memory.stageConclusions {
            let words = conclusion.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in words {
                index[word, default: []].append("conclusion:\(conclusion.prefix(50))")
            }
        }
        // Deduplicate
        for key in index.keys {
            index[key] = Array(Set(index[key] ?? []))
        }
        return index
    }

    /// Search persisted memory by keyword, returning matching file summaries and conclusions
    public static func search(workspaceRoot: String, query: String, limit: Int = 10) -> [String] {
        let memory = load(workspaceRoot: workspaceRoot)
        guard !memory.isEmpty else { return [] }
        let index = buildKeywordIndex(from: memory)
        let queryWords = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        var scored: [String: Int] = [:]
        for word in queryWords {
            if let paths = index[word] {
                for path in paths {
                    scored[path, default: 0] += 1
                }
            }
        }
        return scored.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    // MARK: - Session History

    private struct HistoryEntry: Codable, Sendable {
        let timestamp: Date
        let taskDescription: String
        let conclusions: [String]
        let filesModified: [String]
    }

    public static func appendHistory(memory: TaskMemory, workspaceRoot: String, taskDescription: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let path = (root as NSString).appendingPathComponent(historyFileName)

        var history: [HistoryEntry] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }

        let entry = HistoryEntry(
            timestamp: .now,
            taskDescription: String(taskDescription.prefix(200)),
            conclusions: Array(memory.stageConclusions.suffix(5)),
            filesModified: Array(Set(memory.pendingFiles).prefix(20))
        )
        history.append(entry)
        if history.count > maxHistoryEntries {
            history = Array(history.suffix(maxHistoryEntries))
        }

        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func loadHistory(workspaceRoot: String) -> [(timestamp: Date, description: String, conclusions: [String])] {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }
        let path = (root as NSString).appendingPathComponent(historyFileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let history = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return history.map { (timestamp: $0.timestamp, description: $0.taskDescription, conclusions: $0.conclusions) }
    }

    // MARK: - Save / Load / Merge

    public static func save(_ memory: TaskMemory, workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !memory.isEmpty else { return }

        // Trim before saving to keep file small
        var trimmed = memory
        trimmed.readFiles = Array(Set(trimmed.readFiles).prefix(maxReadFiles))
        trimmed.searchedQueries = Array(Set(trimmed.searchedQueries).prefix(maxSearchedQueries))
        trimmed.stageConclusions = Array(trimmed.stageConclusions.suffix(maxConclusions))
        trimmed.checkpoints = Array(trimmed.checkpoints.suffix(5))
        trimmed.failedTools = Array(Set(trimmed.failedTools).prefix(20))
        trimmed.userDecisions = Array(trimmed.userDecisions.suffix(15))
        // Don't persist file content cache (too large)
        trimmed.fileContentCache = [:]
        // Keep only recent file summaries
        if trimmed.fileSummaries.count > maxReadFiles {
            let sorted = trimmed.fileSummaries.sorted { $0.key < $1.key }
            trimmed.fileSummaries = Dictionary(uniqueKeysWithValues: Array(sorted.suffix(maxReadFiles)))
        }
        trimmed.updatedAt = .now

        let path = (root as NSString).appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func load(workspaceRoot: String) -> TaskMemory {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return TaskMemory() }
        let path = (root as NSString).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let memory = try? JSONDecoder().decode(TaskMemory.self, from: data) else {
            return TaskMemory()
        }
        // Stale check: if memory is older than 7 days, treat as stale
        if let updated = memory.updatedAt, Date().timeIntervalSince(updated) > 7 * 86400 {
            return TaskMemory()
        }
        return memory
    }

    public static func merge(_ persisted: TaskMemory, into current: TaskMemory) -> TaskMemory {
        var result = current
        // Merge read files (persisted first, then current)
        let allRead = Set(persisted.readFiles).union(current.readFiles)
        result.readFiles = Array(allRead.prefix(maxReadFiles))
        // Merge searched queries
        let allSearched = Set(persisted.searchedQueries).union(current.searchedQueries)
        result.searchedQueries = Array(allSearched.prefix(maxSearchedQueries))
        // Merge file summaries (current overwrites persisted)
        var summaries = persisted.fileSummaries
        for (k, v) in current.fileSummaries { summaries[k] = v }
        result.fileSummaries = summaries
        // Keep persisted conclusions if current has none
        if result.stageConclusions.isEmpty {
            result.stageConclusions = Array(persisted.stageConclusions.suffix(maxConclusions))
        }
        if result.checkpoints.isEmpty {
            result.checkpoints = persisted.checkpoints
        }
        if result.verificationStatus == nil {
            result.verificationStatus = persisted.verificationStatus
        }
        // Merge pending files
        let allPending = Set(persisted.pendingFiles).union(current.pendingFiles)
        result.pendingFiles = Array(allPending.prefix(30))
        // Merge user decisions
        if result.userDecisions.isEmpty {
            result.userDecisions = Array(persisted.userDecisions.suffix(15))
        }
        result.updatedAt = .now
        return result
    }
}
