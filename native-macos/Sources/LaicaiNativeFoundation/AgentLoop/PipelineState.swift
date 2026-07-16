import Foundation
import LaicaiNativeDomain

// MARK: - Pipeline Dependencies (Injectable)

/// Injectable dependencies for the pipeline, replacing direct singleton access.
/// All default to `.shared` for backward compatibility.
struct PipelineDependencies {
    var toolRegistry: ToolRegistry
    var memoryEngine: MemoryEngine
    var skillEvolutionEngine: SkillEvolutionEngine
    var failurePatternDB: FailurePatternDB
    var taskOutcomeRecorder: TaskOutcomeRecorder
    var promptRegistry: PromptRegistry
    var securityManager: SecurityManager
    var workspaceSandbox: WorkspaceSandbox

    @MainActor
    static var shared: PipelineDependencies {
        PipelineDependencies(
            toolRegistry: .shared,
            memoryEngine: .shared,
            skillEvolutionEngine: .shared,
            failurePatternDB: .shared,
            taskOutcomeRecorder: .shared,
            promptRegistry: .shared,
            securityManager: .shared,
            workspaceSandbox: .shared
        )
    }
}

// MARK: - Pipeline Config (Immutable)

/// Immutable configuration for a pipeline run.
/// Contains all values that don't change during execution.
struct PipelineConfig {
    // ── Identity ──
    let taskID: UUID
    let intent: UserIntent
    let message: String
    let imageAttachments: [ImageAttachment]
    let priorSteps: [TaskStep]
    let summaryCache: String?
    let startTime: CFAbsoluteTime
    let allConnectors: [ConnectorProfile]

    // ── Derived Config ──
    let needsPlanning: Bool
    let isPureContinuation: Bool
    let isReadOnlyRun: Bool
    let intentString: String

    // ── Constants ──
    let maxNudges: Int = 2
    let maxConsecutiveEmpty: Int = 3
    let maxTransientRetries: Int
    let maxRepeatedFailures: Int = 2
    let maxAutoRounds: Int = 3
    let absoluteMaxSteps: Int = 120

    // ── Agent Config ──
    let maxIterations: Int
    let maxTokensPerTurn: Int
    let workspaceRoot: String
    let supportsToolCalling: Bool
    let contextMode: ContextMode
    let contextWindow: Int
    let modelName: String
    let connectorEndpoint: String
    let apiKey: String
    let emitDebugSteps: Bool
    let allowedTools: Set<String>?

    // ── Dependencies (injectable) ──
    let dependencies: PipelineDependencies

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
        dependencies: PipelineDependencies? = nil,
        startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        self.taskID = task.id
        self.allConnectors = allConnectors
        self.intent = intent
        self.message = message
        self.imageAttachments = imageAttachments
        self.priorSteps = priorSteps
        self.summaryCache = summaryCache
        self.startTime = startTime
        self.dependencies = dependencies ?? PipelineDependencies.shared

        self.needsPlanning =
            intent != .chat
            && priorSteps.isEmpty
            && !AgentLoop.isPureContinuationCommand(message)
            && message.count > 10
        self.isPureContinuation = AgentLoop.isPureContinuationCommand(message)

        let canonicalAllowedTools = AgentLoop.canonicalToolSet(config.allowedTools)
        let isAllowed: (String) -> Bool = { name in
            canonicalAllowedTools?.contains(ToolNameCodec.canonicalName(name)) ?? false
        }
        self.isReadOnlyRun =
            config.allowedTools != nil
            && !isAllowed("file.write")
            && !isAllowed("file.edit")
            && !isAllowed("diff.apply")
            && !isAllowed("shell.exec")
            && !isAllowed("wiki.build")
            && !isAllowed("verify.build")
            && !AgentLoop.explicitApprovalSideEffectTools.contains { isAllowed($0) }

        self.maxTransientRetries = isReadOnlyRun ? 1 : 3

        self.intentString = {
            switch intent {
            case .chat: return "chat"
            case .research: return "research"
            case .task: return "task"
            case .workflow(let name): return "workflow:\(name)"
            }
        }()

        // Agent config
        self.maxIterations = config.maxIterations
        self.maxTokensPerTurn = config.maxTokensPerTurn
        self.workspaceRoot = config.workspaceRoot
        self.supportsToolCalling = config.supportsToolCalling
        self.contextMode = config.contextMode
        self.contextWindow = config.contextWindow
        self.modelName = config.modelName
        self.connectorEndpoint = config.connectorEndpoint
        self.apiKey = config.apiKey
        self.emitDebugSteps = config.emitDebugSteps
        self.allowedTools = config.allowedTools
    }
}

// MARK: - Pipeline State

/// Holds all mutable state that flows through the agent pipeline stages.
/// Previously these were local variables scattered across the monolithic `run()` method.
/// Now organized with PipelineConfig for immutable values.
struct PipelineState {
    // ── Config (immutable) ──
    let config: PipelineConfig

    // ── Identity (mutable) ──
    var task: AgentTask
    var taskContext: TaskContext
    var connector: ConnectorProfile

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

    // ── Derived (mutable) ──
    var usesOllamaChat: Bool
    var effectiveMaxIterations: Int

    // ── Convenience accessors ──

    var allConnectors: [ConnectorProfile] { config.allConnectors }
    var intent: UserIntent { config.intent }
    var message: String { config.message }
    var imageAttachments: [ImageAttachment] { config.imageAttachments }
    var priorSteps: [TaskStep] { config.priorSteps }
    var summaryCache: String? { config.summaryCache }
    var startTime: CFAbsoluteTime { config.startTime }
    var needsPlanning: Bool { config.needsPlanning }
    var isPureContinuation: Bool { config.isPureContinuation }
    var isReadOnlyRun: Bool { config.isReadOnlyRun }
    var intentString: String { config.intentString }
    var maxNudges: Int { config.maxNudges }
    var maxConsecutiveEmpty: Int { config.maxConsecutiveEmpty }
    var maxTransientRetries: Int { config.maxTransientRetries }
    var maxRepeatedFailures: Int { config.maxRepeatedFailures }
    var maxAutoRounds: Int { config.maxAutoRounds }
    var absoluteMaxSteps: Int { config.absoluteMaxSteps }

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
        self.config = PipelineConfig(
            task: task,
            taskContext: taskContext,
            connector: connector,
            allConnectors: allConnectors,
            intent: intent,
            message: message,
            imageAttachments: imageAttachments,
            priorSteps: priorSteps,
            summaryCache: summaryCache,
            config: config,
            startTime: startTime
        )

        self.task = task
        self.taskContext = taskContext
        self.connector = connector

        self.usesOllamaChat = AgentLoop.usesOllamaChat(connector)

        self.effectiveMaxIterations = config.maxIterations
    }
}
