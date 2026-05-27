import Foundation
import LaicaiNativeDomain

extension AppStore {
    public var filteredAgents: [AgentRecord] {
        state.agents
    }

    public func updateSearchText(_ value: String) {
        state.searchText = value
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.state.debouncedSearchText = value
        }
    }

    private func prepareForNewSelection() {
        state.searchText = ""
        state.debouncedSearchText = ""
        state.draftMessage = ""
        state.draftAttachments = []
        state.draftImages = []
        state.pendingFollowUp = nil
        state.modeLabel = "会话"
        syncGeneratingStateForSelectedThread()
    }

    public func newThread() {
        ProjectManager.shared.activeProjectID = nil
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新对话",
            preview: "",
            modelName: connectorName,
            category: .engineering,
            projectID: nil,
            executionState: .idle
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        prepareForNewSelection()
        persistThreads()
    }

    public func selectThread(id: UUID?) {
        state.selectThread(id: id)
        if let id, let thread = state.threads.first(where: { $0.id == id }) {
            ProjectManager.shared.activeProjectID = thread.projectID
        } else {
            ProjectManager.shared.activeProjectID = nil
        }
        state.modeLabel = "会话"
        syncGeneratingStateForSelectedThread()
    }

    public func newThreadInProject(_ projectID: UUID) {
        let connectorName = state.activeConnector?.name ?? state.settings.defaultConnectorName
        let thread = Thread(
            title: "新对话",
            preview: "",
            modelName: connectorName,
            category: .engineering,
            projectID: projectID,
            executionState: .idle
        )
        state.threads.insert(thread, at: 0)
        state.selectThread(id: thread.id)
        ProjectManager.shared.activeProjectID = projectID
        prepareForNewSelection()
        persistThreads()
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

    public func deleteThread(id: UUID) {
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedThreadID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        persistThreads()
    }

    public func pinThread(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].isPinned.toggle()
        state.invalidateThreadSummaryCache()
        persistThreads()
    }

    public func renameThread(id: UUID, title: String) {
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

    public func clearThreadEvents(id: UUID) {
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        state.threads[index].steps = []
        state.threads[index].preview = ""
        persistThreads()
    }

    public func cloneThread(id: UUID) {
        guard let thread = state.threads.first(where: { $0.id == id }) else { return }
        let cloned = Thread(
            title: thread.title + " 副本",
            preview: thread.preview,
            status: thread.status == .running ? .cancelled : thread.status,
            steps: thread.steps,
            connectorID: thread.connectorID,
            workflowName: thread.workflowName,
            context: thread.context,
            modelName: thread.modelName,
            category: thread.category,
            isPinned: false,
            summaryCache: thread.summaryCache,
            multiAgentPlan: thread.multiAgentPlan,
            projectID: thread.projectID,
            executionState: thread.status == .running ? .paused : thread.executionState,
            goal: thread.goal,
            currentPlan: thread.currentPlan,
            artifacts: thread.artifacts
        )
        state.threads.insert(cloned, at: 0)
        state.selectThread(id: cloned.id)
        persistThreads()
        notify("已克隆", style: .success)
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
            projectID: thread.projectID,
            executionState: thread.executionState,
            goal: thread.goal,
            currentPlan: thread.currentPlan,
            artifacts: thread.artifacts
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
