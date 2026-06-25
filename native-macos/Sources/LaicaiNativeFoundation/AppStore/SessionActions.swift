import Foundation
import LaicaiNativeDomain

extension AppStore {
    public var hasRunningGenerationTasks: Bool {
        !generationTasks.isEmpty
    }

    public var selectedThreadIsGenerating: Bool {
        guard let threadID = state.selectedThreadID else { return false }
        return isThreadGenerating(threadID)
    }

    public func isThreadGenerating(_ threadID: UUID) -> Bool {
        if generationTasks[threadID] != nil { return true }
        guard generationTasks.isEmpty,
              state.isGenerating,
              state.selectedThreadID == threadID,
              let thread = state.threads.first(where: { $0.id == threadID }) else {
            return false
        }
        return thread.status == .running || thread.executionState == .running
    }

    public func liveActivity(for threadID: UUID) -> String {
        if let activity = liveActivitiesByThread[threadID] {
            return activity
        }
        guard threadID == state.selectedThreadID, isThreadGenerating(threadID) else {
            return ""
        }
        return state.liveActivity
    }

    public func generationStartedAt(for threadID: UUID) -> Date? {
        if let startedAt = generationStartTimes[threadID] {
            return startedAt
        }
        guard threadID == state.selectedThreadID, isThreadGenerating(threadID) else {
            return nil
        }
        return state.generationStartedAt
    }

    public func estimatedProgress(for threadID: UUID) -> Double? {
        guard isThreadGenerating(threadID),
              let thread = state.threads.first(where: { $0.id == threadID }) else {
            return nil
        }
        let toolCalls = thread.steps.filter { $0.kind == .toolCall }.count
        guard toolCalls > 0 else { return nil }
        let expectedIterations = max(3.0, Double(thread.context.metadata["expectedIterations"] ?? "8") ?? 8.0)
        return min(0.95, Double(toolCalls) / expectedIterations)
    }

    func markGenerationStarted(for threadID: UUID, activity: String) {
        let now = Date()
        generationStartTimes[threadID] = now
        liveActivitiesByThread[threadID] = activity
        state.isGenerating = true
        state.generationStartedAt = now
        state.liveActivity = activity
    }

    func setLiveActivity(_ activity: String, for threadID: UUID) {
        if activity.isEmpty {
            liveActivitiesByThread.removeValue(forKey: threadID)
        } else {
            liveActivitiesByThread[threadID] = activity
        }
        syncGeneratingStateForSelectedThread()
    }

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
        syncPendingFollowUpForSelectedThread()
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
        let hasRunningTasks = !generationTasks.isEmpty
        guard hasRunningTasks else {
            state.isGenerating = false
            state.generationStartedAt = nil
            state.liveActivity = ""
            return
        }

        let selectedIsRunning = selectedThreadIsGenerating
        state.isGenerating = true
        if selectedIsRunning, let selectedID = state.selectedThreadID {
            state.generationStartedAt = generationStartTimes[selectedID] ?? state.generationStartedAt ?? Date()
            state.liveActivity = liveActivitiesByThread[selectedID] ?? "正在生成…"
        } else {
            let runningStarts = generationTasks.keys.compactMap { generationStartTimes[$0] }
            state.generationStartedAt = runningStarts.min() ?? state.generationStartedAt ?? Date()
            state.liveActivity = "后台会话运行中…"
        }
    }

    func syncPendingFollowUpForSelectedThread() {
        guard let threadID = state.selectedThreadID,
              let thread = state.threads.first(where: { $0.id == threadID }) else {
            state.pendingFollowUp = nil
            return
        }
        let pending = thread.executionLedger?.pendingFollowUp?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.pendingFollowUp = pending?.isEmpty == false ? pending : nil
    }

    public func updateExecutionMode(_ mode: ExecutionMode) {
        state.executionMode = mode
        state.modeLabel = mode.title
    }

    public func deleteThread(id: UUID) {
        cancelGenerationTask(for: id)
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
        let wasGenerating = cancelGenerationTask(for: id)
        state.threads[index].steps = []
        state.threads[index].preview = ""
        if wasGenerating {
            state.threads[index].status = .queued
            state.threads[index].executionState = .idle
            state.threads[index].goal = nil
            state.threads[index].currentPlan = []
            state.threads[index].artifacts = []
            state.threads[index].taskProtocol = nil
            state.threads[index].executionLedger = nil
            state.threads[index].multiAgentPlan = nil
        }
        state.threads[index].updatedAt = .now
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
