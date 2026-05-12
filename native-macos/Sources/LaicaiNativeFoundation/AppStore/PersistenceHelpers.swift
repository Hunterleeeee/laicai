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
        do { try environment.threadRepository.saveThreads(persistableThreads) }
        catch { recordToolActivity(name: "threads.save", summary: "会话持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    func updateSummaryCaches() {
        let summaryThreshold = 20
        let indicesToCheck: Range<Int>
        if state.isGenerating, let selectedID = state.selectedThreadID,
           let idx = state.threads.firstIndex(where: { $0.id == selectedID }) {
            indicesToCheck = idx..<(idx + 1)
        } else {
            indicesToCheck = state.threads.startIndex..<state.threads.endIndex
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
        do { try environment.connectorRepository.saveConnectors(state.connectors, activeConnectorID: state.activeConnectorID) }
        catch { recordToolActivity(name: "connectors.save", summary: "连接器持久化失败", statusLine: error.localizedDescription, isFailure: true) }
    }

    func persistSettings() {
        AppSettingsStorage.save(state.settings)
    }

    nonisolated static func isEmptyPlaceholderThread(_ thread: Thread) -> Bool {
        return thread.isEmptyPlaceholder
    }
}
