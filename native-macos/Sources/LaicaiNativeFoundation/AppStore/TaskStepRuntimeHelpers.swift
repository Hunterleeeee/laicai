import AppKit
import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func appendTaskStep(_ step: TaskStep, to taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        let steps = state.threads[threadIndex].steps

        let searchSlice = steps.suffix(20)
        if let existingIndex = searchSlice.lastIndex(where: { $0.id == step.id }) {
            if step.kind == .toolResult {
                state.threads[threadIndex].steps[existingIndex] = step
                state.threads[threadIndex].updatedAt = Date()
                persistThreads()
            }
            return
        }

        if step.kind == .textOutput,
           let streamingIndex = steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            streamBuffers.removeValue(forKey: taskID)
            streamLastFlushAt.removeValue(forKey: taskID)
            var finalStep = step
            finalStep.toolCallId = nil
            state.threads[threadIndex].steps[streamingIndex] = finalStep
            state.threads[threadIndex].updatedAt = Date()
            persistThreads()
            return
        }

        if !state.isGenerating {
            if shouldCollapseDuplicateStep(step, in: steps) { return }
            if steps.contains(where: { $0.kind == step.kind && $0.text == step.text }) { return }
        }

        state.threads[threadIndex].steps.append(step)
        state.threads[threadIndex].updatedAt = Date()
        persistThreads()

        if step.kind == .reviewRequest {
            sendReviewNotification(step: step, threadTitle: state.threads[threadIndex].title)
        }
    }

    private func sendReviewNotification(step: TaskStep, threadTitle: String) {
        let center = NSUserNotificationCenter.default
        let notification = NSUserNotification()
        notification.title = "需要审查确认"
        notification.subtitle = threadTitle
        notification.informativeText = step.diffFilePath.map { "文件：\($0)" } ?? "有变更等待确认"
        notification.soundName = NSUserNotificationDefaultSoundName
        center.deliver(notification)
        updateDockBadge()
    }

    func updateDockBadge() {
        let count = state.pendingReviewCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func appendStreamDelta(_ delta: String, to taskID: UUID) {
        guard !delta.isEmpty else { return }
        streamBuffers[taskID, default: ""] += delta
        let now = Date()
        let pending = streamBuffers[taskID] ?? ""
        let lastFlush = streamLastFlushAt[taskID] ?? .distantPast
        guard pending.count >= streamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= streamFlushInterval else {
            return
        }
        flushStreamBuffer(for: taskID)
    }

    private static let thinkingStreamID = "__thinking_stream__"

    func appendThinkingDelta(_ delta: String, to taskID: UUID) {
        guard !delta.isEmpty else { return }
        thinkingBuffers[taskID, default: ""] += delta
        let now = Date()
        let pending = thinkingBuffers[taskID] ?? ""
        let lastFlush = thinkingLastFlushAt[taskID] ?? .distantPast
        guard pending.count >= streamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= streamFlushInterval else {
            return
        }
        flushThinkingBuffer(for: taskID)
    }

    func flushThinkingBuffer(for taskID: UUID) {
        guard let pending = thinkingBuffers[taskID], !pending.isEmpty else { return }
        thinkingBuffers[taskID] = ""
        thinkingLastFlushAt[taskID] = Date()
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        state.liveActivity = "正在思考…"
        if let idx = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .aiThinking && $0.toolCallId == Self.thinkingStreamID }) {
            state.threads[threadIndex].steps[idx].reasoningContent = (state.threads[threadIndex].steps[idx].reasoningContent ?? "") + pending
        } else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .aiThinking,
                text: "思考中…",
                toolCallId: Self.thinkingStreamID,
                isCollapsible: true,
                isCollapsed: false,
                reasoningContent: pending
            ))
        }
    }

    func flushStreamBuffer(for taskID: UUID) {
        guard let pending = streamBuffers[taskID], !pending.isEmpty else { return }
        streamBuffers[taskID] = ""
        streamLastFlushAt[taskID] = Date()
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        state.liveActivity = "正在生成回复…"
        if let streamIndex = state.threads[threadIndex].steps.lastIndex(where: { $0.kind == .textOutput && $0.toolCallId == Self.streamingOutputID }) {
            state.threads[threadIndex].steps[streamIndex].text += pending
        } else {
            state.threads[threadIndex].steps.append(TaskStep(
                kind: .textOutput,
                text: pending,
                toolCallId: Self.streamingOutputID,
                isCollapsible: false,
                isCollapsed: false
            ))
        }
    }

    func mergeCompletedTask(_ completedTask: AgentTask, into taskID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        for step in completedTask.steps {
            if shouldCollapseDuplicateStep(step, in: state.threads[threadIndex].steps) { continue }
            let alreadyExists = state.threads[threadIndex].steps.contains {
                $0.id == step.id || ($0.kind == step.kind && $0.text == step.text)
            }
            if !alreadyExists {
                state.threads[threadIndex].steps.append(step)
                updateLiveActivity(from: step)
            }
        }
        state.threads[threadIndex].status = completedTask.status
        state.liveActivity = ""
        state.threads[threadIndex].context = completedTask.context
        state.threads[threadIndex].context.memory = Self.taskMemory(from: state.threads[threadIndex])
        if let plan = completedTask.multiAgentPlan {
            state.threads[threadIndex].multiAgentPlan = plan
        }
        state.threads[threadIndex].updatedAt = completedTask.updatedAt
        Self.ensureCheckpointIfNeeded(&state.threads[threadIndex])
        state.selectThread(id: taskID)

        let appIsActive = NSApplication.shared.isActive
        if !appIsActive {
            let threadTitle = state.threads[threadIndex].title
            let noteTitle: String
            switch completedTask.status {
            case .completed: noteTitle = "任务完成"
            case .failed: noteTitle = "任务失败"
            default: noteTitle = "任务状态更新"
            }
            NotificationManager.shared.post(
                title: noteTitle,
                body: threadTitle,
                threadID: taskID.uuidString
            )
        }
    }

    func shouldCollapseDuplicateStep(_ step: TaskStep, in steps: [TaskStep]) -> Bool {
        switch step.kind {
        case .userInput, .aiThinking:
            return steps.contains { $0.kind == step.kind && $0.text == step.text }
        default:
            return false
        }
    }

    func appendAssistantStep(_ text: String, to sessionID: UUID, connectorName: String, metrics: ResponseMetrics? = nil) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let assistantText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.threads[threadIndex].steps.append(TaskStep(kind: .textOutput, text: assistantText, isCollapsible: false, isCollapsed: false, metrics: metrics))
        state.threads[threadIndex].preview = normalizedSessionPreview(assistantText)
        state.threads[threadIndex].modelName = connectorName
        state.threads[threadIndex].updatedAt = .now
        state.selectThread(id: sessionID)
        persistThreads()
    }

    func appendAssistantDelta(_ delta: String, stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard !delta.isEmpty else { return }
        chatStreamBuffers[stepID, default: ""] += delta
        let now = Date()
        let pending = chatStreamBuffers[stepID] ?? ""
        let lastFlush = chatStreamLastFlushAt[stepID] ?? .distantPast
        guard pending.count >= chatStreamFlushCharacterThreshold || now.timeIntervalSince(lastFlush) >= chatStreamFlushInterval else {
            return
        }
        flushAssistantBuffer(stepID: stepID, in: sessionID, connectorName: connectorName)
    }

    func flushAssistantBuffer(stepID: UUID, in sessionID: UUID, connectorName: String) {
        guard let pending = chatStreamBuffers[stepID], !pending.isEmpty else { return }
        chatStreamBuffers[stepID] = ""
        chatStreamLastFlushAt[stepID] = Date()
        updateAssistantStep(stepID, in: sessionID, delta: pending, connectorName: connectorName, persist: false)
    }

    func updateAssistantStep(
        _ stepID: UUID,
        in sessionID: UUID,
        delta: String? = nil,
        finalText: String? = nil,
        metrics: ResponseMetrics? = nil,
        connectorName: String,
        persist shouldPersist: Bool = true
    ) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else {
            appendAssistantStep(finalText ?? delta ?? "", to: sessionID, connectorName: connectorName, metrics: metrics)
            return
        }

        if let finalText {
            state.threads[threadIndex].steps[stepIndex].text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let delta, !delta.isEmpty {
            state.threads[threadIndex].steps[stepIndex].text += delta
        }
        if let metrics {
            state.threads[threadIndex].steps[stepIndex].metrics = metrics
        }

        let text = state.threads[threadIndex].steps[stepIndex].text
        state.threads[threadIndex].preview = normalizedSessionPreview(text)
        state.threads[threadIndex].modelName = connectorName
        state.selectThread(id: sessionID)
        if shouldPersist {
            state.threads[threadIndex].updatedAt = .now
            chatStreamBuffers.removeValue(forKey: stepID)
            chatStreamLastFlushAt.removeValue(forKey: stepID)
            persistThreads()
        }
    }
}
