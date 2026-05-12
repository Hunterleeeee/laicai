import Foundation
import LaicaiNativeDomain

extension AppStore {
    public func deleteTask(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedTaskID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        do { try environment.taskRepository.deleteTask(id: id) }
        catch { recordToolActivity(name: "tasks.delete", summary: "任务删除失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    public func selectTask(id: UUID?) {
        state.selectThread(id: id)
        if let id, let thread = state.threads.first(where: { $0.id == id }) {
            state.modeLabel = thread.workflowName == nil ? "任务" : "工作流"
        }
        syncGeneratingStateForSelectedThread()
    }

    public func prepareTaskContinuation(id: UUID) {
        guard state.threads.contains(where: { $0.id == id }) else { return }
        state.selectThread(id: id)
        state.modeLabel = "任务"
        if state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.draftMessage = "继续这个任务"
        }
    }

    public func selectThread(_ record: ThreadRecord?) {
        state.selectThread(id: record?.id)
        if let record {
            switch record.source {
            case .session:
                state.modeLabel = "聊天"
            case .task:
                let workflowName = state.threads.first { $0.id == record.id }?.workflowName ?? record.task?.workflowName
                state.modeLabel = workflowName == nil ? "任务" : "工作流"
            }
        } else {
            state.modeLabel = "聊天"
        }
        syncGeneratingStateForSelectedThread()
    }

    public func toggleStepCollapsed(taskID: UUID, stepID: UUID) {
        guard let threadIndex = state.threads.firstIndex(where: { $0.id == taskID }) else { return }
        guard let stepIndex = state.threads[threadIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        state.threads[threadIndex].steps[stepIndex].isCollapsed.toggle()
        persistThreads()
    }
}
