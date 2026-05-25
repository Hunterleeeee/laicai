import Foundation
import LaicaiNativeDomain

// MARK: - runLean() — Codex-style agent execution path

extension AgentLoop {
    /// Lean mode entry point. Uses AgentCore for a minimal, Codex-style execution loop.
    ///
    /// Compared to the standard `run()`, this path:
    ///  - Builds a concise system prompt (~300 words) instead of the 3-layer full prompt
    ///  - Uses a lean toolset (5-8 tools) instead of the full 21
    ///  - Skips all mid-loop orchestration noise (phase injection, pattern DB, quality gates,
    ///    auto-recovery, auto-verify, speculative prefetch, etc.)
    ///  - Only post-processes: records task outcome + updates execution ledger
    ///
    /// The caller interface is identical to `run()` for drop-in replacement.
    public func runLean(
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
        let startTime = CFAbsoluteTimeGetCurrent()
        var taskContext = context ?? TaskContext()
        if taskContext.workspaceRoot.isEmpty {
            taskContext.workspaceRoot = config.workspaceRoot
        }

        var task = AgentTask(
            id: taskID ?? UUID(),
            title: String(message.prefix(50)),
            status: .running,
            connectorID: connector.id,
            context: taskContext
        )

        // Emit user input step.
        if !priorSteps.contains(where: { $0.kind == .userInput && $0.text == message }) {
            let userStep = TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false)
            task.steps.append(userStep)
            onStep(userStep)
        }

        // ── Build lean system prompt ──
        let systemPrompt = Self.buildLeanSystemPrompt(
            workspaceRoot: taskContext.workspaceRoot,
            customPrompt: config.customSystemPrompt,
            message: message
        )

        // ── Select lean tool set ──
        let toolDefs: [ToolDefinition]
        if config.supportsToolCalling && intent != .chat {
            toolDefs = Self.leanToolDefinitions(
                for: intent,
                message: message,
                registry: toolRegistry
            )
        } else {
            toolDefs = []
        }

        // ── Build initial messages ──
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt)
        ]

        // Carry prior conversation context (compact).
        if let cache = summaryCache, !cache.isEmpty {
            messages.append(ChatMessage(role: "system", content: "前序对话摘要：\n\(cache)"))
        } else if !priorSteps.isEmpty {
            let compact = Self.compactPriorSteps(priorSteps, limit: 3000)
            if !compact.isEmpty {
                messages.append(ChatMessage(role: "system", content: compact))
            }
        }

        // User message (with images if any).
        if !imageAttachments.isEmpty {
            var parts: [ContentPart] = [.text(message)]
            parts.append(contentsOf: imageAttachments.map { $0.toContentPart() })
            messages.append(ChatMessage(role: "user", contentParts: parts))
        } else {
            messages.append(ChatMessage(role: "user", content: message))
        }

        // ── Configure and run AgentCore ──
        let coreConfig = AgentCoreConfig(
            maxIterations: config.maxIterations,
            maxSteps: 120,
            maxOutputTokens: config.maxTokensPerTurn,
            maxConsecutiveEmpty: 3,
            maxRepeatedToolFailures: 3,
            toolReplayMode: Self.usesOllamaChat(connector) ? .ollamaPseudoChat : .openAIToolCalls
        )

        let core = AgentCore(
            runtime: runtime,
            toolRegistry: toolRegistry,
            config: coreConfig
        )

        let result = try await core.run(
            taskID: task.id,
            messages: messages,
            tools: toolDefs,
            connector: connector,
            context: taskContext,
            onStep: { step in
                task.steps.append(step)
                onStep(step)
            },
            onStreamDelta: onStreamDelta,
            onReasoningDelta: onReasoningDelta,
            onCheckInterrupt: onCheckInterrupt
        )

        // ── Post-process: finalize task status ──
        if result.didComplete {
            task.status = .completed
        } else if result.hadFailure {
            task.status = .failed
        } else {
            task.status = .completed
        }

        // Record outcome for analytics (minimal — no failure pattern DB, no skill evolution).
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let toolCallCount = result.newSteps.filter { $0.kind == TaskStepKind.toolCall }.count
        let toolFailCount = result.newSteps.filter { $0.kind == TaskStepKind.toolResult && $0.isFailure }.count
        TaskOutcomeRecorder.shared.record(
            taskID: task.id.uuidString,
            intent: Self.intentLabel(intent),
            routeLabel: "lean",
            executionMode: "lean",
            iterations: result.iterations,
            status: task.status,
            hadFailure: result.hadFailure,
            wasCancelled: Task.isCancelled,
            wasTruncated: result.wasTruncated,
            toolCalls: toolCallCount,
            toolFailures: toolFailCount,
            durationSeconds: elapsed,
            userFollowupCount: 0,
            modelName: config.modelName
        )

        // Update execution ledger if present on the thread context.
        task.updatedAt = .now
        return task
    }

    // MARK: - Lean System Prompt

    /// Build a concise ~300-word system prompt for lean mode.
    /// Focus: role identity, project instructions, minimal rules.
    static func buildLeanSystemPrompt(
        workspaceRoot: String,
        customPrompt: String?,
        message: String
    ) -> String {
        var prompt = """
        你是来财（Laicai），一个 macOS 本地 AI 代码代理。
        你通过调用工具来完成用户的目标：读文件、搜索代码、执行命令、编辑和写入文件。

        ## 规则
        - 先理解目标，再行动。优先读取相关文件获取上下文。
        - 每次只做一步，观察结果后决定下一步。
        - 修改代码后用 verify_build 验证编译。
        - 如果工具失败，换一种方式；不要对同一参数重复超过 2 次。
        - 完成时给出简短总结，说明做了什么、验证了什么。
        - 不要编造文件内容或工具输出。
        """

        if !workspaceRoot.isEmpty {
            prompt += "\n\n## 工作区\n\(workspaceRoot)"
        }

        // Project memory: inject recent task summaries if available.
        if !workspaceRoot.isEmpty {
            let project = ProjectManager.shared.ensureProject(for: workspaceRoot)
            if !project.conventions.isEmpty {
                let conv = project.conventions.prefix(5).joined(separator: ", ")
                prompt += "\n\n## 项目约定\n\(conv)"
            }
            if !project.discoveredIssues.isEmpty {
                let top3 = project.discoveredIssues.prefix(3).joined(separator: "\n- ")
                prompt += "\n\n## 已知问题\n- \(top3)"
            }
        }

        // Cross-session memory.
        if let memCtx = MemoryEngine.shared.buildMemoryContext(for: message, maxTokens: 500) {
            prompt += "\n\n\(memCtx)"
        }

        // Custom system prompt (user-specified agent personality).
        if let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            prompt += "\n\n## 特别指令\n\(custom)"
        }

        return prompt
    }

    // MARK: - Lean Tool Selection

    /// Select a focused toolset based on intent and message content.
    /// Returns 5-8 tools instead of the full 21.
    static func leanToolDefinitions(
        for intent: UserIntent,
        message: String,
        registry: ToolRegistry
    ) -> [ToolDefinition] {
        // Core coding tools (always included for task mode).
        var names: [String] = [
            "file.read",
            "file.write",
            "file.edit",
            "code.search",
            "shell.exec",
            "verify.build"
        ]

        let lm = message.lowercased()

        // Conditionally include web tools.
        if lm.contains("搜索") || lm.contains("search") || lm.contains("查找")
            || lm.contains("http") || lm.contains("网") || lm.contains("url") {
            names.append("web.search")
            names.append("web.fetch")
        }

        // Research mode gets web tools by default.
        if case .research = intent {
            if !names.contains("web.search") { names.append("web.search") }
            if !names.contains("web.fetch") { names.append("web.fetch") }
        }

        // Wiki task.
        if lm.contains("wiki") || lm.contains("知识库") || lm.contains("笔记") {
            names.append("wiki.build")
        }

        // Workspace indexing for broad tasks.
        if lm.contains("项目") || lm.contains("全局") || lm.contains("整体")
            || lm.contains("架构") || lm.contains("重构") {
            names.append("workspace.index")
        }

        // Build tool definitions from registry.
        let allDefs = registry.toolDefinitions
        return allDefs.filter { def in
            let canonical = ToolNameCodec.canonicalName(def.function.name)
            return names.contains(canonical)
        }
    }

    // MARK: - Compact Prior Steps

    /// Build a compressed text summary of prior steps for continuation.
    static func compactPriorSteps(_ steps: [TaskStep], limit: Int) -> String {
        var out = "前序步骤：\n"
        var budget = limit
        for step in steps.suffix(20) {
            let line: String
            switch step.kind {
            case .userInput:
                line = "[用户] \(step.text.prefix(200))"
            case .toolCall:
                line = "[工具调用] \(step.toolName ?? "")(\(step.toolParams?.values.joined(separator: ",").prefix(100) ?? ""))"
            case .toolResult:
                let success = step.isFailure == true ? "❌" : "✅"
                line = "[工具结果] \(success) \(step.toolName ?? ""): \(step.text.prefix(150))"
            case .textOutput:
                line = "[输出] \(step.text.prefix(300))"
            case .aiThinking:
                continue
            default:
                line = "[\(step.kind.rawValue)] \(step.text.prefix(100))"
            }
            if budget - line.count < 0 { break }
            out += line + "\n"
            budget -= line.count
        }
        return out
    }

    // MARK: - Intent Label

    static func intentLabel(_ intent: UserIntent) -> String {
        switch intent {
        case .chat: return "chat"
        case .research: return "research"
        case .task: return "task"
        case .workflow(let name): return "workflow:\(name)"
        }
    }
}
