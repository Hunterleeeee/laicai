import Foundation
import LaicaiNativeDomain

/// Runs a local task by asking the model, executing requested tools, and feeding results back.
@MainActor
public final class AgentLoop: ObservableObject {
    // G1: Shared repository for persistent memory access
    public static var sharedRepository: SQLiteRepository?

    static let toolCompatibilityFallbackAction = "connector.disableToolCalling"

    let config: Config
    let runtime: any ChatRuntimeClient
    let toolRegistry: ToolRegistry

    public init(
        config: Config,
        runtime: any ChatRuntimeClient,
        toolRegistry: ToolRegistry = .shared
    ) {
        self.config = config
        self.runtime = runtime
        self.toolRegistry = toolRegistry
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
        let wasCancelled = false
        // PERF-3: Chat fast path — skip heavy file scan and git diff for simple chat
        var taskContext = prepareTaskContext(context, intent: intent, message: message)

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

        authorizeUserPathsAndNarrowWorkspace(message: message, intent: intent, taskContext: &taskContext)
        await runPreparationTools(message: message, intent: intent, needsPlanning: needsPlanning, taskContext: &taskContext, task: &task, onStep: onStep)

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
        if intent != .chat, let learnedSkill = SkillEvolutionEngine.shared.bestSkill(intent: intentString, modelName: config.modelName, message: message) {
            let toolSequence = learnedSkill.toolSequence.map { ToolNameCodec.canonicalName($0) }.joined(separator: " → ")
            let skillInjection = """

## 已学技能提示
此类任务曾成功使用策略「\(learnedSkill.strategy)」，推荐工具序列：\(toolSequence)
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
        }

        // D4: Task-aware tool selection guidance
        if intent != .chat {
            var toolHints: [String] = []
            // Detect file creation tasks
            let lowerMsg = message.lowercased()
            let isFileCreation = lowerMsg.contains("创建") || lowerMsg.contains("写入") || lowerMsg.contains("新建") || lowerMsg.contains("create") || lowerMsg.contains("write")
            if isFileCreation {
                toolHints.append("创建文件：用 file_write，不要用 wiki_build（wiki_build 只用于 Obsidian 知识库整理）")
            }
            // Detect when user wants to modify existing code
            if lowerMsg.contains("修改") || lowerMsg.contains("改") || lowerMsg.contains("fix") || lowerMsg.contains("修复") {
                toolHints.append("修改文件：先 file_read 看完整内容，再 file_edit 精确修改，最后 verify_build 验证")
            }
            if !toolHints.isEmpty {
                systemPrompt += "\n\n## 工具使用提示\n" + toolHints.joined(separator: "\n")
            }
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
        // Hard circuit breaker: tool+target combos that have failed too many times
        var circuitBrokenTools: Set<String> = []  // "toolName:targetPrefix"
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
        } else if !isPureContinuation, !toolDefs.isEmpty, let localPath = Self.firstLocalPath(in: message),
                  Self.shouldBootstrapExtract(path: localPath), isToolAllowed("file.extract"),
                  let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract") {
            let bootstrapMessage = await Self.runBootstrapFileExtract(
                path: localPath,
                extractTool: extractTool,
                taskContext: &taskContext,
                task: &task,
                maxTokens: config.maxTokensPerTurn,
                onStep: onStep
            )
            messages.append(bootstrapMessage)
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
                  !taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("工作区索引：") }),
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
               let path = Self.firstReadablePath(inSearchOutput: toolResult.output, workspaceRoot: taskContext.workspaceRoot) {
                if Self.shouldBootstrapExtract(path: path),
                   isToolAllowed("file.extract"),
                   let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract") {
                    let extract = await Self.runBootstrapFileExtract(
                        path: path,
                        extractTool: extractTool,
                        taskContext: &taskContext,
                        task: &task,
                        callId: "call_bootstrap_search_file_extract",
                        maxTokens: max(1200, config.maxTokensPerTurn / 2),
                        onStep: onStep
                    )
                    autoReadBlock = "\n\n自动提取的首个高相关表格/文档（\(path)）：\n\(extract.content ?? "")"
                } else if let readTool = toolRegistry.tool(named: "file_read") {
                    autoReadBlock = await Self.runBootstrapFileRead(
                        path: path,
                        readTool: readTool,
                        taskContext: &taskContext,
                        task: &task,
                        maxTokens: max(1200, config.maxTokensPerTurn / 2),
                        onStep: onStep
                    )
                }
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

        // G5: Inject learned tool patterns from successful past tasks
        if intent != .chat && !taskContext.workspaceRoot.isEmpty, let repo = Self.sharedRepository {
            let lm = message.lowercased()
            let taskType: String
            if lm.contains("修改") || lm.contains("fix") || lm.contains("修复") { taskType = "modify" }
            else if lm.contains("创建") || lm.contains("新建") || lm.contains("create") { taskType = "create" }
            else if lm.contains("搜索") || lm.contains("查找") || lm.contains("search") { taskType = "search" }
            else if lm.contains("解释") || lm.contains("分析") || lm.contains("explain") { taskType = "explain" }
            else { taskType = "general" }
            let patterns = repo.loadMemories(workspace: taskContext.workspaceRoot, limit: 50)
                .filter { $0.category == "tool_pattern" && $0.key.hasPrefix("success_\(taskType)") }
            if let bestPattern = patterns.first {
                systemPrompt += "\n\n## 历史成功路径\n此类任务（\(taskType)）曾用以下工具序列成功完成：\(bestPattern.value)\n请优先按此路径执行。"
            }
        }

        // G1: Task template engine — pre-execute the entire tool sequence for common tasks.
        // Instead of letting the LLM figure out which tools to call (3-5 iterations),
        // the orchestration layer detects the task type and does it all upfront.
        if intent != .chat && needsPlanning && priorSteps.isEmpty && config.supportsToolCalling {
            let templateResult = await Self.executeTaskTemplate(
                message: message,
                taskContext: &taskContext,
                task: &task,
                messages: &messages,
                toolRegistry: toolRegistry,
                onStep: onStep
            )
            if templateResult.executedSteps > 0 {
                let templateStep = TaskStep(
                    kind: .aiThinking,
                    text: "编排层模板引擎：预执行 \(templateResult.executedSteps) 步（\(templateResult.templateName)）",
                    isCollapsible: true,
                    isCollapsed: true
                )
                task.steps.append(templateStep)
                onStep(templateStep)

                // Inject a directive so the LLM knows everything is ready
                messages.append(ChatMessage(role: "system", content: templateResult.directive))
            }
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
        let maxTransientRetries = isReadOnlyRun ? 1 : 3
        var toolFailureCounts: [String: Int] = [:]  // "toolName:target" → count
        var didInjectWorkingSet = false
        let maxRepeatedFailures = 2
        let usesOllamaChat = Self.usesOllamaChat(connector)
        // A4: Dynamic iteration budget — learn from historical average
        var effectiveMaxIterations = config.maxIterations
        if let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentString) {
            let learned = Int(ceil(avgIter * 1.5))
            effectiveMaxIterations = max(3, min(learned, config.maxIterations))
        }
        // Auto-continuation: when iterations exhausted but task not done, auto-extend
        let maxAutoRounds = 3
        var autoRound = 0
        let absoluteMaxSteps = 120  // Hard safety limit: prevent runaway tasks
        repeat {
        while iteration < effectiveMaxIterations {
            guard !Task.isCancelled else {
                task.status = .failed
                return task
            }
            // Hard step count limit
            if task.steps.count >= absoluteMaxSteps {
                let limitStep = TaskStep(
                    kind: .aiThinking,
                    text: "已达到步骤数上限（\(absoluteMaxSteps)步），强制结束。如需继续请新建任务。",
                    isCollapsible: false
                )
                task.steps.append(limitStep)
                onStep(limitStep)
                hadFailure = true
                break
            }
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

            // H4: Proactive tool result compression — after first iteration,
            // old tool results are unlikely to be needed verbatim. Truncate
            // them in-place to free context for new tool results.
            if iteration > 1 {
                let recentKeep = messages.count > 6 ? messages.count - 6 : 0
                for i in 0..<recentKeep {
                    guard let content = messages[i].content, content.count > 800 else { continue }
                    let isToolResult = messages[i].role == "tool"
                        || (messages[i].role == "user" && (content.hasPrefix("工具") || content.hasPrefix("[TOOL_RESULT]") || content.hasPrefix("✅") || content.hasPrefix("编排层")))
                    if isToolResult {
                        messages[i].content = String(content.prefix(500)) + "\n…（历史工具结果已压缩，原\(content.count)字符）"
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

            // F3: Structured progress state — inject every 3 iterations for precise awareness
            if iteration > 0 && iteration % 3 == 0 && intent != .chat {
                var state: [String] = []

                // Files read
                let readFiles = taskContext.memory.readFiles
                if !readFiles.isEmpty {
                    let fileList = readFiles.suffix(10).map { "  \(URL(fileURLWithPath: $0).lastPathComponent)" }.joined(separator: "\n")
                    state.append("📖 已读文件（\(readFiles.count)个，可直接 file_edit）：\n\(fileList)")
                }

                // Files written
                let writtenPaths = taskContext.memory.userDecisions.compactMap { d -> String? in
                    d.hasPrefix("已写入：") ? String(d.dropFirst(4)) : nil
                }
                if !writtenPaths.isEmpty {
                    state.append("✏️ 已写入：\(writtenPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))")
                }

                // Searches done
                let queries = taskContext.memory.searchedQueries
                if !queries.isEmpty {
                    state.append("🔍 已搜索：\(queries.joined(separator: "、"))（不要重复搜索这些词）")
                }

                // Failures
                let failedTools = taskContext.memory.failedTools
                if !failedTools.isEmpty {
                    let failCounts = Dictionary(grouping: failedTools, by: { $0 }).mapValues(\.count)
                    let failSummary = failCounts.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    state.append("❌ 失败：\(failSummary)（不要用相同参数重试已失败的操作）")
                }

                // Build status
                let lastVerify = task.steps.last(where: { $0.toolName == "verify.build" })
                if let lv = lastVerify {
                    state.append(lv.isFailure == true ? "🔴 最近编译：失败" : "🟢 最近编译：通过")
                }

                // Budget
                let remaining = effectiveMaxIterations - iteration
                state.append("⏱ 迭代预算：已用 \(iteration)/\(effectiveMaxIterations)，剩余 \(remaining)")

                if !state.isEmpty {
                    messages.append(ChatMessage(role: "system", content: "## 任务状态（第 \(iteration) 轮）\n" + state.joined(separator: "\n")))
                }
            }
            // Budget warning when truly running low.
            if iteration == effectiveMaxIterations - 2 && iteration > 3 {
                messages.append(ChatMessage(role: "system", content: "即将结束本轮处理，请尽快给出结论或完成执行。"))
            }

            // G3: Aggressive context trimming — strip verbose prompt sections after initial iterations
            var effectiveSystemPrompt = systemPrompt
            if iteration >= 3 {
                // After 3 iterations, the model already has context. Replace verbose guidance
                // with ultra-concise directives to free up context window for tool results.
                var sections = effectiveSystemPrompt.components(separatedBy: "\n## ")
                // Keep first section (core identity) + strip verbose sections
                let stripPrefixes = ["历史经验", "工具效率", "已学技能", "工具使用提示", "项目记忆"]
                sections = sections.filter { section in
                    !stripPrefixes.contains(where: { section.hasPrefix($0) })
                }
                effectiveSystemPrompt = sections.joined(separator: "\n## ")
                // Add a terse action directive instead
                effectiveSystemPrompt += "\n\n[第\(iteration)轮] 直接行动，不要计划或解释。用最少步骤完成任务。"
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
                systemPrompt: effectiveSystemPrompt,
                tools: toolDefs.isEmpty ? nil : toolDefs,
                messages: messages,
                maxOutputTokens: config.maxTokensPerTurn
            )

            // G2: Speculative parallel execution — predict what LLM will need next
            // and start pre-fetching while it's thinking.
            let speculativeTask = Task { @MainActor in
                await Self.speculativePreFetch(
                    iteration: iteration,
                    taskContext: taskContext,
                    task: task,
                    toolRegistry: self.toolRegistry
                )
            }

            let response: SendMessageResponse
            do {
                response = try await runtime.sendMessageStream(request, onChunk: onStreamDelta)
                // G2: Merge speculative pre-fetch results into task context
                let specResult = await speculativeTask.value
                for (path, content) in specResult.cachedFiles {
                    taskContext.memory.fileContentCache[path] = content
                    if !taskContext.memory.readFiles.contains(path) {
                        taskContext.memory.readFiles.append(path)
                    }
                }
                for (path, summary) in specResult.summaries {
                    taskContext.memory.fileSummaries[path] = summary
                }
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
                    let delaySec = min(Int(pow(2.0, Double(transientRetryCount))), 8)
                    try? await Task.sleep(for: .milliseconds(delaySec * 1000))
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
                                var toolResult: ToolResult!
                                var recoveryPlan: RecoveryPlan?

                                // F2: Tool call interception & rewrite — fix common model mistakes
                                var argumentsJSON = argumentsJSON
                                argumentsJSON = Self.rewriteToolArguments(
                                    toolName: toolName,
                                    argumentsJSON: argumentsJSON,
                                    workspaceRoot: taskContext.workspaceRoot
                                )

                                // G4: Smart cache hit — when file.read is for an already-cached file,
                                // return the full content directly (up to token limit) so the model
                                // can immediately proceed without another roundtrip.
                                if toolName == "file.read",
                                   let readPath = callStep.toolParams?["path"],
                                   callStep.toolParams?["offset"] == nil,
                                   let cached = taskContext.memory.fileContentCache[readPath] ?? taskContext.memory.fileContentCache[(taskContext.workspaceRoot as NSString).appendingPathComponent(readPath)] {
                                    let limit = min(cached.count, 20000)
                                    let content = cached.count <= limit ? cached : String(cached.prefix(limit)) + "\n…（共\(cached.count)字符，已截取前\(limit)字符）"
                                    // Include sibling files from F4 directory cache
                                    let dir = (readPath as NSString).deletingLastPathComponent
                                    let siblings = taskContext.memory.fileSummaries["__dir__:\(dir)"]
                                    let siblingHint = siblings.map { "\n同目录其他文件：\($0)" } ?? ""
                                    let cacheNote = "✅ 缓存命中（0ms）\(siblingHint)\n\n\(content)"
                                    toolResult = ToolResult(
                                        output: cacheNote,
                                        data: ["path": readPath, "size": "\(cached.count)", "cached": "true"]
                                    )
                                    return (index, toolResult, nil as RecoveryPlan?)
                                }

                                // C5: workspace.index cache — don't re-scan if already indexed
                                if toolName == "workspace.index",
                                   taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("工作区索引：") }) {
                                    let cached = taskContext.memory.userDecisions.first(where: { $0.hasPrefix("工作区索引：") }) ?? "已索引"
                                    toolResult = ToolResult(
                                        output: "✅ 工作区已索引（缓存）。\(String(cached.prefix(500)))",
                                        data: ["cached": "true"]
                                    )
                                    return (index, toolResult, nil as RecoveryPlan?)
                                }

                                // Dedup: if code_search with identical or very similar query was already done, skip
                                if toolName == "code.search",
                                   let query = callStep.toolParams?["query"] {
                                    let isDuplicate = taskContext.memory.searchedQueries.contains(query)
                                    let isSimilar = !isDuplicate && taskContext.memory.searchedQueries.contains(where: {
                                        $0.lowercased().contains(query.lowercased()) || query.lowercased().contains($0.lowercased())
                                    })
                                    if isDuplicate || isSimilar {
                                        let hint = isSimilar ? "类似查询已搜索过" : "此查询已搜索过"
                                        toolResult = ToolResult(
                                            output: "\(hint)，结果见上方历史。请基于已有结果继续，不要重复搜索。如需进一步定位，改用 shell_exec grep -r 或 find 命令。",
                                            data: ["query": query, "cached": "true"]
                                        )
                                        return (index, toolResult, nil as RecoveryPlan?)
                                    }
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
                                } else {
                                    // Hard circuit breaker: block tool+target combos that failed 3+ times
                                    // Auto-repair: try alternative tool path instead of just blocking
                                    let cbTarget = callStep.toolParams?["path"] ?? callStep.toolParams?["query"] ?? ""
                                    let cbSig = "\(toolName):\(cbTarget.prefix(60))"
                                    if circuitBrokenTools.contains(cbSig) {
                                        // Auto-repair: file.edit → read current content + file.write
                                        if toolName == "file.edit",
                                           let editPath = callStep.toolParams?["path"],
                                           let readTool = self.toolRegistry.tool(named: "file_read"),
                                           let writeTool = self.toolRegistry.tool(named: "file_write") {
                                            // Step 1: read current file
                                            let readJSON = (try? JSONSerialization.data(withJSONObject: ["path": editPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                            let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: taskContext)
                                            if let rr = readResult, rr.success {
                                                // Step 2: extract newText from edits param and append
                                                let editsStr = callStep.toolParams?["edits"] ?? "[]"
                                                let newTexts = Self.extractNewTexts(from: editsStr)
                                                if !newTexts.isEmpty {
                                                    let separator = rr.output.hasSuffix("\n") ? "" : "\n"
                                                    let merged = rr.output + separator + newTexts.joined(separator: "\n")
                                                    let writeDict: [String: Any] = ["path": editPath, "content": merged]
                                                    let writeJSON = (try? JSONSerialization.data(withJSONObject: writeDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                    let writeResult = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext)
                                                    if let wr = writeResult, wr.success {
                                                        toolResult = ToolResult(
                                                            output: "🔴→✅ 熔断自动修复：file.edit 连续失败，编排层改用 file.read + file.write 完成。\n\(wr.output)",
                                                            data: wr.data,
                                                            success: true
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                        // Auto-repair: code.search → shell grep
                                        if toolResult == nil && toolName == "code.search",
                                           let query = callStep.toolParams?["query"],
                                           let shellTool = self.toolRegistry.tool(named: "shell_exec") {
                                            let safeQuery = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
                                            let grepCmd = "grep -rn '\(safeQuery)' . --include='*.swift' --include='*.md' --include='*.py' --include='*.js' --include='*.ts' | head -30"
                                            let shellDict: [String: Any] = ["command": grepCmd]
                                            let shellJSON = (try? JSONSerialization.data(withJSONObject: shellDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                            let shellResult = try? await shellTool.execute(argumentsJSON: shellJSON, context: taskContext)
                                            if let sr = shellResult, sr.success {
                                                toolResult = ToolResult(
                                                    output: "🔴→✅ 熔断自动修复：code.search 连续失败，编排层改用 grep 搜索。\n\(sr.output)",
                                                    data: sr.data,
                                                    success: true
                                                )
                                            }
                                        }
                                        // Fallback: still return circuit_broken if auto-repair failed
                                        if toolResult == nil {
                                            toolResult = ToolResult(
                                                output: "🔴 已熔断：`\(toolName)` 对该目标已连续失败多次且自动修复失败。请使用其他工具完成此操作。",
                                                success: false,
                                                error: "circuit_broken"
                                            )
                                        }
                                    }
                                }
                                if toolResult == nil, let tool = self.toolRegistry.tool(named: apiToolName) {
                                    if tool.requiresReview || ["file.write", "file.edit"].contains(toolName) {
                                        Self.gitCheckpoint(workspaceRoot: self.config.workspaceRoot, paths: Self.checkpointPaths(toolName: toolName, arguments: self.parseParamsFromJSON(argumentsJSON), workspaceRoot: self.config.workspaceRoot))
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
                                    // C3: Automatic parameter mutation retry
                                    // When tools fail with fixable errors, orchestration layer
                                    if !toolResult.success {
                                        if toolName == "file.read",
                                           let path = callStep.toolParams?["path"] {
                                            if toolResult.error == "unsupported_binary_file",
                                               let extractTool = self.toolRegistry.tool(named: "file_extract") ?? self.toolRegistry.tool(named: "file.extract") {
                                                if let er = await Self.autoExtractUnsupportedRead(path: path, extractTool: extractTool, context: taskContext) {
                                                    toolResult = ToolResult(
                                                        output: "file.read 检测到表格/文档，编排层自动改用 file.extract 提取成功：\n\(er.output)",
                                                        data: er.data,
                                                        success: true
                                                    )
                                                    taskContext.memory.readFiles.append(path)
                                                    taskContext.memory.fileContentCache[path] = er.output
                                                } else {
                                                    recoveryPlan = ErrorRecoveryEngine.planRecoveryJSON(
                                                        error: "unsupported_binary_file：\(toolResult.output)",
                                                        toolName: toolName,
                                                        argumentsJSON: argumentsJSON,
                                                        attemptCount: validation.retryCount
                                                    )
                                                }
                                            } else if (toolResult.error == "file_not_found" || toolResult.output.contains("不存在")),
                                                      let searchTool = self.toolRegistry.tool(named: "code_search") {
                                                // Auto-search for similar filename
                                                let filename = (path as NSString).lastPathComponent
                                                let searchJSON = "{\"query\":\"\(filename)\"}"
                                                let searchResult = try? await searchTool.execute(argumentsJSON: searchJSON, context: taskContext)
                                                if let sr = searchResult, sr.success, !sr.output.hasPrefix("未找到") {
                                                    let suggestion = String(sr.output.prefix(500))
                                                    toolResult = ToolResult(
                                                        output: "\(toolResult.output)\n\n编排层自动搜索近似文件：\n\(suggestion)\n请从以上结果中选择正确的文件路径。",
                                                        data: toolResult.data,
                                                        success: false,
                                                        error: toolResult.error
                                                    )
                                                }
                                            }
                                        } else if toolName == "file.write" && toolResult.error == "security_denied" {
                                            // E3: Auto-heal security_denied by adding path to allowed list and retrying
                                            if let path = callStep.toolParams?["path"] {
                                                let dir = (path as NSString).deletingLastPathComponent
                                                if !dir.isEmpty && dir != "/" && !WorkspaceSandbox.isOverlyBroadWorkspace(dir) {
                                                    WorkspaceSandbox.shared.addAllowedPath(dir)
                                                    // Retry the write
                                                    let retryResult = try? await tool.execute(argumentsJSON: argumentsJSON, context: taskContext)
                                                    if let rr = retryResult, rr.success {
                                                        toolResult = ToolResult(
                                                            output: "编排层自动授权路径后重试成功：\(rr.output)",
                                                            data: rr.data,
                                                            success: true
                                                        )
                                                    }
                                                }
                                            }
                                        } else if toolName == "file.edit" && !toolResult.success && toolResult.error != "file_not_found" && toolResult.error != "security_denied" {
                                            // E3+: file.edit failed (all_edits_failed, invalid_edits, etc.)
                                            // Auto-fallback: read current content + apply newText edits via file.write
                                            if toolResult.error == "all_edits_failed",
                                               let editPath = callStep.toolParams?["path"],
                                               let editsJSON = callStep.toolParams?["edits"],
                                               let readTool = self.toolRegistry.tool(named: "file_read"),
                                               let writeTool = self.toolRegistry.tool(named: "file_write") {
                                                // Read current file content
                                                let readDict: [String: Any] = ["path": editPath]
                                                let readJSON = (try? JSONSerialization.data(withJSONObject: readDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                if let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: taskContext),
                                                   readResult.success {
                                                    // Extract newText from the first edit to use as the intended content
                                                    // Parse edits to get all newText segments
                                                    var fallbackContent = readResult.output
                                                    if let editsData = editsJSON.data(using: .utf8),
                                                       let editsArr = try? JSONSerialization.jsonObject(with: editsData) as? [[String: Any]] {
                                                        for editItem in editsArr {
                                                            if let oldText = editItem["oldText"] as? String,
                                                               let newText = editItem["newText"] as? String,
                                                               !oldText.isEmpty {
                                                                // Try fuzzy line-by-line matching for whitespace differences
                                                                let oldNorm = oldText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                                                                let contentNorm = fallbackContent.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                                                                if contentNorm.contains(oldNorm) {
                                                                    // Find the actual range using normalized comparison
                                                                    let lines = fallbackContent.components(separatedBy: "\n")
                                                                    let oldLines = oldText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                                                                    for startIdx in 0...(max(0, lines.count - oldLines.count)) {
                                                                        let window = lines[startIdx..<min(startIdx + oldLines.count, lines.count)]
                                                                        let windowNorm = window.map { $0.trimmingCharacters(in: .whitespaces) }
                                                                        if Array(windowNorm) == oldLines {
                                                                            var newLines = Array(lines[0..<startIdx])
                                                                            newLines.append(contentsOf: newText.components(separatedBy: "\n"))
                                                                            newLines.append(contentsOf: lines[(startIdx + oldLines.count)...])
                                                                            fallbackContent = newLines.joined(separator: "\n")
                                                                            break
                                                                        }
                                                                    }
                                                                } else if oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                                    // Append mode
                                                                    let sep = fallbackContent.hasSuffix("\n") ? "" : "\n"
                                                                    fallbackContent += sep + newText
                                                                }
                                                            }
                                                        }
                                                    }
                                                    // Write back via file.write
                                                    if fallbackContent != readResult.output {
                                                        let writeDict: [String: Any] = ["path": editPath, "content": fallbackContent]
                                                        let writeJSON = (try? JSONSerialization.data(withJSONObject: writeDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                        if let wr = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext), wr.success {
                                                            toolResult = ToolResult(
                                                                output: "file.edit 匹配失败，编排层自动降级：读取文件 → 模糊匹配替换 → file.write 写回成功\n\(wr.output)",
                                                                data: wr.data,
                                                                success: true,
                                                                error: nil
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                            // If auto-fallback didn't work, add hint
                                            if !toolResult.success {
                                                let editFailCount = task.steps.filter { $0.toolName == "file.edit" && $0.isFailure }.count
                                                let hint = "\n\n⚠️ file.edit 失败 \(editFailCount + 1) 次，oldText 匹配不上文件内容。" +
                                                    "\n请改用 file.write 全量写入（先 file.read 读取完整内容，修改后 file.write 写回）。"
                                                toolResult = ToolResult(
                                                    output: toolResult.output + hint,
                                                    data: toolResult.data,
                                                    success: false,
                                                    error: toolResult.error
                                                )
                                            }
                                        } else if toolName == "file.edit" && (toolResult.error == "file_not_found" || toolResult.output.contains("不存在")) {
                                            // E3: file.edit on nonexistent → auto-downgrade to file.write
                                            if let path = callStep.toolParams?["path"],
                                               let content = callStep.toolParams?["content"] ?? callStep.toolParams?["new_content"],
                                               let writeTool = self.toolRegistry.tool(named: "file_write") {
                                                let writeDict: [String: Any] = ["path": path, "content": content]
                                                let writeJSON = (try? JSONSerialization.data(withJSONObject: writeDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                                let writeResult = try? await writeTool.execute(argumentsJSON: writeJSON, context: taskContext)
                                                if let wr = writeResult, wr.success {
                                                    toolResult = ToolResult(
                                                        output: "文件不存在，编排层自动改用 file.write 创建：\(wr.output)",
                                                        data: wr.data,
                                                        success: true
                                                    )
                                                }
                                            }
                                        } else if toolName == "verify.build" && !toolResult.success {
                                            // E3: Extract actionable error info from build failures
                                            let output = toolResult.output
                                            // Extract "file:line: error:" patterns
                                            let errorLines = output.components(separatedBy: .newlines).filter { line in
                                                let l = line.lowercased()
                                                return l.contains("error:") || l.contains("错误") || l.contains("fatal")
                                            }.prefix(5)
                                            if !errorLines.isEmpty {
                                                let errorSummary = errorLines.joined(separator: "\n")
                                                toolResult = ToolResult(
                                                    output: toolResult.output + "\n\n编排层提取关键错误：\n\(errorSummary)\n\n请直接 file_edit 修复以上错误行，然后再次 verify_build。",
                                                    data: toolResult.data,
                                                    success: false,
                                                    error: toolResult.error
                                                )
                                            }
                                        } else if toolName == "code.search",
                                                  let query = callStep.toolParams?["query"],
                                                  (toolResult.output.hasPrefix("未找到") || toolResult.output.contains("0 个匹配")),
                                                  query.count > 4 {
                                            // Auto-simplify: try with just the last meaningful word
                                            let words = query.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "._")).inverted).filter { $0.count > 2 }
                                            if let simpler = words.last, simpler != query,
                                               let searchTool = self.toolRegistry.tool(named: "code_search") {
                                                let retryJSON = "{\"query\":\"\(simpler)\"}"
                                                let retryResult = try? await searchTool.execute(argumentsJSON: retryJSON, context: taskContext)
                                                if let rr = retryResult, rr.success, !rr.output.hasPrefix("未找到") {
                                                    toolResult = ToolResult(
                                                        output: "原查询「\(query)」无结果，编排层自动简化为「\(simpler)」重搜：\n\(rr.output)",
                                                        data: rr.data,
                                                        success: true
                                                    )
                                                    taskContext.memory.searchedQueries.append(simpler)
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    toolResult = ToolResult(
                                        output: "未知工具：\(toolName)",
                                        success: false,
                                        error: "unknown_tool"
                                    )
                                }

                                // Safety net: should never be nil here, but avoid crash
                                if toolResult == nil {
                                    toolResult = ToolResult(
                                        output: "内部错误：工具 \(toolName) 执行后未产生结果",
                                        success: false,
                                        error: "internal_nil_result"
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
                        // Auto-apply writes in agent mode so verify.build sees changes.
                        // Still emit reviewRequest for user rollback capability.
                        if let batchCountString = data["batchCount"], let batchCount = Int(batchCountString) {
                            for batchIndex in 0..<batchCount {
                                let prefix = "batch\(batchIndex)"
                                guard let filePath = data["\(prefix).path"],
                                      let oldContent = data["\(prefix).diffOld"],
                                      let newContent = data["\(prefix).diffNew"],
                                      !newContent.isEmpty else { continue }
                                // Auto-apply: write file immediately
                                let batchFullPath = data["\(prefix).fullPath"] ?? (filePath.hasPrefix("/") ? filePath : (taskContext.workspaceRoot as NSString).appendingPathComponent(filePath))
                                let batchCreateDirs = data["\(prefix).createDirectories"] != "false"
                                do {
                                    try WriteFileTool().performWrite(fullPath: batchFullPath, content: newContent, createDirectories: batchCreateDirs)
                                } catch {
                                    // Write failed — will be surfaced in review step
                                }
                                var reviewParams = toolParams
                                for (key, value) in data where key.hasPrefix(prefix + ".") {
                                    reviewParams[String(key.dropFirst(prefix.count + 1))] = value
                                }
                                reviewParams["batchIndex"] = "\(batchIndex + 1)"
                                reviewParams["batchCount"] = "\(batchCount)"
                                let hunks = Self.extractHunks(from: reviewParams)
                                let reviewStep = TaskStep(
                                    kind: .reviewRequest,
                                    text: "已写入文件（可回滚）（\(batchIndex + 1)/\(batchCount)）：\(filePath)",
                                    toolName: toolName,
                                    toolParams: reviewParams,
                                    toolCallId: callId,
                                    isCollapsible: false,
                                    isCollapsed: false,
                                    diffFilePath: filePath,
                                    diffOldContent: oldContent,
                                    diffNewContent: newContent,
                                    approved: true,
                                    diffHunks: hunks.isEmpty ? nil : hunks
                                )
                                task.steps.append(reviewStep)
                                onStep(reviewStep)
                            }
                        } else if let filePath = data["path"] ?? toolParams["path"],
                                  let oldContent = data["diffOld"],
                                  let newContent = data["diffNew"],
                                  !newContent.isEmpty {
                            // Auto-apply: write file immediately
                            let writeFullPath = data["fullPath"] ?? (filePath.hasPrefix("/") ? filePath : (taskContext.workspaceRoot as NSString).appendingPathComponent(filePath))
                            let createDirs = data["createDirectories"] != "false"
                            var writeSucceeded = false
                            do {
                                try WriteFileTool().performWrite(fullPath: writeFullPath, content: newContent, createDirectories: createDirs)
                                // P1: Post-write verification — confirm file actually has content
                                if let written = try? String(contentsOfFile: writeFullPath, encoding: .utf8),
                                   !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    writeSucceeded = true
                                }
                            } catch {
                                // Write failed — will be surfaced in review step
                            }
                            if !writeSucceeded {
                                // Surface write failure so model doesn't hallucinate success
                                let failStep = TaskStep(
                                    kind: .toolResult,
                                    text: "⚠️ 文件写入验证失败：\(filePath) 写入后为空。请检查工具参数并重试（确保 content 参数包含完整内容）。",
                                    toolName: toolName,
                                    toolCallId: callId,
                                    isFailure: true
                                )
                                task.steps.append(failStep)
                                onStep(failStep)
                            }
                            var reviewParams = toolParams
                            for (key, value) in data {
                                reviewParams[key] = value
                            }
                            let hunks = Self.extractHunks(from: reviewParams)
                            let reviewStep = TaskStep(
                                kind: .reviewRequest,
                                text: writeSucceeded ? "已写入文件（可回滚）：\(filePath)" : "写入失败（文件为空）：\(filePath)",
                                toolName: toolName,
                                toolParams: reviewParams,
                                toolCallId: callId,
                                isCollapsible: false,
                                isCollapsed: false,
                                diffFilePath: filePath,
                                diffOldContent: oldContent,
                                diffNewContent: newContent,
                                approved: true,
                                diffHunks: hunks.isEmpty ? nil : hunks
                            )
                            task.steps.append(reviewStep)
                            onStep(reviewStep)
                        }
                    }
                    if toolResult.data?["streamed"] != "true" {
                        let shouldShowFullOutput = ["shell.exec", "verify.build"].contains(toolName)
                        // Cap step text for UI: full output goes to model via modelContent,
                        // but storing >4K in step.text causes SwiftUI layout thrashing
                        let stepTextLimit = 4000
                        let rawStepText = shouldShowFullOutput ? toolResult.output : displayText
                        let stepText = rawStepText.count > stepTextLimit
                            ? String(rawStepText.prefix(stepTextLimit)) + "\n\n… 共 \(rawStepText.count) 字，完整内容已发送给模型"
                            : rawStepText
                        let resultStep = TaskStep(
                            kind: .toolResult,
                            text: stepText,
                            toolName: toolName,
                            toolParams: toolParams,
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
                            let alternatives = Self.suggestAlternatives(for: toolName, target: target)
                            let circuitMsg = "⚠️ \(toolName) 对 \(target) 已失败 \(toolFailureCounts[failKey]!) 次，禁止再用相同参数重试。\n替代方案：\(alternatives)"
                            messages.append(ChatMessage(role: "system", content: circuitMsg))
                        }
                    } else {
                        // Reset failure count on success
                        let target = callStep.toolParams?["path"] ?? callStep.toolParams?["command"] ?? "unknown"
                        toolFailureCounts["\(toolName):\(target)"] = 0
                    }

                    // Update task memory
                    if toolResult.success {
                        switch toolName {
                        case "file.read", "file.extract":
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
                                // F4: Directory pre-cache — cache sibling file listing
                                let dir = (path as NSString).deletingLastPathComponent
                                let dirCacheKey = "__dir__:\(dir)"
                                if !dir.isEmpty && taskContext.memory.fileSummaries[dirCacheKey] == nil {
                                    let ext = (path as NSString).pathExtension.lowercased()
                                    if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                                        let relevantSiblings = siblings.filter { file in
                                            let fExt = (file as NSString).pathExtension.lowercased()
                                            return fExt == ext || ["swift","py","js","ts","tsx","jsx","rs","go","java","c","cpp","h","m","mm","md","json","yaml","yml","toml"].contains(fExt)
                                        }.sorted().prefix(30)
                                        if !relevantSiblings.isEmpty {
                                            taskContext.memory.fileSummaries[dirCacheKey] = relevantSiblings.joined(separator: ", ")
                                        }
                                    }
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
                            taskContext.memory.userDecisions.append("已写入：\(path)")
                            // Invalidate read cache — file content changed
                            taskContext.memory.fileContentCache.removeValue(forKey: path)
                            let fullPath = (taskContext.workspaceRoot as NSString).appendingPathComponent(path)
                            taskContext.memory.fileContentCache.removeValue(forKey: fullPath)
                        }
                    }

                    // F1: Auto-verify engine — after successful code writes, automatically
                    // run verify.build and inline the result. Saves 1-2 full LLM iterations.
                    var autoVerifyContent = ""
                    if ["file.write", "file.edit"].contains(callStep.toolName ?? "") && toolResult.success {
                        let writtenPath = callStep.toolParams?["path"] ?? ""
                        let ext = (writtenPath as NSString).pathExtension.lowercased()
                        let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
                        let hasBuildSys = ValidationEngine.suggestVerificationCommand(workspaceRoot: taskContext.workspaceRoot) != nil
                        if codeExts.contains(ext) && hasBuildSys && isToolAllowed("verify.build") {
                            if let verifyTool = self.toolRegistry.tool(named: "verify_build") ?? self.toolRegistry.tool(named: "verify.build") {
                                let verifyStep = TaskStep(kind: .toolCall, text: "编排层自动验证编译", toolName: "verify.build", isCollapsible: true, isCollapsed: true)
                                task.steps.append(verifyStep)
                                onStep(verifyStep)
                                let vr = try? await verifyTool.execute(argumentsJSON: "{}", context: taskContext)
                                if let vr {
                                    let vrStep = TaskStep(kind: .toolResult, text: vr.success ? "✅ 编译通过" : "❌ 编译失败", toolName: "verify.build", isCollapsible: true, isCollapsed: vr.success)
                                    task.steps.append(vrStep)
                                    onStep(vrStep)
                                    if vr.success {
                                        autoVerifyContent = "\n\n✅ 编排层自动验证：编译通过。"
                                    } else {
                                        // Extract key error lines for the model
                                        let errLines = vr.output.components(separatedBy: .newlines)
                                            .filter { $0.lowercased().contains("error:") || $0.lowercased().contains("fatal") }
                                            .prefix(8).joined(separator: "\n")
                                        autoVerifyContent = "\n\n❌ 编排层自动验证：编译失败。关键错误：\n\(errLines)\n\n请立即 file_edit 修复后再次等待编排层自动验证。"
                                    }
                                }
                            }
                        }
                    }

                    // C1: Proactive chained tool calls — orchestration layer auto-reads
                    // the most relevant search result, saving a full LLM roundtrip.
                    var chainedContent = ""
                    if callStep.toolName == "code.search" && toolResult.success && !toolResult.output.hasPrefix("未找到") {
                        if let bestPath = Self.firstReadablePath(inSearchOutput: toolResult.output, workspaceRoot: taskContext.workspaceRoot),
                           !taskContext.memory.readFiles.contains(bestPath),
                           let readTool = self.toolRegistry.tool(named: "file_read") {
                            let readJSON = Self.bootstrapReadArgumentsJSON(for: bestPath)
                            let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: taskContext)
                            if let rr = readResult, rr.success {
                                taskContext.memory.readFiles.append(bestPath)
                                if rr.output.count < 100_000 {
                                    taskContext.memory.fileContentCache[bestPath] = rr.output
                                }
                                let chainStep = TaskStep(
                                    kind: .toolResult,
                                    text: "编排层自动读取：\(bestPath)",
                                    toolName: "file.read",
                                    isCollapsible: true,
                                    isCollapsed: true
                                )
                                task.steps.append(chainStep)
                                onStep(chainStep)
                                let readContent = ToolResultFormatter.modelContent(
                                    toolName: "file.read",
                                    result: rr,
                                    limit: max(2000, config.maxTokensPerTurn / 2)
                                )
                                chainedContent = "\n\n编排层已自动读取最相关文件 \(bestPath)：\n\(readContent)"
                            }
                        }
                    }

                    // F5: Smart context window — dynamic token allocation per tool result
                    let toolResultLimit: Int = {
                        let tn = callStep.toolName ?? ""
                        // Failures get full budget — model needs all error details
                        if !toolResult.success { return config.maxTokensPerTurn }
                        // Reads are primary content — generous budget
                        if tn == "file.read" { return config.maxTokensPerTurn }
                        // Successful verify = minimal (just "passed")
                        if tn == "verify.build" { return 200 }
                        // Index/search = medium
                        if tn == "workspace.index" || tn == "code.search" { return min(3000, config.maxTokensPerTurn) }
                        // Shell output varies — cap at half
                        if tn == "shell.exec" { return config.maxTokensPerTurn / 2 }
                        // Default
                        return config.maxTokensPerTurn
                    }()
                    let resultContent = ToolResultFormatter.modelContent(
                        toolName: callStep.toolName ?? "tool",
                        result: toolResult,
                        limit: toolResultLimit
                    ) + chainedContent + autoVerifyContent
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

                // Orchestration layer: smart post-tool-call analysis
                // Inject corrective guidance based on what the orchestration layer observes.
                var orchestrationNotes: [String] = []

                for (idx, toolResult, _) in toolCallResults {
                    let step = callSteps[idx].1
                    let tn = step.toolName ?? ""
                    // 1. verify.build failed with "command not found" → don't retry, it's an env issue
                    if tn == "verify.build" && !toolResult.success {
                        let output = toolResult.output.lowercased()
                        if output.contains("command not found") || output.contains("no such file") {
                            let badCmd = toolResult.data?["command"] ?? "unknown"
                            orchestrationNotes.append("verify.build 失败原因是命令 `\(badCmd)` 不存在，不是代码问题。不要重试相同命令。如果是 npm/cargo/go 等构建工具不存在，跳过验证直接继续。")
                        } else if output.contains("不是 git 仓库") || output.contains("not a git repository") {
                            orchestrationNotes.append("当前工作区不是 git 仓库，git 相关操作会失败。跳过 git 操作。")
                        }
                    }
                    // 2. code.search returned 0 results → suggest alternatives proactively
                    if tn == "code.search" && toolResult.success && toolResult.output.contains("未找到") {
                        orchestrationNotes.append("code.search 未找到结果。改用 shell_exec 的 find 或 grep 命令搜索，或检查关键词是否正确。")
                    }
                    // 3. file.read on a directory → tell model it's not a file
                    if tn == "file.read" && !toolResult.success && toolResult.output.contains("是目录") {
                        if let path = step.toolParams?["path"] {
                            orchestrationNotes.append("\(path) 是目录不是文件。用 shell_exec ls 或 workspace_index 查看目录内容。")
                        }
                    }
                }

                // D2: Loop detector — catch repetitive tool call patterns across iterations
                // Fix: look at toolCall steps specifically (not suffix of all step types)
                let allToolCalls = task.steps.filter { $0.kind == .toolCall }
                let recentToolCalls = allToolCalls.suffix(30)
                let recentSignatures = recentToolCalls.compactMap { step -> String? in
                    guard let name = step.toolName else { return nil }
                    let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? step.toolParams?["command"] ?? ""
                    return "\(name):\(target.prefix(60))"
                }

                // Count how many times the same signature appears in recent history
                let signatureCounts = Dictionary(grouping: recentSignatures, by: { $0 }).mapValues(\.count)
                for (loopSig, count) in signatureCounts where count >= 3 {
                    let parts = loopSig.split(separator: ":", maxSplits: 1)
                    let loopTool = parts.first.map(String.init) ?? "unknown"
                    let loopTarget = parts.count > 1 ? String(parts[1]) : ""
                    orchestrationNotes.append("⚠️ 循环检测：`\(loopTool)` 对 `\(loopTarget)` 已重复 \(count) 次。必须立即换一种完全不同的方法。不要再对同一目标重复相同操作。")
                }

                // D2+: Hard circuit breaker — count FAILED tool calls per tool+target
                let allToolResults = task.steps.filter { $0.kind == .toolResult }
                let failedSignatures = allToolResults.compactMap { step -> String? in
                    guard step.isFailure, let name = step.toolName else { return nil }
                    let target = step.toolParams?["path"] ?? step.toolParams?["query"] ?? ""
                    return "\(name):\(target.prefix(60))"
                }
                let failedCounts = Dictionary(grouping: failedSignatures, by: { $0 }).mapValues(\.count)
                for (failSig, count) in failedCounts where count >= 3 {
                    if !circuitBrokenTools.contains(failSig) {
                        circuitBrokenTools.insert(failSig)
                        let parts = failSig.split(separator: ":", maxSplits: 1)
                        let brokenTool = parts.first.map(String.init) ?? "unknown"
                        let brokenTarget = parts.count > 1 ? String(parts[1]) : ""

                        // Record to FailurePatternDB for cross-session learning
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
                            intent: String(describing: intent),
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
                    messages.append(ChatMessage(role: "system", content: "编排层提示：\n" + orchestrationNotes.joined(separator: "\n")))
                }

                // Auto-fix loop: if we wrote CODE files but didn't verify, nudge to verify
                // Skip verify nudge for non-code files (markdown, config, etc.)
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
                let hasBuildSystem = ValidationEngine.suggestVerificationCommand(workspaceRoot: taskContext.workspaceRoot) != nil
                if batchHadCodeWrite && !batchHadVerify && isToolAllowed("verify.build") && hasBuildSystem {
                    let verifyNudge = "代码文件已修改。下一步必须调用 verify_build 验证编译是否通过。如果失败，立即 file_edit 修复后再次 verify_build。"
                    messages.append(ChatMessage(role: "user", content: verifyNudge))
                }

                // D3: Early task completion detection
                // If we wrote files AND verify passed in this batch, task is effectively done.
                let batchVerifyPassed = toolCallResults.contains { entry in
                    callSteps[entry.0].1.toolName == "verify.build" && entry.1.success
                }
                let batchHadWrite = toolCallResults.contains { entry in
                    writeTools.contains(callSteps[entry.0].1.toolName ?? "") && entry.1.success
                }
                // Also check: non-code files written successfully (no verify needed)
                let batchHadNonCodeWrite = toolCallResults.contains { entry in
                    let step = callSteps[entry.0].1
                    guard entry.1.success, writeTools.contains(step.toolName ?? "") else { return false }
                    let path = step.toolParams?["path"] ?? ""
                    let ext = (path as NSString).pathExtension.lowercased()
                    return !codeExtensions.contains(ext) && !ext.isEmpty
                }
                if (batchHadWrite && batchVerifyPassed) || (batchHadNonCodeWrite && !hasBuildSystem) {
                    messages.append(ChatMessage(role: "system", content: "任务已完成：文件已成功写入\(batchVerifyPassed ? "且编译验证通过" : "")。请输出简短的完成总结，不要调用更多工具。"))
                }
            } else {
                // LLM returned text only — check if it gave up too early
                var rawText = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)

                // Bug fix: thinking models may return empty assistantText but substantial reasoningContent
                // For chat/research, the reasoning IS the answer — promote it instead of discarding
                if rawText.isEmpty,
                   let reasoning = response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                   reasoning.count > 50 {
                    rawText = reasoning
                }

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
                    // D5: On 2nd empty response, strip tools — thinking models sometimes choke on schemas
                    if consecutiveEmptyResponses == 2 {
                        toolDefs = []
                        let stripStep = TaskStep(
                            kind: .aiThinking,
                            text: "编排层：连续空响应，临时移除工具定义重试（部分模型对工具 schema 敏感）。",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        task.steps.append(stripStep)
                        onStep(stripStep)
                    }
                    // Auto-retry empty response once before giving up
                    if consecutiveEmptyResponses == 1 && iteration < effectiveMaxIterations - 1 {
                        let retryStep = TaskStep(
                            kind: .aiThinking,
                            text: "模型返回空内容，自动重试中…",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        task.steps.append(retryStep)
                        onStep(retryStep)
                        continue  // retry same messages, URLSession will get a fresh response
                    }
                    if isReadOnlyRun || intent == .chat {
                        let errorStep = TaskStep(
                            kind: .textOutput,
                            text: (response.reasoningContent ?? "").isEmpty
                                ? "模型返回了空内容，可能是接口不稳定。请重新发送消息试试。"
                                : "模型只返回了思考内容，没有给出最终答案。请重试或换用非思考模型。"
                        )
                        task.steps.append(errorStep)
                        onStep(errorStep)
                        break
                    }
                    messages.append(ChatMessage(role: "assistant", content: text))
                    let nudgeText = Self.buildEmptyResponseNudge(task: task, intent: intent)
                    messages.append(ChatMessage(role: "user", content: nudgeText))
                    continue
                }
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
                if researchNeedsFetch && nudgeCount < maxNudges {
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
                let hasWritten = Self.hasSuccessfulWrite(in: task)

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
                    break
                }
                let isEarlyTurn = iteration < 3 && !toolDefs.isEmpty
                let onlyDidReads = toolCallCount > 0 && !hasWritten
                    && !task.steps.contains(where: { $0.kind == .toolCall && ["shell.exec", "wiki.build", "web.fetch", "file.extract"].contains($0.toolName ?? "") })
                let isPlanOnly = isEarlyTurn && intent != .chat && !isReadOnlyRun
                    && (toolCallCount == 0 || onlyDidReads)
                    && Self.looksLikePlanOnly(text)
                    && !hasFakeToolCalls
                    && !Self.looksLikeProviderError(text)
                if isPlanOnly {
                    messages.append(ChatMessage(role: "assistant", content: text))
                    let nudgeMsg = toolCallCount == 0
                        ? "你刚才只输出了计划/分析，没有调用任何工具。禁止只说不做。立即调用工具执行第一步。"
                        : "你已经读取了资料但停了下来。不要只说计划，立即继续执行下一步：整理到 Wiki 就调用 wiki_build(save=true)，表格/文档先用 file_extract，其他交付用 file_write / shell_exec。"
                    messages.append(ChatMessage(role: "system", content: nudgeMsg))
                    let planStep = TaskStep(
                        kind: .aiThinking,
                        text: "编排层拦截：模型只输出计划未行动，强制要求继续执行。",
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(planStep)
                    onStep(planStep)
                    continue
                }

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
                if Self.needsWikiSaveNudge(message: message, task: task, isReadOnlyRun: isReadOnlyRun, hasWritten: hasWritten),
                   iteration < effectiveMaxIterations - 1 && nudgeCount < maxNudges {
                    nudgeCount += 1
                    let gateStep = TaskStep(
                        kind: .aiThinking,
                        text: "完成质量门：Wiki 任务尚未保存任何笔记，继续执行 wiki_build。",
                        isCollapsible: true,
                        isCollapsed: true
                    )
                    task.steps.append(gateStep)
                    onStep(gateStep)
                    messages.append(ChatMessage(role: "assistant", content: text))
                    messages.append(ChatMessage(role: "system", content: "用户要求整理到 Wiki/知识库，但当前没有任何 wiki_build(save=true) 或文件写入成功记录。不要输出计划或道歉，立即基于已读材料调用 wiki_build 保存原子笔记；材料不足就先用 file_read/file_extract 继续读取。"))
                    didComplete = false
                    continue
                }
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

                if didComplete && intent == .task && !isReadOnlyRun && iteration < effectiveMaxIterations - 1 {
                    let expectsWiki = Self.expectsWikiOutput(message)
                    let qualityIssues = Self.completionQualityIssues(
                        task: task,
                        message: message,
                        workspaceRoot: taskContext.workspaceRoot,
                        hasWritten: hasWritten,
                        expectsWiki: expectsWiki
                    )

                    if !qualityIssues.isEmpty && nudgeCount < maxNudges {
                        nudgeCount += 1
                        didComplete = false
                        messages.append(ChatMessage(role: "assistant", content: text))
                        let wikiInstruction = expectsWiki
                            ? "\n\nWiki 任务必须调用 wiki_build(mode=\"atomic\", save=true) 保存原子笔记，并在需要时调用 wiki_build(mode=\"moc\", save=true) 保存索引页。"
                            : ""
                        messages.append(ChatMessage(role: "system", content: "⚠️ 完成质量检查未通过：\n" + qualityIssues.map { "- \($0)" }.joined(separator: "\n") + "\(wikiInstruction)\n\n请立即修复以上问题后再输出最终总结。"))
                        let gateStep = TaskStep(
                            kind: .aiThinking,
                            text: "完成质量门：\(qualityIssues.joined(separator: "；"))",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        task.steps.append(gateStep)
                        onStep(gateStep)
                        continue
                    }
                }

                break
            }
        }

        if !didComplete && !hadFailure && !wasTruncated && !Task.isCancelled && autoRound < maxAutoRounds && intent != .chat {
            autoRound += 1
            iteration = 0
            let progressSummary = Self.compactProgressSummary(task: task)
            messages.append(ChatMessage(role: "system", content: "已完成第 \(autoRound) 段处理。以下是目前进展，请继续完成剩余工作，不要重复已成功的操作：\n\(progressSummary)"))
            consecutiveEmptyResponses = 0
            transientRetryCount = 0
            didInjectWorkingSet = false
            let roundStep = TaskStep(kind: .aiThinking, text: "继续处理中…", isCollapsible: true, isCollapsed: true)
            task.steps.append(roundStep)
            onStep(roundStep)
        }
        } while !didComplete && !hadFailure && !wasTruncated && autoRound > 0 && autoRound <= maxAutoRounds && intent != .chat

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
            // All auto-rounds exhausted; offer manual continuation as last resort
            let continueStep = TaskStep(
                kind: .error,
                text: "任务尚未完成，可以点击「继续」接着处理。",
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

        // G5: Record successful tool sequences for pattern reuse
        if finalStatus == .completed && iteration <= 5 && !taskContext.workspaceRoot.isEmpty, let repo = Self.sharedRepository {
            let toolSequence = task.steps
                .filter { $0.kind == .toolCall }
                .compactMap { $0.toolName }
            if toolSequence.count >= 2 && toolSequence.count <= 10 {
                // Classify the task type for matching
                let taskType: String
                let lm = message.lowercased()
                if lm.contains("修改") || lm.contains("fix") || lm.contains("修复") { taskType = "modify" }
                else if lm.contains("创建") || lm.contains("新建") || lm.contains("create") { taskType = "create" }
                else if lm.contains("搜索") || lm.contains("查找") || lm.contains("search") { taskType = "search" }
                else if lm.contains("解释") || lm.contains("分析") || lm.contains("explain") { taskType = "explain" }
                else { taskType = "general" }
                let sequenceStr = toolSequence.joined(separator: " → ")
                repo.saveMemory(
                    workspace: taskContext.workspaceRoot,
                    category: "tool_pattern",
                    key: "success_\(taskType)_\(iteration)iter",
                    value: sequenceStr
                )
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

        // Clear task-specific path allowances
        WorkspaceSandbox.shared.clearAllowedPaths()

        return task
    }
}
