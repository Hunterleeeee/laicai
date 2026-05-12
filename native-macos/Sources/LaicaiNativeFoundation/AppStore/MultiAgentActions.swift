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
        projectID: UUID? = nil
    ) {
        let thread = Thread(
            title: String(message.prefix(32)),
            status: .running,
            steps: [],
            connectorID: state.activeConnectorID,
            context: context,
            multiAgentPlan: plan,
            projectID: projectID
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        state.modeLabel = "多Agent协同"
        state.isGenerating = true
        state.generationStartedAt = Date()
        state.liveActivity = "正在规划多Agent协同…"
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

        let maThreadID = thread.id
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
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.finishGenerationTask(maThreadID)
        }
    }

    public func updateMultiAgentPlan(_ plan: MultiAgentPlan, for threadID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].multiAgentPlan = plan
        }
    }

    /// Cancel a multi-agent plan (user chose to cancel from plan editor).
    public func cancelMultiAgentPlan(for threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[idx].multiAgentPlan = nil
        state.threads[idx].status = .cancelled
        state.threads[idx].updatedAt = .now
        persistThreads()
    }
}
