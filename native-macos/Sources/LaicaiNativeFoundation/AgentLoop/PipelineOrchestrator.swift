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
        onStreamDelta: @Sendable @MainActor (String) -> Void = { _ in }
    ) async throws -> AgentTask {

        // ════════════════════════════════════════
        // STAGE 0 — Setup
        // ════════════════════════════════════════
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

        // Inline planning hint
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
                        text: "已达到步骤数上限（\(state.absoluteMaxSteps)步），强制结束。如需继续请新建任务。",
                        isCollapsible: false
                    )
                    state.task.steps.append(limitStep)
                    onStep(limitStep)
                    state.hadFailure = true
                    break
                }
                state.iteration += 1

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
                    connector: connector,
                    modeLabel: intentModeLabel,
                    systemPrompt: effectivePrompt,
                    tools: state.toolDefs.isEmpty ? nil : state.toolDefs,
                    messages: state.messages,
                    maxOutputTokens: config.maxTokensPerTurn
                )

                let response: SendMessageResponse
                do {
                    response = try await runtime.sendMessageStream(request, onChunk: onStreamDelta)
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
                    let isTransient = Self.isTransientError(error)
                    if isTransient, state.transientRetryCount < state.maxTransientRetries, state.iteration < state.effectiveMaxIterations {
                        state.transientRetryCount += 1
                        let retryStep = TaskStep(
                            kind: .aiThinking,
                            text: "模型请求失败（\(error.localizedDescription)），自动重试（\(state.transientRetryCount)/\(state.maxTransientRetries)）…",
                            isCollapsible: true,
                            isCollapsed: true
                        )
                        state.task.steps.append(retryStep)
                        onStep(retryStep)
                        let delaySec = min(Int(pow(2.0, Double(state.transientRetryCount))), 8)
                        try? await Task.sleep(for: .milliseconds(delaySec * 1000))
                        continue
                    }
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

                // Tool compatibility fallback
                if response.toolActivities.contains(where: { $0.isFailure }) {
                    if Self.shouldRetryWithoutTools(
                        response: response,
                        requestedTools: state.toolDefs,
                        hasRetriedWithoutTools: state.usedToolCompatibilityFallback
                    ) {
                        let fallbackStep = TaskStep(
                            kind: .aiThinking,
                            text: "检测到当前连接器不兼容工具调用请求，已自动切换为无工具模式继续；后续不会伪造搜索、读取、联网或写入结果。",
                            isCollapsible: true,
                            isCollapsed: false,
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
                    // Emit thinking step
                    if !response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || response.reasoningContent != nil {
                        let thinkingStep = TaskStep(
                            kind: .aiThinking,
                            text: response.assistantText,
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
                            content: response.assistantText.isEmpty ? nil : response.assistantText,
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
                    switch action {
                    case .continueLoop: continue
                    case .breakLoop: break
                    }
                    break
                }
            }

            // Auto-continuation
            if !state.didComplete && !state.hadFailure && !state.wasTruncated && !Task.isCancelled && state.autoRound < state.maxAutoRounds && state.intent != .chat {
                state.autoRound += 1
                state.iteration = 0
                let progressSummary = Self.compactProgressSummary(task: state.task)
                state.messages.append(ChatMessage(role: "system", content: "已完成第 \(state.autoRound) 段处理。以下是目前进展，请继续完成剩余工作，不要重复已成功的操作：\n\(progressSummary)"))
                state.consecutiveEmptyResponses = 0
                state.transientRetryCount = 0
                state.didInjectWorkingSet = false
                let roundStep = TaskStep(kind: .aiThinking, text: "继续处理中…", isCollapsible: true, isCollapsed: true)
                state.task.steps.append(roundStep)
                onStep(roundStep)
            }
        } while !state.didComplete && !state.hadFailure && !state.wasTruncated && state.autoRound > 0 && state.autoRound <= state.maxAutoRounds && state.intent != .chat

        // Fallback wiki build (uses instance method)
        if !state.didComplete && !state.hadFailure && !state.wasTruncated && state.intent != .chat {
            if let fallbackSaved = await runFallbackWikiBuildIfNeeded(
                message: message,
                taskContext: &state.taskContext,
                task: &state.task,
                emitMissingMaterialFailure: false,
                onStep: onStep
            ) {
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
