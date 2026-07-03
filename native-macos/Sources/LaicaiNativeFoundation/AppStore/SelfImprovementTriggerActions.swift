import Foundation
import LaicaiNativeDomain

extension AppStore {
    func checkAndTriggerSelfImprovement() {
        guard let diagnosis = SelfImprovementEngine.shared.shouldTrigger() else { return }
        guard let connector = state.activeConnector else { return }
        guard !state.isGenerating else { return }

        let message = SelfImprovementEngine.shared.generateImprovementTask(diagnosis: diagnosis)

        var context = AutoContextEngine.buildContext(
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            userInput: message
        )
        context.metadata["selfImproveTask"] = "true"
        context.metadata["diagnosisCategory"] = diagnosis.category.rawValue

        let userStep = TaskStep(kind: .userInput, text: "🔧 自我改进：\(diagnosis.description)", isCollapsible: false, isCollapsed: false)
        let planStep = TaskStep(
            kind: .aiThinking,
            text: "检测到性能问题，启动自我改进流程。类别：\(diagnosis.category.rawValue)，严重程度：\(diagnosis.severity.rawValue)",
            isCollapsible: true,
            isCollapsed: false
        )
        let thread = Thread(
            title: "自我改进：\(diagnosis.category.rawValue)",
            status: .running,
            steps: [userStep, planStep],
            connectorID: connector.id,
            context: context,
            executionState: .running,
            goal: message,
            currentPlan: [
                "定位自我改进问题：\(diagnosis.description)",
                "修改最小必要代码",
                "运行构建验证并记录结果"
            ]
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        persistThreads()

        let generationRunID = markGenerationStarted(for: thread.id, activity: "正在执行自我改进…")
        var loopConfig = AgentLoop.Config(
            maxIterations: 20,
            maxTokensPerTurn: 16384,
            workspaceRoot: SelfImprovementEngine.shared.harnessRoot,
            supportsToolCalling: true,
            contextMode: .deep,
            modelName: connector.modelName
        )
        loopConfig.allowedTools = [
            "file.read", "file.edit", "diff.apply", "code.search", "workspace.index", "shell.exec", "verify.build", "skill.manage", "git"
        ]

        let loop = AgentLoop(config: loopConfig, runtime: environment.runtimeClient)
        let targetID = thread.id
        agentLoops[targetID] = loop

        generationTasks[targetID] = Task { [weak self] in
            guard let self else { return }
            await self.runTriggeredSelfImprovementTask(
                SelfImprovementRun(
                    loop: loop,
                    thread: thread,
                    targetID: targetID,
                    generationRunID: generationRunID,
                    message: message,
                    connector: connector,
                    context: context,
                    diagnosis: diagnosis
                ))
        }
    }

    private struct SelfImprovementRun {
        let loop: AgentLoop
        let thread: Thread
        let targetID: UUID
        let generationRunID: UUID
        let message: String
        let connector: ConnectorProfile
        let context: TaskContext
        let diagnosis: SelfImprovementEngine.Diagnosis
    }

    private func runTriggeredSelfImprovementTask(_ run: SelfImprovementRun) async {
        do {
            let completedTask = try await run.loop.run(
                taskID: run.targetID,
                message: run.message,
                intent: UserIntent.task,
                connector: run.connector,
                context: run.context,
                priorSteps: run.thread.steps,
                onStep: { @MainActor [weak self] (step: TaskStep) in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.targetID, runID: run.generationRunID) else { return }
                    self.appendTaskStep(step, to: run.targetID)
                },
                onStreamDelta: { @Sendable @MainActor [weak self] (delta: String) in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.targetID, runID: run.generationRunID) else { return }
                    self.appendStreamDelta(delta, to: run.targetID)
                }
            )
            guard shouldAcceptGenerationCallback(for: run.targetID, runID: run.generationRunID) else { return }
            completeTriggeredSelfImprovement(completedTask, targetID: run.targetID, diagnosis: run.diagnosis)
        } catch {
            failTriggeredSelfImprovement(targetID: run.targetID, generationRunID: run.generationRunID, error: error)
        }

        finishGenerationTask(run.targetID, runID: run.generationRunID)
    }

    private func completeTriggeredSelfImprovement(
        _ completedTask: AgentTask,
        targetID: UUID,
        diagnosis: SelfImprovementEngine.Diagnosis
    ) {
        flushStreamBuffer(for: targetID)
        mergeCompletedTask(completedTask, into: targetID)
        persistThreadsNow()
        recordTriggeredSelfImprovementAttempt(completedTask, diagnosis: diagnosis)
    }

    private func recordTriggeredSelfImprovementAttempt(
        _ completedTask: AgentTask,
        diagnosis: SelfImprovementEngine.Diagnosis
    ) {
        let succeeded = completedTask.status == .completed
        SelfImprovementEngine.shared.recordAttempt(
            category: diagnosis.category.rawValue,
            description: diagnosis.description,
            filesChanged: triggeredSelfImprovementFilesChanged(from: completedTask),
            buildSuccess: succeeded,
            commitHash: nil
        )
        if succeeded {
            SelfImprovementEngine.shared.onImprovementSuccess()
        } else {
            SelfImprovementEngine.shared.onImprovementFailure()
        }
    }

    private func triggeredSelfImprovementFilesChanged(from completedTask: AgentTask) -> [String] {
        completedTask.steps
            .filter { $0.kind == .toolCall && AgentLoop.isFileChangeTool($0.toolName ?? "") }
            .map { AgentLoop.pathForFileChange(callStep: $0) }
            .filter { !$0.isEmpty }
    }

    private func failTriggeredSelfImprovement(targetID: UUID, generationRunID: UUID, error: Error) {
        guard shouldAcceptGenerationCallback(for: targetID, runID: generationRunID) else { return }
        flushStreamBuffer(for: targetID)
        if let threadIndex = state.threads.firstIndex(where: { $0.id == targetID }) {
            state.threads[threadIndex].steps.append(
                TaskStep(kind: .error, text: "自我改进失败：\(error.localizedDescription)", isFailure: true, recoverable: false)
            )
            state.threads[threadIndex].status = .failed
            syncAgentSnapshot(at: threadIndex)
            state.threads[threadIndex].updatedAt = Date()
            persistThreadsNow()
        }
        SelfImprovementEngine.shared.onImprovementFailure()
    }
}
