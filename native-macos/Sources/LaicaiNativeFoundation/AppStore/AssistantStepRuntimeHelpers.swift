import AppKit
import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    func appendAssistantStep(_ text: String, to sessionID: UUID, connectorName: String, metrics: ResponseMetrics? = nil) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == sessionID }) else { return }
        let assistantText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.threads[threadIndex].steps.append(
            TaskStep(kind: .textOutput, text: assistantText, isCollapsible: false, isCollapsed: false, metrics: metrics))
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
