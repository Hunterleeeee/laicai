import Foundation

// MARK: - Legacy Types (kept for backward compat + migration)

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case tool
    case system

    public var title: String {
        switch self {
        case .user: return "你"
        case .assistant: return "助手"
        case .tool: return "工具"
        case .system: return "系统"
        }
    }
}

public enum SessionCategory: String, Codable, Sendable, CaseIterable {
    case inbox = "Inbox"
    case engineering = "Engineering"
    case research = "Research"
    case operations = "Operations"
}

public struct ChatTurn: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var text: String
    public var createdAt: Date
    public var isSummary: Bool
    public var metrics: ResponseMetrics?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = .now,
        isSummary: Bool = false,
        metrics: ResponseMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isSummary = isSummary
        self.metrics = metrics
    }
}

public struct ChatSession: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var preview: String
    public var updatedAt: Date
    public var isPinned: Bool
    public var category: SessionCategory
    public var modelName: String
    public var unreadCount: Int
    public var turns: [ChatTurn]

    public init(
        id: UUID = UUID(),
        title: String,
        preview: String,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        category: SessionCategory = .inbox,
        modelName: String,
        unreadCount: Int = 0,
        turns: [ChatTurn] = []
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.category = category
        self.modelName = modelName
        self.unreadCount = unreadCount
        self.turns = turns
    }

    /// Create a ChatSession from a unified Thread (for legacy compatibility).
    public init(thread: Thread) {
        id = thread.id
        title = thread.title
        preview = thread.preview
        updatedAt = thread.updatedAt
        isPinned = thread.isPinned
        category = thread.category
        modelName = thread.modelName
        unreadCount = thread.unreadCount
        turns = thread.steps.map { step in
            ChatTurn(
                id: step.id,
                role: step.kind == .userInput ? .user : .assistant,
                text: step.text,
                createdAt: step.createdAt,
                metrics: step.metrics
            )
        }
    }
}

// MARK: - Agent Architecture Types (2026)

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingReview
    case completed
    case failed
    case cancelled

    public var title: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .waitingReview: return "待审查"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已暂停"
        }
    }

    public var icon: String {
        switch self {
        case .queued: return "clock"
        case .running: return "play.fill"
        case .waitingReview: return "eye"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "pause.circle"
        }
    }
}

public enum TaskStepKind: String, Codable, Sendable {
    case userInput
    case aiThinking
    case toolCall
    case toolResult
    case textOutput
    case error
    case reviewRequest
    case reviewResult

    public var icon: String {
        switch self {
        case .userInput: return "person.fill"
        case .aiThinking: return "sparkles"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return "doc.text"
        case .textOutput: return "text.bubble"
        case .error: return "exclamationmark.triangle"
        case .reviewRequest: return "eye"
        case .reviewResult: return "checkmark.circle"
        }
    }

    public var title: String {
        switch self {
        case .userInput: return "你"
        case .aiThinking: return "思考"
        case .toolCall: return "工具调用"
        case .toolResult: return "工具结果"
        case .textOutput: return "输出"
        case .error: return "错误"
        case .reviewRequest: return "审查请求"
        case .reviewResult: return "审查结果"
        }
    }
}

public struct DiffHunk: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var index: Int
    public var oldText: String
    public var newText: String
    public var summary: String
    public var approved: Bool?

    public init(id: UUID = UUID(), index: Int, oldText: String, newText: String, summary: String, approved: Bool? = nil) {
        self.id = id
        self.index = index
        self.oldText = oldText
        self.newText = newText
        self.summary = summary
        self.approved = approved
    }
}

public struct TaskStep: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var kind: TaskStepKind
    public var text: String
    public var toolName: String?
    public var toolParams: [String: String]?
    public var toolCallId: String?
    public var isCollapsible: Bool
    public var isCollapsed: Bool
    public var isFailure: Bool
    public var recoverable: Bool
    public var retryAction: String?
    public var diffFilePath: String?
    public var diffOldContent: String?
    public var diffNewContent: String?
    public var approved: Bool?
    public var diffHunks: [DiffHunk]?
    public var metrics: ResponseMetrics?
    public var continuationOf: UUID?
    public var agentRole: AgentRole?
    public var reasoningContent: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: TaskStepKind,
        text: String,
        toolName: String? = nil,
        toolParams: [String: String]? = nil,
        toolCallId: String? = nil,
        isCollapsible: Bool = false,
        isCollapsed: Bool = false,
        isFailure: Bool = false,
        recoverable: Bool = false,
        retryAction: String? = nil,
        diffFilePath: String? = nil,
        diffOldContent: String? = nil,
        diffNewContent: String? = nil,
        approved: Bool? = nil,
        diffHunks: [DiffHunk]? = nil,
        metrics: ResponseMetrics? = nil,
        continuationOf: UUID? = nil,
        agentRole: AgentRole? = nil,
        reasoningContent: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolParams = toolParams
        self.toolCallId = toolCallId
        self.isCollapsible = isCollapsible
        self.isCollapsed = isCollapsed
        self.isFailure = isFailure
        self.recoverable = recoverable
        self.retryAction = retryAction
        self.diffFilePath = diffFilePath
        self.diffOldContent = diffOldContent
        self.diffNewContent = diffNewContent
        self.approved = approved
        self.diffHunks = diffHunks
        self.metrics = metrics
        self.continuationOf = continuationOf
        self.agentRole = agentRole
        self.reasoningContent = reasoningContent
        self.createdAt = createdAt
    }
}

public struct ResponseMetrics: Equatable, Codable, Sendable {
    public var thinkingDuration: TimeInterval?
    public var totalDuration: TimeInterval
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var tokensPerSecond: Double?

    public init(
        thinkingDuration: TimeInterval? = nil,
        totalDuration: TimeInterval = 0,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.thinkingDuration = thinkingDuration
        self.totalDuration = totalDuration
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
    }
}

public struct TaskContext: Equatable, Codable, Sendable {
    public var workspaceRoot: String
    public var vaultRoot: String?
    public var relevantFiles: [FileInfo]
    public var claudeMD: String?
    public var gitBranch: String?
    public var gitDiff: String?
    public var memory: TaskMemory
    public var contextMode: ContextMode
    public var comfyUIServerURL: String?
    public var comfyUIModelName: String?
    public var imageGenerationEndpoint: String?
    public var imageGenerationModelName: String?
    public var imageGenerationAPIKey: String?
    public var metadata: [String: String]

    public init(
        workspaceRoot: String = "",
        vaultRoot: String? = nil,
        relevantFiles: [FileInfo] = [],
        claudeMD: String? = nil,
        gitBranch: String? = nil,
        gitDiff: String? = nil,
        memory: TaskMemory = TaskMemory(),
        contextMode: ContextMode = .balanced,
        comfyUIServerURL: String? = nil,
        comfyUIModelName: String? = nil,
        imageGenerationEndpoint: String? = nil,
        imageGenerationModelName: String? = nil,
        imageGenerationAPIKey: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.workspaceRoot = workspaceRoot
        self.vaultRoot = vaultRoot
        self.relevantFiles = relevantFiles
        self.claudeMD = claudeMD
        self.gitBranch = gitBranch
        self.gitDiff = gitDiff
        self.memory = memory
        self.contextMode = contextMode
        self.comfyUIServerURL = comfyUIServerURL
        self.comfyUIModelName = comfyUIModelName
        self.imageGenerationEndpoint = imageGenerationEndpoint
        self.imageGenerationModelName = imageGenerationModelName
        self.imageGenerationAPIKey = imageGenerationAPIKey
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceRoot
        case vaultRoot
        case relevantFiles
        case claudeMD
        case gitBranch
        case gitDiff
        case metadata
        case memory
        case contextMode
        case comfyUIServerURL
        case comfyUIModelName
        case imageGenerationEndpoint
        case imageGenerationModelName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? ""
        vaultRoot = try container.decodeIfPresent(String.self, forKey: .vaultRoot)
        relevantFiles = try container.decodeIfPresent([FileInfo].self, forKey: .relevantFiles) ?? []
        claudeMD = try container.decodeIfPresent(String.self, forKey: .claudeMD)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        gitDiff = try container.decodeIfPresent(String.self, forKey: .gitDiff)
        memory = try container.decodeIfPresent(TaskMemory.self, forKey: .memory) ?? TaskMemory()
        contextMode = try container.decodeIfPresent(ContextMode.self, forKey: .contextMode) ?? .balanced
        comfyUIServerURL = try container.decodeIfPresent(String.self, forKey: .comfyUIServerURL)
        comfyUIModelName = try container.decodeIfPresent(String.self, forKey: .comfyUIModelName)
        imageGenerationEndpoint = try container.decodeIfPresent(String.self, forKey: .imageGenerationEndpoint)
        imageGenerationModelName = try container.decodeIfPresent(String.self, forKey: .imageGenerationModelName)
        imageGenerationAPIKey = nil
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceRoot, forKey: .workspaceRoot)
        try container.encodeIfPresent(vaultRoot, forKey: .vaultRoot)
        try container.encode(relevantFiles, forKey: .relevantFiles)
        try container.encodeIfPresent(claudeMD, forKey: .claudeMD)
        try container.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try container.encodeIfPresent(gitDiff, forKey: .gitDiff)
        try container.encode(memory, forKey: .memory)
        try container.encode(contextMode, forKey: .contextMode)
        try container.encodeIfPresent(comfyUIServerURL, forKey: .comfyUIServerURL)
        try container.encodeIfPresent(comfyUIModelName, forKey: .comfyUIModelName)
        try container.encodeIfPresent(imageGenerationEndpoint, forKey: .imageGenerationEndpoint)
        try container.encodeIfPresent(imageGenerationModelName, forKey: .imageGenerationModelName)
        try container.encode(metadata, forKey: .metadata)
    }
}

public struct TaskMemory: Equatable, Codable, Sendable {
    public var readFiles: [String]
    public var searchedQueries: [String]
    public var failedTools: [String]
    public var stageConclusions: [String]
    public var checkpoints: [String]
    public var verificationStatus: String?
    public var pendingFiles: [String]
    public var userDecisions: [String]
    public var fileSummaries: [String: String]
    public var fileContentCache: [String: String]
    public var trimDetails: [String]
    public var updatedAt: Date?

    public init(
        readFiles: [String] = [],
        searchedQueries: [String] = [],
        failedTools: [String] = [],
        stageConclusions: [String] = [],
        checkpoints: [String] = [],
        verificationStatus: String? = nil,
        pendingFiles: [String] = [],
        userDecisions: [String] = [],
        fileSummaries: [String: String] = [:],
        fileContentCache: [String: String] = [:],
        trimDetails: [String] = [],
        updatedAt: Date? = nil
    ) {
        self.readFiles = readFiles
        self.searchedQueries = searchedQueries
        self.failedTools = failedTools
        self.stageConclusions = stageConclusions
        self.checkpoints = checkpoints
        self.verificationStatus = verificationStatus
        self.pendingFiles = pendingFiles
        self.userDecisions = userDecisions
        self.fileSummaries = fileSummaries
        self.fileContentCache = fileContentCache
        self.trimDetails = trimDetails
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        readFiles.isEmpty
            && searchedQueries.isEmpty
            && failedTools.isEmpty
            && stageConclusions.isEmpty
            && checkpoints.isEmpty
            && verificationStatus == nil
            && pendingFiles.isEmpty
            && userDecisions.isEmpty
            && fileSummaries.isEmpty
            && trimDetails.isEmpty
    }

    /// Append a decision with dedup + cap. userDecisions feeds back into the LLM
    /// context every turn; unbounded growth saturates the window.
    /// Cap = 24, with newest entries kept. Duplicate entries are deduped (newer wins).
    public mutating func appendDecision(_ entry: String, cap: Int = 24) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userDecisions.removeAll { $0 == trimmed }
        userDecisions.append(trimmed)
        if userDecisions.count > cap {
            userDecisions.removeFirst(userDecisions.count - cap)
        }
    }
}

public enum AgentRuntimeState: String, Codable, Sendable, CaseIterable {
    case created
    case planning
    case gatheringEvidence
    case executing
    case verifying
    case waitingUser
    case paused
    case completed
    case failed
    case cancelled

    public var title: String {
        switch self {
        case .created: return "已创建"
        case .planning: return "规划中"
        case .gatheringEvidence: return "采集中"
        case .executing: return "执行中"
        case .verifying: return "验证中"
        case .waitingUser: return "等待用户"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public enum AgentRiskPolicy: String, Codable, Sendable, CaseIterable {
    case ask
    case inspect
    case act
    case review
    case dangerous

    public var title: String {
        switch self {
        case .ask: return "问答"
        case .inspect: return "只读"
        case .act: return "执行"
        case .review: return "审查"
        case .dangerous: return "高风险"
        }
    }
}

public enum AgentContinuationPolicy: String, Codable, Sendable, CaseIterable {
    case ownFollowUps
    case pendingWhileRunning
    case explicitNewThreadOnly

    public var title: String {
        switch self {
        case .ownFollowUps: return "追问归属当前 Agent"
        case .pendingWhileRunning: return "运行中追问排队"
        case .explicitNewThreadOnly: return "显式新建才换线程"
        }
    }
}

public struct AgentTaskProtocol: Equatable, Codable, Sendable {
    public var taskGoal: String
    public var workspaceRoot: String
    public var threadID: UUID
    public var expectedOutcome: String
    public var completionCriteria: [String]
    public var riskPolicy: AgentRiskPolicy
    public var continuationPolicy: AgentContinuationPolicy
    public var createdAt: Date

    public init(
        taskGoal: String = "",
        workspaceRoot: String = "",
        threadID: UUID = UUID(),
        expectedOutcome: String = "",
        completionCriteria: [String] = [],
        riskPolicy: AgentRiskPolicy = .act,
        continuationPolicy: AgentContinuationPolicy = .ownFollowUps,
        createdAt: Date = .now
    ) {
        self.taskGoal = taskGoal
        self.workspaceRoot = workspaceRoot
        self.threadID = threadID
        self.expectedOutcome = expectedOutcome
        self.completionCriteria = completionCriteria
        self.riskPolicy = riskPolicy
        self.continuationPolicy = continuationPolicy
        self.createdAt = createdAt
    }

    public var isExecutable: Bool {
        !taskGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !completionCriteria.isEmpty
    }
}

public struct AgentExecutionLedger: Equatable, Codable, Sendable {
    public var originalRequest: String
    public var goal: String
    public var state: AgentRuntimeState
    public var stateHistory: [String]
    public var plan: [String]
    public var readFiles: [String]
    public var searches: [String]
    public var pages: [String]
    public var modifiedFiles: [String]
    public var artifacts: [String]
    public var commands: [String]
    public var verification: [String]
    public var failedTools: [String]
    public var errorReasons: [String]
    public var alternativePaths: [String]
    public var nextAction: String?
    public var unfinishedWork: [String]
    public var pendingFollowUp: String?
    public var updatedAt: Date

    public init(
        originalRequest: String = "",
        goal: String = "",
        state: AgentRuntimeState = .created,
        stateHistory: [String] = [],
        plan: [String] = [],
        readFiles: [String] = [],
        searches: [String] = [],
        pages: [String] = [],
        modifiedFiles: [String] = [],
        artifacts: [String] = [],
        commands: [String] = [],
        verification: [String] = [],
        failedTools: [String] = [],
        errorReasons: [String] = [],
        alternativePaths: [String] = [],
        nextAction: String? = nil,
        unfinishedWork: [String] = [],
        pendingFollowUp: String? = nil,
        updatedAt: Date = .now
    ) {
        self.originalRequest = originalRequest
        self.goal = goal
        self.state = state
        self.stateHistory = stateHistory
        self.plan = plan
        self.readFiles = readFiles
        self.searches = searches
        self.pages = pages
        self.modifiedFiles = modifiedFiles
        self.artifacts = artifacts
        self.commands = commands
        self.verification = verification
        self.failedTools = failedTools
        self.errorReasons = errorReasons
        self.alternativePaths = alternativePaths
        self.nextAction = nextAction
        self.unfinishedWork = unfinishedWork
        self.pendingFollowUp = pendingFollowUp
        self.updatedAt = updatedAt
    }

    public var hasToolEvidence: Bool {
        !readFiles.isEmpty
            || !searches.isEmpty
            || !pages.isEmpty
            || !commands.isEmpty
            || !verification.isEmpty
            || !modifiedFiles.isEmpty
            || !artifacts.isEmpty
    }

    public mutating func transition(to newState: AgentRuntimeState, reason: String) {
        guard state != newState else { return }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedReason.isEmpty ? "" : "：\(trimmedReason)"
        stateHistory.append("\(state.rawValue) -> \(newState.rawValue)\(suffix)")
        if stateHistory.count > 40 {
            stateHistory.removeFirst(stateHistory.count - 40)
        }
        state = newState
        updatedAt = .now
    }

    public mutating func appendUnique(_ value: String, to keyPath: WritableKeyPath<AgentExecutionLedger, [String]>, cap: Int = 80) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !self[keyPath: keyPath].contains(trimmed) {
            self[keyPath: keyPath].append(trimmed)
            if self[keyPath: keyPath].count > cap {
                self[keyPath: keyPath].removeFirst(self[keyPath: keyPath].count - cap)
            }
        }
        updatedAt = .now
    }
}

public struct FileInfo: Identifiable, Equatable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var language: String
    public var summary: String
    public var lastModified: Date?

    public init(path: String, language: String = "", summary: String = "", lastModified: Date? = nil) {
        self.path = path
        self.language = language
        self.summary = summary
        self.lastModified = lastModified
    }
}

public struct AgentTask: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus
    public var steps: [TaskStep]
    public var connectorID: UUID?
    public var workflowName: String?
    public var context: TaskContext
    public var multiAgentPlan: MultiAgentPlan?
    public var taskProtocol: AgentTaskProtocol?
    public var executionLedger: AgentExecutionLedger?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "新任务",
        status: TaskStatus = .queued,
        steps: [TaskStep] = [],
        connectorID: UUID? = nil,
        workflowName: String? = nil,
        context: TaskContext = TaskContext(),
        multiAgentPlan: MultiAgentPlan? = nil,
        taskProtocol: AgentTaskProtocol? = nil,
        executionLedger: AgentExecutionLedger? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.steps = steps
        self.connectorID = connectorID
        self.workflowName = workflowName
        self.context = context
        self.multiAgentPlan = multiAgentPlan
        self.taskProtocol = taskProtocol
        self.executionLedger = executionLedger
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Create an AgentTask from a unified Thread (for legacy compatibility).
    public init(thread: Thread) {
        id = thread.id
        title = thread.title
        status = thread.status
        steps = thread.steps
        connectorID = thread.connectorID
        workflowName = thread.workflowName
        context = thread.context
        multiAgentPlan = thread.multiAgentPlan
        taskProtocol = thread.taskProtocol
        executionLedger = thread.executionLedger
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }

    public var preview: String {
        if let lastStep = steps.last {
            let truncated = lastStep.text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(truncated)
        }
        return "空任务"
    }
}
