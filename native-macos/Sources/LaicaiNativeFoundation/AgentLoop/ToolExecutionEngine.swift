import Foundation
import LaicaiNativeDomain

// MARK: - Tool Execution Engine
// Handles the complete tool call lifecycle:
//   1. Emit call steps to UI
//   2. Execute tools in smart batches (concurrent where safe)
//   3. Process results (review steps, memory updates, auto-verify, chaining)
//   4. Build model-facing result messages
//
// Extracted from AgentLoop.run() lines 1045-1821 (~777 lines).

struct ToolCallEntry {
    let responseIndex: Int
    let callStep: TaskStep
    let apiToolName: String
    let argumentsJSON: String
    let callID: String
    let toolParams: [String: String]
}

struct ToolCallExecutionResult {
    let responseIndex: Int
    let result: ToolResult
    let recoveryPlan: RecoveryPlan?
}

@MainActor
struct ToolExecutionEngine {
    private struct SingleToolExecutionRequest {
        let index: Int
        let callStep: TaskStep
        let toolName: String
        let apiToolName: String
        let argumentsJSON: String
        let taskID: UUID
        let taskContext: TaskContext
        let circuitBrokenTools: Set<String>
        let config: AgentLoop.Config
        let toolRegistry: ToolRegistry
    }

    private struct ResultProcessingRequest {
        let callSteps: [ToolCallEntry]
        let toolCallResults: [ToolCallExecutionResult]
        let config: AgentLoop.Config
        let toolRegistry: ToolRegistry
    }

    private struct RecoveryPlanExecutionRequest {
        let plan: RecoveryPlan
        let originalToolName: String
        let config: AgentLoop.Config
        let toolRegistry: ToolRegistry
    }

    private struct ReviewStepEmissionRequest {
        let data: [String: String]
        let toolName: String
        let toolParams: [String: String]
        let callId: String
    }

    private struct AutoVerifyRequest {
        let callStep: TaskStep
        let toolResult: ToolResult
        let config: AgentLoop.Config
        let toolRegistry: ToolRegistry
    }

    struct ExecutionResult {
        var callSteps: [ToolCallEntry]
        var toolCallResults: [ToolCallExecutionResult]
        var hadFailure: Bool
    }

    // MARK: - Public Entry

    static func execute(
        response: SendMessageResponse,
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> ExecutionResult {
        // Step 1: Emit call steps immediately (user sees tools in real-time)
        var callSteps: [ToolCallEntry] = []
        for (index, toolCall) in response.toolCalls.enumerated() {
            let apiToolName = toolCall.function.name
            let toolName = ToolNameCodec.canonicalName(apiToolName)
            let argumentsJSON = toolCall.function.arguments
            let callId = toolCall.id ?? "call_\(apiToolName)_\(state.iteration)"
            let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
            let callStep = TaskStep(
                kind: .toolCall,
                text: ToolStepFormatter.callText(toolName: toolName, arguments: toolParams),
                toolName: toolName,
                toolParams: toolParams,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true
            )
            state.task.steps.append(callStep)
            onStep(callStep)
            callSteps.append(
                ToolCallEntry(
                    responseIndex: index,
                    callStep: callStep,
                    apiToolName: apiToolName,
                    argumentsJSON: argumentsJSON,
                    callID: callId,
                    toolParams: toolParams
                ))
        }

        // Step 2: Execute in smart batches
        // Note: uses sequential execution per batch to avoid inout-in-escaping-closure.
        // scheduledToolCallBatches already groups by exclusivity (read-only batches can be parallel in future).
        var toolCallResults: [ToolCallExecutionResult] = []
        for batch in AgentLoop.scheduledToolCallBatches(callSteps) {
            for callEntry in batch {
                let index = callEntry.responseIndex
                let callStep = callEntry.callStep
                let apiToolName = callEntry.apiToolName
                let toolName = callStep.toolName ?? apiToolName
                let result = await executeSingleTool(
                    SingleToolExecutionRequest(
                        index: index,
                        callStep: callStep,
                        toolName: toolName,
                        apiToolName: apiToolName,
                        argumentsJSON: callEntry.argumentsJSON,
                        taskID: state.config.taskID,
                        taskContext: state.taskContext,
                        circuitBrokenTools: state.circuitBrokenTools,
                        config: config,
                        toolRegistry: toolRegistry
                    ))
                toolCallResults.append(result)
            }
        }
        toolCallResults.sort { $0.responseIndex < $1.responseIndex }

        // Step 3: Process results
        var hadFailure = false
        await processResults(
            request: ResultProcessingRequest(
                callSteps: callSteps,
                toolCallResults: toolCallResults,
                config: config,
                toolRegistry: toolRegistry
            ),
            state: &state,
            hadFailure: &hadFailure,
            onStep: onStep
        )

        return ExecutionResult(
            callSteps: callSteps,
            toolCallResults: toolCallResults,
            hadFailure: hadFailure
        )
    }

    // MARK: - Single Tool Execution

    private static func executeSingleTool(_ request: SingleToolExecutionRequest) async -> ToolCallExecutionResult {
        let index = request.index
        let callStep = request.callStep
        let toolName = request.toolName
        let taskContext = request.taskContext

        // F2: Tool call interception & rewrite
        var argumentsJSON = request.argumentsJSON
        argumentsJSON = AgentLoop.rewriteToolArguments(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            workspaceRoot: taskContext.workspaceRoot
        )

        // G4: Smart cache hit — file.read on already-cached file
        if let cached = checkCacheHit(toolName: toolName, callStep: callStep, taskContext: taskContext) {
            return ToolCallExecutionResult(responseIndex: index, result: cached, recoveryPlan: nil)
        }

        let outcome = await executeToolAfterCache(request: request, argumentsJSON: argumentsJSON)

        // Post-hook
        _ = await HookEngine.shared.runPostHooks(
            toolName: toolName,
            params: callStep.toolParams ?? [:],
            result: outcome.result,
            context: taskContext
        )

        return ToolCallExecutionResult(responseIndex: index, result: outcome.result, recoveryPlan: outcome.recoveryPlan)
    }

    private struct ToolExecutionOutcome {
        var result: ToolResult
        var recoveryPlan: RecoveryPlan?
    }

    private static func executeToolAfterCache(
        request: SingleToolExecutionRequest,
        argumentsJSON: String
    ) async -> ToolExecutionOutcome {
        if let preflight = await preflightToolFailure(request) {
            return ToolExecutionOutcome(result: preflight)
        }
        if let repaired = await circuitBreakerRepairIfNeeded(request) {
            return ToolExecutionOutcome(result: repaired)
        }
        guard let tool = request.toolRegistry.tool(named: request.apiToolName) else {
            return ToolExecutionOutcome(result: ToolResult(output: "未知工具：\(request.toolName)", success: false, error: "unknown_tool"))
        }
        guard !AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: request.toolName, tool: tool) else {
            return ToolExecutionOutcome(result: AgentLoop.approvalRequiredToolResult(toolName: request.toolName))
        }
        return await executeValidatedTool(request: request, argumentsJSON: argumentsJSON, tool: tool)
    }

    private static func preflightToolFailure(_ request: SingleToolExecutionRequest) async -> ToolResult? {
        let preHookOutput = await HookEngine.shared.runPreHooks(
            toolName: request.toolName,
            params: request.callStep.toolParams ?? [:],
            context: request.taskContext
        )
        if let preHookOutput, preHookOutput.contains("⚠️") {
            return ToolResult(output: preHookOutput, success: false, error: "pre_hook_failed")
        }
        guard !isToolAllowed(request.toolName, config: request.config) else { return nil }
        return ToolResult(
            output: "已阻止工具调用：\(request.toolName)。当前执行级别只允许理解意图和只读分析；如果要运行命令、构建、测试或修改文件，请切换到「执行」。",
            success: false,
            error: "tool_not_allowed"
        )
    }

    private static func circuitBreakerRepairIfNeeded(_ request: SingleToolExecutionRequest) async -> ToolResult? {
        let cbTarget = AgentLoop.circuitBreakerTarget(for: request.callStep)
        let cbSig = "\(request.toolName):\(cbTarget.prefix(60))"
        guard request.circuitBrokenTools.contains(cbSig) else { return nil }
        return await AgentLoop.attemptCircuitBreakerRepair(
            toolName: request.toolName,
            callStep: request.callStep,
            taskContext: request.taskContext,
            toolRegistry: request.toolRegistry
        )
    }

    private static func executeValidatedTool(
        request: SingleToolExecutionRequest,
        argumentsJSON: String,
        tool: any LaicaiTool
    ) async -> ToolExecutionOutcome {
        let validated = await validatedToolResult(request: request, argumentsJSON: argumentsJSON, tool: tool)
        var toolResult = validated.result
        var recoveryPlan = recoveryPlanIfNeeded(
            validation: validated.validation,
            toolResult: toolResult,
            toolName: request.toolName,
            argumentsJSON: argumentsJSON
        )
        if !toolResult.success {
            let autoRecoveryRequest = AgentLoop.AutoRecoveryRequest(
                toolName: request.toolName,
                callStep: request.callStep,
                argumentsJSON: argumentsJSON,
                currentResult: toolResult,
                validation: validated.validation,
                taskContext: request.taskContext,
                config: request.config,
                toolRegistry: request.toolRegistry
            )
            toolResult = await AgentLoop.attemptAutoRecovery(autoRecoveryRequest, recoveryPlan: &recoveryPlan)
        }
        return ToolExecutionOutcome(result: toolResult, recoveryPlan: recoveryPlan)
    }

    private static func validatedToolResult(
        request: SingleToolExecutionRequest,
        argumentsJSON: String,
        tool: any LaicaiTool
    ) async -> (result: ToolResult, validation: ValidationEngine.ValidationResult) {
        guard request.toolName == "shell.exec" else {
            let validated = await ValidationEngine.executeWithValidationJSON(
                tool: tool,
                argumentsJSON: argumentsJSON,
                context: request.taskContext
            )
            return (validated.result, validated.validation)
        }
        let streamStepID = UUID()
        let callID = request.callStep.toolCallId ?? "call_\(request.index)"
        let result = await AgentLoop.executeShellStreamingViaNotification(
            AgentLoop.ShellStreamingRequest(
                argumentsJSON: argumentsJSON,
                context: request.taskContext,
                threadID: request.taskID,
                resultStepID: streamStepID,
                callID: callID,
                command: request.callStep.toolParams?["command"] ?? ""
            ))
        return (
            result,
            ValidationEngine.ValidationResult(isValid: tool.validate(result: result), error: result.error, retryCount: 0)
        )
    }

    private static func recoveryPlanIfNeeded(
        validation: ValidationEngine.ValidationResult,
        toolResult: ToolResult,
        toolName: String,
        argumentsJSON: String
    ) -> RecoveryPlan? {
        guard !validation.isValid else { return nil }
        let recoveryError = [toolResult.error, toolResult.output]
            .compactMap { $0 }
            .joined(separator: "：")
        return ErrorRecoveryEngine.planRecoveryJSON(
            error: recoveryError.isEmpty ? "验证失败" : recoveryError,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            attemptCount: validation.retryCount
        )
    }

    // MARK: - Cache Hit Check

    private static func checkCacheHit(toolName: String, callStep: TaskStep, taskContext: TaskContext) -> ToolResult? {
        // file.read cache
        if toolName == "file.read",
            let readPath = callStep.toolParams?["path"],
            callStep.toolParams?["offset"] == nil,
            let cached = taskContext.memory.fileContentCache[readPath]
                ?? taskContext.memory.fileContentCache[(taskContext.workspaceRoot as NSString).appendingPathComponent(readPath)] {
            let limit = min(cached.count, 20000)
            let content = cached.count <= limit ? cached : String(cached.prefix(limit)) + "\n…（共\(cached.count)字符，已截取前\(limit)字符）"
            let dir = (readPath as NSString).deletingLastPathComponent
            let siblings = taskContext.memory.fileSummaries["__dir__:\(dir)"]
            let siblingHint = siblings.map { "\n同目录其他文件：\($0)" } ?? ""
            return ToolResult(
                output: "✅ 缓存命中（0ms）\(siblingHint)\n\n\(content)",
                data: ["path": readPath, "size": "\(cached.count)", "cached": "true"]
            )
        }

        // workspace.index cache
        if toolName == "workspace.index",
            taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("工作区索引：") }) {
            let cached = taskContext.memory.userDecisions.first(where: { $0.hasPrefix("工作区索引：") }) ?? "已索引"
            return ToolResult(
                output: "✅ 工作区已索引（缓存）。\(String(cached.prefix(500)))",
                data: ["cached": "true"]
            )
        }

        // code.search dedup
        if toolName == "code.search",
            let query = callStep.toolParams?["query"] {
            let isDuplicate = taskContext.memory.searchedQueries.contains(query)
            let isSimilar =
                !isDuplicate
                && taskContext.memory.searchedQueries.contains(where: {
                    $0.lowercased().contains(query.lowercased()) || query.lowercased().contains($0.lowercased())
                })
            if isDuplicate || isSimilar {
                let hint = isSimilar ? "类似查询已搜索过" : "此查询已搜索过"
                return ToolResult(
                    output: "\(hint)，结果见上方历史。请基于已有结果继续，不要重复搜索。如需进一步定位，改用 shell_exec grep -r 或 find 命令。",
                    data: ["query": query, "cached": "true"]
                )
            }
        }

        return nil
    }

    // MARK: - Result Processing

    private static func processResults(
        request: ResultProcessingRequest,
        state: inout PipelineState,
        hadFailure: inout Bool,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        for executionResult in request.toolCallResults {
            let shouldContinue = await processExecutionResult(
                executionResult,
                request: request,
                state: &state,
                hadFailure: &hadFailure,
                onStep: onStep
            )
            if shouldContinue {
                continue
            }
        }
    }

    private struct ProcessedToolResult {
        let index: Int
        let toolResult: ToolResult
        let recoveryPlan: RecoveryPlan?
        let callStep: TaskStep
        let toolName: String
        let toolParams: [String: String]
        let resultParams: [String: String]
        let callId: String
        let displayText: String

        init(_ executionResult: ToolCallExecutionResult, callSteps: [ToolCallEntry]) {
            index = executionResult.responseIndex
            toolResult = executionResult.result
            recoveryPlan = executionResult.recoveryPlan
            callStep = callSteps[index].callStep
            toolName = callStep.toolName ?? "tool"
            toolParams = callStep.toolParams ?? [:]
            resultParams = AgentLoop.resultStepParams(toolName: toolName, arguments: toolParams, result: toolResult)
            callId = callStep.toolCallId ?? "call_\(index)"
            displayText = ToolResultFormatter.displayText(toolName: toolName, arguments: toolParams, result: toolResult)
        }
    }

    private static func processExecutionResult(
        _ executionResult: ToolCallExecutionResult,
        request: ResultProcessingRequest,
        state: inout PipelineState,
        hadFailure: inout Bool,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        let processed = ProcessedToolResult(executionResult, callSteps: request.callSteps)
        emitReviewOutputs(processed, state: &state, onStep: onStep)
        emitToolResultStep(processed, state: &state, onStep: onStep)
        recordToolOutcome(processed, config: request.config, state: state)
        if await recoveredIfPossible(processed, request: request, state: &state, hadFailure: &hadFailure, onStep: onStep) {
            return true
        }
        updateFailureTracking(processed, state: &state, hadFailure: &hadFailure)
        updateMemory(toolName: processed.toolName, callStep: processed.callStep, toolResult: processed.toolResult, state: &state)
        let extraContent = await postProcessingContent(processed, request: request, state: &state, onStep: onStep)
        appendToolResultMessage(processed, extraContent: extraContent, config: request.config, state: &state)
        return false
    }

    private static func emitReviewOutputs(
        _ processed: ProcessedToolResult,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        if processed.toolResult.success,
            AgentLoop.isFileChangeTool(processed.toolName),
            let data = processed.toolResult.data {
            emitReviewSteps(
                request: ReviewStepEmissionRequest(
                    data: data,
                    toolName: processed.toolName,
                    toolParams: processed.toolParams,
                    callId: processed.callId
                ),
                state: &state,
                onStep: onStep
            )
        }
        emitDocumentReviewIfNeeded(processed, state: &state, onStep: onStep)
    }

    private static func emitDocumentReviewIfNeeded(
        _ processed: ProcessedToolResult,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard processed.toolResult.success,
            processed.toolName == "document.transform",
            let action = processed.toolResult.data?["action"],
            ["apply", "copy", "render"].contains(action),
            let outputPath = processed.toolResult.data?["pdfPath"] ?? processed.toolResult.data?["outputPath"]
        else {
            return
        }
        let reviewStep = TaskStep(
            kind: .reviewRequest,
            text: "已生成文档（可回滚）：\(outputPath)",
            toolName: processed.toolName,
            toolParams: processed.resultParams,
            toolCallId: processed.callId,
            isCollapsible: false,
            isCollapsed: false,
            diffFilePath: outputPath,
            approved: true
        )
        state.task.steps.append(reviewStep)
        onStep(reviewStep)
    }

    private static func emitToolResultStep(
        _ processed: ProcessedToolResult,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard processed.toolResult.data?["streamed"] != "true" else { return }
        let shouldShowFullOutput = ["shell.exec", "verify.build"].contains(processed.toolName)
        let stepText = toolResultStepText(processed, shouldShowFullOutput: shouldShowFullOutput)
        let resultStep = TaskStep(
            kind: .toolResult,
            text: stepText,
            toolName: processed.toolName,
            toolParams: processed.resultParams,
            toolCallId: processed.callId,
            isCollapsible: true,
            isCollapsed: processed.toolResult.success ? !shouldShowFullOutput : false,
            isFailure: !processed.toolResult.success
        )
        state.task.steps.append(resultStep)
        onStep(resultStep)
    }

    private static func toolResultStepText(
        _ processed: ProcessedToolResult,
        shouldShowFullOutput: Bool
    ) -> String {
        let stepTextLimit = 4000
        let rawStepText = shouldShowFullOutput ? processed.toolResult.output : processed.displayText
        let stepText =
            rawStepText.count > stepTextLimit
            ? String(rawStepText.prefix(stepTextLimit)) + "\n\n… 共 \(rawStepText.count) 字，完整内容已发送给模型"
            : rawStepText
        guard !processed.toolResult.success else { return stepText }
        let errorDetail = processed.toolResult.error ?? processed.toolResult.output.prefix(200).description
        let hint = diagnosticHintForFailure(toolName: processed.toolName, error: errorDetail)
        return hint.isEmpty ? stepText : "\(stepText)\n\n\(hint)"
    }

    private static func recordToolOutcome(
        _ processed: ProcessedToolResult,
        config: AgentLoop.Config,
        state: PipelineState
    ) {
        TaskOutcomeRecorder.shared.recordToolOutcome(
            taskID: state.task.id.uuidString,
            toolName: processed.toolName,
            modelName: config.modelName,
            success: processed.toolResult.success,
            durationSeconds: processed.toolResult.data?["durationSeconds"].flatMap(Double.init) ?? 0,
            wasRetry: processed.recoveryPlan != nil
        )
    }

    private static func recoveredIfPossible(
        _ processed: ProcessedToolResult,
        request: ResultProcessingRequest,
        state: inout PipelineState,
        hadFailure: inout Bool,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        guard !processed.toolResult.success, let recoveryPlan = processed.recoveryPlan else { return false }
        let recovered = await executeRecoveryPlan(
            request: RecoveryPlanExecutionRequest(
                plan: recoveryPlan,
                originalToolName: processed.toolName,
                config: request.config,
                toolRegistry: request.toolRegistry
            ),
            state: &state,
            onStep: onStep
        )
        if recovered {
            hadFailure = false
        }
        return recovered
    }

    private static func updateFailureTracking(
        _ processed: ProcessedToolResult,
        state: inout PipelineState,
        hadFailure: inout Bool
    ) {
        let target = AgentLoop.circuitBreakerTarget(for: processed.callStep)
        guard !processed.toolResult.success else {
            state.toolFailureCounts["\(processed.toolName):\(target)"] = 0
            return
        }
        hadFailure = true
        let failKey = "\(processed.toolName):\(target)"
        state.toolFailureCounts[failKey, default: 0] += 1
        let failCount = state.toolFailureCounts[failKey] ?? 1
        appendFailureGuidance(processed, target: target, failCount: failCount, state: &state)
    }

    private static func appendFailureGuidance(
        _ processed: ProcessedToolResult,
        target: String,
        failCount: Int,
        state: inout PipelineState
    ) {
        let errorDetail = processed.toolResult.error ?? processed.toolResult.output.prefix(200).description
        let diagnosticHint = diagnosticHintForFailure(toolName: processed.toolName, error: errorDetail)
        if processed.toolName == "file.edit" && failCount == 1 {
            appendFileEditFailureGuidance(target: target, errorDetail: errorDetail, state: &state)
        } else if isDeterministicUnsupportedFileFailure(toolName: processed.toolName, result: processed.toolResult) {
            appendCircuitBreakerGuidance(processed.toolName, target: target, errorDetail: errorDetail, diagnosticHint: diagnosticHint, state: &state)
        } else if failCount >= state.maxRepeatedFailures {
            appendRepeatedFailureGuidance(
                FailureGuidanceContext(
                    toolName: processed.toolName,
                    target: target,
                    failCount: failCount,
                    errorDetail: errorDetail,
                    diagnosticHint: diagnosticHint
                ),
                state: &state
            )
        }
    }

    private struct FailureGuidanceContext {
        let toolName: String
        let target: String
        let failCount: Int
        let errorDetail: String
        let diagnosticHint: String
    }

    private static func appendFileEditFailureGuidance(target: String, errorDetail: String, state: inout PipelineState) {
        let fileName = URL(fileURLWithPath: target).lastPathComponent
        state.messages.append(
            ChatMessage(
                role: "system",
                content: """
                    编排层：file.edit 对 \(fileName) 匹配失败（原因：\(errorDetail)）。
                    下次对该文件直接使用 file_write 全量写入（先 file_read 获取当前内容，在内容中做修改，然后 file_write 写回完整内容）。
                    不要再尝试 file_edit。
                    """
            ))
    }

    private static func appendCircuitBreakerGuidance(
        _ toolName: String,
        target: String,
        errorDetail: String,
        diagnosticHint: String,
        state: inout PipelineState
    ) {
        let alternatives = AgentLoop.suggestAlternatives(for: toolName, target: target)
        state.circuitBrokenTools.insert("\(toolName):\(target.prefix(60))")
        state.messages.append(
            ChatMessage(
                role: "system",
                content: "⚠️ \(toolName) 对 \(target) 返回确定性失败：\(errorDetail)\n\(diagnosticHint)\n替代方案：\(alternatives)\n不要再用同一工具和同一参数重试。"
            ))
    }

    private static func appendRepeatedFailureGuidance(_ context: FailureGuidanceContext, state: inout PipelineState) {
        state.circuitBrokenTools.insert("\(context.toolName):\(context.target.prefix(60))")
        let alternatives = AgentLoop.suggestAlternatives(for: context.toolName, target: context.target)
        state.messages.append(
            ChatMessage(
                role: "system",
                content:
                    [
                        "⚠️ \(context.toolName) 对 \(context.target) 已失败 \(context.failCount) 次。",
                        "最近失败原因：\(context.errorDetail)",
                        context.diagnosticHint,
                        "替代方案：\(alternatives)",
                        "禁止再用相同参数重试。"
                    ].joined(separator: "\n")
            ))
    }

    private static func postProcessingContent(
        _ processed: ProcessedToolResult,
        request: ResultProcessingRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        let autoVerifyContent = await autoVerifyContentIfNeeded(processed, request: request, state: &state, onStep: onStep)
        let chainedContent = await chainedReadContentIfNeeded(processed, request: request, state: &state, onStep: onStep)
        return chainedContent + autoVerifyContent
    }

    private static func autoVerifyContentIfNeeded(
        _ processed: ProcessedToolResult,
        request: ResultProcessingRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        guard AgentLoop.isFileChangeTool(processed.callStep.toolName ?? ""), processed.toolResult.success else { return "" }
        return await runAutoVerify(
            request: AutoVerifyRequest(
                callStep: processed.callStep,
                toolResult: processed.toolResult,
                config: request.config,
                toolRegistry: request.toolRegistry
            ),
            state: &state,
            onStep: onStep
        )
    }

    private static func chainedReadContentIfNeeded(
        _ processed: ProcessedToolResult,
        request: ResultProcessingRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        guard processed.callStep.toolName == "code.search",
            processed.toolResult.success,
            !processed.toolResult.output.hasPrefix("未找到")
        else {
            return ""
        }
        return await runChainedRead(
            toolResult: processed.toolResult,
            state: &state,
            config: request.config,
            toolRegistry: request.toolRegistry,
            onStep: onStep
        )
    }

    private static func appendToolResultMessage(
        _ processed: ProcessedToolResult,
        extraContent: String,
        config: AgentLoop.Config,
        state: inout PipelineState
    ) {
        let toolResultLimit = dynamicTokenLimit(
            toolName: processed.callStep.toolName ?? "",
            success: processed.toolResult.success,
            config: config
        )
        let resultContent =
            ToolResultFormatter.modelContent(
                toolName: processed.callStep.toolName ?? "tool",
                result: processed.toolResult,
                limit: toolResultLimit
            ) + extraContent
        if state.usesOllamaChat {
            state.messages.append(
                ChatMessage(
                    role: "user",
                    content: "工具 \(processed.callStep.toolName ?? "tool") 执行结果：\n\(resultContent)"
                ))
        } else {
            state.messages.append(
                ChatMessage(
                    role: "tool",
                    content: resultContent,
                    toolCallId: processed.callStep.toolCallId
                ))
        }
    }

    // MARK: - Recovery Plan Execution

    private static func executeRecoveryPlan(
        request: RecoveryPlanExecutionRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        // Build action chain: primary action + fallback chain
        let actions = [request.plan.action] + request.plan.fallbackChain
        for action in actions {
            switch await executeRecoveryAction(action, request: request, state: &state, onStep: onStep) {
            case .succeeded:
                return true
            case .stopped:
                return false
            case .continueNext:
                continue
            }
        }
        return false
    }

    private enum RecoveryActionOutcome {
        case succeeded
        case stopped
        case continueNext
    }

    private static func executeRecoveryAction(
        _ action: RecoveryAction,
        request: RecoveryPlanExecutionRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> RecoveryActionOutcome {
        switch action {
        case .fallbackTool(let fallbackName, let fallbackJSON):
            return await executeFallbackRecovery(
                fallbackName: fallbackName,
                fallbackJSON: fallbackJSON,
                request: request,
                state: &state,
                onStep: onStep
            )
        case .retryWithModifiedJSON(let modifiedJSON):
            return await executeModifiedJSONRecovery(modifiedJSON, request: request, state: &state)
        case .retryWithModifiedParams(let params):
            let jsonData = try? JSONSerialization.data(withJSONObject: params)
            let jsonStr = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await executeModifiedJSONRecovery(jsonStr, request: request, state: &state, successPrefix: "编排层修正参数后重试")
        case .retry:
            return .continueNext
        case .askUser(let question):
            state.messages.append(ChatMessage(role: "system", content: "编排层：\(request.originalToolName) 需要用户确认：\(question)"))
            return .stopped
        case .abort(let reason):
            state.messages.append(ChatMessage(role: "system", content: "编排层：\(request.originalToolName) 自动恢复放弃：\(reason)"))
            return .stopped
        }
    }

    private static func executeFallbackRecovery(
        fallbackName: String,
        fallbackJSON: String,
        request: RecoveryPlanExecutionRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> RecoveryActionOutcome {
        let canonicalName = ToolNameCodec.canonicalName(fallbackName)
        guard isToolAllowed(canonicalName, config: request.config),
            let tool = request.toolRegistry.tool(named: fallbackName)
        else {
            return .continueNext
        }
        let callId = "call_recovery_\(canonicalName)_\(UUID().uuidString.prefix(8))"
        emitRecoveryCallStep(canonicalName: canonicalName, fallbackJSON: fallbackJSON, callId: callId, state: &state, onStep: onStep)
        let result = await recoveryToolResult(
            tool: tool,
            canonicalName: canonicalName,
            fallbackJSON: fallbackJSON,
            state: state
        )
        emitRecoveryResultStep(result: result, canonicalName: canonicalName, callId: callId, state: &state, onStep: onStep)
        guard result.success else { return .continueNext }
        appendRecoverySuccessMessage(
            prefix: "自动恢复工具 \(canonicalName) 执行成功（原工具 \(request.originalToolName) 失败后自动降级）。请基于这些结果继续。",
            canonicalName: canonicalName,
            result: result,
            config: request.config,
            state: &state
        )
        return .succeeded
    }

    private static func emitRecoveryCallStep(
        canonicalName: String,
        fallbackJSON: String,
        callId: String,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let callStep = TaskStep(
            kind: .toolCall,
            text: "自动恢复：\(canonicalName)",
            toolName: canonicalName,
            toolParams: AgentLoop.displayParamsFromJSON(fallbackJSON),
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(callStep)
        onStep(callStep)
    }

    private static func recoveryToolResult(
        tool: any LaicaiTool,
        canonicalName: String,
        fallbackJSON: String,
        state: PipelineState
    ) async -> ToolResult {
        guard !AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) else {
            return AgentLoop.approvalRequiredToolResult(toolName: canonicalName)
        }
        let validated = await ValidationEngine.executeWithValidationJSON(
            tool: tool,
            argumentsJSON: fallbackJSON,
            context: state.taskContext,
            maxRetries: 1
        )
        return validated.result
    }

    private static func emitRecoveryResultStep(
        result: ToolResult,
        canonicalName: String,
        callId: String,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let resultStep = TaskStep(
            kind: .toolResult,
            text: result.success ? "自动恢复成功" : "自动恢复失败",
            toolName: canonicalName,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true,
            isFailure: !result.success
        )
        state.task.steps.append(resultStep)
        onStep(resultStep)
    }

    private static func executeModifiedJSONRecovery(
        _ modifiedJSON: String,
        request: RecoveryPlanExecutionRequest,
        state: inout PipelineState,
        successPrefix: String = "编排层自动修正参数后重试"
    ) async -> RecoveryActionOutcome {
        let canonicalName = ToolNameCodec.canonicalName(request.originalToolName)
        guard let tool = request.toolRegistry.tool(named: ToolNameCodec.apiName(canonicalName)),
            !AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool)
        else {
            return .continueNext
        }
        let (result, _) = await ValidationEngine.executeWithValidationJSON(
            tool: tool,
            argumentsJSON: modifiedJSON,
            context: state.taskContext,
            maxRetries: 1
        )
        guard result.success else { return .continueNext }
        appendRecoverySuccessMessage(
            prefix: "\(successPrefix) \(canonicalName) 成功：",
            canonicalName: canonicalName,
            result: result,
            config: request.config,
            state: &state
        )
        return .succeeded
    }

    private static func appendRecoverySuccessMessage(
        prefix: String,
        canonicalName: String,
        result: ToolResult,
        config: AgentLoop.Config,
        state: inout PipelineState
    ) {
        let content = ToolResultFormatter.modelContent(toolName: canonicalName, result: result, limit: config.maxTokensPerTurn)
        state.messages.append(ChatMessage(role: "user", content: "\(prefix)\n\n\(content)"))
    }

    // MARK: - Review Step Emission

    private static func emitReviewSteps(
        request: ReviewStepEmissionRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let reviewSteps = AgentLoop.fileChangeReviewSteps(
            data: request.data,
            toolName: request.toolName,
            toolParams: request.toolParams,
            callId: request.callId,
            workspaceRoot: state.taskContext.workspaceRoot
        )
        for reviewStep in reviewSteps {
            state.task.steps.append(reviewStep)
            onStep(reviewStep)
        }
    }

    // MARK: - Memory Update

    private static func updateMemory(toolName: String, callStep: TaskStep, toolResult: ToolResult, state: inout PipelineState) {
        if toolResult.success {
            updateSuccessfulToolMemory(toolName: toolName, callStep: callStep, toolResult: toolResult, state: &state)
        } else {
            state.taskContext.memory.failedTools.append(callStep.toolName ?? "unknown")
        }
        updateDeliveryMemory(callStep: callStep, toolResult: toolResult, state: &state)
    }

    private static func updateSuccessfulToolMemory(
        toolName: String,
        callStep: TaskStep,
        toolResult: ToolResult,
        state: inout PipelineState
    ) {
        switch toolName {
        case "file.read", "file.extract":
            updateReadMemory(callStep: callStep, toolResult: toolResult, state: &state)
        case "code.search":
            if let query = callStep.toolParams?["query"] {
                state.taskContext.memory.searchedQueries.append(query)
            }
        default:
            break
        }
    }

    private static func updateReadMemory(callStep: TaskStep, toolResult: ToolResult, state: inout PipelineState) {
        guard let path = callStep.toolParams?["path"] else { return }
        if !state.taskContext.memory.readFiles.contains(path) {
            state.taskContext.memory.readFiles.append(path)
        }
        let summary = fileSummary(from: toolResult.output)
        if !summary.isEmpty {
            state.taskContext.memory.fileSummaries[path] = String(summary.prefix(300))
        }
        if toolResult.output.count < 100_000 {
            state.taskContext.memory.fileContentCache[path] = toolResult.output
        }
        precacheDirectorySummary(for: path, state: &state)
    }

    private static func fileSummary(from output: String) -> String {
        let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
        let signatures =
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
            .prefix(8).joined(separator: "; ")
        guard signatures.isEmpty else { return signatures }
        return output.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
            .joined(separator: " … ")
    }

    private static func precacheDirectorySummary(for path: String, state: inout PipelineState) {
        let dir = (path as NSString).deletingLastPathComponent
        let dirCacheKey = "__dir__:\(dir)"
        guard !dir.isEmpty,
            state.taskContext.memory.fileSummaries[dirCacheKey] == nil,
            let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else {
            return
        }
        let relevantSiblings = relevantSiblingFiles(siblings, sameExtensionAs: path)
        if !relevantSiblings.isEmpty {
            state.taskContext.memory.fileSummaries[dirCacheKey] = relevantSiblings.joined(separator: ", ")
        }
    }

    private static func relevantSiblingFiles(_ siblings: [String], sameExtensionAs path: String) -> [String] {
        let ext = (path as NSString).pathExtension.lowercased()
        let knownExts = [
            "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java",
            "c", "cpp", "h", "m", "mm", "md", "json", "yaml", "yml", "toml"
        ]
        return Array(
            siblings.filter { file in
                let fExt = (file as NSString).pathExtension.lowercased()
                return fExt == ext || knownExts.contains(fExt)
            }.sorted().prefix(30))
    }

    private static func updateDeliveryMemory(callStep: TaskStep, toolResult: ToolResult, state: inout PipelineState) {
        if AgentLoop.isFileChangeTool(callStep.toolName ?? ""), toolResult.success {
            updateFileChangeDeliveryMemory(callStep: callStep, toolResult: toolResult, state: &state)
        } else if isSuccessfulDocumentDelivery(callStep: callStep, toolResult: toolResult) {
            updateDocumentDeliveryMemory(toolResult: toolResult, state: &state)
        } else if isSuccessfulSkillDelivery(callStep: callStep, toolResult: toolResult) {
            updateSkillDeliveryMemory(callStep: callStep, toolResult: toolResult, state: &state)
        }
    }

    private static func updateFileChangeDeliveryMemory(
        callStep: TaskStep,
        toolResult: ToolResult,
        state: inout PipelineState
    ) {
        let path = AgentLoop.pathForFileChange(callStep: callStep, toolResult: toolResult)
        guard !path.isEmpty else { return }
        state.taskContext.memory.appendDecision("已写入：\(path)")
        state.taskContext.memory.fileContentCache.removeValue(forKey: path)
        let fullPath = (state.taskContext.workspaceRoot as NSString).appendingPathComponent(path)
        state.taskContext.memory.fileContentCache.removeValue(forKey: fullPath)
    }

    private static func isSuccessfulDocumentDelivery(callStep: TaskStep, toolResult: ToolResult) -> Bool {
        guard callStep.toolName == "document.transform",
            toolResult.success,
            let action = toolResult.data?["action"]
        else {
            return false
        }
        return ["workspace", "apply", "copy", "render"].contains(action)
    }

    private static func updateDocumentDeliveryMemory(toolResult: ToolResult, state: inout PipelineState) {
        guard let action = toolResult.data?["action"],
            let path = toolResult.data?["workflowPath"] ?? toolResult.data?["pdfPath"] ?? toolResult.data?["outputPath"]
        else {
            return
        }
        let label = action == "workspace" ? "文档交付工作区" : (action == "render" ? "已渲染文档" : "已生成文档")
        state.taskContext.memory.appendDecision("\(label)：\(path)")
        state.taskContext.memory.fileContentCache.removeValue(forKey: path)
    }

    private static func isSuccessfulSkillDelivery(callStep: TaskStep, toolResult: ToolResult) -> Bool {
        callStep.toolName == "skill.manage"
            && toolResult.success
            && (toolResult.data?["action"] ?? callStep.toolParams?["action"]) != nil
    }

    private static func updateSkillDeliveryMemory(callStep: TaskStep, toolResult: ToolResult, state: inout PipelineState) {
        let action = toolResult.data?["action"] ?? callStep.toolParams?["action"] ?? ""
        guard ["create", "update"].contains(action) else { return }
        let name = toolResult.data?["name"] ?? callStep.toolParams?["name"] ?? "技能"
        let path = toolResult.data?["path"].map { "：\($0)" } ?? ""
        state.taskContext.memory.appendDecision("已沉淀技能：\(name)\(path)")
    }

    // MARK: - Auto-Verify

    private static func runAutoVerify(
        request: AutoVerifyRequest,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        let callStep = request.callStep
        let toolResult = request.toolResult
        let config = request.config
        let toolRegistry = request.toolRegistry
        let writtenPath = AgentLoop.pathForFileChange(callStep: callStep, toolResult: toolResult)
        let ext = (writtenPath as NSString).pathExtension.lowercased()
        let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
        let hasBuildSys = ValidationEngine.suggestVerificationCommand(workspaceRoot: state.taskContext.workspaceRoot) != nil
        guard codeExts.contains(ext) && hasBuildSys && isToolAllowed("verify.build", config: config) else { return "" }
        guard let verifyTool = toolRegistry.tool(named: "verify_build") ?? toolRegistry.tool(named: "verify.build") else { return "" }

        let verifyStep = TaskStep(kind: .toolCall, text: "验证编译", toolName: "verify.build", isCollapsible: true, isCollapsed: true)
        if config.emitDebugSteps {
            state.task.steps.append(verifyStep)
            onStep(verifyStep)
        }
        let verifyResult = try? await verifyTool.execute(argumentsJSON: "{}", context: state.taskContext)
        guard let verifyResult else { return "" }

        let verifyStepResult = TaskStep(
            kind: .toolResult, text: verifyResult.success ? "✅ 编译通过" : "❌ 编译失败", toolName: "verify.build", isCollapsible: true,
            isCollapsed: verifyResult.success)
        state.task.steps.append(verifyStepResult)
        if config.emitDebugSteps || !verifyResult.success {
            onStep(verifyStepResult)
        }

        if verifyResult.success {
            return "\n\n✅ 自动验证：编译通过。"
        } else {
            let errLines = verifyResult.output.components(separatedBy: .newlines)
                .filter { $0.lowercased().contains("error:") || $0.lowercased().contains("fatal") }
                .prefix(8).joined(separator: "\n")
            return "\n\n❌ 自动验证：编译失败。关键错误：\n\(errLines)\n\n请根据错误继续修复后再次验证。"
        }
    }

    // MARK: - Chained Read

    private static func runChainedRead(
        toolResult: ToolResult,
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
        guard let bestPath = AgentLoop.firstReadablePath(inSearchOutput: toolResult.output, workspaceRoot: state.taskContext.workspaceRoot),
            !state.taskContext.memory.readFiles.contains(bestPath),
            let readTool = toolRegistry.tool(named: "file_read")
        else { return "" }

        let readJSON = AgentLoop.bootstrapReadArgumentsJSON(for: bestPath)
        let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: state.taskContext)
        guard let readResultValue = readResult, readResultValue.success else { return "" }

        state.taskContext.memory.readFiles.append(bestPath)
        if readResultValue.output.count < 100_000 {
            state.taskContext.memory.fileContentCache[bestPath] = readResultValue.output
        }
        let chainStep = TaskStep(kind: .toolResult, text: "已读取：\(bestPath)", toolName: "file.read", isCollapsible: true, isCollapsed: true)
        if config.emitDebugSteps {
            state.task.steps.append(chainStep)
            onStep(chainStep)
        }
        let readContent = ToolResultFormatter.modelContent(toolName: "file.read", result: readResultValue, limit: max(2000, config.maxTokensPerTurn / 2))
        return "\n\n已读取最相关文件 \(bestPath)：\n\(readContent)"
    }

    // MARK: - Dynamic Token Limit

    private static func dynamicTokenLimit(toolName: String, success: Bool, config: AgentLoop.Config) -> Int {
        if !success { return config.maxTokensPerTurn }
        if toolName == "file.read" { return config.maxTokensPerTurn }
        if toolName == "document.transform" { return min(max(config.maxTokensPerTurn, 8000), 40_000) }
        if toolName == "verify.build" { return 200 }
        if toolName == "workspace.index" || toolName == "code.search" { return min(3000, config.maxTokensPerTurn) }
        if toolName == "shell.exec" { return config.maxTokensPerTurn / 2 }
        return config.maxTokensPerTurn
    }

    // MARK: - Utility

    private static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        AgentLoop.allowsTool(name, allowedTools: config.allowedTools)
    }

    private static func isDeterministicUnsupportedFileFailure(toolName: String, result: ToolResult) -> Bool {
        guard ["file.read", "file.extract", "document.transform"].contains(toolName) else { return false }
        let code = result.error ?? ""
        return code == "unsupported_binary_file" || code == "unsupported_file_type"
    }

    /// Generate actionable diagnostic hint based on error type.
    private static func diagnosticHintForFailure(toolName: String, error: String) -> String {
        let lower = error.lowercased()
        let hintRules: [(keywords: [String], hint: String)] = [
            (["timeout", "超时"], "诊断：请求超时。可能是网络不稳定或服务端响应慢。"),
            (["connection", "连接", "cannot find host"], "诊断：连接失败。请检查网络连接和服务端地址是否正确。"),
            (["429", "rate limit", "限流"], "诊断：触发限流。请稍后重试或降低请求频率。"),
            (["401", "403", "unauthorized", "forbidden"], "诊断：认证失败。请检查 API Key 是否正确且未过期。"),
            (["404", "not found"], "诊断：资源不存在。请检查路径或端点是否正确。"),
            (["500", "502", "503", "server error"], "诊断：服务端错误。可能是服务暂时不可用，请稍后重试。"),
            (["no such file", "文件不存在", "not found"], "诊断：文件不存在。请先用 file_read 确认路径，或用 file_write 创建新文件。"),
            (["permission", "权限"], "诊断：权限不足。请检查文件权限或工作区访问权限。"),
            (["encoding", "编码", "utf"], "诊断：编码问题。文件可能包含非文本内容。"),
            (["match", "匹配"], "诊断：内容匹配失败。请先 file_read 获取最新内容，再用新内容重试。"),
            (["not allowed", "blocked", "禁止"], "诊断：工具被阻止。请检查执行级别设置。")
        ]
        return hintRules.first { rule in
            rule.keywords.contains { lower.contains($0) }
        }?.hint ?? ""
    }
}
