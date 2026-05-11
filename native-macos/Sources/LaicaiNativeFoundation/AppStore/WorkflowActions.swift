import Foundation
import LaicaiNativeDomain

extension AppStore {
    /// Execute a predefined workflow.
    func executeWorkflow(
        taskTitle: String,
        workflow: WorkflowDefinition,
        context: TaskContext,
        message: String,
        decision: PlannerDecision? = nil,
        userParams: [String: String] = [:]
    ) {
        guard let connector = state.activeConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        let plannerDecision = decision ?? PlannerDecision(
            intent: .workflow(workflow.name),
            confidence: 0.95,
            reason: "用户手动选择了工作流。",
            routeLabel: "工作流",
            expectedCapabilities: workflow.steps.map(\.name)
        )

        let thread = Thread(
            title: String(taskTitle.prefix(32)),
            status: .running,
            steps: [
                TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
                TaskStep(
                    kind: .aiThinking,
                    text: Self.plannerStepText(for: plannerDecision),
                    isCollapsible: true,
                    isCollapsed: true
                )
            ],
            connectorID: state.activeConnectorID,
            workflowName: workflow.name,
            context: context
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.modeLabel = "工作流"
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在执行工作流…"
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        let run = WorkflowRun(name: workflow.name, goal: message, statusLine: "执行中")
        state.workflowRuns.insert(run, at: 0)
        if state.workflowRuns.count > 20 { state.workflowRuns = Array(state.workflowRuns.prefix(20)) }
        persistThreads()

        let wfThreadID = thread.id
        generationTasks[wfThreadID] = Task { [weak self] in
            guard let self else { return }

            let steps = await StepExecutor.executeWorkflow(
                workflow,
                context: context,
                connector: connector,
                runtime: self.environment.runtimeClient,
                userParams: userParams,
                onStepProgress: { [weak self] progress in
                    guard let self else { return }
                    self.handleWorkflowStepProgress(progress, threadID: thread.id, runID: run.id)
                },
                onStreamDelta: { _ in }
            )

            guard !Task.isCancelled else { return }

            if let threadIndex = self.state.threads.firstIndex(where: { $0.id == thread.id }) {
                let hasError = steps.contains { $0.isFailure }
                self.state.threads[threadIndex].steps.append(Self.workflowCompletionCheckStep(steps: steps, hasError: hasError))
                self.state.threads[threadIndex].status = hasError ? .failed : .completed
                self.state.threads[threadIndex].updatedAt = .now
                if let runIndex = self.state.workflowRuns.firstIndex(where: { $0.id == run.id }) {
                    self.state.workflowRuns[runIndex].statusLine = hasError ? "失败" : "完成"
                    self.state.workflowRuns[runIndex].updatedAt = .now
                }
                self.persistThreadsNow()
            }

            self.finishGenerationTask(wfThreadID)
        }
    }

    func handleWorkflowStepProgress(_ progress: StepExecutor.StepProgress, threadID: UUID, runID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].steps.append(progress.taskStep)
            state.threads[idx].updatedAt = .now
            updateLiveActivity(from: progress.taskStep)
        }
        if let runIdx = state.workflowRuns.firstIndex(where: { $0.id == runID }) {
            state.workflowRuns[runIdx].statusLine = "步骤 \(progress.stepIndex + 1)/\(progress.totalSteps)：\(progress.stepName)"
        }
    }

    public func startWorkflow(named name: String, goal: String? = nil, userParams: [String: String] = [:]) {
        guard let workflow = WorkflowLibrary.find(named: name, workspaceRoot: state.settings.workspacePath) else {
            notify("未找到工作流：\(name)", style: .error)
            return
        }
        let trimmedGoal = goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = trimmedGoal.isEmpty ? "运行工作流：\(workflow.name)" : trimmedGoal
        let context = AutoContextEngine.buildContext(
            workspaceRoot: state.settings.workspacePath,
            vaultRoot: state.settings.vaultPath,
            userInput: message,
            fileLimit: state.settings.contextMode.relevantFileLimit,
            comfyUIServerURL: state.settings.comfyUIServerURL,
            comfyUIModelName: state.settings.comfyUIModelName
        )
        executeWorkflow(taskTitle: message, workflow: workflow, context: context, message: message, userParams: userParams)
    }

    public func useSkill(_ skill: SkillDefinition) {
        if let connector = ModelRouter.selectModel(for: skill, connectors: state.connectors, activeConnectorID: state.activeConnectorID),
           connector.id != state.activeConnectorID {
            selectConnector(id: connector.id)
        }

        if let workflowName = skill.workflowName {
            startWorkflow(named: workflowName, goal: "使用「\(skill.name)」")
            return
        }

        let tools = skill.tools.isEmpty ? "" : "，可用工具：\(skill.tools.joined(separator: "、"))"
        let hint = skill.systemHint.map { "\n\n执行指南：\($0)" } ?? ""
        state.draftMessage = "使用「\(skill.name)」：\(skill.description)\(tools)。\(hint)\n\n"
        notify("已套用技能：\(skill.name)", style: .success)
    }
}
