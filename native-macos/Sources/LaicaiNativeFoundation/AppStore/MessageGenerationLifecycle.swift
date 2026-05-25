import Foundation
import LaicaiNativeDomain

extension AppStore {
    func appendPendingFollowUp(to targetTaskID: UUID) {
        guard let followUp = state.pendingFollowUp, !followUp.isEmpty else { return }
        if let threadIndex = state.threads.firstIndex(where: { $0.id == targetTaskID }) {
            let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
            state.threads[threadIndex].steps.append(step)
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
            state.threads[threadIndex].executionLedger?.nextAction = "处理用户补充：\(followUp)"
            state.threads[threadIndex].executionLedger?.transition(to: .executing, reason: "运行结束后接续 pending follow-up")
            state.threads[threadIndex].updatedAt = .now
            persistThreadsNow()
        }
        state.pendingFollowUp = nil
    }

    func finishGenerationTask(_ targetTaskID: UUID) {
        generationTasks.removeValue(forKey: targetTaskID)
        agentLoops.removeValue(forKey: targetTaskID)
        streamBuffers.removeValue(forKey: targetTaskID)
        streamLastFlushAt.removeValue(forKey: targetTaskID)
        if generationTasks.isEmpty {
            state.isGenerating = false
            state.generationStartedAt = nil
            state.liveActivity = ""
        }
    }
}
