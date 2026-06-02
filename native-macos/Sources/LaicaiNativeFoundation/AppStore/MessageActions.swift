import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func sendDraft() {
        reconcileSelectedRunningTaskIfIdle()
        let message = composedDraftMessage()
        let selectedThreadRunning: Bool = {
            guard let tid = state.selectedThreadID else { return false }
            return generationTasks[tid] != nil || state.isGenerating && state.selectedThread?.status == .running
        }()
        guard !message.isEmpty else { return }
        if selectedThreadRunning {
            submitFollowUp()
            state.draftMessage = ""
            return
        }

        if handleSlashCommand(message) { return }

        let agentInvocation = customAgentInvocation(from: message)
        var effectiveMessage = agentInvocation?.message ?? message
        effectiveMessage = Self.enrichVagueMessage(effectiveMessage, thread: state.selectedThread)

        if answerSelectedTaskStatusQuestion(effectiveMessage) {
            return
        }
        var decision = IntentRouter.plan(effectiveMessage)
        if decision.intent != .chat,
           Self.isStandaloneCapabilityOrConceptQuestion(effectiveMessage) || Self.isStandaloneGeneralQuestion(effectiveMessage) {
            decision = PlannerDecision(
                intent: .chat,
                confidence: max(decision.confidence, 0.82),
                reason: "这是独立能力、概念或泛问题，不应续接当前执行任务。",
                routeLabel: "会话 问答",
                expectedCapabilities: ["解释", "分析", "规划"]
            )
        }

        if decision.intent == .chat,
           let tid = state.selectedThreadID,
           let thread = state.threads.first(where: { $0.id == tid }),
           (thread.isExecution || thread.steps.contains(where: { $0.kind == .toolCall })),
           Self.shouldRouteChatFollowUpIntoSelectedTask(message: effectiveMessage, task: AgentTask(thread: thread)) {
            var expectedCapabilities = decision.expectedCapabilities + ["运行命令", "提出文件修改"]
            if Self.isWikiPersistenceFollowUp(effectiveMessage) {
                expectedCapabilities.append("写入知识库")
            }
            decision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.75),
                reason: decision.reason + " [当前会话 已有工具调用历史，自动切换为执行姿态]",
                routeLabel: "会话 执行",
                expectedCapabilities: Array(Set(expectedCapabilities))
            )
        }

        if decision.intent == .chat, agentInvocation == nil {
            // All messages flow through the same execution path regardless of thread type.
            // The isChatIntent flag in sendTaskDraft dynamically limits iterations and tools.
        }

        let matchedSkill = SkillMatcher.match(input: effectiveMessage, intent: decision.intent)
        sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent, matchedSkill: matchedSkill)
    }
}
