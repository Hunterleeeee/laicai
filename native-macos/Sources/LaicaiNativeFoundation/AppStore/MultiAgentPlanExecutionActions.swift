import Foundation
import LaicaiNativeDomain

extension AppStore {
    private func connectorForPlanExecution(thread: Thread) -> ConnectorProfile? {
        if let connectorID = thread.connectorID,
           let connector = state.connectors.first(where: { $0.id == connectorID }) {
            return connector
        }
        return state.activeConnector
    }

    /// Execute a user-edited multi-agent plan (triggered from the plan editor UI).
    public func executeEditedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.isEditable || plan.status == .queued else { return }

        let threadBeforeStart = state.threads[idx]
        guard let connector = connectorForPlanExecution(thread: threadBeforeStart) else {
            notify("请先选择一个连接器，再执行编排计划。", style: .error)
            return
        }

        plan.isEditable = false
        plan.status = .running
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].connectorID = connector.id
        Self.markAgentRunning(
            &state.threads[idx],
            goal: state.threads[idx].goal ?? state.threads[idx].steps.first(where: { $0.kind == .userInput })?.text ?? state.threads[idx].title,
            plan: Self.agentPlanLines(for: plan, message: state.threads[idx].goal ?? state.threads[idx].title)
        )
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        let epThreadID = thread.id
        let generationRunID = markGenerationStarted(for: epThreadID, activity: "正在执行编排计划…")
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
                        guard let self, self.shouldAcceptGenerationCallback(for: epThreadID, runID: generationRunID) else { return }
                        self.appendTaskStep(step, to: epThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self, self.shouldAcceptGenerationCallback(for: epThreadID, runID: generationRunID) else { return }
                        self.appendStreamDelta(delta, to: epThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self, self.shouldAcceptGenerationCallback(for: epThreadID, runID: generationRunID) else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: epThreadID)
                    }
                )
                guard self.shouldAcceptGenerationCallback(for: epThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: epThreadID)
                self.mergeCompletedTask(completedTask, into: epThreadID)
                self.persistThreadsNow()
            } catch {
                guard self.shouldAcceptGenerationCallback(for: epThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: epThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == epThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多会话执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.syncAgentSnapshot(at: idx)
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.finishGenerationTask(epThreadID, runID: generationRunID)
        }
    }

    /// Resume a failed multi-agent plan from where it left off.
    public func resumeFailedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
              var plan = state.threads[idx].multiAgentPlan,
              plan.status == .failed else { return }

        let threadBeforeStart = state.threads[idx]
        guard let connector = connectorForPlanExecution(thread: threadBeforeStart) else {
            notify("请先选择一个连接器，再恢复编排计划。", style: .error)
            return
        }

        for i in plan.agents.indices where plan.agents[i].status == .failed {
            plan.agents[i].status = .queued
            plan.agents[i].errorMessage = nil
            plan.agents[i].retryCount = 0
            plan.agents[i].updatedAt = .now
        }
        plan.status = .running
        plan.isEditable = false
        state.threads[idx].multiAgentPlan = plan
        state.threads[idx].connectorID = connector.id
        Self.markAgentRunning(
            &state.threads[idx],
            goal: state.threads[idx].goal ?? state.threads[idx].steps.first(where: { $0.kind == .userInput })?.text ?? state.threads[idx].title,
            plan: Self.agentPlanLines(for: plan, message: state.threads[idx].goal ?? state.threads[idx].title)
        )
        state.threads[idx].updatedAt = .now

        let thread = state.threads[idx]
        let message = thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title

        let rpThreadID = thread.id
        let generationRunID = markGenerationStarted(for: rpThreadID, activity: "正在恢复编排计划…")
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
                        guard let self, self.shouldAcceptGenerationCallback(for: rpThreadID, runID: generationRunID) else { return }
                        self.appendTaskStep(step, to: rpThreadID)
                    },
                    onStreamDelta: { [weak self] delta in
                        guard let self, self.shouldAcceptGenerationCallback(for: rpThreadID, runID: generationRunID) else { return }
                        self.appendStreamDelta(delta, to: rpThreadID)
                    },
                    onPlanUpdate: { [weak self] updatedPlan in
                        guard let self, self.shouldAcceptGenerationCallback(for: rpThreadID, runID: generationRunID) else { return }
                        self.updateMultiAgentPlan(updatedPlan, for: rpThreadID)
                    }
                )
                guard self.shouldAcceptGenerationCallback(for: rpThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: rpThreadID)
                self.mergeCompletedTask(completedTask, into: rpThreadID)
                self.persistThreadsNow()
            } catch {
                guard self.shouldAcceptGenerationCallback(for: rpThreadID, runID: generationRunID) else { return }
                self.flushStreamBuffer(for: rpThreadID)
                if let idx = self.state.threads.firstIndex(where: { $0.id == rpThreadID }) {
                    self.state.threads[idx].steps.append(
                        TaskStep(kind: .error, text: "多会话恢复执行失败：\(error.localizedDescription)", isFailure: true, recoverable: true)
                    )
                    self.state.threads[idx].status = .failed
                    self.syncAgentSnapshot(at: idx)
                    self.state.threads[idx].updatedAt = .now
                    self.persistThreadsNow()
                }
            }
            self.finishGenerationTask(rpThreadID, runID: generationRunID)
        }
    }
}
