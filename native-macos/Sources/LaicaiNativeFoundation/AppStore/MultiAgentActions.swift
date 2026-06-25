import Foundation
import LaicaiNativeDomain

extension AppStore {
    func createMultiAgentPlanDraft(
        message: String,
        context: TaskContext,
        connector: ConnectorProfile,
        plan: MultiAgentPlan,
        decision: PlannerDecision,
        projectID: UUID? = nil,
        reuseThreadID: UUID? = nil
    ) {
        var editablePlan = plan
        editablePlan.status = .queued
        editablePlan.isEditable = true
        editablePlan.updatedAt = .now

        let planLines = Self.agentPlanLines(for: editablePlan, message: message)
        let initialSteps = Self.initialMultiAgentSteps(message: message, plan: editablePlan)
        let threadID = reuseThreadID ?? UUID()
        let taskProtocol = Self.makeTaskProtocol(
            threadID: threadID,
            message: message,
            context: context,
            decision: decision
        )
        let ledger = AgentExecutionLedger(
            originalRequest: message,
            goal: message,
            state: .waitingUser,
            stateHistory: ["created -> waitingUser：等待确认多会话编排计划"],
            plan: planLines,
            nextAction: "确认或调整编排计划后开始执行"
        )

        if let reuseThreadID, let index = state.threads.firstIndex(where: { $0.id == reuseThreadID }) {
            state.threads[index].title = String(message.prefix(32))
            state.threads[index].status = .waitingReview
            state.threads[index].steps = initialSteps
            state.threads[index].connectorID = connector.id
            state.threads[index].context = context
            state.threads[index].multiAgentPlan = editablePlan
            state.threads[index].projectID = projectID
            state.threads[index].executionState = .waitingForApproval
            state.threads[index].goal = message
            state.threads[index].currentPlan = planLines
            state.threads[index].taskProtocol = taskProtocol
            state.threads[index].executionLedger = ledger
            state.threads[index].updatedAt = .now
            syncAgentSnapshot(at: index)
        } else {
            var thread = Thread(
                id: threadID,
                title: String(message.prefix(32)),
                status: .waitingReview,
                steps: initialSteps,
                connectorID: connector.id,
                context: context,
                multiAgentPlan: editablePlan,
                projectID: projectID,
                executionState: .waitingForApproval,
                goal: message,
                currentPlan: planLines,
                taskProtocol: taskProtocol,
                executionLedger: ledger
            )
            Self.syncAgentSnapshot(&thread)
            state.threads.insert(thread, at: 0)
        }

        state.selectThread(id: threadID)
        state.modeLabel = "多会话待确认"
        syncGeneratingStateForSelectedThread()
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        notify("已生成多会话编排计划，确认后开始执行。", style: .info)
        persistThreads()
    }

    func executeMultiAgent(
        message: String,
        context: TaskContext,
        connector: ConnectorProfile,
        plan: MultiAgentPlan,
        intent: UserIntent,
        decision: PlannerDecision,
        projectID: UUID? = nil,
        reuseThreadID: UUID? = nil
    ) {
        let planLines = Self.agentPlanLines(for: plan, message: message)
        let initialSteps = Self.initialMultiAgentSteps(message: message, plan: plan)
        let threadID = reuseThreadID ?? UUID()
        if let reuseThreadID, let index = state.threads.firstIndex(where: { $0.id == reuseThreadID }) {
            state.threads[index].title = String(message.prefix(32))
            state.threads[index].status = .running
            state.threads[index].steps = initialSteps
            state.threads[index].connectorID = connector.id
            state.threads[index].context = context
            state.threads[index].multiAgentPlan = plan
            state.threads[index].projectID = projectID
            state.threads[index].executionState = .running
            state.threads[index].goal = message
            state.threads[index].currentPlan = planLines
            state.threads[index].taskProtocol = Self.makeTaskProtocol(
                threadID: threadID,
                message: message,
                context: context,
                decision: decision
            )
            state.threads[index].executionLedger = Self.makeExecutionLedger(
                threadID: threadID,
                message: message,
                context: context,
                decision: decision,
                plan: planLines
            )
            state.threads[index].updatedAt = .now
        } else {
            let thread = Thread(
                id: threadID,
                title: String(message.prefix(32)),
                status: .running,
                steps: initialSteps,
                connectorID: connector.id,
                context: context,
                multiAgentPlan: plan,
                projectID: projectID,
                executionState: .running,
                goal: message,
                currentPlan: planLines,
                taskProtocol: Self.makeTaskProtocol(
                    threadID: threadID,
                    message: message,
                    context: context,
                    decision: decision
                ),
                executionLedger: Self.makeExecutionLedger(
                    threadID: threadID,
                    message: message,
                    context: context,
                    decision: decision,
                    plan: planLines
                )
            )
            state.threads.insert(thread, at: 0)
        }
        state.selectThread(id: threadID)
        state.modeLabel = "多会话协同"
        let generationRunID = markGenerationStarted(for: threadID, activity: "正在规划多会话协同…")
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        persistThreads()

        let orchConfig = MultiAgentOrchestrator.Config(
            workspaceRoot: state.settings.workspacePath,
            contextMode: state.settings.contextMode
        )
        let orchestrator = MultiAgentOrchestrator(
            config: orchConfig,
            runtime: environment.runtimeClient
        )

        let maThreadID = threadID
        generationTasks[maThreadID] = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTask = try await orchestrator.run(
                    taskID: maThreadID,
                    message: message,
                    intent: intent,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: context,
                    plan: plan,
                    onStep: { [weak self] step in
                        guard let self, self.shouldAcceptGenerationCallback(for: maThreadID, runID: generationRunID) else { return }
                        self.appendTaskStep(step, to: maThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self, self.shouldAcceptGenerationCallback(for: maThreadID, runID: generationRunID) else { return }
                        self.appendStreamDelta(delta, to: maThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self, self.shouldAcceptGenerationCallback(for: maThreadID, runID: generationRunID) else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: maThreadID)
                    }
                )

                guard self.shouldAcceptGenerationCallback(for: maThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: maThreadID)
                self.mergeCompletedTask(completedTask, into: maThreadID)
                self.persistThreadsNow()
            } catch {
                guard self.shouldAcceptGenerationCallback(for: maThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: maThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == maThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多会话执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.syncAgentSnapshot(at: idx)
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.finishGenerationTask(maThreadID, runID: generationRunID)
        }
    }

    private static func initialMultiAgentSteps(message: String, plan: MultiAgentPlan) -> [TaskStep] {
        let roles = plan.agents.map { $0.role.title }.joined(separator: "、")
        let suffix = roles.isEmpty ? plan.title : roles
        let statusText = plan.isEditable
            ? "多会话协同已创建，等待确认：\(suffix)。"
            : "多会话协同已创建：\(suffix)。"
        return [
            TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
            TaskStep(
                kind: .aiThinking,
                text: statusText,
                isCollapsible: true,
                isCollapsed: true,
                agentRole: .planner
            )
        ]
    }

    public func updateMultiAgentPlan(_ plan: MultiAgentPlan, for threadID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].multiAgentPlan = plan
            state.threads[idx].currentPlan = Self.agentPlanLines(for: plan, message: state.threads[idx].goal ?? state.threads[idx].title)
            syncAgentSnapshot(at: idx)
        }
    }

    /// Cancel a multi-agent plan (user chose to cancel from plan editor).
    public func cancelMultiAgentPlan(for threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[idx].multiAgentPlan = nil
        state.threads[idx].status = .cancelled
        syncAgentSnapshot(at: idx)
        state.threads[idx].updatedAt = .now
        persistThreads()
    }
}
