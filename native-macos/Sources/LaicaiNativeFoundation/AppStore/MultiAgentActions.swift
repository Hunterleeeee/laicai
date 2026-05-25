import Foundation
import LaicaiNativeDomain

extension AppStore {
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
            state.threads[index].connectorID = state.activeConnectorID
            state.threads[index].context = context
            state.threads[index].multiAgentPlan = plan
            state.threads[index].projectID = projectID
            state.threads[index].agentState = .running
            state.threads[index].agentGoal = message
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
                connectorID: state.activeConnectorID,
                context: context,
                multiAgentPlan: plan,
                projectID: projectID,
                agentState: .running,
                agentGoal: message,
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
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在规划多会话协同…"
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
                        guard let self else { return }
                        self.appendTaskStep(step, to: maThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self else { return }
                        self.appendStreamDelta(delta, to: maThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: maThreadID)
                    }
                )

                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: maThreadID)
                self.mergeCompletedTask(completedTask, into: maThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
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
            self.finishGenerationTask(maThreadID)
        }
    }

    private static func initialMultiAgentSteps(message: String, plan: MultiAgentPlan) -> [TaskStep] {
        let roles = plan.agents.map { $0.role.title }.joined(separator: "、")
        return [
            TaskStep(kind: .userInput, text: message, isCollapsible: false, isCollapsed: false),
            TaskStep(
                kind: .aiThinking,
                text: "多会话协同已创建：\(roles.isEmpty ? plan.title : roles)。",
                isCollapsible: true,
                isCollapsed: true,
                agentRole: .planner
            )
        ]
    }

    public func updateMultiAgentPlan(_ plan: MultiAgentPlan, for threadID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].multiAgentPlan = plan
            state.threads[idx].currentPlan = Self.agentPlanLines(for: plan, message: state.threads[idx].agentGoal ?? state.threads[idx].title)
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
