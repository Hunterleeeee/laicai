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
        let hasFinalOutput = state.task.steps.contains {
            $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Synthesize a closing answer whenever the loop ended without one —
        // including after failures. "Silent fail" is the worst outcome: the
        // user gets no result AND no explanation. Deliberately does NOT flip
        // didComplete: the loop's own verdict (exhaustion, unrecovered
        // failure) stands; the summary only ends the silence.
        if !state.didComplete && !state.wasTruncated && !hasFinalOutput {
            if let summaryStep = try? await AgentLoop.finalizeFromCollectedEvidence(
                AgentLoop.EvidenceFinalizationRequest(
                    task: state.task,
                    originalMessage: state.message,
                    connector: state.connector,
                    runtime: runtime,
                    systemPrompt: systemPrompt,
                    maxOutputTokens: config.maxTokensPerTurn
                ))
            {
                state.task.steps.append(summaryStep)
                onStep(summaryStep)
            }
        }

        // ── Manual continuation offer ──
        // This is an incomplete, recoverable result—not a hard failure. Keep
        // the wording consistent with the terminal status and let the ledger
        // expose the continuation action. Fires whenever evidence-based
        // finalization above did not produce a completed result, regardless
        // of earlier tool failures.
        if !state.didComplete && !state.wasTruncated {
            let continueStep = TaskStep(
                kind: .error,
                text: "会话尚未形成完整结果，可以点击「继续处理」接着执行。",
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
        let finalStatus: TaskStatus =
            AgentLoop.meetsCompletionCriteria(
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
        state.task.context = state.taskContext
        TaskMemoryStore.save(state.taskContext.memory, workspaceRoot: config.workspaceRoot)
        TaskMemoryStore.appendHistory(
            memory: state.taskContext.memory, workspaceRoot: config.workspaceRoot, taskDescription: state.task.title)

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
        await captureDiffStat(state: &state, config: config, onStep: onStep)

        // ── Cleanup ──
        WorkspaceSandbox.shared.clearAllowedPaths()
    }

    // MARK: - Private Helpers

    private static func emitStageAudit(state: inout PipelineState, onStep: @MainActor (TaskStep) -> Void) {
        let hasPlan =
            state.task.steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("执行计划") }
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
        guard let firstSuggestion = suggestions.first else { return }

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
        ensureExecutionLedger(state: &state)
        guard var ledger = state.task.executionLedger else { return }
        let planEntries = state.taskContext.memory.userDecisions.filter { $0.hasPrefix("执行计划：") }
        ledger.plan = ledger.plan.isEmpty ? planEntries : ledger.plan
        ledger.readFiles = merged(ledger.readFiles, state.taskContext.memory.readFiles)
        ledger.searches = merged(ledger.searches, state.taskContext.memory.searchedQueries)
        ledger.failedTools = merged(ledger.failedTools, state.taskContext.memory.failedTools)
        if let verification = state.taskContext.memory.verificationStatus, !verification.isEmpty {
            ledger.appendUnique(verification, to: \.verification)
        }
        for step in state.task.steps {
            record(step, in: &ledger)
        }
        applyFinalStatus(finalStatus, intent: state.intent, ledger: &ledger)
        ledger.updatedAt = .now
        state.task.executionLedger = ledger
    }

    private static func ensureExecutionLedger(state: inout PipelineState) {
        guard state.task.executionLedger == nil else { return }
        state.task.executionLedger = AgentExecutionLedger(
            originalRequest: state.message,
            goal: state.task.title,
            state: .created,
            plan: state.taskContext.memory.userDecisions.filter { $0.hasPrefix("执行计划：") },
            nextAction: "继续处理当前会话"
        )
    }

    private static func merged(_ existing: [String], _ additions: [String]) -> [String] {
        Array(Set(existing + additions)).sorted()
    }

    private static func record(_ step: TaskStep, in ledger: inout AgentExecutionLedger) {
        recordReviewStep(step, in: &ledger)
        recordDocumentArtifact(step, in: &ledger)
        recordCommand(step, in: &ledger)
        recordFailure(step, in: &ledger)
    }

    private static func recordReviewStep(_ step: TaskStep, in ledger: inout AgentExecutionLedger) {
        guard step.kind == .reviewRequest, let path = step.diffFilePath else { return }
        if step.approved == true {
            ledger.appendUnique(path, to: \.modifiedFiles)
        } else {
            ledger.appendUnique(path, to: \.artifacts)
        }
    }

    private static func recordDocumentArtifact(_ step: TaskStep, in ledger: inout AgentExecutionLedger) {
        guard step.toolName == "document.transform",
            let path = step.toolParams?["outputPath"] ?? step.toolParams?["pdfPath"] ?? step.diffFilePath
        else { return }
        ledger.appendUnique(path, to: \.artifacts)
    }

    private static func recordCommand(_ step: TaskStep, in ledger: inout AgentExecutionLedger) {
        guard step.toolName == "shell.exec" || step.toolName == "verify.build",
            let command = step.toolParams?["command"]
        else { return }
        ledger.appendUnique(command, to: \.commands)
    }

    private static func recordFailure(_ step: TaskStep, in ledger: inout AgentExecutionLedger) {
        guard step.isFailure else { return }
        let toolName = step.toolName ?? "unknown"
        ledger.appendUnique(toolName, to: \.failedTools)
        ledger.appendUnique(String(step.text.prefix(500)), to: \.errorReasons)
        if let recovery = recoveryPath(for: toolName, step: step) {
            ledger.appendUnique(recovery, to: \.alternativePaths)
        }
    }

    private static func applyFinalStatus(
        _ finalStatus: TaskStatus,
        intent: UserIntent,
        ledger: inout AgentExecutionLedger
    ) {
        switch finalStatus {
        case .completed:
            ledger.transition(to: .completed, reason: "完成门禁通过")
            ledger.nextAction = nil
            ledger.unfinishedWork = []
        case .failed:
            ledger.transition(to: .failed, reason: "完成门禁未通过")
            ledger.nextAction = "从失败点恢复或补齐证据"
            if !ledger.hasToolEvidence && intent != .chat {
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
            repo.saveMemory(
                workspace: state.taskContext.workspaceRoot, category: "file_structure", key: path, value: String(summary.prefix(200)))
        }
        if let verifyStep = state.task.steps.first(where: { $0.toolName == "verify.build" && !$0.isFailure }),
            let cmd = verifyStep.toolParams?["command"]
                ?? verifyStep.text.components(separatedBy: "命令：").last?.components(separatedBy: "\n").first
        {
            repo.saveMemory(
                workspace: state.taskContext.workspaceRoot, category: "build", key: "build_command", value: String(cmd.prefix(200)))
        }
    }

    private static func recordToolPatterns(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus) {
        guard finalStatus == .completed && state.iteration <= 5 && !state.taskContext.workspaceRoot.isEmpty,
            let repo = AgentLoop.sharedRepository
        else { return }

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
        let promptTag = state.config.dependencies.promptRegistry.versionTag(for: PromptRegistry.tagContinueTask)

        state.config.dependencies.taskOutcomeRecorder.record(
            TaskOutcomeRecord(
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
                userRating: 0,
                modelName: config.modelName
            ))
    }

    static func executionModeLabel(state: PipelineState, config: AgentLoop.Config) -> String {
        if state.isReadOnlyRun { return "inspect" }
        return "codexFull"
    }

    private static func computeOutcomeScore(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, duration: Double)
        -> Int
    {
        let userFollowups = state.task.steps.filter { $0.kind == .userInput && $0.text != state.message }.count
        return ResultEvaluator.score(
            ResultEvaluator.ScoreRequest(
                status: finalStatus,
                iterations: state.iteration,
                maxIterations: state.effectiveMaxIterations,
                hadFailure: state.hadFailure,
                wasCancelled: false,
                wasTruncated: state.wasTruncated,
                durationSeconds: duration,
                userFollowupCount: userFollowups
            ))
    }

    private static func learnFromFailures(state: PipelineState, config: AgentLoop.Config, finalStatus: TaskStatus, outcomeScore: Int) {
        let rewardThreshold = 55
        let shouldLearn = (state.hadFailure || finalStatus == .failed) && outcomeScore < rewardThreshold
        guard shouldLearn else { return }

        let recentTools = state.task.steps.filter { $0.kind == .toolCall }.compactMap { $0.toolName }
        let failedToolNamesRaw = state.task.steps.filter { $0.kind == .toolResult && $0.isFailure }.compactMap { $0.toolName }

        var failedCounts: [String: Int] = [:]
        for toolName in failedToolNamesRaw { failedCounts[toolName, default: 0] += 1 }
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

        state.config.dependencies.failurePatternDB.record(
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
                state.config.dependencies.failurePatternDB.markSuccess(patternHash: hash)
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
            state.config.dependencies.skillEvolutionEngine.extractSkill(
                SkillExtractionRequest(
                    taskTitle: state.task.title,
                    intent: state.intentString,
                    toolsUsed: uniqueTools,
                    modelName: config.modelName,
                    outcomeScore: outcomeScore,
                    strategy: strategy
                ))
        }

        // Update Q-value if a learned skill was used
        if let usedSkillID = state.task.context.metadata["learnedSkillID"].flatMap(Int.init) {
            if finalStatus == .completed {
                state.config.dependencies.skillEvolutionEngine.updateQ(
                    skillID: usedSkillID,
                    outcomeScore: outcomeScore,
                    succeeded: true
                )
            } else {
                state.config.dependencies.skillEvolutionEngine.penalize(skillID: usedSkillID)
            }
        }
    }

    private static func storeExecutionTrace(state: PipelineState) {
        let traceEntries = state.task.steps.filter { $0.kind == .toolCall || $0.kind == .toolResult }
            .map { step -> [String: String] in
                var entry: [String: String] = [
                    "kind": step.kind == .toolCall ? "call" : "result",
                    "tool": step.toolName ?? "",
                    "text": String(step.text.prefix(200)),
                ]
                if step.isFailure { entry["failure"] = "true" }
                return entry
            }
        if let traceData = try? JSONSerialization.data(withJSONObject: traceEntries),
            let traceJSON = String(data: traceData, encoding: .utf8)
        {
            state.config.dependencies.taskOutcomeRecorder.storeTrace(
                taskID: state.task.id.uuidString,
                traceJSON: traceJSON
            )
        }
    }

    private static func captureDiffStat(
        state: inout PipelineState,
        config: AgentLoop.Config,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        let workRoot = state.taskContext.metadata["worktreeOriginalRoot"] ?? config.workspaceRoot
        guard !workRoot.isEmpty, state.intent != .chat else { return }

        // Run git off the main actor — a slow/hung repo must not freeze the UI.
        guard let diffOutput = await computeDiffStat(workRoot: workRoot) else { return }

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

    private static func computeDiffStat(workRoot: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard
                let result = try? ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["diff", "--stat"],
                    currentDirectoryURL: URL(fileURLWithPath: workRoot),
                    timeout: 15
                ),
                result.exitCode == 0,
                !result.timedOut
            else { return nil }
            let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        }.value
    }

    // MARK: - Utility

    static func classifyTaskType(message: String) -> String {
        let lowercaseMessage = message.lowercased()
        if lowercaseMessage.contains("修改") || lowercaseMessage.contains("fix") || lowercaseMessage.contains("修复") { return "modify" }
        if lowercaseMessage.contains("创建") || lowercaseMessage.contains("新建") || lowercaseMessage.contains("create") { return "create" }
        if lowercaseMessage.contains("搜索") || lowercaseMessage.contains("查找") || lowercaseMessage.contains("search") { return "search" }
        if lowercaseMessage.contains("解释") || lowercaseMessage.contains("分析") || lowercaseMessage.contains("explain") { return "explain" }
        return "general"
    }
}
