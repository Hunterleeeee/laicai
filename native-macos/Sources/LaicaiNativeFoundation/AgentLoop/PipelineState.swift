import Foundation
import LaicaiNativeDomain

// MARK: - Pipeline State

/// Holds all mutable state that flows through the agent pipeline stages.
/// Previously these were local variables scattered across the monolithic `run()` method.
struct PipelineState {
    // ── Identity ──
    var task: AgentTask
    var taskContext: TaskContext
    var connector: ConnectorProfile
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
    var didConnectorFailover: Bool = false

    // ── Derived Config (computed once) ──
    let needsPlanning: Bool
    let isPureContinuation: Bool
    let isReadOnlyRun: Bool
    var usesOllamaChat: Bool
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
        config: AgentLoop.Config,
        startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
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
        self.startTime = startTime

        self.needsPlanning = intent != .chat
            && priorSteps.isEmpty
            && !AgentLoop.isPureContinuationCommand(message)
            && message.count > 10
        self.isPureContinuation = AgentLoop.isPureContinuationCommand(message)

        let canonicalAllowedTools = AgentLoop.canonicalToolSet(config.allowedTools)
        let isAllowed: (String) -> Bool = { name in
            canonicalAllowedTools?.contains(ToolNameCodec.canonicalName(name)) ?? false
        }
        self.isReadOnlyRun = config.allowedTools != nil
            && !isAllowed("file.write")
            && !isAllowed("file.edit")
            && !isAllowed("diff.apply")
            && !isAllowed("shell.exec")
            && !isAllowed("wiki.build")
            && !isAllowed("verify.build")
            && !AgentLoop.explicitApprovalSideEffectTools.contains { isAllowed($0) }

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
            let learned = max(1, Int(ceil(avgIter * 1.5)))
            self.effectiveMaxIterations = min(config.maxIterations, max(3, learned))
        }
    }
}
