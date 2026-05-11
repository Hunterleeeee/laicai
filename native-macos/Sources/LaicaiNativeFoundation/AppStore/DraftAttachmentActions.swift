import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func queueFollowUp(_ message: String) {
        state.pendingFollowUp = message
    }

    public func submitFollowUp() {
        guard let followUp = state.pendingFollowUp, !followUp.isEmpty else { return }
        state.pendingFollowUp = nil
        state.draftMessage = ""
        if let taskID = state.selectedTaskID,
           let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) {
            let step = TaskStep(kind: .userInput, text: followUp, isCollapsible: false, isCollapsed: false)
            state.threads[threadIndex].steps.append(step)
            persistThreads()
        }
    }

    public func clearPendingFollowUp() {
        state.pendingFollowUp = nil
    }

    public func addDraftAttachments(_ paths: [String]) {
        let cleaned = paths
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
