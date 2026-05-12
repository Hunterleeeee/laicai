import Foundation
import LaicaiNativeDomain

extension AppStore {
    public var filteredSessions: [ChatSession] {
        state.sessions
    }

    public func updateSearchText(_ value: String) { state.searchText = value }

    public func newSession() {
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新会话",
            preview: "",
            modelName: connectorName,
            category: .engineering,
            projectID: nil
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
    }

    public func newSessionInProject(_ projectID: UUID) {
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新会话",
            preview: "",
            modelName: connectorName,
            category: .engineering,
            projectID: projectID
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
    }

    public func selectSession(id: UUID?) {
        state.selectThread(id: id)
        state.modeLabel = "聊天"
        syncGeneratingStateForSelectedThread()
    }

    func syncGeneratingStateForSelectedThread() {
        if let tid = state.selectedThreadID, generationTasks[tid] != nil {
            if !state.isGenerating {
                state.isGenerating = true
                state.generationStartedAt = state.generationStartedAt ?? Date()
                state.liveActivity = "正在生成…"
            }
        } else if state.isGenerating {
            state.isGenerating = false
            state.generationStartedAt = nil
            state.liveActivity = ""
        }
    }

    public func updateExecutionMode(_ mode: ExecutionMode) {
        state.executionMode = mode
        state.modeLabel = mode.title
    }

    public func deleteSession(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedSessionID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        persistThreads()
    }

    public func pinSession(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].isPinned.toggle()
        state.invalidateThreadSummaryCache()
        persistThreads()
    }

    public func renameSession(id: UUID, title: String) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            state.threads[index].title = trimmed
            state.invalidateThreadSummaryCache()
        }
        persistThreads()
    }

    public func rateThread(id: UUID, rating: Int) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].userRating = rating
        persistThreads()
        TaskOutcomeRecorder.shared.rate(taskID: id.uuidString, rating: rating)
    }

    public func clearSessionTurns(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].steps = []
        state.threads[index].preview = ""
        persistThreads()
    }

    public func cloneSession(id: UUID) {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return }
        let cloned = Thread(
            title: thread.title + " 副本",
            preview: thread.preview,
            steps: thread.steps,
            connectorID: thread.connectorID,
            workflowName: thread.workflowName,
            context: thread.context,
            modelName: thread.modelName,
            category: thread.category,
            source: thread.source,
            projectID: thread.projectID
        )
        state.threads.insert(cloned, at: 0)
        state.selectThread(id: cloned.id)
        persistThreads()
        notify("已克隆会话", style: .success)
    }

    public func forkThread(id: UUID, fromStepID: UUID) {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return }
        guard let stepIndex = thread.steps.firstIndex(where: { $0.id == fromStepID }) else { return }
        let forkedSteps = Array(thread.steps.prefix(through: stepIndex))
        let forked = Thread(
            title: thread.title + " 分支",
            preview: forkedSteps.last?.text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines) ?? thread.preview,
            steps: forkedSteps,
            connectorID: thread.connectorID,
            context: thread.context,
            modelName: thread.modelName,
            source: thread.source,
            projectID: thread.projectID
        )
        state.threads.insert(forked, at: 0)
        state.selectThread(id: forked.id)
        persistThreads()
        notify("已创建分支", style: .success)
    }

    public func selectWorkbenchTab(_ tab: WorkbenchTab) { state.workbenchTab = tab }

    public func selectNextWorkbenchTab() {
        guard let index = WorkbenchTab.allCases.firstIndex(of: state.workbenchTab) else { return }
        state.workbenchTab = WorkbenchTab.allCases[(index + 1) % WorkbenchTab.allCases.count]
    }
}
