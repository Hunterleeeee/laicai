import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func sendDraft() {
        reconcileSelectedRunningTaskIfIdle()
        let message = composedDraftMessage()
        let selectedThreadRunning: Bool = {
            guard let tid = state.selectedThreadID else { return false }
            return isThreadGenerating(tid)
        }()
        guard !message.isEmpty else { return }
        if selectedThreadRunning {
            submitFollowUp()
            state.draftMessage = ""
            return
        }
        if executeQueuedMultiAgentPlanIfRequested(message) {
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
            let readOnlyFollowUp = Self.isReadOnlyInvestigationFollowUp(effectiveMessage)
            let shouldExecuteFollowUp = Self.isExplicitExecutionFollowUp(effectiveMessage)
                || (!readOnlyFollowUp && Self.isContinuationCommand(effectiveMessage) && thread.status != .completed)
            let originalMessage = thread.goal
                ?? thread.steps.first(where: { $0.kind == .userInput })?.text
                ?? thread.title
            let originalDecision = IntentRouter.plan(originalMessage)
            var expectedCapabilities = shouldExecuteFollowUp
                ? originalDecision.expectedCapabilities
                : ["读取工作区", "解释", "分析"]
            if shouldExecuteFollowUp, expectedCapabilities.isEmpty || originalDecision.intent == .chat {
                expectedCapabilities = ["读取工作区", "形成可验证结果"]
            }
            if shouldExecuteFollowUp,
               !thread.context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !expectedCapabilities.contains("读取工作区") {
                expectedCapabilities.append("读取工作区")
            }
            if Self.isWikiPersistenceFollowUp(effectiveMessage) {
                expectedCapabilities.append("写入知识库")
            }
            decision = PlannerDecision(
                intent: .task,
                confidence: max(decision.confidence, 0.75),
                reason: decision.reason + (shouldExecuteFollowUp
                    ? " [当前会话已有工具调用历史，按明确续跑/执行意图恢复执行姿态]"
                    : " [当前会话已有工具调用历史，本轮按只读追问续接，不默认修改或运行命令]"),
                routeLabel: shouldExecuteFollowUp ? "会话 执行" : "会话 分析",
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

    private func executeQueuedMultiAgentPlanIfRequested(_ message: String) -> Bool {
        guard let thread = state.selectedThread,
              let plan = thread.multiAgentPlan,
              plan.isEditable,
              plan.status == .queued,
              Self.isQueuedPlanExecutionCommand(message) else {
            return false
        }
        executeEditedPlan(threadID: thread.id)
        if isThreadGenerating(thread.id) {
            state.draftMessage = ""
            state.draftAttachments = []
            state.draftImages = []
        }
        return true
    }

    private static func isQueuedPlanExecutionCommand(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if isContinuationCommand(normalized) { return true }
        let commands = ["执行", "开始", "确认", "确认执行", "确认并执行", "开始执行", "按这个执行", "就这样", "跑起来"]
        return commands.contains { normalized == $0 || normalized.contains($0) }
    }
}
