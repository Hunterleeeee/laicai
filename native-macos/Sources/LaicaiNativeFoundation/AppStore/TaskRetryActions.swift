import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func retryLastMessage() {
        guard !selectedThreadIsGenerating else { return }

        if let thread = state.selectedThread, thread.isExecution {
            guard thread.status != .running else { return }
            guard let lastUserStep = thread.steps.last(where: { $0.kind == .userInput }) else { return }
            BehaviorSignalTracker.record(signal: .retry, thread: thread)
            // Never replace text the user is currently composing. Retry can
            // be invoked again after the draft is sent or discarded.
            if !state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notify("编辑框里还有未发送内容，已保留；请先发送或清空后再重试。", style: .info)
                return
            }
            state.selectThread(id: thread.id)
            state.draftMessage = Self.retryMessage(for: thread, lastUserMessage: lastUserStep.text)
            sendDraft()
            return
        }

        guard let thread = state.selectedThread, thread.isChatOnly else { return }
        guard let lastUserIndex = thread.steps.lastIndex(where: { $0.kind == .userInput }) else { return }
        guard state.threads.contains(where: { $0.id == thread.id }) else { return }
        let lastUserStep = thread.steps[lastUserIndex]
        // Keep the existing turn in the conversation. Do not overwrite a
        // message the user is already composing.
        if !state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notify("编辑框里还有未发送内容，已保留；请先发送或清空后再重试。", style: .info)
            return
        }
        state.selectThread(id: thread.id)
        state.draftMessage = lastUserStep.text
        persistThreads()
        sendDraft()
    }

    public func continueTask() {
        guard let thread = state.selectedThread else { return }
        continueThread(id: thread.id)
    }

    public func continueThread(id: UUID) {
        guard !isThreadGenerating(id) else {
            notify("这个对话正在运行中，可以发送补充指令或等待完成。", style: .info)
            return
        }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == id }) else { return }
        guard state.threads[threadIndex].canContinue else {
            notify("这个对话暂时没有可继续的执行现场。", style: .info)
            return
        }
        guard state.threads[threadIndex].status != .running else {
            notify("这个对话已经在运行。", style: .info)
            return
        }

        state.selectThread(id: id)
        ProjectManager.shared.activeProjectID = state.threads[threadIndex].projectID
        state.modeLabel = "会话"
        let ledgerNext = state.threads[threadIndex].executionLedger?.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = state.threads[threadIndex].executionLedger?.pendingFollowUp?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending, !pending.isEmpty {
            state.draftMessage = pending
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
        } else if let ledgerNext, !ledgerNext.isEmpty {
            state.draftMessage = "继续处理当前。下一步：\(ledgerNext)。优先基于执行账本和已有证据，不要重复已经完成的读取、搜索或执行步骤。"
        } else {
            state.draftMessage = "继续处理，并优先基于当前证据形成结论；不要重复已经完成的读取、搜索或执行步骤。"
        }
        state.threads[threadIndex].executionLedger?.transition(to: .gatheringEvidence, reason: "用户点击继续")
        sendDraft()
    }

    public func clearSelectedThread() {
        guard let threadID = state.selectedThreadID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == threadID })
        else { return }
        cancelGenerationTask(for: threadID)
        state.threads[threadIndex].steps = []
        state.threads[threadIndex].status = .queued
        state.threads[threadIndex].executionState = .idle
        state.threads[threadIndex].goal = nil
        state.threads[threadIndex].currentPlan = []
        state.threads[threadIndex].artifacts = []
        state.threads[threadIndex].taskProtocol = nil
        state.threads[threadIndex].executionLedger = nil
        state.threads[threadIndex].preview = ""
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }
}
