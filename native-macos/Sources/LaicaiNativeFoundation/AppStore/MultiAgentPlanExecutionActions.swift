import Foundation
import LaicaiNativeDomain

extension AppStore {
    private func connectorForPlanExecution(thread: Thread) -> ConnectorProfile? {
        if let connectorID = thread.connectorID,
            let connector = state.connectors.first(where: { $0.id == connectorID })
        {
            return connector
        }
        return state.activeConnector
    }

    /// Execute a user-edited multi-agent plan (triggered from the plan editor UI).
    public func executeEditedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
            var plan = state.threads[idx].multiAgentPlan,
            plan.isEditable || plan.status == .queued
        else { return }

        let threadBeforeStart = state.threads[idx]
        guard let connector = connectorForPlanExecution(thread: threadBeforeStart) else {
            notify("请先选择一个连接器，再执行编排计划。", style: .error)
            return
        }

        plan.isEditable = false
        plan.status = .running
        markPlanExecutionRunning(at: idx, plan: plan, connector: connector)

        let thread = state.threads[idx]

        let epThreadID = thread.id
        let generationRunID = markGenerationStarted(for: epThreadID, activity: "正在执行编排计划…")
        generationTasks[epThreadID] = Task { [weak self] in
            guard let self else { return }
            await self.runMultiAgentPlanExecution(
                MultiAgentPlanRun(
                    thread: thread,
                    plan: plan,
                    connector: connector,
                    threadID: epThreadID,
                    generationRunID: generationRunID,
                    failurePrefix: "多会话执行失败"
                ))
        }
    }

    /// Resume a failed multi-agent plan from where it left off.
    public func resumeFailedPlan(threadID: UUID) {
        guard let idx = state.threads.firstIndex(where: { $0.id == threadID }),
            var plan = state.threads[idx].multiAgentPlan,
            plan.status == .failed
        else { return }

        let threadBeforeStart = state.threads[idx]
        guard let connector = connectorForPlanExecution(thread: threadBeforeStart) else {
            notify("请先选择一个连接器，再恢复编排计划。", style: .error)
            return
        }

        Self.resetFailedAgentsForResume(&plan)
        plan.status = .running
        plan.isEditable = false
        markPlanExecutionRunning(at: idx, plan: plan, connector: connector)

        let thread = state.threads[idx]

        let rpThreadID = thread.id
        let generationRunID = markGenerationStarted(for: rpThreadID, activity: "正在恢复编排计划…")
        generationTasks[rpThreadID] = Task { [weak self] in
            guard let self else { return }
            await self.runMultiAgentPlanExecution(
                MultiAgentPlanRun(
                    thread: thread,
                    plan: plan,
                    connector: connector,
                    threadID: rpThreadID,
                    generationRunID: generationRunID,
                    failurePrefix: "多会话恢复执行失败"
                ))
        }
    }

    private func markPlanExecutionRunning(
        at index: Int,
        plan: MultiAgentPlan,
        connector: ConnectorProfile
    ) {
        state.threads[index].multiAgentPlan = plan
        state.threads[index].connectorID = connector.id
        Self.markAgentRunning(
            &state.threads[index],
            goal: Self.threadGoal(for: state.threads[index]),
            plan: Self.agentPlanLines(for: plan, message: state.threads[index].goal ?? state.threads[index].title)
        )
        state.threads[index].updatedAt = .now
    }

    private static func resetFailedAgentsForResume(_ plan: inout MultiAgentPlan) {
        for index in plan.agents.indices where plan.agents[index].status == .failed {
            plan.agents[index].status = .queued
            plan.agents[index].errorMessage = nil
            plan.agents[index].retryCount = 0
            plan.agents[index].updatedAt = .now
        }
    }

    private static func threadGoal(for thread: Thread) -> String {
        thread.goal ?? thread.steps.first(where: { $0.kind == .userInput })?.text ?? thread.title
    }

    private struct MultiAgentPlanRun {
        let thread: Thread
        let plan: MultiAgentPlan
        let connector: ConnectorProfile
        let threadID: UUID
        let generationRunID: UUID
        let failurePrefix: String
    }

    private func runMultiAgentPlanExecution(_ run: MultiAgentPlanRun) async {
        do {
            let completedTask = try await multiAgentOrchestrator().run(
                MultiAgentOrchestrator.RunRequest(
                    taskID: run.threadID,
                    message: Self.threadGoal(for: run.thread),
                    intent: .task,
                    connectorSelection: .init(connector: run.connector, allConnectors: state.connectors),
                    plan: run.plan,
                    context: run.thread.context
                ),
                onStep: { [weak self] step in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.threadID, runID: run.generationRunID) else { return }
                    self.appendTaskStep(step, to: run.threadID)
                },
                onStreamDelta: { [weak self] delta in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.threadID, runID: run.generationRunID) else { return }
                    self.appendStreamDelta(delta, to: run.threadID)
                },
                onPlanUpdate: { [weak self] updatedPlan in
                    guard let self, self.shouldAcceptGenerationCallback(for: run.threadID, runID: run.generationRunID) else { return }
                    self.updateMultiAgentPlan(updatedPlan, for: run.threadID)
                }
            )
            guard shouldAcceptGenerationCallback(for: run.threadID, runID: run.generationRunID) else { return }
            completeMultiAgentPlanExecution(completedTask, threadID: run.threadID)
        } catch {
            failMultiAgentPlanExecution(
                threadID: run.threadID,
                generationRunID: run.generationRunID,
                prefix: run.failurePrefix,
                error: error
            )
        }
        finishGenerationTask(run.threadID, runID: run.generationRunID)
    }

    private func multiAgentOrchestrator() -> MultiAgentOrchestrator {
        MultiAgentOrchestrator(
            config: .init(
                workspaceRoot: state.settings.workspacePath,
                contextMode: state.settings.contextMode
            ),
            runtime: environment.runtimeClient
        )
    }

    private func completeMultiAgentPlanExecution(_ completedTask: AgentTask, threadID: UUID) {
        flushStreamBuffer(for: threadID)
        mergeCompletedTask(completedTask, into: threadID)
        persistThreadsNow()
    }

    private func failMultiAgentPlanExecution(
        threadID: UUID,
        generationRunID: UUID,
        prefix: String,
        error: Error
    ) {
        guard shouldAcceptGenerationCallback(for: threadID, runID: generationRunID) else { return }
        flushStreamBuffer(for: threadID)
        if let idx = state.threads.firstIndex(where: { $0.id == threadID }) {
            state.threads[idx].steps.append(
                TaskStep(kind: .error, text: "\(prefix)：\(error.localizedDescription)", isFailure: true, recoverable: true)
            )
            state.threads[idx].status = .failed
            syncAgentSnapshot(at: idx)
            state.threads[idx].updatedAt = .now
            persistThreadsNow()
        }
    }
}
