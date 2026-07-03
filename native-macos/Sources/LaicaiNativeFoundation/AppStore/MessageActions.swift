import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func sendDraft() {
        reconcileSelectedRunningTaskIfIdle()
        let message = composedDraftMessage()
        guard !message.isEmpty else { return }
        if selectedThreadIsGenerating {
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
        decision = Self.standaloneChatDecisionIfNeeded(decision, message: effectiveMessage)
        decision = selectedTaskFollowUpDecision(decision, message: effectiveMessage)

        let matchedSkill = SkillMatcher.match(input: effectiveMessage, intent: decision.intent)
        sendTaskDraft(message: effectiveMessage, decision: decision, customAgent: agentInvocation?.agent, matchedSkill: matchedSkill)
    }

    private static func standaloneChatDecisionIfNeeded(_ decision: PlannerDecision, message: String) -> PlannerDecision {
        guard decision.intent != .chat,
              isStandaloneCapabilityOrConceptQuestion(message) || isStandaloneGeneralQuestion(message) else { return decision }
        return PlannerDecision(
            intent: .chat,
            confidence: max(decision.confidence, 0.82),
            reason: "这是独立能力、概念或泛问题，不应续接当前执行任务。",
            routeLabel: "会话 问答",
            expectedCapabilities: ["解释", "分析", "规划"]
        )
    }

    private func selectedTaskFollowUpDecision(_ decision: PlannerDecision, message: String) -> PlannerDecision {
        guard decision.intent == .chat,
              let thread = selectedTaskFollowUpThread(message: message) else { return decision }
        let readOnlyFollowUp = Self.isReadOnlyInvestigationFollowUp(message)
        let shouldExecuteFollowUp = Self.isExplicitExecutionFollowUp(message)
            || (!readOnlyFollowUp && Self.isContinuationCommand(message) && thread.status != .completed)
        return PlannerDecision(
            intent: .task,
            confidence: max(decision.confidence, 0.75),
            reason: followUpReason(base: decision.reason, shouldExecute: shouldExecuteFollowUp),
            routeLabel: shouldExecuteFollowUp ? "会话 执行" : "会话 分析",
            expectedCapabilities: Array(Set(followUpExpectedCapabilities(
                thread: thread,
                message: message,
                shouldExecute: shouldExecuteFollowUp
            )))
        )
    }

    private func selectedTaskFollowUpThread(message: String) -> Thread? {
        guard let tid = state.selectedThreadID,
              let thread = state.threads.first(where: { $0.id == tid }),
              thread.isExecution || thread.steps.contains(where: { $0.kind == .toolCall }),
              Self.shouldRouteChatFollowUpIntoSelectedTask(message: message, task: AgentTask(thread: thread)) else { return nil }
        return thread
    }

    private func followUpExpectedCapabilities(
        thread: Thread,
        message: String,
        shouldExecute: Bool
    ) -> [String] {
        let originalMessage = thread.goal
            ?? thread.steps.first(where: { $0.kind == .userInput })?.text
            ?? thread.title
        let originalDecision = IntentRouter.plan(originalMessage)
        var capabilities = shouldExecute ? originalDecision.expectedCapabilities : ["读取工作区", "解释", "分析"]
        if shouldExecute, capabilities.isEmpty || originalDecision.intent == .chat {
            capabilities = ["读取工作区", "形成可验证结果"]
        }
        if shouldExecute,
           !thread.context.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !capabilities.contains("读取工作区") {
            capabilities.append("读取工作区")
        }
        if Self.isWikiPersistenceFollowUp(message) {
            capabilities.append("写入知识库")
        }
        return capabilities
    }

    private func followUpReason(base: String, shouldExecute: Bool) -> String {
        base + (shouldExecute
            ? " [当前会话已有工具调用历史，按明确续跑/执行意图恢复执行姿态]"
            : " [当前会话已有工具调用历史，本轮按只读追问续接，不默认修改或运行命令]")
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
