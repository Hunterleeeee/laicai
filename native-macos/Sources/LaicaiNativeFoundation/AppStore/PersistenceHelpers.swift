import Foundation
import LaicaiNativeDomain

@MainActor
extension AppStore {
    /// H1: Debounced persistence during streaming/generation.
    func persistThreads() {
        guard state.isGenerating else {
            persistThreadsNow()
            return
        }
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.persistDebounceInterval ?? 1.0))
            guard !Task.isCancelled else { return }
            self?.persistThreadsNow()
        }
    }

    func persistThreadsNow() {
        lastPersistedAt = Date()
        updateSummaryCaches()
        let persistableThreads = state.threads.filter { !$0.isEmptyPlaceholder }
        do { try environment.agentRepository.saveAgents(persistableThreads) } catch {
            recordToolActivity(name: "agents.save", summary: "Agent 持久化失败", statusLine: error.localizedDescription, isFailure: true)
        }
    }

    func updateSummaryCaches() {
        let summaryThreshold = 20
        let indicesToCheck: [Int]
        if !generationTasks.isEmpty {
            let runningIDs = Set(generationTasks.keys)
            indicesToCheck = state.threads.indices.filter { runningIDs.contains(state.threads[$0].id) }
        } else {
            indicesToCheck = Array(state.threads.indices)
        }
        for index in indicesToCheck {
            let thread = state.threads[index]
            guard thread.steps.count > summaryThreshold else { continue }
            let recentStepCount = min(14, thread.steps.count)
            let earlyStepsCount = thread.steps.count - recentStepCount
            let needsUpdate: Bool
            if let cache = thread.summaryCache {
                needsUpdate = !cache.contains("\(earlyStepsCount) 条早期步骤")
            } else {
                needsUpdate = true
            }
            guard needsUpdate else { continue }
            state.threads[index].summaryCache = Self.generateSummaryCache(for: thread)
        }
    }

    func persistConnectors() {
        do {
            try environment.connectorRepository.saveConnectors(
                state.connectors,
                activeConnectorID: state.activeConnectorID
            )
        } catch {
            recordToolActivity(
                name: "connectors.save",
                summary: "连接器持久化失败",
                statusLine: error.localizedDescription,
                isFailure: true
            )
        }
    }

    func persistSettings() {
        AppSettingsStorage.save(state.settings)
    }

    nonisolated static func isEmptyPlaceholderThread(_ thread: Thread) -> Bool {
        return thread.isEmptyPlaceholder
    }
}
