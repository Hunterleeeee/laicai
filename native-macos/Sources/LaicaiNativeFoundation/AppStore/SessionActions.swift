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
            let thread = state.threads.first(where: { $0.id == threadID })
        else {
            return false
        }
        // Keep compatibility with restored/in-flight task state that has not
        // registered its async handle yet. Lifecycle cleanup now corrects
        // terminal thread state before this fallback can persist.
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
            let thread = state.threads.first(where: { $0.id == threadID })
        else { return nil }

        // The TypingIndicator polls this every second; recompute only when the
        // step count actually changed instead of filtering all steps 60x/min.
        let steps = thread.steps
        if let cached = estimatedProgressCache[threadID], cached.steps == steps.count {
            return cached.value
        }
        let progress = computeEstimatedProgress(steps: steps)
        estimatedProgressCache[threadID] = (steps.count, progress)
        return progress
    }

    private func computeEstimatedProgress(steps: [TaskStep]) -> Double? {
        let toolCalls = steps.filter { $0.kind == .toolCall }.count
        let completedTools = steps.filter { $0.kind == .toolResult }.count
        let hasMutation = steps.contains {
            guard let name = $0.toolName else { return false }
            return ["file.write", "file.edit", "diff.apply", "document.transform"].contains(name)
        }
        let hasVerification = steps.contains {
            guard let name = $0.toolName else { return false }
            return ["verify.build", "shell.exec"].contains(name)
                && ($0.kind == .toolCall || $0.kind == .toolResult)
        }
        let hasOutput = steps.contains { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Do not show a made-up percentage before there is observable work.
        guard toolCalls > 0 || hasOutput else { return nil }
        let evidenceProgress: Double
        if hasVerification && hasOutput {
            evidenceProgress = 0.92
        } else if hasVerification {
            evidenceProgress = 0.78
        } else if hasMutation {
            evidenceProgress = 0.62
        } else if completedTools > 0 {
            evidenceProgress = 0.35
        } else {
            evidenceProgress = 0.18
        }
        // Within a phase, completed tool results provide a small monotonic
        // increment, but never imply completion before verification/summarize.
        let toolProgress = min(0.12, Double(completedTools) * 0.02)
        return min(0.92, evidenceProgress + toolProgress)
    }

    @discardableResult
    func markGenerationStarted(for threadID: UUID, activity: String) -> UUID {
        let now = Date()
        let runID = UUID()
        generationRunIDs[threadID] = runID
        generationStartTimes[threadID] = now
        liveActivitiesByThread[threadID] = activity
        estimatedProgressCache.removeValue(forKey: threadID)
        // A fresh run must not inherit residue from a previous interrupted one.
        streamPresentation.clearAll(threadID: threadID)
        generationPresentation.markStarted(threadID: threadID, activity: activity, startedAt: now)
        state.isGenerating = true
        state.generationStartedAt = now
        state.liveActivity = activity
        return runID
    }

    func setLiveActivity(_ activity: String, for threadID: UUID) {
        if activity.isEmpty {
            liveActivitiesByThread.removeValue(forKey: threadID)
        } else {
            liveActivitiesByThread[threadID] = activity
        }
        generationPresentation.updateActivity(threadID: threadID, activity: activity)
        syncGeneratingStateForSelectedThread()
    }

    public var filteredAgents: [AgentRecord] {
        state.agents
    }

    public func updateSearchText(_ value: String) {
        state.searchText = value
        refreshSidebarPresentation()
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.state.debouncedSearchText = value
            self?.refreshSidebarPresentation()
        }
    }

    private func prepareForNewSelection() {
        state.searchText = ""
        state.debouncedSearchText = ""
        // A user-authored draft belongs to the composer, not to the thread
        // being left. Preserve it across explicit new-thread navigation.
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
        composerFocusEpoch += 1
        persistThreads()
    }

    public func selectThread(id: UUID?) {
        state.selectThread(id: id)
        refreshSidebarPresentation()
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
        composerFocusEpoch += 1
        persistThreads()
    }

    func syncGeneratingStateForSelectedThread() {
        let hasRunningTasks = !generationTasks.isEmpty
        guard hasRunningTasks else {
            generationPresentation.reset()
            assignGenerationState(isGenerating: false, startedAt: nil, activity: "")
            return
        }

        // Rehydrate the independent publisher when a running task was restored
        // or when selection changes after the task started.
        for threadID in generationTasks.keys {
            let startedAt = generationStartTimes[threadID] ?? Date()
            let activity = liveActivitiesByThread[threadID] ?? "正在生成…"
            if !generationPresentation.snapshot(for: threadID).isGenerating {
                generationPresentation.markStarted(threadID: threadID, activity: activity, startedAt: startedAt)
            }
        }

        let selectedIsRunning = selectedThreadIsGenerating
        if selectedIsRunning, let selectedID = state.selectedThreadID {
            assignGenerationState(
                isGenerating: true,
                startedAt: generationStartTimes[selectedID] ?? state.generationStartedAt ?? Date(),
                activity: liveActivitiesByThread[selectedID] ?? "正在生成…")
        } else {
            let runningStarts = generationTasks.keys.compactMap { generationStartTimes[$0] }
            assignGenerationState(
                isGenerating: true,
                startedAt: runningStarts.min() ?? state.generationStartedAt ?? Date(),
                activity: "后台会话运行中…")
        }
    }

    /// @Published fires objectWillChange even when the assigned value equals the
    /// current one. Streaming flushes route through here several times a second,
    /// so skip redundant writes instead of re-rendering the whole view tree.
    private func assignGenerationState(isGenerating: Bool, startedAt: Date?, activity: String) {
        var changed = false
        if state.isGenerating != isGenerating {
            state.isGenerating = isGenerating
            changed = true
        }
        if state.generationStartedAt != startedAt {
            state.generationStartedAt = startedAt
            changed = true
        }
        if state.liveActivity != activity {
            state.liveActivity = activity
            changed = true
        }
        _ = changed
    }

    func syncPendingFollowUpForSelectedThread() {
        guard let threadID = state.selectedThreadID,
            let thread = state.threads.first(where: { $0.id == threadID })
        else {
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
        guard let index = state.threads.firstIndex(where: { $0.id == id }) else { return }
        let thread = state.threads[index]
        cancelGenerationTask(for: id)
        deletedThreadBackup = (thread, index)
        state.threads.removeAll(where: { $0.id == id })
        if state.selectedThreadID == id {
            state.selectThread(id: nil)
            selectThread(state.threads.first.map { ThreadRecord(thread: $0, includeEvents: false) })
        }
        persistThreads()
        NotificationCenter.default.post(
            name: .laicaiThreadDeleted,
            object: nil,
            userInfo: ["title": thread.title]
        )
    }

    public func undoDeleteThread() {
        guard let backup = deletedThreadBackup else { return }
        let insertionIndex = min(backup.index, state.threads.count)
        state.threads.insert(backup.thread, at: insertionIndex)
        deletedThreadBackup = nil
        state.invalidateThreadSummaryCache()
        persistThreads()
        NotificationCenter.default.post(
            name: .laicaiThreadRestored,
            object: nil,
            userInfo: ["title": backup.thread.title]
        )
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
