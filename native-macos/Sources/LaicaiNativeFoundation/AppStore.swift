import AppKit
import Combine
import Foundation
import LaicaiNativeDomain

@MainActor
public final class AppStore: ObservableObject {
    @Published public internal(set) var state: AppState
    @Published public var isShowingTaskModeInfo = false
    let environment: AppEnvironment
    var agentLoops: [UUID: AgentLoop] = [:]
    public static let streamingOutputID = "__streaming_output__"
    var streamBuffers: [UUID: String] = [:]
    var streamLastFlushAt: [UUID: Date] = [:]
    var thinkingBuffers: [UUID: String] = [:]
    var thinkingLastFlushAt: [UUID: Date] = [:]
    var chatStreamBuffers: [UUID: String] = [:]
    var chatStreamLastFlushAt: [UUID: Date] = [:]
    var generationStartTimes: [UUID: Date] = [:]
    var liveActivitiesByThread: [UUID: String] = [:]
    var generationRunIDs: [UUID: UUID] = [:]
    var healthChecksInFlight: Set<UUID> = []
    private var _cachedThreadSummaries: [ThreadRecord]?
    private var _cachedSummaryGen: UInt64 = 0
    private var _cachedSummarySignature: Int = 0
    var searchDebounceTask: Task<Void, Never>?

    public var cachedThreadRecordSummaries: [ThreadRecord] {
        let signature = threadSummarySignature()
        if let cached = _cachedThreadSummaries,
           _cachedSummaryGen == state.threadSummaryGeneration,
           _cachedSummarySignature == signature {
            return cached
        }
        let result = state.threadRecordSummaries
        _cachedThreadSummaries = result
        _cachedSummaryGen = state.threadSummaryGeneration
        _cachedSummarySignature = signature
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

    let streamFlushCharacterThreshold = 1_800
    let streamFlushInterval: TimeInterval = 1.4
    let chatStreamFlushCharacterThreshold = 2_400
    let chatStreamFlushInterval: TimeInterval = 1.5
    private var shellStreamObserver: NSObjectProtocol?

    // H1: Debounced persistence — collapse rapid persist calls into one
    var persistDebounceTask: Task<Void, Never>?
    var lastPersistedAt: Date = .distantPast
    let persistDebounceInterval: TimeInterval = 1.0

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        var startupConnectorSwitchMessage: String?
        if let activeID = initialState.activeConnectorID,
           let active = initialState.connectors.first(where: { $0.id == activeID }),
           active.health == .offline,
           let fallback = AgentLoop.fallbackConnector(after: active, allConnectors: initialState.connectors) {
            initialState.activeConnectorID = fallback.id
            initialState.settings.defaultConnectorName = fallback.name
            startupConnectorSwitchMessage = "当前模型离线，已自动切换到 \(AgentLoop.displayConnectorName(fallback))。"
        }
        self.state = initialState
        self.environment = environment
        if let startupConnectorSwitchMessage {
            self.state.notice = AppNotice(message: startupConnectorSwitchMessage, style: .info)
            persistSettings()
            persistConnectors()
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
        let environment = AppEnvironment.live
        return AppStore(state: .bootstrap(environment: environment), environment: environment)
    }

    // MARK: - Message Sending

    var generationTasks: [UUID: Task<Void, Never>] = [:]

}
