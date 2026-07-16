import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func queueFollowUp(_ message: String, for threadID: UUID? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let targetThreadID = threadID ?? state.selectedThreadID else { return }
        let queued = Self.mergedPendingFollowUp(existing: pendingFollowUp(for: targetThreadID), incoming: trimmed)
        if targetThreadID == state.selectedThreadID {
            state.pendingFollowUp = queued
        }
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == targetThreadID }) else { return }
        if state.threads[threadIndex].executionLedger == nil {
            state.threads[threadIndex].executionLedger = AgentExecutionLedger(
                originalRequest: state.threads[threadIndex].steps.first(where: { $0.kind == .userInput })?.text
                    ?? state.threads[threadIndex].title,
                goal: state.threads[threadIndex].goal ?? state.threads[threadIndex].title,
                state: .executing,
                plan: state.threads[threadIndex].currentPlan
            )
        }
        state.threads[threadIndex].executionLedger?.pendingFollowUp = queued
        state.threads[threadIndex].executionLedger?.nextAction = "处理用户补充：\(queued)"
        state.threads[threadIndex].executionLedger?.transition(to: .executing, reason: "运行中收到追问，已排队")
        state.threads[threadIndex].updatedAt = .now
    }

    static func mergedPendingFollowUp(existing: String?, incoming: String) -> String {
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return incoming }
        guard existing != incoming else { return existing }
        return """
            \(existing)

            追加补充：
            \(incoming)
            """
    }

    public func submitFollowUp() {
        guard let targetThreadID = state.selectedThreadID else { return }
        let draft = state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyQueued = pendingFollowUp(for: targetThreadID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let followUp = draft.isEmpty ? alreadyQueued : draft
        guard !followUp.isEmpty else { return }
        queueFollowUp(followUp, for: targetThreadID)
        state.draftMessage = ""
        notify("补充指令已排队，会在当前会话 安全点继续处理。", style: .info)
        persistThreads()
    }

    public func clearPendingFollowUp() {
        state.pendingFollowUp = nil
        state.draftMessage = ""
        if let agentID = state.selectedAgentID,
            let threadIndex = state.threads.firstIndex(where: { $0.id == agentID })
        {
            state.threads[threadIndex].executionLedger?.pendingFollowUp = nil
            persistThreads()
        }
    }

    public func addDraftAttachments(_ paths: [String]) {
        let cleaned =
            paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        var existing = state.draftAttachments
        for path in cleaned where !existing.contains(path) {
            existing.append(path)
        }
        state.draftAttachments = existing
    }

    public func removeDraftAttachment(_ path: String) {
        state.draftAttachments.removeAll { $0 == path }
    }

    public func addDraftImage(_ attachment: ImageAttachment) {
        state.draftImages.append(attachment)
    }

    public func removeDraftImage(id: UUID) {
        state.draftImages.removeAll { $0.id == id }
    }

    public func clearDraftImages() {
        state.draftImages.removeAll()
    }
}
