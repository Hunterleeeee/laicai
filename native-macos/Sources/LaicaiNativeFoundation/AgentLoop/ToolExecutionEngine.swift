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

@MainActor
struct ToolExecutionEngine {

    typealias CallEntry = (Int, TaskStep, String, String, String, [String: String])
    // (index, callStep, apiToolName, argumentsJSON, callId, toolParams)

    struct ExecutionResult {
        var callSteps: [CallEntry]
        var toolCallResults: [(Int, ToolResult, RecoveryPlan?)]
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
        var callSteps: [CallEntry] = []
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
            callSteps.append((index, callStep, apiToolName, argumentsJSON, callId, toolParams))
        }

        // Step 2: Execute in smart batches
        // Note: uses sequential execution per batch to avoid inout-in-escaping-closure.
        // scheduledToolCallBatches already groups by exclusivity (read-only batches can be parallel in future).
        var toolCallResults: [(Int, ToolResult, RecoveryPlan?)] = []
        for batch in AgentLoop.scheduledToolCallBatches(callSteps) {
            for (index, callStep, apiToolName, argumentsJSON, _, _) in batch {
                let toolName = callStep.toolName ?? apiToolName
                let result = await executeSingleTool(
                    index: index,
                    callStep: callStep,
                    toolName: toolName,
                    apiToolName: apiToolName,
                    argumentsJSON: argumentsJSON,
                    taskContext: state.taskContext,
                    circuitBrokenTools: state.circuitBrokenTools,
                    config: config,
                    toolRegistry: toolRegistry
                )
                toolCallResults.append(result)
            }
        }
        toolCallResults.sort { $0.0 < $1.0 }

        // Step 3: Process results
        var hadFailure = false
        await processResults(
            callSteps: callSteps,
            toolCallResults: toolCallResults,
            state: &state,
            config: config,
            toolRegistry: toolRegistry,
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

    private static func executeSingleTool(
        index: Int,
        callStep: TaskStep,
        toolName: String,
        apiToolName: String,
        argumentsJSON: String,
        taskContext: TaskContext,
        circuitBrokenTools: Set<String>,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry
    ) async -> (Int, ToolResult, RecoveryPlan?) {
        var toolResult: ToolResult!
        var recoveryPlan: RecoveryPlan?

        // F2: Tool call interception & rewrite
        var argumentsJSON = argumentsJSON
        argumentsJSON = AgentLoop.rewriteToolArguments(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            workspaceRoot: taskContext.workspaceRoot
        )

        // G4: Smart cache hit — file.read on already-cached file
        if let cached = checkCacheHit(toolName: toolName, callStep: callStep, taskContext: taskContext) {
            return (index, cached, nil)
        }

        // Pre-hook
        let preHookOutput = await HookEngine.shared.runPreHooks(
            toolName: toolName,
            params: callStep.toolParams ?? [:],
            context: taskContext
        )
        if let preOut = preHookOutput, preOut.contains("⚠️") {
            toolResult = ToolResult(output: preOut, success: false, error: "pre_hook_failed")
        } else if !isToolAllowed(toolName, config: config) {
            toolResult = ToolResult(
                output: "已阻止工具调用：\(toolName)。当前执行级别只允许理解意图和只读分析；如果要运行命令、构建、测试或修改文件，请切换到「执行」。",
                success: false,
                error: "tool_not_allowed"
            )
        } else {
            // Circuit breaker check + auto-repair
            let cbTarget = AgentLoop.circuitBreakerTarget(for: callStep)
            let cbSig = "\(toolName):\(cbTarget.prefix(60))"
            if circuitBrokenTools.contains(cbSig) {
                toolResult = await AgentLoop.attemptCircuitBreakerRepair(
                    toolName: toolName,
                    callStep: callStep,
                    taskContext: taskContext,
                    toolRegistry: toolRegistry
                )
            }

            // Normal execution
            if toolResult == nil, let tool = toolRegistry.tool(named: apiToolName) {
                if AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: toolName, tool: tool) {
                    toolResult = AgentLoop.approvalRequiredToolResult(toolName: toolName)
                } else if AgentLoop.isFileChangeTool(toolName: toolName, tool: tool) {
                    AgentLoop.gitCheckpoint(
                        workspaceRoot: config.workspaceRoot,
                        paths: AgentLoop.checkpointPaths(
                            toolName: toolName,
                            arguments: AgentLoop.displayParamsFromJSON(argumentsJSON),
                            workspaceRoot: config.workspaceRoot
                        )
                    )
                }

                if toolResult == nil {
                    let validation: ValidationEngine.ValidationResult
                    if toolName == "shell.exec" {
                        let streamStepID = UUID()
                        let callID = callStep.toolCallId ?? "call_\(index)"
                        let result = await AgentLoop.executeShellStreamingViaNotification(
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
                    if !toolResult.success {
                        toolResult = await AgentLoop.attemptAutoRecovery(
                            toolName: toolName,
                            callStep: callStep,
                            argumentsJSON: argumentsJSON,
                            currentResult: toolResult,
                            recoveryPlan: &recoveryPlan,
                            validation: validation,
                            taskContext: taskContext,
                            config: config,
                            toolRegistry: toolRegistry
                        )
                    }
                }
            } else if toolResult == nil {
                toolResult = ToolResult(
                    output: "未知工具：\(toolName)",
                    success: false,
                    error: "unknown_tool"
                )
            }
        }

        // Safety net
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

    // MARK: - Cache Hit Check

    private static func checkCacheHit(toolName: String, callStep: TaskStep, taskContext: TaskContext) -> ToolResult? {
        // file.read cache
        if toolName == "file.read",
           let readPath = callStep.toolParams?["path"],
           callStep.toolParams?["offset"] == nil,
           let cached = taskContext.memory.fileContentCache[readPath] ?? taskContext.memory.fileContentCache[(taskContext.workspaceRoot as NSString).appendingPathComponent(readPath)] {
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
            let isSimilar = !isDuplicate && taskContext.memory.searchedQueries.contains(where: {
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
        callSteps: [CallEntry],
        toolCallResults: [(Int, ToolResult, RecoveryPlan?)],
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        hadFailure: inout Bool,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        for (index, toolResult, recoveryPlan) in toolCallResults {
            let callStep = callSteps[index].1
            let toolName = callStep.toolName ?? "tool"
            let toolParams = callStep.toolParams ?? [:]
            let resultParams = AgentLoop.resultStepParams(toolName: toolName, arguments: toolParams, result: toolResult)
            let callId = callStep.toolCallId ?? "call_\(index)"

            let displayText = ToolResultFormatter.displayText(
                toolName: toolName,
                arguments: toolParams,
                result: toolResult
            )

            // Emit review steps for file changes
            if toolResult.success, AgentLoop.isFileChangeTool(toolName), let data = toolResult.data {
                emitReviewSteps(
                    data: data,
                    toolName: toolName,
                    toolParams: toolParams,
                    callId: callId,
                    state: &state,
                    onStep: onStep
                )
            }
            if toolResult.success,
               toolName == "document.transform",
               let action = toolResult.data?["action"],
               ["apply", "copy", "render"].contains(action),
               let outputPath = toolResult.data?["pdfPath"] ?? toolResult.data?["outputPath"] {
                let reviewStep = TaskStep(
                    kind: .reviewRequest,
                    text: "已生成文档（可回滚）：\(outputPath)",
                    toolName: toolName,
                    toolParams: resultParams,
                    toolCallId: callId,
                    isCollapsible: false,
                    isCollapsed: false,
                    diffFilePath: outputPath,
                    approved: true
                )
                state.task.steps.append(reviewStep)
                onStep(reviewStep)
            }

            // Emit result step (unless streamed)
            if toolResult.data?["streamed"] != "true" {
                let shouldShowFullOutput = ["shell.exec", "verify.build"].contains(toolName)
                let stepTextLimit = 4000
                let rawStepText = shouldShowFullOutput ? toolResult.output : displayText
                let stepText = rawStepText.count > stepTextLimit
                    ? String(rawStepText.prefix(stepTextLimit)) + "\n\n… 共 \(rawStepText.count) 字，完整内容已发送给模型"
                    : rawStepText
                let resultStep = TaskStep(
                    kind: .toolResult,
                    text: stepText,
                    toolName: toolName,
                    toolParams: resultParams,
                    toolCallId: callId,
                    isCollapsible: true,
                    isCollapsed: !shouldShowFullOutput,
                    isFailure: !toolResult.success
                )
                state.task.steps.append(resultStep)
                onStep(resultStep)
            }

            // Record tool-level outcome
            TaskOutcomeRecorder.shared.recordToolOutcome(
                taskID: state.task.id.uuidString,
                toolName: toolName,
                modelName: config.modelName,
                success: toolResult.success,
                durationSeconds: toolResult.data?["durationSeconds"].flatMap(Double.init) ?? 0,
                wasRetry: recoveryPlan != nil
            )

            // Handle recovery — execute the recovery plan inline
            if !toolResult.success, let recoveryPlan {
                let recovered = await executeRecoveryPlan(
                    plan: recoveryPlan,
                    originalToolName: toolName,
                    state: &state,
                    config: config,
                    toolRegistry: toolRegistry,
                    onStep: onStep
                )
                if recovered {
                    hadFailure = false // Recovery succeeded, don't count as failure
                }
            }

            // Circuit breaker tracking
            if !toolResult.success {
                hadFailure = true
                let target = AgentLoop.circuitBreakerTarget(for: callStep)
                let failKey = "\(toolName):\(target)"
                state.toolFailureCounts[failKey, default: 0] += 1
                let failCount = state.toolFailureCounts[failKey] ?? 1

                // file.edit is especially prone to failure — after 1st failure, strongly hint file.write
                if toolName == "file.edit" && failCount == 1 {
                    state.messages.append(ChatMessage(role: "system", content: "编排层：file.edit 对 \(URL(fileURLWithPath: target).lastPathComponent) 匹配失败。下次对该文件直接使用 file_write 全量写入（先 file_read 获取当前内容，在内容中做修改，然后 file_write 写回完整内容）。不要再尝试 file_edit。"))
                } else if isDeterministicUnsupportedFileFailure(toolName: toolName, result: toolResult) {
                    let alternatives = AgentLoop.suggestAlternatives(for: toolName, target: target)
                    state.circuitBrokenTools.insert("\(toolName):\(target.prefix(60))")
                    state.messages.append(ChatMessage(
                        role: "system",
                        content: "⚠️ \(toolName) 对 \(target) 返回确定性失败：\(toolResult.error ?? toolResult.output)。不要再用同一工具和同一参数重试。\n替代方案：\(alternatives)\n如果会话目标要求交付文件，必须改用可执行脚本/系统工具真实生成目标文件；不能只写方案或声称完成。"
                    ))
                } else if failCount >= state.maxRepeatedFailures {
                    state.circuitBrokenTools.insert("\(toolName):\(target.prefix(60))")
                    let alternatives = AgentLoop.suggestAlternatives(for: toolName, target: target)
                    let circuitMsg = "⚠️ \(toolName) 对 \(target) 已失败 \(failCount) 次，禁止再用相同参数重试。\n替代方案：\(alternatives)"
                    state.messages.append(ChatMessage(role: "system", content: circuitMsg))
                }
            } else {
                let target = AgentLoop.circuitBreakerTarget(for: callStep)
                state.toolFailureCounts["\(toolName):\(target)"] = 0
            }

            // Update task memory
            updateMemory(toolName: toolName, callStep: callStep, toolResult: toolResult, state: &state)

            // F1: Auto-verify after code writes
            var autoVerifyContent = ""
            if AgentLoop.isFileChangeTool(callStep.toolName ?? "") && toolResult.success {
                autoVerifyContent = await runAutoVerify(
                    callStep: callStep,
                    toolResult: toolResult,
                    state: &state,
                    config: config,
                    toolRegistry: toolRegistry,
                    onStep: onStep
                )
            }

            // C1: Proactive chained reads after search
            var chainedContent = ""
            if callStep.toolName == "code.search" && toolResult.success && !toolResult.output.hasPrefix("未找到") {
                chainedContent = await runChainedRead(
                    toolResult: toolResult,
                    state: &state,
                    config: config,
                    toolRegistry: toolRegistry,
                    onStep: onStep
                )
            }

            // F5: Dynamic token allocation per tool result
            let toolResultLimit = dynamicTokenLimit(toolName: callStep.toolName ?? "", success: toolResult.success, config: config)
            let resultContent = ToolResultFormatter.modelContent(
                toolName: callStep.toolName ?? "tool",
                result: toolResult,
                limit: toolResultLimit
            ) + chainedContent + autoVerifyContent

            // Append to messages
            if state.usesOllamaChat {
                state.messages.append(ChatMessage(
                    role: "user",
                    content: "工具 \(callStep.toolName ?? "tool") 执行结果：\n\(resultContent)"
                ))
            } else {
                state.messages.append(ChatMessage(
                    role: "tool",
                    content: resultContent,
                    toolCallId: callStep.toolCallId
                ))
            }
        }
    }

    // MARK: - Recovery Plan Execution

    private static func executeRecoveryPlan(
        plan: RecoveryPlan,
        originalToolName: String,
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool {
        // Build action chain: primary action + fallback chain
        let actions = [plan.action] + plan.fallbackChain
        for action in actions {
            switch action {
            case .fallbackTool(let fallbackName, let fallbackJSON):
                let canonicalName = ToolNameCodec.canonicalName(fallbackName)
                guard isToolAllowed(canonicalName, config: config),
                      let tool = toolRegistry.tool(named: fallbackName) else { continue }
                let params = AgentLoop.displayParamsFromJSON(fallbackJSON)
                let callId = "call_recovery_\(canonicalName)_\(UUID().uuidString.prefix(8))"
                let callStep = TaskStep(
                    kind: .toolCall,
                    text: "自动恢复：\(canonicalName)",
                    toolName: canonicalName,
                    toolParams: params,
                    toolCallId: callId,
                    isCollapsible: true,
                    isCollapsed: true
                )
                state.task.steps.append(callStep)
                onStep(callStep)
                let result: ToolResult
                if AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) {
                    result = AgentLoop.approvalRequiredToolResult(toolName: canonicalName)
                } else {
                    let validated = await ValidationEngine.executeWithValidationJSON(
                        tool: tool,
                        argumentsJSON: fallbackJSON,
                        context: state.taskContext,
                        maxRetries: 1
                    )
                    result = validated.result
                }
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
                if result.success {
                    let content = ToolResultFormatter.modelContent(toolName: canonicalName, result: result, limit: config.maxTokensPerTurn)
                    state.messages.append(ChatMessage(
                        role: "user",
                        content: "自动恢复工具 \(canonicalName) 执行成功（原工具 \(originalToolName) 失败后自动降级）。请基于这些结果继续。\n\n\(content)"
                    ))
                    return true
                }

            case .retryWithModifiedJSON(let modifiedJSON):
                let canonicalName = ToolNameCodec.canonicalName(originalToolName)
                guard let tool = toolRegistry.tool(named: ToolNameCodec.apiName(canonicalName)) else { continue }
                guard !AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) else {
                    continue
                }
                let (result, _) = await ValidationEngine.executeWithValidationJSON(
                    tool: tool,
                    argumentsJSON: modifiedJSON,
                    context: state.taskContext,
                    maxRetries: 1
                )
                if result.success {
                    let content = ToolResultFormatter.modelContent(toolName: canonicalName, result: result, limit: config.maxTokensPerTurn)
                    state.messages.append(ChatMessage(
                        role: "user",
                        content: "编排层自动修正参数后重试 \(canonicalName) 成功：\n\n\(content)"
                    ))
                    return true
                }

            case .retryWithModifiedParams(let params):
                let jsonData = try? JSONSerialization.data(withJSONObject: params)
                let jsonStr = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let canonicalName = ToolNameCodec.canonicalName(originalToolName)
                guard let tool = toolRegistry.tool(named: ToolNameCodec.apiName(canonicalName)) else { continue }
                guard !AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: canonicalName, tool: tool) else {
                    continue
                }
                let (result, _) = await ValidationEngine.executeWithValidationJSON(
                    tool: tool,
                    argumentsJSON: jsonStr,
                    context: state.taskContext,
                    maxRetries: 1
                )
                if result.success {
                    let content = ToolResultFormatter.modelContent(toolName: canonicalName, result: result, limit: config.maxTokensPerTurn)
                    state.messages.append(ChatMessage(
                        role: "user",
                        content: "编排层修正参数后重试 \(canonicalName) 成功：\n\n\(content)"
                    ))
                    return true
                }

            case .retry:
                break // Already retried in ValidationEngine

            case .askUser(let question):
                state.messages.append(ChatMessage(role: "system", content: "编排层：\(originalToolName) 需要用户确认：\(question)"))
                return false

            case .abort(let reason):
                state.messages.append(ChatMessage(role: "system", content: "编排层：\(originalToolName) 自动恢复放弃：\(reason)"))
                return false
            }
        }
        return false
    }

    // MARK: - Review Step Emission

    private static func emitReviewSteps(
        data: [String: String],
        toolName: String,
        toolParams: [String: String],
        callId: String,
        state: inout PipelineState,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let reviewSteps = AgentLoop.fileChangeReviewSteps(
            data: data,
            toolName: toolName,
            toolParams: toolParams,
            callId: callId,
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
            switch toolName {
            case "file.read", "file.extract":
                if let path = callStep.toolParams?["path"] {
                    if !state.taskContext.memory.readFiles.contains(path) {
                        state.taskContext.memory.readFiles.append(path)
                    }
                    let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
                    let signatures = toolResult.output
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
                        .prefix(8).joined(separator: "; ")
                    let summary = signatures.isEmpty
                        ? toolResult.output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).joined(separator: " … ")
                        : signatures
                    if !summary.isEmpty {
                        state.taskContext.memory.fileSummaries[path] = String(summary.prefix(300))
                    }
                    if toolResult.output.count < 100_000 {
                        state.taskContext.memory.fileContentCache[path] = toolResult.output
                    }
                    // F4: Directory pre-cache
                    let dir = (path as NSString).deletingLastPathComponent
                    let dirCacheKey = "__dir__:\(dir)"
                    if !dir.isEmpty && state.taskContext.memory.fileSummaries[dirCacheKey] == nil {
                        let ext = (path as NSString).pathExtension.lowercased()
                        if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                            let relevantSiblings = siblings.filter { file in
                                let fExt = (file as NSString).pathExtension.lowercased()
                                return fExt == ext || ["swift","py","js","ts","tsx","jsx","rs","go","java","c","cpp","h","m","mm","md","json","yaml","yml","toml"].contains(fExt)
                            }.sorted().prefix(30)
                            if !relevantSiblings.isEmpty {
                                state.taskContext.memory.fileSummaries[dirCacheKey] = relevantSiblings.joined(separator: ", ")
                            }
                        }
                    }
                }
            case "code.search":
                if let query = callStep.toolParams?["query"] {
                    state.taskContext.memory.searchedQueries.append(query)
                }
            default: break
            }
        } else {
            state.taskContext.memory.failedTools.append(callStep.toolName ?? "unknown")
        }
        if AgentLoop.isFileChangeTool(callStep.toolName ?? ""), toolResult.success {
            let path = AgentLoop.pathForFileChange(callStep: callStep, toolResult: toolResult)
            if !path.isEmpty {
                state.taskContext.memory.appendDecision("已写入：\(path)")
                state.taskContext.memory.fileContentCache.removeValue(forKey: path)
                let fullPath = (state.taskContext.workspaceRoot as NSString).appendingPathComponent(path)
                state.taskContext.memory.fileContentCache.removeValue(forKey: fullPath)
            }
        } else if callStep.toolName == "document.transform",
                  toolResult.success,
                  let action = toolResult.data?["action"],
                  ["workspace", "apply", "copy", "render"].contains(action),
                  let path = toolResult.data?["workflowPath"] ?? toolResult.data?["pdfPath"] ?? toolResult.data?["outputPath"] {
            let label = action == "workspace" ? "文档交付工作区" : (action == "render" ? "已渲染文档" : "已生成文档")
            state.taskContext.memory.appendDecision("\(label)：\(path)")
            state.taskContext.memory.fileContentCache.removeValue(forKey: path)
        } else if callStep.toolName == "skill.manage",
                  toolResult.success,
                  let action = toolResult.data?["action"] ?? callStep.toolParams?["action"] {
            let name = toolResult.data?["name"] ?? callStep.toolParams?["name"] ?? "技能"
            if ["create", "update"].contains(action) {
                let path = toolResult.data?["path"].map { "：\($0)" } ?? ""
                state.taskContext.memory.appendDecision("已沉淀技能：\(name)\(path)")
            }
        }
    }

    // MARK: - Auto-Verify

    private static func runAutoVerify(
        callStep: TaskStep,
        toolResult: ToolResult,
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> String {
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
        let vr = try? await verifyTool.execute(argumentsJSON: "{}", context: state.taskContext)
        guard let vr else { return "" }

        let vrStep = TaskStep(kind: .toolResult, text: vr.success ? "✅ 编译通过" : "❌ 编译失败", toolName: "verify.build", isCollapsible: true, isCollapsed: vr.success)
        state.task.steps.append(vrStep)
        if config.emitDebugSteps || !vr.success {
            onStep(vrStep)
        }

        if vr.success {
            return "\n\n✅ 自动验证：编译通过。"
        } else {
            let errLines = vr.output.components(separatedBy: .newlines)
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
              let readTool = toolRegistry.tool(named: "file_read") else { return "" }

        let readJSON = AgentLoop.bootstrapReadArgumentsJSON(for: bestPath)
        let readResult = try? await readTool.execute(argumentsJSON: readJSON, context: state.taskContext)
        guard let rr = readResult, rr.success else { return "" }

        state.taskContext.memory.readFiles.append(bestPath)
        if rr.output.count < 100_000 {
            state.taskContext.memory.fileContentCache[bestPath] = rr.output
        }
        let chainStep = TaskStep(kind: .toolResult, text: "已读取：\(bestPath)", toolName: "file.read", isCollapsible: true, isCollapsed: true)
        if config.emitDebugSteps {
            state.task.steps.append(chainStep)
            onStep(chainStep)
        }
        let readContent = ToolResultFormatter.modelContent(toolName: "file.read", result: rr, limit: max(2000, config.maxTokensPerTurn / 2))
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
}
