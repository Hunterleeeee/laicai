import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func sendDraft() {
        reconcileSelectedRunningTaskIfIdle()
        let message = composedDraftMessage()
        let selectedThreadRunning: Bool = {
            guard let tid = state.selectedThreadID else { return false }
            return generationTasks[tid] != nil
        }()
        guard !message.isEmpty, !selectedThreadRunning else { return }

        if handleSlashCommand(message) { return }

        let agentInvocation = customAgentInvocation(from: message)
        var effectiveMessage = agentInvocation?.message ?? message
        effectiveMessage = Self.enrichVagueMessage(effectiveMessage, thread: state.selectedThread)

        if answerSelectedTaskStatusQuestion(effectiveMessage) {
            return
        }
        var decision = IntentRouter.plan(effectiveMessage)

        if decision.intent == .chat,
           let tid = state.selectedThreadID,
           let thread = state.threads.first(where: { $0.id == tid }),
           thread.steps.contains(where: { $0.kind == .toolCall }) {
            decision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.75),
                reason: decision.reason + " [线程已有工具调用历史，自动升级为任务模式]",
                routeLabel: "任务",
                expectedCapabilities: decision.expectedCapabilities + ["运行命令", "提出文件修改"]
            )
        }

        let matchedSkill = SkillMatcher.match(input: effectiveMessage, intent: decision.intent)
        sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent, matchedSkill: matchedSkill)
    }
}
