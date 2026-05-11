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
    static let streamingOutputID = "__streaming_output__"
    var streamBuffers: [UUID: String] = [:]
    var streamLastFlushAt: [UUID: Date] = [:]
    var thinkingBuffers: [UUID: String] = [:]
    var thinkingLastFlushAt: [UUID: Date] = [:]
    var chatStreamBuffers: [UUID: String] = [:]
    var chatStreamLastFlushAt: [UUID: Date] = [:]
    var healthChecksInFlight: Set<UUID> = []
    private var _cachedThreadSummaries: [ThreadRecord]?
    private var _cachedSummaryGen: UInt64 = 0

    public var cachedThreadRecordSummaries: [ThreadRecord] {
        if let cached = _cachedThreadSummaries, _cachedSummaryGen == state.threadSummaryGeneration {
            return cached
        }
        let result = state.threadRecordSummaries
        _cachedThreadSummaries = result
        _cachedSummaryGen = state.threadSummaryGeneration
        return result
    }

    let streamFlushCharacterThreshold = 900
    let streamFlushInterval: TimeInterval = 0.8
    let chatStreamFlushCharacterThreshold = 1_200
    let chatStreamFlushInterval: TimeInterval = 0.9
    private var shellStreamObserver: NSObjectProtocol?

    // H1: Debounced persistence — collapse rapid persist calls into one
    var persistDebounceTask: Task<Void, Never>?
    var lastPersistedAt: Date = .distantPast
    let persistDebounceInterval: TimeInterval = 1.0

    public init(state: AppState, environment: AppEnvironment = .preview) {
        var initialState = state
        Self.markStaleRunningTasks(in: &initialState)
        self.state = initialState
        self.environment = environment
        if initialState.threads != state.threads {
            persistThreads()
        }
        // Self-evolution: auto-promote winning prompt variants on startup
        PromptRegistry.shared.autoPromote()
        // Auto-resume: select the most recently interrupted task on launch
        autoResumeInterruptedTask()
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
