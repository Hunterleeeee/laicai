import Foundation
import LaicaiNativeDomain

extension AppStore {
    private func trimmedPendingFollowUp(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func pendingFollowUp(for targetTaskID: UUID) -> String? {
        if let thread = state.threads.first(where: { $0.id == targetTaskID }),
            let pending = trimmedPendingFollowUp(thread.executionLedger?.pendingFollowUp)
        {
            return pending
        }
        guard targetTaskID == state.selectedThreadID else { return nil }
        return trimmedPendingFollowUp(state.pendingFollowUp)
    }

    func consumePendingFollowUp(for targetTaskID: UUID) -> String? {
        guard let followUp = pendingFollowUp(for: targetTaskID) else { return nil }
        if let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
        }
        if targetTaskID == state.selectedThreadID {
            state.pendingFollowUp = nil
            state.draftMessage = ""
        }
        return followUp
    }

    func appendPendingFollowUp(to targetTaskID: UUID) {
        guard let followUp = consumePendingFollowUp(for: targetTaskID) else { return }
        if let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
            state.threads[threadIndex].steps.append(step)
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
            state.threads[threadIndex].executionLedger?.nextAction = "处理用户补充：\(followUp)"
            state.threads[threadIndex].executionLedger?.transition(to: .executing, reason: "运行结束后接续 pending follow-up")
            state.threads[threadIndex].updatedAt = .now
            persistThreadsNow()
        }
    }

    func shouldAcceptGenerationCallback(for targetTaskID: UUID, runID: UUID? = nil) -> Bool {
        guard generationTasks[targetTaskID] != nil, !Task.isCancelled else { return false }
        guard let runID else { return true }
        return generationRunIDs[targetTaskID] == runID
    }

    func finishGenerationTask(_ targetTaskID: UUID, runID: UUID? = nil) {
        if let runID, generationRunIDs[targetTaskID] != runID {
            return
        }
        generationTasks.removeValue(forKey: targetTaskID)
        agentLoops.removeValue(forKey: targetTaskID)
        streamBuffers.removeValue(forKey: targetTaskID)
        streamLastFlushAt.removeValue(forKey: targetTaskID)
        thinkingBuffers.removeValue(forKey: targetTaskID)
        thinkingLastFlushAt.removeValue(forKey: targetTaskID)
        generationStartTimes.removeValue(forKey: targetTaskID)
        liveActivitiesByThread.removeValue(forKey: targetTaskID)
        generationRunIDs.removeValue(forKey: targetTaskID)
        if generationTasks.isEmpty {
            state.isGenerating = false
            state.generationStartedAt = nil
            state.liveActivity = ""
        } else {
            syncGeneratingStateForSelectedThread()
        }
    }
}
