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
        userParams: [String: String] = [:],
        projectID: UUID? = nil,
        reuseThreadID: UUID? = nil
    ) {
        guard let connector = state.activeConnector else {
            notify("请先选择一个连接器", style: .error)
            return
        }
        let plannerDecision =
            decision
            ?? PlannerDecision(
                intent: .workflow(workflow.name),
                confidence: 0.95,
                reason: "用户手动选择了工作流。",
                routeLabel: "会话 工作流",
                expectedCapabilities: workflow.steps.map(\.name)
            )

        let initialSteps = [
            TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
            TaskStep(
                kind: .aiThinking,
                text: "规划：工作流 \(workflow.name) 正在准备执行。",
                isCollapsible: true,
                isCollapsed: true
            )
        ]
        let threadID = reuseThreadID ?? UUID()
        let plan = Self.agentPlanLines(for: plannerDecision, message: message)
        if let reuseThreadID, let index = state.threads.firstIndex(where: { $0.id == reuseThreadID }) {
            state.threads[index].title = String(taskTitle.prefix(32))
            state.threads[index].status = .running
            state.threads[index].steps = initialSteps
            state.threads[index].connectorID = connector.id
            state.threads[index].workflowName = workflow.name
            state.threads[index].context = context
            state.threads[index].projectID = projectID
            state.threads[index].executionState = .running
            state.threads[index].goal = message
            state.threads[index].currentPlan = plan
            state.threads[index].taskProtocol = Self.makeTaskProtocol(threadID: threadID, message: message, context: context, decision: plannerDecision)
            state.threads[index].executionLedger = Self.makeExecutionLedger(
                threadID: threadID, message: message, context: context, decision: plannerDecision, plan: plan)
            state.threads[index].updatedAt = .now
        } else {
            let thread = Thread(
                id: threadID,
                title: String(taskTitle.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: connector.id,
                workflowName: workflow.name,
                context: context,
                projectID: projectID,
                executionState: .running,
                goal: message,
                currentPlan: plan,
                taskProtocol: Self.makeTaskProtocol(threadID: threadID, message: message, context: context, decision: plannerDecision),
                executionLedger: Self.makeExecutionLedger(threadID: threadID, message: message, context: context, decision: plannerDecision, plan: plan)
            )
            state.threads.insert(thread, at: 0)
        }
        state.selectThread(id: threadID)
        state.modeLabel = "会话 工作流"
        let generationRunID = markGenerationStarted(for: threadID, activity: "会话 正在执行工作流…")
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        let run = WorkflowRun(name: workflow.name, goal: message, statusLine: "执行中")
        state.workflowRuns.insert(run, at: 0)
        if state.workflowRuns.count > 20 { state.workflowRuns = Array(state.workflowRuns.prefix(20)) }
        persistThreads()

        let wfThreadID = threadID
        generationTasks[wfThreadID] = Task { [weak self] in
            guard let self else { return }

            let steps = await StepExecutor.executeWorkflow(
                workflow,
                context: context,
                connector: connector,
                runtime: self.environment.runtimeClient,
                userParams: userParams,
                onStepProgress: { [weak self] progress in
                    guard let self, self.shouldAcceptGenerationCallback(for: wfThreadID, runID: generationRunID) else { return }
                    self.handleWorkflowStepProgress(progress, threadID: threadID, runID: run.id, generationRunID: generationRunID)
                },
                onStreamDelta: { _ in }
            )

            guard self.shouldAcceptGenerationCallback(for: wfThreadID, runID: generationRunID) else { return }

            if let threadIndex = self.state.threads.firstIndex(where: { $0.id == threadID }) {
                let hasError = steps.contains { $0.isFailure }
                self.state.threads[threadIndex].steps.append(Self.workflowCompletionCheckStep(steps: steps, hasError: hasError))
                self.state.threads[threadIndex].status = hasError ? .failed : .completed
                self.syncAgentSnapshot(at: threadIndex)
                Self.ensureCheckpointIfNeeded(&self.state.threads[threadIndex])
                self.state.threads[threadIndex].updatedAt = .now
                if let runIndex = self.state.workflowRuns.firstIndex(where: { $0.id == run.id }) {
                    self.state.workflowRuns[runIndex].statusLine = hasError ? "失败" : "完成"
                    self.state.workflowRuns[runIndex].updatedAt = .now
                }
                self.persistThreadsNow()
            }

            self.finishGenerationTask(wfThreadID, runID: generationRunID)
        }
    }

    func handleWorkflowStepProgress(_ progress: StepExecutor.StepProgress, threadID: UUID, runID: UUID, generationRunID: UUID? = nil) {
        guard shouldAcceptGenerationCallback(for: threadID, runID: generationRunID) else { return }
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].steps.append(progress.taskStep)
            state.threads[idx].updatedAt = .now
            updateLiveActivity(from: progress.taskStep, for: threadID)
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
        executeWorkflow(
            taskTitle: message,
            workflow: workflow,
            context: context,
            message: message,
            userParams: userParams,
            projectID: nil
        )
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
