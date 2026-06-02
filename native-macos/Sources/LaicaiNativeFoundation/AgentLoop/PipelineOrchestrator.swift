import Foundation
import LaicaiNativeDomain

// MARK: - Pipeline Orchestrator
// Thin orchestrator that coordinates the four pipeline stages:
//   1. Plan   — ContextBuilder + BootstrapEngine
//   2. Execute — Main iteration loop (LLM call + tool execution)
//   3. Verify  — Post-tool analysis (IterationEngine.analyzeToolResults)
//   4. Output  — TaskFinalizer
//
// This replaces the 2500+ line monolithic run() method with a structured pipeline.
// The old run() delegates here; both paths produce identical AgentTask results.

@MainActor
extension AgentLoop {

    func runPipeline(
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
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in },
        onReasoningDelta: @Sendable @MainActor (String) -> Void = { _ in },
        onCheckInterrupt: @MainActor () -> String? = { nil }
    ) async throws -> AgentTask {

        // ════════════════════════════════════════
        // STAGE 0 — Setup
        // ════════════════════════════════════════
        var taskContext = prepareTaskContext(context, intent: intent, message: message)
        seedContinuationMaterial(from: priorSteps, into: &taskContext)
        var task = AgentTask(
            id: taskID ?? UUID(),
            title: String(message.prefix(50)),
            status: .running,
            connectorID: connector.id,
            context: taskContext
        )
        hydrateRuntimeContract(from: taskContext, into: &task)

        // Emit user input step
        if !priorSteps.contains(where: { $0.kind == .userInput && $0.text == message }) {
            let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
            task.steps.append(userStep)
            onStep(userStep)
        }

        // Inline planning hint
        if config.emitDebugSteps, intent != .chat, !priorSteps.contains(where: { $0.kind == .aiThinking }) {
            let startStep = TaskStep(
                kind: .aiThinking,
                text: "正在理解会话目标并准备执行。",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(startStep)
            onStep(startStep)
        }

        authorizeUserPathsAndNarrowWorkspace(message: message, intent: intent, taskContext: &taskContext)
        let needsPlanning = intent != .chat
            && priorSteps.isEmpty
            && !Self.isPureContinuationCommand(message)
            && message.count > 10
        await runPreparationTools(message: message, intent: intent, needsPlanning: needsPlanning, taskContext: &taskContext, task: &task, onStep: onStep)

        // Initialize PipelineState
        var state = PipelineState(
            task: task,
            taskContext: taskContext,
            connector: connector,
            allConnectors: allConnectors,
            intent: intent,
            message: message,
            imageAttachments: imageAttachments,
            priorSteps: priorSteps,
            summaryCache: summaryCache,
            config: config
        )

        // ════════════════════════════════════════
        // STAGE 1 — Plan (Context + Prompts + Tools)
        // ════════════════════════════════════════
        let contextResult = ContextBuilder.build(
            state: &state,
            config: config,
            toolRegistry: toolRegistry
        )
        state.systemPrompt = contextResult.systemPrompt
        state.toolDefs = contextResult.toolDefs
        state.currentPhase = contextResult.initialPhase
        state.injectedPatternHashes = contextResult.injectedPatternHashes

        // Emit skill/pattern steps that ContextBuilder appended to state.task
        for step in state.task.steps where !task.steps.contains(where: { $0.id == step.id }) {
            onStep(step)
        }
        task = state.task

        // Build initial messages
        state.messages = Self.initialMessages(
            systemPrompt: state.systemPrompt,
            message: message,
            priorSteps: priorSteps,
            summaryCache: summaryCache,
            context: state.taskContext,
            imageAttachments: imageAttachments
        )

        // Handle tool-disabled mode
        if intent != .chat, !config.supportsToolCalling {
            let disabledStep = TaskStep(
                kind: .aiThinking,
                text: "当前连接器已关闭工具调用，本轮将只基于已有上下文继续；如果需要读取文件、搜索项目、联网、运行命令或写入内容，请切换支持工具调用的连接器后重试。",
                isCollapsible: true,
                isCollapsed: false
            )
            state.task.steps.append(disabledStep)
            onStep(disabledStep)
            Self.applyToolCompatibilityFallbackInstruction(to: &state.messages)
        }

        // ════════════════════════════════════════
        // STAGE 1b — Bootstrap (pre-loop tool calls)
        // ════════════════════════════════════════
        let bootstrapHandled = try await BootstrapEngine.execute(
            state: &state,
            config: config,
            toolRegistry: toolRegistry,
            runtime: runtime,
            onStep: onStep
        )
        if bootstrapHandled {
            // Truncated continuation was handled — return early
            return state.task
        }

        // ════════════════════════════════════════
        // STAGE 2+3 — Execute + Verify Loop
        // ════════════════════════════════════════
        repeat {
            while state.iteration < state.effectiveMaxIterations {
                guard !Task.isCancelled else {
                    state.task.status = .failed
                    return state.task
                }
                // Hard step count limit
                if state.task.steps.count >= state.absoluteMaxSteps {
                    let limitStep = TaskStep(
                        kind: .aiThinking,
                        text: "已达到步骤数上限（\(state.absoluteMaxSteps)步），强制结束。如需继续请新建会话。",
                        isCollapsible: false
                    )
                    state.task.steps.append(limitStep)
                    onStep(limitStep)
                    state.hadFailure = true
                    break
                }
                state.iteration += 1
                let iterationStartTime = Date()

                // Codex-style steer: check for injected user correction
                if let steerMsg = pendingSteer {
                    pendingSteer = nil
                    let steerStep = TaskStep(
                        kind: .userInput,
                        text: "🔀 \(steerMsg)",
                        isCollapsible: false,
                        isCollapsed: false
                    )
                    state.task.steps.append(steerStep)
                    onStep(steerStep)
                    state.messages.append(ChatMessage(role: "user", content: "[方向修正] 用户在执行中插入了新指令，请立即调整方向：\n\(steerMsg)"))
                }

                // Check for user interrupt (pending follow-up injection)
                if let interrupt = onCheckInterrupt() {
                    let interruptStep = TaskStep(
                        kind: .userInput,
                        text: interrupt,
                        isCollapsible: false,
                        isCollapsed: false
                    )
                    state.task.steps.append(interruptStep)
                    onStep(interruptStep)
                    state.messages.append(ChatMessage(role: "user", content: interrupt))
                }

                // Prepare iteration: phase refresh, compression, progress
                IterationEngine.prepareIteration(
                    state: &state,
                    config: config,
                    toolRegistry: toolRegistry,
                    allConnectors: allConnectors
                )
                // Emit any new steps from iteration prep
                emitNewSteps(from: &state, into: &task, onStep: onStep)

                // Build effective system prompt (trim after iteration 3)
                let effectivePrompt = IterationEngine.effectiveSystemPrompt(
                    basePrompt: state.systemPrompt,
                    iteration: state.iteration
                )

                let intentModeLabel: String = {
                    switch intent {
                    case .chat: return "思考"
                    case .research: return "研究"
                    case .task: return state.isReadOnlyRun ? "分析" : "执行"
                    case .workflow: return "工作流"
                    }
                }()

                // Speculative pre-fetch while LLM thinks
                let speculativeTask = Task { @MainActor in
                    await Self.speculativePreFetch(
                        iteration: state.iteration,
                        taskContext: state.taskContext,
                        task: state.task,
                        toolRegistry: self.toolRegistry
                    )
                }

                // LLM call
                let request = SendMessageRequest(
                    sessionID: state.task.id,
                    message: "",
                    connector: state.connector,
                    modeLabel: intentModeLabel,
                    systemPrompt: effectivePrompt,
                    tools: state.toolDefs.isEmpty ? nil : state.toolDefs,
                    messages: state.messages,
                    maxOutputTokens: config.maxTokensPerTurn
                )

                let response: SendMessageResponse
                do {
                    response = try await runtime.sendMessageStream(request, onChunk: onStreamDelta, onReasoningChunk: onReasoningDelta)

                    // Record per-request token usage for analytics
                    if let m = response.metrics {
                        let projectName = ProjectManager.shared.activeProject?.name ?? ""
                        UsageTracker.shared.record(
                            modelName: config.modelName,
                            connectorName: state.connector.name,
                            projectName: projectName,
                            threadID: state.task.id.uuidString,
                            inputTokens: m.inputTokens ?? 0,
                            outputTokens: m.outputTokens ?? 0,
                            durationSeconds: m.totalDuration,
                            tokensPerSecond: m.tokensPerSecond ?? 0,
                            isStreaming: true,
                            intent: state.intentString
                        )
                    }

                    // Merge speculative results
                    let specResult = await speculativeTask.value
                    for (path, content) in specResult.cachedFiles {
                        state.taskContext.memory.fileContentCache[path] = content
                        if !state.taskContext.memory.readFiles.contains(path) {
                            state.taskContext.memory.readFiles.append(path)
                        }
                    }
                    for (path, summary) in specResult.summaries {
                        state.taskContext.memory.fileSummaries[path] = summary
                    }
                } catch {
                    let recovery = Self.resolveErrorRecovery(
                        error: error,
                        currentConnector: state.connector,
                        allConnectors: state.allConnectors,
                        didConnectorFailover: state.didConnectorFailover,
                        transientRetryCount: state.transientRetryCount,
                        maxTransientRetries: state.maxTransientRetries,
                        iteration: state.iteration,
                        effectiveMaxIterations: state.effectiveMaxIterations
                    )
                    switch recovery {
                    case .connectorFailover(let fallback):
                        state.didConnectorFailover = true
                        let failed = state.connector
                        state.connector = fallback
                        state.task.connectorID = fallback.id
                        state.usesOllamaChat = Self.usesOllamaChat(fallback)
                        state.transientRetryCount = 0
                        let failoverStep = Self.connectorFailoverStep(from: failed, to: fallback, reason: error.localizedDescription)
                        state.task.steps.append(failoverStep)
                        onStep(failoverStep)
                        state.messages.append(Self.connectorFailoverMessage(from: failed, to: fallback, reason: error.localizedDescription))
                        continue
                    case .transientRetry(let delaySec):
                        state.transientRetryCount += 1
                        let retryStep = TaskStep(
                            kind: .aiThinking,
                            text: "模型请求失败（\(error.localizedDescription)），自动重试（\(state.transientRetryCount)/\(state.maxTransientRetries)）…",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        if config.emitDebugSteps {
                            state.task.steps.append(retryStep)
                            onStep(retryStep)
                        }
                        try? await Task.sleep(for: .milliseconds(delaySec * 1000))
                        continue
                    case .fatal:
                        let errorStep = TaskStep(
                            kind: .error,
                            text: "模型请求失败：\(error.localizedDescription)",
                            isFailure: true,
                            recoverable: true
                        )
                        state.task.steps.append(errorStep)
                        onStep(errorStep)
                        state.task.status = .failed
                        return state.task
                    }
                }

                // Tool compatibility fallback
                if response.toolActivities.contains(where: { $0.isFailure }) {
                    if Self.shouldRetryWithoutTools(
                        response: response,
                        requestedTools: state.toolDefs,
                        hasRetriedWithoutTools: state.usedToolCompatibilityFallback
                    ) {
                        let fallbackStep = TaskStep(
                            kind: .aiThinking,
                            text: "当前连接不兼容工具调用请求，换一种方式继续。",
                            isCollapsible: true,
                            isCollapsed: true,
                            retryAction: Self.toolCompatibilityFallbackAction
                        )
                        state.task.steps.append(fallbackStep)
                        onStep(fallbackStep)
                        state.toolDefs = []
                        state.usedToolCompatibilityFallback = true
                        Self.applyToolCompatibilityFallbackInstruction(to: &state.messages)
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
                    state.task.steps.append(errorStep)
                    onStep(errorStep)
                    state.hadFailure = true
                    state.didComplete = false
                    break
                }

                // ── STAGE 2: Execute (tool calls) ──
                if response.hasToolCalls {
                    let sanitizedAssistant = AgentLoop.sanitizeAssistantVisibleText(response.assistantText)
                    let assistantThinkingText = sanitizedAssistant.text ?? ""
                    // Emit thinking step
                    if !assistantThinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || response.reasoningContent != nil {
                        let thinkingStep = TaskStep(
                            kind: .aiThinking,
                            text: assistantThinkingText,
                            isCollapsible: true,
                            reasoningContent: response.reasoningContent
                        )
                        state.task.steps.append(thinkingStep)
                        onStep(thinkingStep)
                    }
                    // Add assistant message with tool calls
                    if state.usesOllamaChat {
                        let toolNames = response.toolCalls
                            .map { ToolNameCodec.canonicalName($0.function.name) }
                            .joined(separator: ", ")
                        state.messages.append(ChatMessage(role: "assistant", content: "我将调用这些工具：\(toolNames)"))
                    } else {
                        state.messages.append(ChatMessage(
                            role: "assistant",
                            content: assistantThinkingText.isEmpty ? nil : assistantThinkingText,
                            reasoningContent: response.reasoningContent,
                            toolCalls: response.toolCalls
                        ))
                    }
                    // Execute tools via engine
                    let execResult = await ToolExecutionEngine.execute(
                        response: response,
                        state: &state,
                        config: config,
                        toolRegistry: toolRegistry,
                        onStep: onStep
                    )
                    if execResult.hadFailure { state.hadFailure = true }
                    // Post-tool analysis
                    IterationEngine.analyzeToolResults(
                        callSteps: execResult.callSteps,
                        toolCallResults: execResult.toolCallResults,
                        state: &state,
                        config: config
                    )

                    // Log iteration with tool calls
                    let iterationDuration = Date().timeIntervalSince(iterationStartTime)
                    let toolLogs = execResult.callSteps.enumerated().map { idx, callEntry in
                        let result = idx < execResult.toolCallResults.count ? execResult.toolCallResults[idx].1 : nil
                        return AgentIterationLog.ToolCallLog(
                            toolName: callEntry.2,  // apiToolName is at index 2
                            success: result?.success ?? false,
                            durationSeconds: result?.data?["durationSeconds"].flatMap(Double.init) ?? 0,
                            errorDetail: result?.error
                        )
                    }
                    let tokenLog: AgentIterationLog.TokenUsageLog? = response.metrics.map { m in
                        AgentIterationLog.TokenUsageLog(
                            inputTokens: m.inputTokens ?? 0,
                            outputTokens: m.outputTokens ?? 0,
                            tokensPerSecond: m.tokensPerSecond ?? 0
                        )
                    }
                    AgentLogger.shared.logIteration(AgentIterationLog(
                        timestamp: iterationStartTime,
                        taskID: state.task.id.uuidString,
                        iteration: state.iteration,
                        phase: state.currentPhase.rawValue,
                        intent: state.intentString,
                        connectorName: state.connector.name,
                        toolCalls: toolLogs,
                        tokenUsage: tokenLog,
                        error: nil,
                        durationSeconds: iterationDuration,
                        messageCount: state.messages.count,
                        stepCount: state.task.steps.count
                    ))
                } else {
                    // ── STAGE 3: Text response → Verify + Output ──
                    let action = await ResponseHandler.handle(
                        response: response,
                        state: &state,
                        config: config,
                        runtime: runtime,
                        toolRegistry: toolRegistry,
                        onStep: onStep
                    )

                    // Log iteration with text response
                    let iterationDuration = Date().timeIntervalSince(iterationStartTime)
                    let tokenLog: AgentIterationLog.TokenUsageLog? = response.metrics.map { m in
                        AgentIterationLog.TokenUsageLog(
                            inputTokens: m.inputTokens ?? 0,
                            outputTokens: m.outputTokens ?? 0,
                            tokensPerSecond: m.tokensPerSecond ?? 0
                        )
                    }
                    AgentLogger.shared.logIteration(AgentIterationLog(
                        timestamp: iterationStartTime,
                        taskID: state.task.id.uuidString,
                        iteration: state.iteration,
                        phase: state.currentPhase.rawValue,
                        intent: state.intentString,
                        connectorName: state.connector.name,
                        toolCalls: [],
                        tokenUsage: tokenLog,
                        error: nil,
                        durationSeconds: iterationDuration,
                        messageCount: state.messages.count,
                        stepCount: state.task.steps.count
                    ))

                    switch action {
                    case .continueLoop: continue
                    case .breakLoop: break
                    }
                    break
                }
            }

            // Inner while exited — if auto-round already fired and still not done, mark failure
            if !state.didComplete && !state.hadFailure && !state.wasTruncated && state.autoRound >= 1 {
                state.hadFailure = true
                state.didComplete = false
                let maxIterStep = TaskStep(
                    kind: .error,
                    text: "已达到最大迭代次数（\(state.effectiveMaxIterations)），未能在限定步骤内完成。",
                    isFailure: true,
                    recoverable: true,
                    retryAction: "继续处理"
                )
                state.task.steps.append(maxIterStep)
                onStep(maxIterStep)
            }

            // Auto-continuation (max 1 round, with context compression)
            if !state.didComplete && !state.hadFailure && !state.wasTruncated && !Task.isCancelled && state.autoRound < 1 && state.intent != .chat {
                state.autoRound += 1
                state.iteration = 0

                // Compress context before continuing — keep system prompt + last 6 messages + progress summary
                let progressSummary = Self.compactProgressSummary(task: state.task)
                let systemMsgs = state.messages.filter { $0.role == "system" }
                let recentMsgs = state.messages.suffix(6)
                state.messages = Array(systemMsgs.prefix(2)) + Array(recentMsgs)
                state.messages.append(ChatMessage(role: "system", content: "自动继续中（已压缩上下文）。\n当前进展：\n\(progressSummary)\n请继续完成剩余工作，不要重复已成功的操作。"))

                state.consecutiveEmptyResponses = 0
                state.transientRetryCount = 0
                state.didInjectWorkingSet = false
                let roundStep = TaskStep(kind: .aiThinking, text: "自动继续处理中（第 1 轮）…", isCollapsible: true, isCollapsed: false)
                state.task.steps.append(roundStep)
                onStep(roundStep)
            }
        } while !state.didComplete && !state.hadFailure && !state.wasTruncated && state.autoRound > 0 && state.autoRound <= 1 && state.intent != .chat

        // Fallback wiki build (uses instance method)
        if !state.didComplete && !state.hadFailure && !state.wasTruncated && state.intent != .chat {
            var taskContext = state.taskContext
            var task = state.task
            if let fallbackSaved = await runFallbackWikiBuildIfNeeded(
                message: message,
                taskContext: &taskContext,
                task: &task,
                emitMissingMaterialFailure: false,
                onStep: onStep
            ) {
                state.taskContext = taskContext
                state.task = task
                state.didComplete = fallbackSaved
                state.hadFailure = !fallbackSaved
            }
        }

        // ════════════════════════════════════════
        // STAGE 4 — Output (Finalization + Learning)
        // ════════════════════════════════════════
        await TaskFinalizer.finalize(
            state: &state,
            config: config,
            systemPrompt: state.systemPrompt,
            runtime: runtime,
            onStep: onStep
        )

        return state.task
    }


    // MARK: - Helpers

    private func emitNewSteps(from state: inout PipelineState, into task: inout AgentTask, onStep: @MainActor (TaskStep) -> Void) {
        for step in state.task.steps where !task.steps.contains(where: { $0.id == step.id }) {
            task.steps.append(step)
            onStep(step)
        }
        task = state.task
    }
}
