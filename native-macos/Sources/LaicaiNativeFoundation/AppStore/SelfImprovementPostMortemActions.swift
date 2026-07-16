import Foundation
import LaicaiNativeDomain

extension AppStore {
    func triggerPreciseSelfImprovement(prompt: String, report: SessionPostMortem.Report) {
        guard SelfImprovementEngine.shared.shouldTrigger() != nil || report.hasCritical else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = """
            # 自我改进任务（会话后检触发）

            \(prompt)

            ## 执行步骤
            1. 先读取上述建议修复文件中指定行号附近的代码
            2. 理解当前实现和问题根因
            3. 用 file_edit 修改代码（最小化修改）
            4. 运行 `bash \(SelfImprovementEngine.shared.buildScript)` 验证编译
            5. 编译通过后提交：先运行 `git status --short`，只 `git add -- <本轮修改文件>`，再 `git commit -m "self-fix: \(report.findings.first?.pattern.rawValue ?? "postmortem")"`
            6. 重启应用

            ## 限制
            - 只修改 LaicaiNativeFoundation 目录下的 .swift 文件
            - 不要修改 Models.swift 的 struct 定义
            - 每次最多修改 3 个文件
            - 必须编译通过
            """

        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["postmortemThreadID"] = report.threadID.uuidString

        let targetID = UUID()
        let thread = Thread(
            id: targetID,
            title: "🔧 自动修复：\(report.findings.first?.pattern.rawValue ?? "postmortem")",
            status: .running,
            connectorID: connector.id,
            context: context,
            modelName: connector.modelName,
            category: .engineering,
            executionState: .running,
            goal: message,
            currentPlan: [
                "读取后检建议定位根因",
                "修改最小必要代码",
                "构建验证并准备提交",
            ]
        )
        state.threads.insert(thread, at: 0)
        persistThreadsNow()

        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = [
            "file.read", "file.edit", "diff.apply", "code.search", "workspace.index", "shell.exec", "verify.build", "skill.manage", "git",
        ]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        agentLoops[targetID] = loop

        let targetTaskID = targetID
        let generationRunID = markGenerationStarted(for: targetTaskID, activity: "正在执行自我改进复盘…")

        generationTasks[targetTaskID] = Task { [weak self] in
            guard let self else { return }
            await self.runPostMortemSelfImprovementTask(
                PostMortemSelfImprovementRun(
                    loop: loop,
                    targetTaskID: targetTaskID,
                    generationRunID: generationRunID,
                    message: message,
                    connector: connector,
                    context: context,
                    report: report
                ))
        }
    }

    private struct PostMortemSelfImprovementRun {
        let loop: AgentLoop
        let targetTaskID: UUID
        let generationRunID: UUID
        let message: String
        let connector: ConnectorProfile
        let context: TaskContext
        let report: SessionPostMortem.Report
    }

    private func runPostMortemSelfImprovementTask(_ run: PostMortemSelfImprovementRun) async {
        do {
            let completedTask = try await run.loop.run(
                taskID: run.targetTaskID,
                message: run.message,
                intent: UserIntent.task,
                connector: run.connector,
                context: run.context,
                priorSteps: [],
                onStep: { @MainActor [weak self] (step: TaskStep) in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.targetTaskID, runID: run.generationRunID) else { return }
                    self.appendTaskStep(step, to: run.targetTaskID)
                },
                onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.targetTaskID, runID: run.generationRunID) else { return }
                    self.appendStreamDelta(delta, to: run.targetTaskID)
                }
            )
            guard shouldAcceptGenerationCallback(for: run.targetTaskID, runID: run.generationRunID) else { return }
            completePostMortemSelfImprovement(completedTask, targetTaskID: run.targetTaskID, report: run.report)
        } catch {
            failPostMortemSelfImprovement(targetTaskID: run.targetTaskID, generationRunID: run.generationRunID, error: error)
        }

        finishGenerationTask(run.targetTaskID, runID: run.generationRunID)
    }

    private func completePostMortemSelfImprovement(
        _ completedTask: AgentTask,
        targetTaskID: UUID,
        report: SessionPostMortem.Report
    ) {
        mergeCompletedTask(completedTask, into: targetTaskID)
        persistThreadsNow()
        recordPostMortemSelfImprovementAttempt(completedTask, report: report)
    }

    private func recordPostMortemSelfImprovementAttempt(
        _ completedTask: AgentTask,
        report: SessionPostMortem.Report
    ) {
        let succeeded = completedTask.status == .completed
        SelfImprovementEngine.shared.recordAttempt(
            category: report.findings.first?.pattern.rawValue ?? "postmortem",
            description: report.summary,
            filesChanged: completedTask.steps
                .filter { $0.kind == .reviewRequest }
                .compactMap(\.diffFilePath),
            buildSuccess: succeeded,
            commitHash: nil
        )
        if succeeded {
            SelfImprovementEngine.shared.onImprovementSuccess()
        } else {
            SelfImprovementEngine.shared.onImprovementFailure()
        }
    }

    private func failPostMortemSelfImprovement(
        targetTaskID: UUID,
        generationRunID: UUID,
        error: Error
    ) {
        guard shouldAcceptGenerationCallback(for: targetTaskID, runID: generationRunID) else { return }
        if let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            state.threads[threadIndex].steps.append(
                TaskStep(kind: .error, text: "自动修复失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
            )
            state.threads[threadIndex].status = .failed
            syncAgentSnapshot(at: threadIndex)
            state.threads[threadIndex].updatedAt = Date()
            persistThreadsNow()
        }
        SelfImprovementEngine.shared.onImprovementFailure()
    }
}
