import Foundation
import LaicaiNativeDomain

extension AppStore {
    /// Codex-style steer: inject a correction into a running agent loop.
    /// Unlike stop, this does NOT cancel the task; it redirects it.
    public func steerRunningTask(_ message: String) {
        guard let threadID = state.selectedThreadID,
              let loop = agentLoops[threadID] else { return }
        loop.steer(message)
        ToastCenter.shared.show("🔀 已发送方向修正")
    }

    public func stopGenerating() {
        if let threadID = state.selectedThreadID {
            generationTasks[threadID]?.cancel()
            generationTasks.removeValue(forKey: threadID)
            agentLoops.removeValue(forKey: threadID)
        }

        state.isGenerating = false
        state.generationStartedAt = nil
        state.liveActivity = ""
        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .task,
           state.threads[threadIndex].status == .running {
            flushStreamBuffer(for: threadID)
            state.threads[threadIndex].steps.append(TaskStep(kind: .error, text: "已中断", isFailure: false, recoverable: true, retryAction: "重试"))
            state.threads[threadIndex].status = .cancelled
            state.threads[threadIndex].updatedAt = .now
            BehaviorSignalTracker.record(signal: .cancel, thread: state.threads[threadIndex])
            persistThreads()
            streamBuffers.removeValue(forKey: threadID)
            streamLastFlushAt.removeValue(forKey: threadID)
        }

        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].source == .session {
            var steps = state.threads[threadIndex].steps
            if let lastStep = steps.last, lastStep.kind == .textOutput {
                if lastStep.text.isEmpty {
                    steps.removeLast()
                } else {
                    steps[steps.count - 1] = TaskStep(
                        id: lastStep.id, kind: .textOutput,
                        text: lastStep.text + "\n\n（已中断）",
                        isCollapsible: false, isCollapsed: false,
                        metrics: lastStep.metrics, createdAt: lastStep.createdAt
                    )
                }
                state.threads[threadIndex].steps = steps
                state.threads[threadIndex].preview = normalizedSessionPreview(steps.last?.text ?? "")
                state.threads[threadIndex].updatedAt = .now
            }
        }
        chatStreamBuffers.removeAll()
        chatStreamLastFlushAt.removeAll()
        persistThreads()
    }
}
