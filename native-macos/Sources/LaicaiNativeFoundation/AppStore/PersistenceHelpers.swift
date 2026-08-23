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
        persistDebounceTask?.cancel()
        persistDebounceTask = nil
        // During streaming, skip O(all threads × all steps) summary projection.
        // The final persist after generation finishes rebuilds summaries and the
        // sidebar once, preventing periodic UI stalls while text/reasoning grows.
        if generationTasks.isEmpty {
            updateSummaryCaches()
            refreshSidebarPresentation()
        }
        let persistableThreads = state.threads.filter { !$0.isEmptyPlaceholder }
        let repository = environment.agentRepository
        // Off the main thread: JSON encoding + SQLite transaction must not
        // block the UI during streaming or step updates.
        Task.detached(priority: .utility) { [repository, persistableThreads] in
            let started = Date()
            do {
                try repository.saveAgents(persistableThreads)
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
                if elapsedMs > 50 {
                    LaicaiLog.info("agents.save took \(elapsedMs)ms (\(persistableThreads.count) threads)")
                }
            } catch {
                LaicaiLog.error("Agent 持久化失败：\(error.localizedDescription)")
            }
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
        connectorsPersistTask?.cancel()
        let connectors = state.connectors
        let activeConnectorID = state.activeConnectorID
        let repository = environment.connectorRepository
        connectorsPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.preferencePersistDebounceInterval ?? 0.25))
            guard !Task.isCancelled else { return }
            Task.detached(priority: .utility) {
                do {
                    try repository.saveConnectors(connectors, activeConnectorID: activeConnectorID)
                } catch {
                    LaicaiLog.error("连接器持久化失败：\(error.localizedDescription)")
                }
            }
            self?.connectorsPersistTask = nil
        }
    }

    func persistSettings() {
        settingsPersistTask?.cancel()
        let settings = state.settings
        settingsPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.preferencePersistDebounceInterval ?? 0.25))
            guard !Task.isCancelled else { return }
            Task.detached(priority: .utility) {
                do {
                    try AppSettingsStorage.save(settings)
                } catch {
                    LaicaiLog.error("应用设置保存失败：\(error.localizedDescription)")
                }
            }
            self?.settingsPersistTask = nil
        }
    }

    nonisolated static func isEmptyPlaceholderThread(_ thread: Thread) -> Bool {
        return thread.isEmptyPlaceholder
    }
}
