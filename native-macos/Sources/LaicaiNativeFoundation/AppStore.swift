import AppKit
import Combine
import Foundation
import LaicaiNativeDomain

@MainActor
public final class AppStore: ObservableObject {
    @Published public internal(set) var state: AppState
    @Published public var isShowingTaskModeInfo = false
    /// True while the live SQLite workspace is being loaded off the main thread.
    @Published public private(set) var isBootstrapping = true
    /// Incremented every time a new thread is created so the UI can request
    /// composer focus after an explicit "new conversation/task" action.
    @Published public internal(set) var composerFocusEpoch = 0
    /// Independent publisher for high-frequency generation presentation.
    public let generationPresentation = GenerationPresentationStore()
    /// Independent publisher for live streaming text. Token-level flushes
    /// mutate this store instead of AppState so the object graph stays stable.
    public let streamPresentation = StreamTextStore()
    /// Low-frequency projection for the sidebar thread list.
    public let sidebarPresentation = SidebarPresentationStore()
    var environment: AppEnvironment
    var agentLoops: [UUID: AgentLoop] = [:]
    public static let streamingOutputID = "__streaming_output__"
    var streamBuffers: [UUID: String] = [:]
    var streamLastFlushAt: [UUID: Date] = [:]
    var thinkingBuffers: [UUID: String] = [:]
    var thinkingLastFlushAt: [UUID: Date] = [:]
    var generationStartTimes: [UUID: Date] = [:]
    var liveActivitiesByThread: [UUID: String] = [:]
    var generationRunIDs: [UUID: UUID] = [:]
    var estimatedProgressCache: [UUID: (steps: Int, value: Double?)] = [:]
    var healthChecksInFlight: Set<UUID> = []
    private var _cachedThreadSummaries: [ThreadRecord]?
    private var _cachedSummaryGen: UInt64 = 0
    private var _cachedSummarySignature: Int = 0
    private var _cachedSelectedThreadID: UUID?
    var searchDebounceTask: Task<Void, Never>?
    var deletedThreadBackup: (thread: Thread, index: Int)?

    public var cachedThreadRecordSummaries: [ThreadRecord] {
        // Streaming text updates do not affect sidebar records. The lightweight
        // signature below still invalidates the cache for status, title, time,
        // pin/archive, project, or selection changes.
        let signature = threadSummarySignature()
        if let cached = _cachedThreadSummaries,
            _cachedSummaryGen == state.threadSummaryGeneration,
            _cachedSelectedThreadID == state.selectedThreadID,
            _cachedSummarySignature == signature
        {
            return cached
        }
        let result = state.threadRecordSummaries
        _cachedThreadSummaries = result
        _cachedSummaryGen = state.threadSummaryGeneration
        _cachedSummarySignature = signature
        _cachedSelectedThreadID = state.selectedThreadID
        return result
    }


    private func threadSummarySignature() -> Int {
        var hasher = Hasher()
        hasher.combine(state.threadSummaryGeneration)
        hasher.combine(state.selectedThreadID)
        for thread in state.threads where !thread.isEmptyPlaceholder || thread.id == state.selectedThreadID {
            hasher.combine(thread.id)
            hasher.combine(thread.title)
            hasher.combine(thread.status.rawValue)
            hasher.combine(thread.updatedAt.timeIntervalSinceReferenceDate)
            hasher.combine(thread.isPinned)
            hasher.combine(thread.isArchived)
            hasher.combine(thread.projectID)
            hasher.combine(thread.executionState.rawValue)
        }
        return hasher.finalize()
    }

    let streamFlushCharacterThreshold = 700
    let streamFlushInterval: TimeInterval = 0.65
    private var shellStreamObserver: NSObjectProtocol?

    // H1: Debounced persistence — collapse rapid persist calls into one
    var persistDebounceTask: Task<Void, Never>?
    var settingsPersistTask: Task<Void, Never>?
    var connectorsPersistTask: Task<Void, Never>?
    var lastPersistedAt: Date = .distantPast
    let persistDebounceInterval: TimeInterval = 1.0
    let preferencePersistDebounceInterval: TimeInterval = 0.25

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        var startupConnectorSwitchMessage: String?
        if let activeID = initialState.activeConnectorID,
            let active = initialState.connectors.first(where: { $0.id == activeID }),
            active.health == .offline,
            let fallback = AgentLoop.fallbackConnector(after: active, allConnectors: initialState.connectors)
        {
            // Keep the user's selected connector and persisted defaults intact.
            // Request-time fallback is handled without rewriting preferences.
            startupConnectorSwitchMessage = "当前模型离线，本次请求可临时使用 \(AgentLoop.displayConnectorName(fallback))。"
        }
        self.state = initialState
        self.environment = environment
        self.sidebarPresentation.update(
            records: initialState.threadRecordSummaries,
            selectedThreadID: initialState.selectedThreadID,
            searchText: initialState.searchText,
            debouncedSearchText: initialState.debouncedSearchText
        )
        if let startupConnectorSwitchMessage {
            self.state.notice = AppNotice(message: startupConnectorSwitchMessage, style: .info)
        }
        if initialState.threads != state.threads {
            persistThreads()
        }
        // Self-evolution: auto-promote winning prompt variants on startup
        PromptRegistry.shared.autoPromote()
        // Auto-resume: select the most recently interrupted task on launch
        autoResumeInterruptedTask()
        // Keep launch cheap: history is available in the sidebar, but no old timeline
        // should be rendered until the user explicitly opens it.
        if !Self.isRunningTests {
            self.state.selectThread(id: nil)
        }
        syncGeneratingStateForSelectedThread()
        shellStreamObserver = NotificationCenter.default.addObserver(
            forName: .shellStreamUpdate,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            Task { @MainActor [weak self] in
                guard let self = self, let info = info else { return }
                self.handleShellStreamNotification(info)
            }
        }
    }

    public static func preview() -> AppStore {
        AppStore(state: .preview, environment: .preview)
    }

    public static func live() -> AppStore {
        // Bootstrap off the main thread: the main thread must not pay
        // SQLite open/migrate + full JSON decode synchronously at launch.
        let store = AppStore(state: .empty, environment: .preview)
        store.beginAsyncBootstrap()
        return store
    }

    private var bootstrapTask: Task<Void, Never>?

    func refreshSidebarPresentation() {
        let query = (state.debouncedSearchText.isEmpty ? state.searchText : state.debouncedSearchText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let records = query.isEmpty ? cachedThreadRecordSummaries : state.filteredThreadRecordSummaries
        sidebarPresentation.update(
            records: records,
            selectedThreadID: state.selectedThreadID,
            searchText: state.searchText,
            debouncedSearchText: state.debouncedSearchText
        )
    }

    private func beginAsyncBootstrap() {
        bootstrapTask = Task { @MainActor [weak self] in
            let started = Date()
            let loaded = await Task.detached(priority: .userInitiated) { () -> BootstrappedRuntime in
                let environment = AppEnvironment.live
                let state = AppState.bootstrap(environment: environment)
                return BootstrappedRuntime(environment: environment, state: state)
            }.value
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
            LaicaiLog.info("Bootstrap completed off main thread in \(elapsedMs)ms")
            guard let self, !Task.isCancelled else { return }
            self.environment = loaded.environment
            self.state = loaded.state
            self.refreshSidebarPresentation()
            self.isBootstrapping = false
            self.bootstrapTask = nil
        }
    }
// MARK: - Message Sending

    var generationTasks: [UUID: Task<Void, Never>] = [:]

}

private struct BootstrappedRuntime {
    let environment: AppEnvironment
    let state: AppState
}
