import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func deleteExecutingAgent(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedThreadID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        persistThreads()
    }

    public func selectExecutingAgent(id: UUID?) {
        state.selectThread(id: id)
        syncActiveProjectForSelectedThread(id: id)
        if let id, let thread = state.threads.first(where: { $0.id == id }) {
            state.modeLabel = thread.workflowName == nil ? "会话" : "工作流"
        }
        syncGeneratingStateForSelectedThread()
    }

    public func prepareAgentContinuation(id: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.selectThread(id: id)
        syncActiveProjectForSelectedThread(id: id)
        state.modeLabel = state.threads[threadIndex].workflowName == nil ? "会话" : "工作流"
        state.draftMessage = "继续这个会话"
        syncGeneratingStateForSelectedThread()
    }

    public func deleteTask(id: UUID) { deleteExecutingAgent(id: id) }

    public func selectTask(id: UUID?) { selectThread(id: id) }

    public func prepareTaskContinuation(id: UUID) { prepareAgentContinuation(id: id) }

    public func selectThread(_ record: ThreadRecord?) {
        state.selectThread(id: record?.id)
        syncActiveProjectForSelectedThread(id: record?.id)
        if let record {
            let workflowName = state.threads.first { $0.id == record.id }?.workflowName
            state.modeLabel = workflowName == nil ? "会话" : "工作流"
        } else {
            state.modeLabel = "会话"
        }
        syncGeneratingStateForSelectedThread()
    }

    private func syncActiveProjectForSelectedThread(id: UUID?) {
        guard let id, let thread = state.threads.first(where: { $0.id == id }) else {
            ProjectManager.shared.activeProjectID = nil
            return
        }
        ProjectManager.shared.activeProjectID = thread.projectID
    }

    public func toggleStepCollapsed(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        state.threads[threadIndex].steps[stepIndex].isCollapsed.toggle()
        persistThreads()
    }
}
