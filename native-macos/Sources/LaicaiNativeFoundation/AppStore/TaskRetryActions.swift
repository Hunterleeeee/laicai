import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func retryLastMessage() {
        guard !state.isGenerating else { return }

        if let thread = state.selectedThread, thread.source == .task {
            guard thread.status != .running else { return }
            guard let lastUserStep = thread.steps.last(where: { $0.kind == .userInput }) else { return }
            BehaviorSignalTracker.record(signal: .retry, thread: thread)
            state.draftMessage = Self.retryMessage(for: thread, lastUserMessage: lastUserStep.text)
            sendDraft()
            return
        }

        guard let thread = state.selectedThread, thread.source == .session else { return }
        guard let lastUserIndex = thread.steps.lastIndex(where: { $0.kind == .userInput }) else { return }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let lastUserStep = thread.steps[lastUserIndex]
        state.threads[threadIndex].steps = Array(thread.steps.prefix(lastUserIndex))
        state.threads[threadIndex].preview = thread.steps.prefix(lastUserIndex).last?.text ?? ""
        state.draftMessage = lastUserStep.text
        persistThreads()
        sendDraft()
    }

    public func continueTask() {
        guard !state.isGenerating else { return }
        guard let thread = state.selectedThread, thread.source == .task else { return }
        guard thread.status == .failed || thread.status == .completed else { return }

        if let threadIndex = state.threads.firstIndex(where: { $0.id == thread.id }) {
            state.threads[threadIndex].status = .queued
            state.threads[threadIndex].updatedAt = .now
            persistThreads()
        }

        state.draftMessage = "继续处理，并优先基于当前证据形成结论；不要重复已经完成的读取、搜索或执行步骤。"
        sendDraft()
    }

    public func clearSelectedThread() {
        guard let threadID = state.selectedThreadID,
              let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }) else { return }
        state.threads[threadIndex].steps = []
        state.threads[threadIndex].status = .queued
        state.threads[threadIndex].preview = ""
        state.threads[threadIndex].updatedAt = .now
        persistThreads()
    }
}
