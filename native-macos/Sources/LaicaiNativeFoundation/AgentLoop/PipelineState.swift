import Foundation
import LaicaiNativeDomain

// MARK: - Pipeline State

/// Holds all mutable state that flows through the agent pipeline stages.
/// Previously these were local variables scattered across the monolithic `run()` method.
struct PipelineState {
    // ── Identity ──
    var task: AgentTask
    var taskContext: TaskContext
    let connector: ConnectorProfile
    let allConnectors: [ConnectorProfile]
    let intent: UserIntent
    let message: String
    let imageAttachments: [ImageAttachment]
    let priorSteps: [TaskStep]
    let summaryCache: String?
    let startTime: CFAbsoluteTime

    // ── Prompt & Tools ──
    var systemPrompt: String = ""
    var toolDefs: [ToolDefinition] = []
    var currentPhase: TaskPhase = .explore
    var messages: [ChatMessage] = []
    var injectedPatternHashes: [String] = []

    // ── Iteration Tracking ──
    var iteration: Int = 0
    var didComplete: Bool = false
    var hadFailure: Bool = false
    var wasTruncated: Bool = false
    var nudgeCount: Int = 0
    var consecutiveEmptyResponses: Int = 0
    var transientRetryCount: Int = 0
    var autoRound: Int = 0
    var didInjectWorkingSet: Bool = false

    // ── Circuit Breakers ──
    var circuitBrokenTools: Set<String> = []
    var toolFailureCounts: [String: Int] = [:]
    var usedToolCompatibilityFallback: Bool = false

    // ── Derived Config (computed once) ──
    let needsPlanning: Bool
    let isPureContinuation: Bool
    let isReadOnlyRun: Bool
    let usesOllamaChat: Bool
    var effectiveMaxIterations: Int
    let intentString: String

    // ── Constants ──
    let maxNudges: Int = 2
    let maxConsecutiveEmpty: Int = 3
    let maxTransientRetries: Int
    let maxRepeatedFailures: Int = 2
    let maxAutoRounds: Int = 3
    let absoluteMaxSteps: Int = 120

    @MainActor
    init(
        task: AgentTask,
        taskContext: TaskContext,
        connector: ConnectorProfile,
        allConnectors: [ConnectorProfile],
        intent: UserIntent,
        message: String,
        imageAttachments: [ImageAttachment],
        priorSteps: [TaskStep],
        summaryCache: String?,
        config: AgentLoop.Config
    ) {
        self.task = task
        self.taskContext = taskContext
        self.connector = connector
        self.allConnectors = allConnectors
        self.intent = intent
        self.message = message
        self.imageAttachments = imageAttachments
        self.priorSteps = priorSteps
        self.summaryCache = summaryCache
        self.startTime = CFAbsoluteTimeGetCurrent()

        self.needsPlanning = intent != .chat
            && priorSteps.isEmpty
            && !AgentLoop.isPureContinuationCommand(message)
            && message.count > 10
        self.isPureContinuation = AgentLoop.isPureContinuationCommand(message)

        self.isReadOnlyRun = config.allowedTools != nil
            && !(config.allowedTools?.contains("file.write") ?? false)
            && !(config.allowedTools?.contains("file.edit") ?? false)
            && !(config.allowedTools?.contains("shell.exec") ?? false)
            && !(config.allowedTools?.contains("wiki.build") ?? false)
            && !(config.allowedTools?.contains("verify.build") ?? false)

        self.usesOllamaChat = AgentLoop.usesOllamaChat(connector)
        self.maxTransientRetries = isReadOnlyRun ? 1 : 3

        self.intentString = {
            switch intent {
            case .chat: return "chat"
            case .research: return "research"
            case .task: return "task"
            case .workflow(let name): return "workflow:\(name)"
            }
        }()

        self.effectiveMaxIterations = config.maxIterations
        if let avgIter = TaskOutcomeRecorder.shared.avgIterations(intent: intentString) {
            let learned = Int(ceil(avgIter * 1.5))
            self.effectiveMaxIterations = max(3, min(learned, config.maxIterations))
        }
    }
}
