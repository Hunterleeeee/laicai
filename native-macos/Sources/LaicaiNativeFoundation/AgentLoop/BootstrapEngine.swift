import Foundation
import LaicaiNativeDomain

// MARK: - Bootstrap Engine
// Executes pre-loop tool calls (web_fetch, file_read, file_extract, workspace_index,
// code_search, web_search, task templates) and injects results into messages.
// Extracted from the monolithic run() method (lines 270-688).

@MainActor
struct BootstrapEngine {

    /// Runs all applicable bootstrap tool calls and returns updated messages.
    /// Also handles truncated output continuation from prior steps.
    static func execute(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        runtime: any ChatRuntimeClient,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        // Handle truncated output continuation
        if AgentLoop.shouldContinueTruncatedOutputOnly(message: state.message, priorSteps: state.priorSteps),
           let previousText = AgentLoop.lastTextOutput(in: state.priorSteps) {
            try await handleTruncatedContinuation(
                state: &state,
                config: config,
                runtime: runtime,
                previousText: previousText,
                onStep: onStep
            )
            return true // early exit — handled separately
        }

        guard !state.isPureContinuation else { return false }
        guard !state.toolDefs.isEmpty else { return false }

        // Try bootstrap tools in priority order (only one fires)
        if try await bootstrapWebFetch(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }
        if try await bootstrapFileExtract(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }
        if try await bootstrapFileRead(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }
        if try await bootstrapWorkspaceIndex(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }
        if try await bootstrapCodeSearch(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }
        if try await bootstrapWebSearch(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep) { return false }

        // G5: Inject learned tool patterns from successful past tasks
        injectLearnedToolPatterns(state: &state, config: config)

        // Task template engine
        if state.intent != .chat && state.needsPlanning && state.priorSteps.isEmpty && config.supportsToolCalling {
            await executeTaskTemplate(state: &state, config: config, toolRegistry: toolRegistry, onStep: onStep)
        }

        return false
    }

    // MARK: - Truncated Output Continuation

    private static func handleTruncatedContinuation(
        state: inout PipelineState,
        config: AgentLoop.Config,
        runtime: any ChatRuntimeClient,
        previousText: String,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws {
        let thinkingStep = TaskStep(
            kind: .aiThinking,
            text: "检测到上一条回复被截断，正在从截断处继续输出；本轮不会搜索、读取文件或调用工具。",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(thinkingStep)
        onStep(thinkingStep)

        var wasTruncated = true
        let originalStepID = state.priorSteps.last(where: { $0.kind == .textOutput })?.id
        if let continuationStep = try? await AgentLoop.continueTruncatedOutput(
            taskID: state.task.id,
            originalMessage: state.message,
            previousText: previousText,
            messages: state.messages,
            connector: state.connector,
            runtime: runtime,
            maxOutputTokens: config.maxTokensPerTurn,
            originalStepID: originalStepID
        ) {
            state.task.steps.append(continuationStep)
            onStep(continuationStep)
            wasTruncated = continuationStep.text.contains("回复仍被截断")
            state.didComplete = !wasTruncated
        }
        if wasTruncated {
            let stillTruncatedStep = TaskStep(
                kind: .error,
                text: "续写仍被截断。请继续在这个会话里发送\u{201C}接着说\u{201D}，我会继续沿用当前上下文。",
                isFailure: false,
                recoverable: true,
                retryAction: "接着说"
            )
            state.task.steps.append(stillTruncatedStep)
            onStep(stillTruncatedStep)
        }
        let checkStep = AgentLoop.completionCheckStep(
            for: state.task,
            didComplete: state.didComplete,
            hadFailure: false,
            wasTruncated: wasTruncated
        )
        state.task.steps.append(checkStep)
        onStep(checkStep)
        state.task.status = state.didComplete ? .completed : .failed
        state.task.updatedAt = .now
        state.wasTruncated = wasTruncated
    }

    // MARK: - Bootstrap: Web Fetch

    private static func bootstrapWebFetch(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard isToolAllowed("web.fetch", config: config),
              let url = AgentLoop.firstURL(in: state.message),
              let fetchTool = toolRegistry.tool(named: "web_fetch") else { return false }

        let argumentsJSON = AgentLoop.bootstrapWebFetchArgumentsJSON(for: url)
        let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
        let callId = "call_bootstrap_web_fetch"

        let (_, _, toolResult) = await executeBootstrapTool(
            toolName: "web.fetch",
            tool: fetchTool,
            argumentsJSON: argumentsJSON,
            toolParams: toolParams,
            callId: callId,
            state: &state,
            config: config,
            onStep: onStep
        )

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "web.fetch",
            result: toolResult,
            limit: config.maxTokensPerTurn
        )
        let instruction = toolResult.success
            ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWebFetch, baseline: "我已读取用户提供的网页。请基于网页正文和当前会话目标继续工作，必要时再搜索或读取项目文件；不要声称无法访问该链接。")
            : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWebFetch + "_fail", baseline: "我尝试读取用户提供的网页但失败。请明确说明失败原因，不能编造网页内容。")
        state.messages.append(ChatMessage(
            role: "user",
            content: "\(instruction)\n\n\(resultContent)"
        ))
        return true
    }

    // MARK: - Bootstrap: File Extract

    private static func bootstrapFileExtract(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard let localPath = AgentLoop.firstLocalPath(in: state.message),
              AgentLoop.shouldBootstrapExtract(path: localPath),
              isToolAllowed("file.extract", config: config),
              let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract") else { return false }

        let bootstrapMessage = await AgentLoop.runBootstrapFileExtract(
            path: localPath,
            extractTool: extractTool,
            taskContext: &state.taskContext,
            task: &state.task,
            maxTokens: config.maxTokensPerTurn,
            onStep: onStep
        )
        state.messages.append(bootstrapMessage)
        return true
    }

    // MARK: - Bootstrap: File Read

    private static func bootstrapFileRead(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard isToolAllowed("file.read", config: config),
              let localPath = AgentLoop.firstLocalPath(in: state.message),
              let readTool = toolRegistry.tool(named: "file_read") else { return false }

        let argumentsJSON = AgentLoop.bootstrapReadArgumentsJSON(for: localPath)
        let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
        let callId = "call_bootstrap_file_read"

        let (_, _, toolResult) = await executeBootstrapTool(
            toolName: "file.read",
            tool: readTool,
            argumentsJSON: argumentsJSON,
            toolParams: toolParams,
            callId: callId,
            state: &state,
            config: config,
            onStep: onStep
        )

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "file.read",
            result: toolResult,
            limit: config.maxTokensPerTurn
        )
        let instruction = toolResult.success
            ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapFileRead, baseline: "我已直接读取用户提供的本地路径。请基于真实读取结果继续推进当前会话目标；如果这是目录，先根据目录清单判断下一步该读哪些文件。")
            : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapFileRead + "_fail", baseline: "我尝试读取用户提供的本地路径但失败。请明确说明失败原因，不能编造文件内容。")
        state.messages.append(ChatMessage(
            role: "user",
            content: "\(instruction)\n\n\(resultContent)"
        ))
        return true
    }

    // MARK: - Bootstrap: Workspace Index

    private static func bootstrapWorkspaceIndex(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard isToolAllowed("workspace.index", config: config),
              AgentLoop.shouldBootstrapWorkspaceIndex(for: state.message, intent: state.intent),
              !state.taskContext.memory.userDecisions.contains(where: { $0.hasPrefix("工作区索引：") }),
              let indexTool = toolRegistry.tool(named: "workspace_index") else { return false }

        let argumentsJSON = AgentLoop.bootstrapWorkspaceIndexArgumentsJSON()
        let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
        let callId = "call_bootstrap_workspace_index"

        let (_, _, toolResult) = await executeBootstrapTool(
            toolName: "workspace.index",
            tool: indexTool,
            argumentsJSON: argumentsJSON,
            toolParams: toolParams,
            callId: callId,
            state: &state,
            config: config,
            onStep: onStep
        )

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "workspace.index",
            result: toolResult,
            limit: config.maxTokensPerTurn
        )
        let instruction = toolResult.success
            ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceIndex, baseline: "我已先建立工作区索引。请基于索引里的入口候选、测试候选、配置候选和风险候选判断项目结构；下一步优先读取 README/项目指令/配置/入口/测试文件，必要时用 code_search 精确补充，不要自由拼 shell find。")
            : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceIndex + "_fail", baseline: "我尝试建立工作区索引但失败。请说明失败原因，必要时再使用 code_search 或 file_read 降级。")
        state.messages.append(ChatMessage(
            role: "user",
            content: "\(instruction)\n\n\(resultContent)"
        ))
        return true
    }

    // MARK: - Bootstrap: Code Search

    private static func bootstrapCodeSearch(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard isToolAllowed("code.search", config: config),
              AgentLoop.shouldBootstrapWorkspaceSearch(for: state.message, intent: state.intent, context: state.taskContext),
              let searchTool = toolRegistry.tool(named: "code_search") else { return false }

        let argumentsJSON = AgentLoop.bootstrapWorkspaceSearchArgumentsJSON(for: state.message)
        let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
        let callId = "call_bootstrap_code_search"

        let (_, _, toolResult) = await executeBootstrapTool(
            toolName: "code.search",
            tool: searchTool,
            argumentsJSON: argumentsJSON,
            toolParams: toolParams,
            callId: callId,
            state: &state,
            config: config,
            onStep: onStep
        )

        // Auto-read first result
        var autoReadBlock = ""
        if toolResult.success,
           let path = AgentLoop.firstReadablePath(inSearchOutput: toolResult.output, workspaceRoot: state.taskContext.workspaceRoot) {
            if AgentLoop.shouldBootstrapExtract(path: path),
               isToolAllowed("file.extract", config: config),
               let extractTool = toolRegistry.tool(named: "file_extract") ?? toolRegistry.tool(named: "file.extract") {
                let extract = await AgentLoop.runBootstrapFileExtract(
                    path: path,
                    extractTool: extractTool,
                    taskContext: &state.taskContext,
                    task: &state.task,
                    callId: "call_bootstrap_search_file_extract",
                    maxTokens: max(1200, config.maxTokensPerTurn / 2),
                    onStep: onStep
                )
                autoReadBlock = "\n\n自动提取的首个高相关表格/文档（\(path)）：\n\(extract.content ?? "")"
            } else if let readTool = toolRegistry.tool(named: "file_read") {
                autoReadBlock = await AgentLoop.runBootstrapFileRead(
                    path: path,
                    readTool: readTool,
                    taskContext: &state.taskContext,
                    task: &state.task,
                    maxTokens: max(1200, config.maxTokensPerTurn / 2),
                    onStep: onStep
                )
            }
        }

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "code.search",
            result: toolResult,
            limit: config.maxTokensPerTurn
        )
        let fileHints = state.taskContext.relevantFiles.prefix(12).map { "- \($0.path) (\($0.language))" }.joined(separator: "\n")
        let hintBlock = fileHints.isEmpty ? "" : "\n\n自动相关文件线索：\n\(fileHints)"
        let instruction = toolResult.success
            ? PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceSearch, baseline: "我已先搜索工作区，并尽量自动读取首个高相关文件片段。请基于这些真实线索继续推进当前会话目标；如果线索不足，再调用 file_read/code_search 等工具，不要凭空猜文件内容。")
            : PromptRegistry.shared.prompt(for: PromptRegistry.tagBootstrapWorkspaceSearch + "_fail", baseline: "我尝试先搜索工作区但失败。请明确说明失败原因，必要时让用户检查工作区路径。")
        state.messages.append(ChatMessage(
            role: "user",
            content: "\(instruction)\n\n\(resultContent)\(autoReadBlock)\(hintBlock)"
        ))
        return true
    }

    // MARK: - Bootstrap: Web Search

    private static func bootstrapWebSearch(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async throws -> Bool {
        guard isToolAllowed("web.search", config: config),
              AgentLoop.shouldBootstrapWebSearch(for: state.message, intent: state.intent),
              let webTool = toolRegistry.tool(named: "web_search") else { return false }

        let searchMessage = AgentLoop.bootstrapWebSearchMessage(for: state.message, priorSteps: state.priorSteps)
        let argumentsJSON = AgentLoop.bootstrapWebSearchArgumentsJSON(for: searchMessage)
        let toolParams = AgentLoop.displayParamsFromJSON(argumentsJSON)
        let callId = "call_bootstrap_web_search"

        let (_, _, toolResult) = await executeBootstrapTool(
            toolName: "web.search",
            tool: webTool,
            argumentsJSON: argumentsJSON,
            toolParams: toolParams,
            callId: callId,
            state: &state,
            config: config,
            onStep: onStep
        )

        let resultContent = ToolResultFormatter.modelContent(
            toolName: "web.search",
            result: toolResult,
            limit: config.maxTokensPerTurn
        )
        let instruction = toolResult.success
            ? "我已先执行联网搜索。请只基于下面的真实搜索结果回答用户问题，并尽量给出来源标题或链接；不要编造未搜索到的信息。"
            : "我已先尝试联网搜索，但搜索失败。请明确告知用户搜索失败，不能编造实时信息。"
        state.messages.append(ChatMessage(
            role: "user",
            content: "\(instruction)\n\n\(resultContent)"
        ))
        return true
    }

    // MARK: - Learned Tool Patterns

    private static func injectLearnedToolPatterns(state: inout PipelineState, config: AgentLoop.Config) {
        guard state.intent != .chat && !state.taskContext.workspaceRoot.isEmpty,
              let repo = AgentLoop.sharedRepository else { return }

        let taskType = TaskFinalizer.classifyTaskType(message: state.message)
        let patterns = repo.loadMemories(workspace: state.taskContext.workspaceRoot, limit: 50)
            .filter { $0.category == "tool_pattern" && $0.key.hasPrefix("success_\(taskType)") }
        if let bestPattern = patterns.first {
            state.systemPrompt += "\n\n## 历史成功路径\n此类会话目标（\(taskType)）曾用以下工具序列成功完成：\(bestPattern.value)\n请优先按此路径执行。"
        }
    }

    // MARK: - Task Template Engine

    private static func executeTaskTemplate(
        state: inout PipelineState,
        config: AgentLoop.Config,
        toolRegistry: ToolRegistry,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        let templateResult = await AgentLoop.executeTaskTemplate(
            message: state.message,
            taskContext: &state.taskContext,
            task: &state.task,
            messages: &state.messages,
            toolRegistry: toolRegistry,
            emitDebugSteps: config.emitDebugSteps,
            onStep: onStep
        )
        guard templateResult.executedSteps > 0 else { return }

        if config.emitDebugSteps {
            let templateStep = TaskStep(
                kind: .aiThinking,
                text: "会话 预处理完成：\(templateResult.executedSteps) 步（\(templateResult.templateName)）",
                isCollapsible: true,
                isCollapsed: true
            )
            state.task.steps.append(templateStep)
            onStep(templateStep)
        }

        state.messages.append(ChatMessage(role: "system", content: templateResult.directive))
    }

    // MARK: - Shared Bootstrap Execution

    @discardableResult
    private static func executeBootstrapTool(
        toolName: String,
        tool: any LaicaiTool,
        argumentsJSON: String,
        toolParams: [String: String],
        callId: String,
        state: inout PipelineState,
        config: AgentLoop.Config,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> (TaskStep, TaskStep, ToolResult) {
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: toolName, arguments: toolParams),
            toolName: toolName,
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: false
        )
        state.task.steps.append(callStep)
        onStep(callStep)

        let toolResult: ToolResult
        if AgentLoop.requiresExplicitUserApprovalBeforeExecution(toolName: toolName, tool: tool) {
            toolResult = AgentLoop.approvalRequiredToolResult(toolName: toolName)
        } else {
            let validated = await ValidationEngine.executeWithValidationJSON(
                tool: tool,
                argumentsJSON: argumentsJSON,
                context: state.taskContext
            )
            toolResult = validated.result
        }
        let displayText = ToolResultFormatter.displayText(
            toolName: toolName,
            arguments: toolParams,
            result: toolResult
        )
        let resultStep = TaskStep(
            kind: .toolResult,
            text: displayText,
            toolName: toolName,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: false,
            isFailure: !toolResult.success
        )
        state.task.steps.append(resultStep)
        onStep(resultStep)

        return (callStep, resultStep, toolResult)
    }

    // MARK: - Utility

    private static func isToolAllowed(_ name: String, config: AgentLoop.Config) -> Bool {
        AgentLoop.allowsTool(name, allowedTools: config.allowedTools)
    }
}
