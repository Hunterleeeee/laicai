import Foundation
import LaicaiNativeDomain

// MARK: - Response Handler
// Processes text-only LLM responses: empty response handling, plan-only detection,
// truncation continuation, quality gates, fake tool call sanitization.
// Extracted from the monolithic run() method (lines 1956-2292).

@MainActor
struct ResponseHandler {
    struct HandleRequest {
        let response: SendMessageResponse
        let config: AgentLoop.Config
        let runtime: any ChatRuntimeClient
    }

    /// Action to take after processing a text response.
    enum Action {
        case continueLoop  // keep iterating
        case breakLoop  // exit the main loop
    }

    /// Process a text-only (no tool calls) response from the LLM.
    static func handle(
        request: HandleRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Action {
        let rawText = resolvedAssistantText(request.response)

        // ── Empty / thinking-only responses ──
        if rawText.isEmpty {
            return await handleEmptyResponse(
                response: request.response,
                state: &state,
                config: request.config,
                onStep: onStep
            )
        }

        state.consecutiveEmptyResponses = 0
        let text = rawText
        let toolCallCount = state.task.steps.filter({ $0.kind == .toolCall }).count
        let hasFakeToolCalls = AgentLoop.containsFakeToolCallSyntax(text)
        let hasWritten = AgentLoop.hasSuccessfulWrite(in: state.task)

        // ── Tool spam detection ──
        if emitToolSpamStepIfNeeded(text: text, state: &state, onStep: onStep) {
            return .breakLoop
        }

        // ── Research needs fetch nudge ──
        if emitResearchFetchNudgeIfNeeded(text: text, hasFakeToolCalls: hasFakeToolCalls, state: &state, onStep: onStep) {
            return .continueLoop
        }

        // ── Plan-only detection ──
        let isEarlyTurn = state.iteration < 3 && !state.toolDefs.isEmpty
        let onlyDidReads =
            toolCallCount > 0 && !hasWritten
            && !state.task.steps.contains(where: {
                $0.kind == .toolCall && ["shell.exec", "wiki.build", "web.fetch", "file.extract"].contains($0.toolName ?? "")
            })
        let isPlanOnly =
            isEarlyTurn && state.intent != .chat && !state.isReadOnlyRun
            && (toolCallCount == 0 || onlyDidReads)
            && AgentLoop.looksLikePlanOnly(text)
            && !hasFakeToolCalls
            && !AgentLoop.looksLikeProviderError(text)
        if emitPlanOnlyNudgeIfNeeded(
            PlanNudgeRequest(
                isPlanOnly: isPlanOnly,
                text: text,
                toolCallCount: toolCallCount,
                config: request.config
            ), state: &state, onStep: onStep) {
            return .continueLoop
        }
        let requiresToolEvidence =
            AgentLoop.shouldRequireToolEvidenceBeforeFinalText(
                AgentLoop.ToolEvidenceRequirementContext(
                    message: state.message,
                    intent: state.intent,
                    isReadOnlyRun: state.isReadOnlyRun,
                    toolCallCount: toolCallCount,
                    toolDefs: state.toolDefs,
                    usedToolCompatibilityFallback: state.usedToolCompatibilityFallback
                )
            )
            && state.iteration < state.effectiveMaxIterations - 1
            && !hasFakeToolCalls
            && !AgentLoop.looksLikeProviderError(text)
            && state.nudgeCount < state.maxNudges
        if emitToolEvidenceNudgeIfNeeded(
            requiresToolEvidence: requiresToolEvidence,
            text: text,
            config: request.config,
            state: &state,
            onStep: onStep
        ) {
            return .continueLoop
        }

        // ── All-read-no-write nudge ──
        let isActMode =
            !state.isReadOnlyRun
            && isToolAllowed("shell.exec", config: request.config)
            && isToolAllowed("file.write", config: request.config)
        let allReadNoWrite = isActMode && toolCallCount >= 3 && !hasWritten
        let pastHalfBudget = state.iteration >= max(2, state.effectiveMaxIterations / 3)
        let expectsFurtherExecution = AgentLoop.expectsWriteOutput(state.message) || AgentLoop.expectsWikiOutput(state.message)
        let shouldNudge =
            allReadNoWrite && pastHalfBudget
            && expectsFurtherExecution
            && state.intent != .chat && state.intent != .research
            && state.nudgeCount < 1
            && !AgentLoop.looksLikeProviderError(text)
            && !hasFakeToolCalls
        if emitAllReadNoWriteNudgeIfNeeded(shouldNudge: shouldNudge, text: text, toolCallCount: toolCallCount, state: &state) {
            return .continueLoop
        }

        // ── Fake tool call warning ──
        emitFakeToolCallWarningIfNeeded(hasFakeToolCalls: hasFakeToolCalls, state: &state, onStep: onStep)

        // ── Sanitize & guard ──
        let sanitized = AgentLoop.sanitizeAssistantVisibleText(text)
        var visibleText = sanitized.text ?? text
        // Completion-claim guard
        visibleText = textWithCompletionWarningIfNeeded(visibleText, hasWritten: hasWritten, state: state)

        // ── Provider error ──
        if emitProviderErrorIfNeeded(text: text, state: &state, onStep: onStep) {
            return .breakLoop
        }

        // ── Emit output step ──
        let outputStep = TaskStep(
            kind: .textOutput,
            text: visibleText,
            isCollapsible: false,
            isCollapsed: false,
            metrics: request.response.metrics
        )
        state.task.steps.append(outputStep)
        onStep(outputStep)

        // ── Wiki save nudge ──
        if emitWikiSaveNudgeIfNeeded(text: text, hasWritten: hasWritten, state: &state, onStep: onStep) {
            return .continueLoop
        }

        // ── Truncation handling ──
        await handleTruncationIfNeeded(request: request, state: &state, text: text, outputStep: outputStep, onStep: onStep)
        // Completion is determined by meetsCompletionCriteria in TaskFinalizer.
        // ResponseHandler only handles per-iteration decisions (empty response, tool compatibility).
        state.didComplete = !state.wasTruncated
        return .breakLoop
    }

    private struct PlanNudgeRequest {
        let isPlanOnly: Bool
        let text: String
        let toolCallCount: Int
        let config: AgentLoop.Config
    }

    private struct ToolEvidenceNudgeRequest {
        let requiresToolEvidence: Bool
        let text: String
        let config: AgentLoop.Config
    }

    private static func resolvedAssistantText(_ response: SendMessageResponse) -> String {
        let assistantText = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard assistantText.isEmpty,
            let reasoning = response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning.count > 50
        else {
            return assistantText
        }
        return reasoning
    }

    private static func emitToolSpamStepIfNeeded(
        text: String,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard AgentLoop.looksLikeToolSpam(text) else { return false }
        let spamStep = TaskStep(
            kind: .aiThinking,
            text: "模型输出了异常的工具列表文本（非实际工具调用），已自动跳过。建议换用支持 function calling 的模型。",
            isCollapsible: false,
            isCollapsed: false
        )
        state.task.steps.append(spamStep)
        onStep(spamStep)
        return true
    }

    private static func emitResearchFetchNudgeIfNeeded(
        text: String,
        hasFakeToolCalls: Bool,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard researchNeedsFetch(text: text, hasFakeToolCalls: hasFakeToolCalls, state: state),
            state.nudgeCount < state.maxNudges
        else {
            return false
        }
        state.nudgeCount += 1
        state.messages.append(ChatMessage(role: "assistant", content: text))
        state.messages.append(ChatMessage(role: "user", content: "你已经完成搜索，但还没有读取任何来源详情。请至少调用 web_fetch 读取 1-2 个最关键来源后再总结，不要只基于搜索摘要回答。"))
        let nudgeStep = TaskStep(
            kind: .aiThinking,
            text: "研究模式需要读取关键来源详情。正在引导模型调用 web_fetch 后再总结（第 \(state.nudgeCount)/\(state.maxNudges) 次）。",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(nudgeStep)
        onStep(nudgeStep)
        return true
    }

    private static func researchNeedsFetch(
        text: String,
        hasFakeToolCalls: Bool,
        state: PipelineState
    ) -> Bool {
        state.intent == .research
            && state.task.steps.contains(where: { $0.kind == .toolCall && $0.toolName == "web.search" })
            && !state.task.steps.contains(where: { $0.kind == .toolCall && $0.toolName == "web.fetch" })
            && state.iteration < state.effectiveMaxIterations - 1
            && !AgentLoop.looksLikeProviderError(text)
            && !state.usedToolCompatibilityFallback
            && !hasFakeToolCalls
    }

    private static func emitPlanOnlyNudgeIfNeeded(
        _ request: PlanNudgeRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard request.isPlanOnly else { return false }
        state.messages.append(ChatMessage(role: "assistant", content: request.text))
        let nudgeMsg =
            request.toolCallCount == 0
            ? "你刚才只输出了计划/分析，没有调用任何工具。禁止只说不做。立即调用工具执行第一步。"
            : "你已经读取了资料但停了下来。不要只说计划，立即继续执行下一步：整理到 Wiki 就调用 wiki_build(save=true)，表格/文档先用 file_extract，其他交付用 file_write / shell_exec。"
        state.messages.append(ChatMessage(role: "system", content: nudgeMsg))
        appendDebugStepIfNeeded(
            TaskStep(kind: .aiThinking, text: "检测到还没真正执行，继续推进。", isCollapsible: true, isCollapsed: true),
            config: request.config,
            state: &state,
            onStep: onStep
        )
        return true
    }

    private static func emitToolEvidenceNudgeIfNeeded(
        requiresToolEvidence: Bool,
        text: String,
        config: AgentLoop.Config,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        emitToolEvidenceNudgeIfNeeded(
            ToolEvidenceNudgeRequest(requiresToolEvidence: requiresToolEvidence, text: text, config: config),
            state: &state,
            onStep: onStep
        )
    }

    private static func emitToolEvidenceNudgeIfNeeded(
        _ request: ToolEvidenceNudgeRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard request.requiresToolEvidence else { return false }
        state.nudgeCount += 1
        state.messages.append(ChatMessage(role: "assistant", content: request.text))
        state.messages.append(
            ChatMessage(
                role: "system",
                content: "当前是会话执行任务，但你没有调用任何工具就给出了结论。不要裸答。请先调用 workspace_index、code_search、file_read、web_search 或更合适的工具取得真实证据；如果任务需要修改或验证，继续执行对应工具。"))
        appendDebugStepIfNeeded(
            TaskStep(kind: .aiThinking, text: "执行质量门：尚未调用工具取证，继续执行。", isCollapsible: true, isCollapsed: true),
            config: request.config,
            state: &state,
            onStep: onStep
        )
        return true
    }

    private static func appendDebugStepIfNeeded(
        _ step: TaskStep,
        config: AgentLoop.Config,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard config.emitDebugSteps else { return }
        state.task.steps.append(step)
        onStep(step)
    }

    private static func emitAllReadNoWriteNudgeIfNeeded(
        shouldNudge: Bool,
        text: String,
        toolCallCount: Int,
        state: inout PipelineState
    ) -> Bool {
        guard shouldNudge else { return false }
        state.nudgeCount += 1
        state.messages.append(ChatMessage(role: "assistant", content: text))
        state.messages.append(ChatMessage(role: "user", content: "已调研\(toolCallCount)次但0次执行。请执行或给出结论。"))
        return true
    }

    private static func emitFakeToolCallWarningIfNeeded(
        hasFakeToolCalls: Bool,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard hasFakeToolCalls, !state.usedToolCompatibilityFallback else { return }
        let warningStep = TaskStep(
            kind: .aiThinking,
            text: "检测到模型将工具调用写成了文本，说明该模型不兼容函数调用。建议切换到支持 function calling 的云端模型（如 GPT-4o/5.5、Claude）来执行复杂会话。",
            isCollapsible: false,
            isCollapsed: false
        )
        state.task.steps.append(warningStep)
        onStep(warningStep)
    }

    private static func textWithCompletionWarningIfNeeded(
        _ visibleText: String,
        hasWritten: Bool,
        state: PipelineState
    ) -> String {
        let missingDeliverables = missingDeliverablePaths(state)
        guard AgentLoop.expectsWriteOutput(state.message),
            !hasWritten || !missingDeliverables.isEmpty,
            !AgentLoop.hasSavedWiki(in: state.task),
            AgentLoop.containsFalseCompletionClaim(visibleText)
        else {
            return visibleText
        }
        let targetText =
            missingDeliverables.isEmpty
            ? ""
            : "目标文件尚未生成：\(missingDeliverables.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))。"
        return visibleText + "\n\n---\n⚠️ **来财提醒**：\(targetText)本轮没有足够的真实交付证据。上面的「已修改 / 已保存 / 已创建」等说法是模型自述，请以上方工具结果和磁盘文件为准。"
    }

    private static func missingDeliverablePaths(_ state: PipelineState) -> [String] {
        AgentLoop.expectedDeliverablePaths(
            from: state.message,
            workspaceRoot: state.taskContext.workspaceRoot
        ).filter { path in
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || isDirectory.boolValue
        }
    }

    private static func emitProviderErrorIfNeeded(
        text: String,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard AgentLoop.looksLikeProviderError(text) else { return false }
        let errorStep = TaskStep(
            kind: .error,
            text: text,
            isFailure: true,
            recoverable: true,
            retryAction: "检查端点、模型名和请求兼容性后重试"
        )
        state.task.steps.append(errorStep)
        onStep(errorStep)
        state.hadFailure = true
        state.didComplete = false
        return true
    }

    private static func emitWikiSaveNudgeIfNeeded(
        text: String,
        hasWritten: Bool,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) -> Bool {
        guard
            AgentLoop.needsWikiSaveNudge(
                message: state.message,
                task: state.task,
                isReadOnlyRun: state.isReadOnlyRun,
                hasWritten: hasWritten
            ),
            state.iteration < state.effectiveMaxIterations - 1,
            state.nudgeCount < state.maxNudges
        else {
            return false
        }
        state.nudgeCount += 1
        let gateStep = TaskStep(
            kind: .aiThinking,
            text: "完成质量门：Wiki会话尚未保存任何笔记，继续执行 wiki_build。",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(gateStep)
        onStep(gateStep)
        state.messages.append(ChatMessage(role: "assistant", content: text))
        state.messages.append(
            ChatMessage(
                role: "system",
                content: "用户要求整理到 Wiki/知识库，但当前没有任何 wiki_build(save=true) 或文件写入成功记录。不要输出计划或道歉，立即基于已读材料调用 wiki_build 保存原子笔记；材料不足就先用 file_read/file_extract 继续读取。")
        )
        state.didComplete = false
        return true
    }

    private static func handleTruncationIfNeeded(
        request: HandleRequest,
        state: inout PipelineState,
        text: String,
        outputStep: TaskStep,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        guard request.response.finishReason == "length" else { return }
        state.wasTruncated = true
        let limitStep = TaskStep(
            kind: .aiThinking,
            text: "输出达到当前上限（\(request.config.maxTokensPerTurn) 词元），正在自动续写下一段。",
            isFailure: false,
            recoverable: true,
            retryAction: "接着说"
        )
        state.task.steps.append(limitStep)
        onStep(limitStep)
        await continueTruncatedResponse(request: request, state: &state, text: text, outputStep: outputStep, onStep: onStep)
    }

    private static func continueTruncatedResponse(
        request: HandleRequest,
        state: inout PipelineState,
        text: String,
        outputStep: TaskStep,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        guard
            let continuationStep = try? await AgentLoop.continueTruncatedOutput(
                AgentLoop.TruncatedContinuationRequest(
                    taskID: state.task.id,
                    originalMessage: state.message,
                    previousText: text,
                    messages: state.messages,
                    connector: state.connector,
                    runtime: request.runtime,
                    maxOutputTokens: request.config.maxTokensPerTurn,
                    originalStepID: outputStep.id
                ))
        else {
            return
        }
        state.task.steps.append(continuationStep)
        onStep(continuationStep)
        if continuationStep.text.contains("回复仍被截断") {
            emitStillTruncatedStep(state: &state, onStep: onStep)
        } else {
            state.wasTruncated = false
        }
    }

    private static func emitStillTruncatedStep(
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let stillTruncatedStep = TaskStep(
            kind: .error,
            text: "第二段回复仍被截断。请继续在这个会话里发送\u{201C}接着说\u{201D}，我会继续沿用当前上下文。",
            isFailure: false,
            recoverable: true,
            retryAction: "接着说"
        )
        state.task.steps.append(stillTruncatedStep)
        onStep(stillTruncatedStep)
    }

    // MARK: - Empty Response Handling

    private static func handleEmptyResponse(
        response: SendMessageResponse,
        state: inout PipelineState,
        config: AgentLoop.Config,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Action {
        state.consecutiveEmptyResponses += 1

        // Fallback wiki build
        if state.intent != .chat {
            // Note: runFallbackWikiBuildIfNeeded is an instance method on AgentLoop,
            // so this must be called from the orchestrator. We signal via a flag instead.
        }

        guard state.iteration < state.effectiveMaxIterations - 1 else {
            let exhaustedStep = TaskStep(
                kind: .error,
                text: response.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? "模型只返回了思考内容，没有给出最终答案或工具调用。本轮未形成可交付结果。"
                    : "模型返回了空内容，没有给出最终答案或工具调用。本轮未形成可交付结果。",
                isFailure: true,
                recoverable: true,
                retryAction: "继续处理"
            )
            state.task.steps.append(exhaustedStep)
            onStep(exhaustedStep)
            state.hadFailure = true
            state.didComplete = false
            return .breakLoop
        }

        if state.consecutiveEmptyResponses >= state.maxConsecutiveEmpty || (state.toolDefs.isEmpty && state.consecutiveEmptyResponses > 1) {
            let stopStep = TaskStep(
                kind: .error,
                text: "模型连续 \(state.consecutiveEmptyResponses) 次返回空响应/纯思考内容，停止重试。本轮未形成可交付结果。",
                isCollapsible: false,
                isCollapsed: false,
                isFailure: true,
                recoverable: true,
                retryAction: "继续处理"
            )
            state.task.steps.append(stopStep)
            onStep(stopStep)
            state.hadFailure = true
            state.didComplete = false
            return .breakLoop
        }

        // On 2nd empty response, strip tools
        if state.consecutiveEmptyResponses == 2 {
            state.toolDefs = []
            let stripStep = TaskStep(
                kind: .aiThinking,
                text: "模型连续空响应，临时移除工具定义，换一种方式继续。",
                isCollapsible: true,
                isCollapsed: true
            )
            state.task.steps.append(stripStep)
            onStep(stripStep)
            state.messages.append(ChatMessage(role: "system", content: "上一轮模型没有返回任何可见内容或工具调用。已临时移除工具 schema，请直接用文字给出基于已有材料的结论；如果用户要求保存/写入但工具不可用，请明确说明尚未保存。"))
            return .continueLoop
        }

        // Auto-retry: peel trailing orchestration-injected nudges
        if state.consecutiveEmptyResponses == 1 {
            let nudgeMarkers = [
                "[工具可用性更新]",
                "立即调用工具",
                "请至少调用",
                "你已经完成搜索",
                "完成质量门",
                "已临时移除工具 schema"
            ]
            var peeled = 0
            while peeled < 2, state.messages.count > 2 {
                let last = state.messages[state.messages.count - 1]
                let body = last.content ?? ""
                let isInjected = nudgeMarkers.contains(where: { body.contains($0) })
                guard isInjected else { break }
                state.messages.removeLast()
                peeled += 1
            }
            let retryStep = TaskStep(
                kind: .aiThinking,
                text: peeled > 0
                    ? "模型返回空内容，剥离最近 \(peeled) 条编排提示后自动重试…"
                    : "模型返回空内容，自动重试中…",
                isCollapsible: true,
                isCollapsed: true
            )
            state.task.steps.append(retryStep)
            onStep(retryStep)
            return .continueLoop
        }

        let nudgeText = AgentLoop.buildEmptyResponseNudge(task: state.task, intent: state.intent)
        state.messages.append(ChatMessage(role: "user", content: nudgeText))
        return .continueLoop
    }

    // MARK: - Utility

    private static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        AgentLoop.allowsTool(name, allowedTools: config.allowedTools)
    }
}
