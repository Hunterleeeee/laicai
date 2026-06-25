import Foundation
import LaicaiNativeDomain

extension AppStore {
    @discardableResult
    func cancelGenerationTask(for threadID: UUID, discardBuffers: Bool = true) -> Bool {
        let wasGenerating = isThreadGenerating(threadID)
        generationTasks[threadID]?.cancel()
        generationTasks.removeValue(forKey: threadID)
        agentLoops.removeValue(forKey: threadID)
        if discardBuffers {
            streamBuffers.removeValue(forKey: threadID)
            streamLastFlushAt.removeValue(forKey: threadID)
            thinkingBuffers.removeValue(forKey: threadID)
            thinkingLastFlushAt.removeValue(forKey: threadID)
        }
        generationStartTimes.removeValue(forKey: threadID)
        liveActivitiesByThread.removeValue(forKey: threadID)
        syncGeneratingStateForSelectedThread()
        return wasGenerating
    }

    /// Codex-style steer: inject a correction into a running agent loop.
    /// Unlike stop, this does NOT cancel the task; it redirects it.
    public func steerRunningTask(_ message: String) {
        guard let threadID = state.selectedThreadID,
              let loop = agentLoops[threadID] else { return }
        loop.steer(message)
        notify("已发送方向修正")
    }

    public func stopGenerating() {
        let targetThreadIDs: [UUID]
        if let selectedID = state.selectedThreadID, isThreadGenerating(selectedID) {
            targetThreadIDs = [selectedID]
        } else {
            targetThreadIDs = Array(generationTasks.keys)
        }

        for threadID in targetThreadIDs {
            cancelGenerationTask(for: threadID, discardBuffers: false)
        }

        syncGeneratingStateForSelectedThread()
        for threadID in targetThreadIDs {
            guard let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }) else { continue }
            flushThinkingBuffer(for: threadID)
            flushStreamBuffer(for: threadID)
            let isExecution = state.threads[threadIndex].isExecution
            guard state.threads[threadIndex].status == .running else {
                streamBuffers.removeValue(forKey: threadID)
                streamLastFlushAt.removeValue(forKey: threadID)
                thinkingBuffers.removeValue(forKey: threadID)
                thinkingLastFlushAt.removeValue(forKey: threadID)
                continue
            }
            if isExecution && !state.threads[threadIndex].steps.contains(where: { $0.kind == .error && $0.text == "已中断" }) {
                state.threads[threadIndex].steps.append(TaskStep(kind: .error, text: "已中断", isFailure: false, recoverable: true, retryAction: "重试"))
            }
            state.threads[threadIndex].status = .cancelled
            if isExecution {
                syncAgentSnapshot(at: threadIndex)
            } else {
                state.threads[threadIndex].executionState = .paused
            }
            state.threads[threadIndex].updatedAt = .now
            BehaviorSignalTracker.record(signal: .cancel, thread: state.threads[threadIndex])
            streamBuffers.removeValue(forKey: threadID)
            streamLastFlushAt.removeValue(forKey: threadID)
            thinkingBuffers.removeValue(forKey: threadID)
            thinkingLastFlushAt.removeValue(forKey: threadID)
        }

        if let threadID = state.selectedThreadID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == threadID }),
           state.threads[threadIndex].isChatOnly {
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
