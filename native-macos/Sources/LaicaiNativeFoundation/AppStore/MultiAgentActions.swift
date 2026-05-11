import Foundation
import LaicaiNativeDomain

extension AppStore {
    func executeMultiAgent(
        message: String,
        context: TaskContext,
        connector: ConnectorProfile,
        plan: MultiAgentPlan,
        intent: UserIntent,
        decision: PlannerDecision
    ) {
        let thread = Thread(
            title: String(message.prefix(32)),
            status: .running,
            steps: [],
            connectorID: state.activeConnectorID,
            context: context,
            multiAgentPlan: plan
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
            self.generationTasks.removeValue(forKey: maThreadID)
            self.streamBuffers.removeValue(forKey: maThreadID)
            self.streamLastFlushAt.removeValue(forKey: maThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }

    public func updateMultiAgentPlan(_ plan: MultiAgentPlan, for threadID: UUID) {
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].multiAgentPlan = plan
        }
    }

    /// Execute a user-edited multi-agent plan (triggered from the plan editor UI).
    public func executeEditedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.isEditable else { return }

        plan.isEditable = false
        plan.status = .running
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].status = .running
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        guard let connector = state.activeConnector else { return }

        state.isGenerating = true
        state.generationStartedAt = Date()
        let epThreadID = thread.id
        generationTasks[epThreadID] = Task { [weak self] in
            guard let self else { return }
            let orchestrator = MultiAgentOrchestrator(
                config: .init(
                    workspaceRoot: self.state.settings.workspacePath,
                    contextMode: self.state.settings.contextMode
                ),
                runtime: self.environment.runtimeClient
            )
            do {
                let completedTask = try await orchestrator.run(
                    taskID: epThreadID,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: epThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: epThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: epThreadID)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: epThreadID)
                self.mergeCompletedTask(completedTask, into: epThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: epThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == epThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.generationTasks.removeValue(forKey: epThreadID)
            self.streamBuffers.removeValue(forKey: epThreadID)
            self.streamLastFlushAt.removeValue(forKey: epThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
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

    /// Resume a failed multi-agent plan from where it left off.
    public func resumeFailedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.status == .failed else { return }

        for i in plan.agents.indices where plan.agents[i].status == .failed {
            plan.agents[i].status = .queued
            plan.agents[i].errorMessage = nil
            plan.agents[i].retryCount = 0
            plan.agents[i].updatedAt = .now
        }
        plan.status = .running
        plan.isEditable = false
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].status = .running
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        guard let connector = state.activeConnector else { return }

        state.isGenerating = true
        state.generationStartedAt = Date()
        let rpThreadID = thread.id
        generationTasks[rpThreadID] = Task { [weak self] in
            guard let self else { return }
            let orchestrator = MultiAgentOrchestrator(
                config: .init(
                    workspaceRoot: self.state.settings.workspacePath,
                    contextMode: self.state.settings.contextMode
                ),
                runtime: self.environment.runtimeClient
            )
            do {
                let completedTask = try await orchestrator.run(
                    taskID: rpThreadID,
                    message: message,
                    intent: .task,
                    connector: connector,
                    allConnectors: self.state.connectors,
                    context: thread.context,
                    plan: plan,
                    onStep: { [weak self] step in
                        self?.appendTaskStep(step, to: rpThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        self?.appendStreamDelta(delta, to: rpThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        self?.updateMultiAgentPlan(updatedPlan, for: rpThreadID)
                    }
                )
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: rpThreadID)
                self.mergeCompletedTask(completedTask, into: rpThreadID)
                self.persistThreadsNow()
            } catch {
                guard !Task.isCancelled else { return }
                self.flushStreamBuffer(for: rpThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == rpThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多Agent恢复执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.generationTasks.removeValue(forKey: rpThreadID)
            self.streamBuffers.removeValue(forKey: rpThreadID)
            self.streamLastFlushAt.removeValue(forKey: rpThreadID)
            if self.generationTasks.isEmpty {
                self.state.isGenerating = false
                self.state.generationStartedAt = nil
                self.state.liveActivity = ""
            }
        }
    }
}
