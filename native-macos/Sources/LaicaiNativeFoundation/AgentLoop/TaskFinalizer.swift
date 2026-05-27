import Foundation
import LaicaiNativeDomain

// MARK: - Task Finalizer
// Handles post-loop finalization: diagnostics, outcome recording, skill evolution,
// memory persistence. Extracted from the tail of the monolithic run() method.

@MainActor
struct TaskFinalizer {

    static func finalize(
        state: inout PipelineState,
        config: AgentLoop.Config,
        systemPrompt: String,
        runtime: any ChatRuntimeClient,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        if AgentLoop.hasSatisfiedImageGenerationRequest(state.task) && !state.wasTruncated {
            state.didComplete = true
        }

        // ── Evidence-based finalization ──
        let hasFinalOutput = state.task.steps.contains { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !state.didComplete && !state.hadFailure && !state.wasTruncated && !hasFinalOutput {
            if let summaryStep = try? await AgentLoop.finalizeFromCollectedEvidence(
                task: state.task,
                originalMessage: state.message,
                connector: state.connector,
                runtime: runtime,
                systemPrompt: systemPrompt,
                maxOutputTokens: config.maxTokensPerTurn
            ) {
                state.task.steps.append(summaryStep)
                onStep(summaryStep)
                state.didComplete = true
            }
        }

        // ── Manual continuation offer ──
        if !state.didComplete && !state.hadFailure && !state.wasTruncated {
            let continueStep = TaskStep(
                kind: .error,
                text: "会话 尚未完成，可以点击「继续」接着处理。",
                isFailure: false,
                recoverable: true,
                retryAction: "继续处理"
            )
            state.task.steps.append(continueStep)
            onStep(continueStep)
        }

        // ── Diagnostic audit (collapsed) ──
        emitStageAudit(state: &state, onStep: onStep)
        emitDiagnosticAudit(state: &state, onStep: onStep)

        // ── Final status ──
        let finalStatus: TaskStatus = AgentLoop.meetsCompletionCriteria(
            task: state.task,
            intent: state.intent,
            didComplete: state.didComplete,
            hadFailure: state.hadFailure,
            wasTruncated: state.wasTruncated,
            isReadOnlyRun: state.isReadOnlyRun
        ) ? .completed : .failed
        state.task.status = finalStatus
        state.task.updatedAt = .now
        updateExecutionLedger(state: &state, finalStatus: finalStatus)

        // ── Suggested next actions ──
        emitSuggestedActions(state: &state, finalStatus: finalStatus, onStep: onStep)

        // ── Persistent memory ──
        persistCrossSessionMemory(state: state, config: config, finalStatus: finalStatus)

        // ── Tool pattern recording ──
        recordToolPatterns(state: state, config: config, finalStatus: finalStatus)

        // ── Outcome recording ──
        let duration = CFAbsoluteTimeGetCurrent() - state.startTime
        recordOutcome(state: state, config: config, finalStatus: finalStatus, duration: duration)

        // ── Failure pattern learning ──
        let outcomeScore = computeOutcomeScore(state: state, config: config, finalStatus: finalStatus, duration: duration)
        learnFromFailures(state: state, config: config, finalStatus: finalStatus, outcomeScore: outcomeScore)

        // ── Skill evolution ──
        evolveSkills(state: state, config: config, finalStatus: finalStatus, outcomeScore: outcomeScore)

        // ── Execution trace ──
        storeExecutionTrace(state: state)

        // ── Persist task memory ──
        TaskMemoryStore.save(state.taskContext.memory, workspaceRoot: config.workspaceRoot)
        TaskMemoryStore.appendHistory(memory: state.taskContext.memory, workspaceRoot: config.workspaceRoot, taskDescription: state.task.title)

        // ── Update project knowledge ──
        if !config.workspaceRoot.isEmpty {
            let summary = state.taskContext.memory.stageConclusions.last ?? state.task.title
            let modified = Array(Set(state.taskContext.memory.pendingFiles))
            ProjectManager.shared.learnFromTask(
                rootPath: config.workspaceRoot,
                summary: summary,
                filesModified: modified,
                conclusions: state.taskContext.memory.stageConclusions
            )
        }

        // ── Diff stat for review ──
        captureDiffStat(state: &state, config: config, onStep: onStep)

        // ── Cleanup ──
        WorkspaceSandbox.shared.clearAllowedPaths()
    }

    // MARK: - Private Helpers

    private static func emitStageAudit(state: inout PipelineState, onStep: @MainActor (TaskStep) -> Void) {
        let hasPlan = state.task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("执行计划") }
            || state.taskContext.memory.userDecisions.contains { $0.hasPrefix("执行计划：") }
        if AgentLoop.shouldEmitStageSummary(
            for: state.task,
            hasPlan: hasPlan,
            hadFailure: state.hadFailure,
            wasTruncated: state.wasTruncated,
            isReadOnlyRun: state.isReadOnlyRun
        ) {
            let summaryStep = AgentLoop.stageSummaryStep(
                for: state.task,
                didComplete: state.didComplete,
                hadFailure: state.hadFailure,
                wasTruncated: state.wasTruncated
            )
            state.task.steps.append(summaryStep)
            onStep(summaryStep)
        }
        if let evidenceStep = AgentLoop.evidenceChecklistStep(
            for: state.task,
            didComplete: state.didComplete,
            hadFailure: state.hadFailure,
            wasTruncated: state.wasTruncated,
            isReadOnlyRun: state.isReadOnlyRun
        ) {
            state.task.steps.append(evidenceStep)
            onStep(evidenceStep)
        }
    }

    private static func emitDiagnosticAudit(state: inout PipelineState, onStep: @MainActor (TaskStep) -> Void) {
        let toolCallCount = state.task.steps.filter { $0.kind == .toolCall }.count
        let emitDiagnosticAudit = (state.hadFailure && toolCallCount > 0) || state.wasTruncated
        guard emitDiagnosticAudit else { return }

        var checkStep = AgentLoop.completionCheckStep(
            for: state.task,
            didComplete: state.didComplete,
            hadFailure: state.hadFailure,
            wasTruncated: state.wasTruncated,
            isReadOnlyRun: state.isReadOnlyRun
        )
        checkStep.isCollapsible = true
        checkStep.isCollapsed = true
        state.task.steps.append(checkStep)
        onStep(checkStep)
    }

    private static func emitSuggestedActions(
        state: inout PipelineState,
        finalStatus: TaskStatus,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard finalStatus == .completed && !state.isReadOnlyRun && state.intent != .chat else { return }

        let hasFileEdits = state.task.steps.contains {
            (AgentLoop.isFileChangeTool($0.toolName ?? "") || AgentLoop.isSuccessfulDocumentWrite($0)) && !$0.isFailure
        }
        let hasVerify = state.task.steps.contains { $0.toolName == "verify.build" }
        let hasGitCommit = state.task.steps.contains { $0.toolName == "git" && ($0.toolParams?["subcommand"] ?? "").contains("commit") }

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
        guard !suggestions.isEmpty else { return }

        let firstSuggestion = suggestions[0]
        let nextStep = TaskStep(
            kind: .aiThinking,
            text: "建议下一步：\n" + suggestions.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
            isCollapsible: true,
            isCollapsed: false,
            retryAction: firstSuggestion
        )
        state.task.steps.append(nextStep)
        onStep(nextStep)
    }

    private static func updateExecutionLedger(state: inout PipelineState, finalStatus: TaskStatus) {
        if state.task.executionLedger == nil {
            state.task.executionLedger = AgentExecutionLedger(
                originalRequest: state.message,
                goal: state.task.title,
                state: .created,
                plan: state.taskContext.memory.userDecisions.filter { $0.hasPrefix("执行计划：") },
                nextAction: "继续处理当前会话"
            )
        }
        guard var ledger = state.task.executionLedger else { return }
        ledger.plan = ledger.plan.isEmpty ? state.taskContext.memory.userDecisions.filter { $0.hasPrefix("执行计划：") } : ledger.plan
        ledger.readFiles = Array(Set(ledger.readFiles + state.taskContext.memory.readFiles)).sorted()
        ledger.searches = Array(Set(ledger.searches + state.taskContext.memory.searchedQueries)).sorted()
        ledger.failedTools = Array(Set(ledger.failedTools + state.taskContext.memory.failedTools)).sorted()
        if let verification = state.taskContext.memory.verificationStatus, !verification.isEmpty {
            ledger.appendUnique(verification, to: \.verification)
        }
        for step in state.task.steps {
            if step.kind == .reviewRequest, let path = step.diffFilePath {
                if step.approved == true {
                    ledger.appendUnique(path, to: \.modifiedFiles)
                } else {
                    ledger.appendUnique(path, to: \.artifacts)
                }
            }
            if step.toolName == "document.transform",
               let path = step.toolParams?["outputPath"] ?? step.toolParams?["pdfPath"] ?? step.diffFilePath {
                ledger.appendUnique(path, to: \.artifacts)
            }
            if step.toolName == "shell.exec" || step.toolName == "verify.build" {
                if let command = step.toolParams?["command"] {
                    ledger.appendUnique(command, to: \.commands)
                }
            }
            if step.isFailure {
                ledger.appendUnique(step.toolName ?? "unknown", to: \.failedTools)
                ledger.appendUnique(String(step.text.prefix(500)), to: \.errorReasons)
                if let recovery = recoveryPath(for: step.toolName ?? "unknown", step: step) {
                    ledger.appendUnique(recovery, to: \.alternativePaths)
                }
            }
        }
        switch finalStatus {
        case .completed:
            ledger.transition(to: .completed, reason: "完成门禁通过")
            ledger.nextAction = nil
            ledger.unfinishedWork = []
        case .failed:
            ledger.transition(to: .failed, reason: "完成门禁未通过")
            ledger.nextAction = "从失败点恢复或补齐证据"
            if !ledger.hasToolEvidence && state.intent != .chat {
                ledger.unfinishedWork.append("缺少真实工具证据")
            }
        case .cancelled:
            ledger.transition(to: .paused, reason: "任务暂停")
            ledger.nextAction = "从检查点继续"
        case .waitingReview:
            ledger.transition(to: .waitingUser, reason: "等待用户审查")
            ledger.nextAction = "等待审查后继续"
        case .queued, .running:
            ledger.transition(to: .executing, reason: "任务仍在执行")
        }
        ledger.updatedAt = .now
        state.task.executionLedger = ledger
    }

    private static func recoveryPath(for toolName: String, step: TaskStep) -> String? {
        switch ToolNameCodec.canonicalName(toolName) {
        case "file.edit":
            return "file.edit 失败后改走 file.read + file.write，并基于最新磁盘内容生成 diff"
        case "code.search":
            return "code.search 失败后改走 workspace.index 或 shell.exec rg 精确搜索"
        case "file.read":
            return "file.read 失败后确认路径/类型；Office 或 PDF 改用 file.extract/document.transform"
        case "web.fetch":
            return "web.fetch 失败后换来源或先 web.search 找替代页面"
        case "browser", "browser.real":
            return "页面检查失败后改用 browser.extract/browser.screenshot 或 computer.screenshot 留证"
        case "computer":
            return "界面自动化失败后改用截图、窗口列表或让用户确认权限"
        case "verify.build":
            return "构建验证失败后读取关键错误文件，修复后再次 verify.build；环境问题需记录阻塞"
        case "shell.exec":
            if step.text.lowercased().contains("危险") || step.text.lowercased().contains("dangerous") {
                return "危险 shell 操作被拦截；需要用户明确授权或选择非破坏性替代路径"
            }
            return "shell.exec 失败后缩小命令范围、改用结构化工具或记录环境阻塞"
        default:
            return nil
        }
    }

    private static func persistCrossSessionMemory(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus) {
        guard finalStatus == .completed, !state.taskContext.workspaceRoot.isEmpty, let repo = AgentLoop.sharedRepository else { return }

        for (path, summary) in state.taskContext.memory.fileSummaries.prefix(10) {
            repo.saveMemory(workspace: state.taskContext.workspaceRoot, category: "file_structure", key: path, value: String(summary.prefix(200)))
        }
        if let verifyStep = state.task.steps.first(where: { $0.toolName == "verify.build" && !$0.isFailure }),
           let cmd = verifyStep.toolParams?["command"] ?? verifyStep.text.components(separatedBy: "命令：").last?.components(separatedBy: "\n").first {
            repo.saveMemory(workspace: state.taskContext.workspaceRoot, category: "build", key: "build_command", value: String(cmd.prefix(200)))
        }
    }

    private static func recordToolPatterns(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus) {
        guard finalStatus == .completed && state.iteration <= 5 && !state.taskContext.workspaceRoot.isEmpty,
              let repo = AgentLoop.sharedRepository else { return }

        let toolSequence = state.task.steps
            .filter { $0.kind == .toolCall }
            .compactMap { $0.toolName }
        guard toolSequence.count >= 2 && toolSequence.count <= 10 else { return }

        let taskType = classifyTaskType(message: state.message)
        let sequenceStr = toolSequence.joined(separator: " → ")
        repo.saveMemory(
            workspace: state.taskContext.workspaceRoot,
            category: "tool_pattern",
            key: "success_\(taskType)_\(state.iteration)iter",
            value: sequenceStr
        )
    }

    private static func recordOutcome(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, duration: Double) {
        let toolCalls = state.task.steps.filter { $0.kind == .toolCall }.count
        let toolFailures = state.task.steps.filter { $0.kind == .toolResult && $0.isFailure }.count
        let userFollowups = state.task.steps.filter { $0.kind == .userInput && $0.text != state.message }.count
        let promptTag = PromptRegistry.shared.versionTag(for: PromptRegistry.tagContinueTask)

        TaskOutcomeRecorder.shared.record(
            taskID: state.task.id.uuidString,
            intent: state.intentString,
            routeLabel: "会话 执行",
            executionMode: executionModeLabel(state: state, config: config),
            iterations: state.iteration,
            status: finalStatus,
            hadFailure: state.hadFailure,
            wasCancelled: false,
            wasTruncated: state.wasTruncated,
            toolCalls: toolCalls,
            toolFailures: toolFailures,
            durationSeconds: duration,
            userFollowupCount: userFollowups,
            promptTag: promptTag,
            modelName: config.modelName
        )
    }

    static func executionModeLabel(state: PipelineState, config: AgentLoop.Config) -> String {
        if state.isReadOnlyRun { return "inspect" }
        switch config.kernelMode {
        case .legacy:
            return "legacy"
        case .pipeline:
            return "pipeline"
        case .codexFull:
            return "codexFull"
        }
    }

    private static func computeOutcomeScore(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, duration: Double) -> Int {
        let userFollowups = state.task.steps.filter { $0.kind == .userInput && $0.text != state.message }.count
        return ResultEvaluator.score(
            status: finalStatus,
            iterations: state.iteration,
            maxIterations: state.effectiveMaxIterations,
            hadFailure: state.hadFailure,
            wasCancelled: false,
            wasTruncated: state.wasTruncated,
            durationSeconds: duration,
            userFollowupCount: userFollowups
        )
    }

    private static func learnFromFailures(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, outcomeScore: Int) {
        let rewardThreshold = 55
        let shouldLearn = (state.hadFailure || finalStatus == .failed) && outcomeScore < rewardThreshold
        guard shouldLearn else { return }

        let recentTools = state.task.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName }
        let failedToolNamesRaw = state.task.steps.filter { $0.kind == .toolResult && $0.isFailure }.compactMap { $0.toolName }

        var failedCounts: [String: Int] = [:]
        for t in failedToolNamesRaw { failedCounts[t, default: 0] += 1 }
        let failedSummary = failedCounts.sorted(by: { $0.value > $1.value })
            .prefix(5)
            .map { $0.value > 1 ? "\($0.key)(\($0.value)次)" : $0.key }
            .joined(separator: "、")

        let rootCauseText: String
        let instructionText: String
        if !failedCounts.isEmpty {
            rootCauseText = "\(failedSummary)工具执行失败"
            instructionText = "类似请求中\(failedSummary)曾失败，请预先检查参数有效性或使用替代方案。"
        } else if state.hadFailure {
            rootCauseText = "工具执行中出现错误"
            instructionText = "类似请求曾出错，请更谨慎地验证工具参数和前置条件。"
        } else {
            rootCauseText = "会话 未能完成"
            instructionText = "遇到类似意图时，优先确认用户需求范围，避免过度执行。"
        }

        FailurePatternDB.shared.record(
            intent: state.intentString,
            triggerTools: Array(Set(recentTools)),
            triggerKeywords: [state.message],
            rootCause: rootCauseText,
            preemptiveInstruction: instructionText,
            modelName: config.modelName
        )
    }

    private static func evolveSkills(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, outcomeScore: Int) {
        // Close the loop: if patterns were injected and task succeeded, mark them as effective
        if finalStatus == .completed && !state.injectedPatternHashes.isEmpty {
            for hash in state.injectedPatternHashes {
                FailurePatternDB.shared.markSuccess(patternHash: hash)
            }
        }

        // Extract reusable skill from successful tasks
        if finalStatus == .completed && outcomeScore >= 70 {
            let usedTools = state.task.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName }
            let uniqueTools = Array(Set(usedTools))
            let orderedTools = state.task.steps
                .filter { $0.kind == .toolCall }
                .compactMap { $0.toolName }
            let dedupedSequence: [String] = {
                var seen = Set<String>()
                return orderedTools.filter { seen.insert($0).inserted }
            }()
            let strategy = dedupedSequence.isEmpty ? "工具辅助完成" : dedupedSequence.prefix(8).joined(separator: " → ")
            SkillEvolutionEngine.shared.extractSkill(
                taskTitle: state.task.title,
                intent: state.intentString,
                toolsUsed: uniqueTools,
                modelName: config.modelName,
                outcomeScore: outcomeScore,
                strategy: strategy
            )
        }

        // Update Q-value if a learned skill was used
        if let usedSkillID = state.task.context.metadata["learnedSkillID"].flatMap(Int.init) {
            if finalStatus == .completed {
                SkillEvolutionEngine.shared.updateQ(
                    skillID: usedSkillID,
                    outcomeScore: outcomeScore,
                    succeeded: true
                )
            } else {
                SkillEvolutionEngine.shared.penalize(skillID: usedSkillID)
            }
        }
    }

    private static func storeExecutionTrace(state: PipelineState) {
        let traceEntries = state.task.steps.filter { $0.kind == .toolCall || $0.kind == .toolResult }
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
            TaskOutcomeRecorder.shared.storeTrace(taskID: state.task.id.uuidString, traceJSON: traceJSON)
        }
    }

    private static func captureDiffStat(
        state: inout PipelineState,
        config: AgentLoop.Config,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        let workRoot = state.taskContext.metadata["worktreeOriginalRoot"] ?? config.workspaceRoot
        guard !workRoot.isEmpty, state.intent != .chat else { return }

        let diffProc = Process()
        diffProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        diffProc.arguments = ["diff", "--stat"]
        diffProc.currentDirectoryURL = URL(fileURLWithPath: workRoot)
        let diffPipe = Pipe()
        diffProc.standardOutput = diffPipe
        diffProc.standardError = diffPipe

        do {
            try diffProc.run()
        } catch {
            return
        }
        diffProc.waitUntilExit()

        let diffOutput = String(data: diffPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard !diffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let diffStep = TaskStep(
            kind: .toolResult,
            text: "📋 文件变更：\n```\n\(String(diffOutput.prefix(2000)))\n```",
            isCollapsible: true,
            isCollapsed: true
        )
        state.task.steps.append(diffStep)
        onStep(diffStep)
        state.task.context.metadata["diffStat"] = String(diffOutput.prefix(1000))
    }

    // MARK: - Utility

    static func classifyTaskType(message: String) -> String {
        let lm = message.lowercased()
        if lm.contains("修改") || lm.contains("fix") || lm.contains("修复") { return "modify" }
        if lm.contains("创建") || lm.contains("新建") || lm.contains("create") { return "create" }
        if lm.contains("搜索") || lm.contains("查找") || lm.contains("search") { return "search" }
        if lm.contains("解释") || lm.contains("分析") || lm.contains("explain") { return "explain" }
        return "general"
    }
}
