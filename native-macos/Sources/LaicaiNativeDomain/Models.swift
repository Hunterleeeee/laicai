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
        category: SessionCategory,
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
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
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

// MARK: - Unified Thread Model

public enum ThreadSource: String, Codable, Sendable {
    case session
    case task
}

public enum ThreadEventKind: String, Codable, Sendable {
    case user
    case assistant
    case thinking
    case toolCall
    case toolResult
    case review
    case error
}

public struct ThreadEvent: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var kind: ThreadEventKind
    public var text: String
    public var createdAt: Date
    public var sourceStepID: UUID?
    public var sourceTurnID: UUID?
    public var metrics: ResponseMetrics?

    public init(
        id: UUID = UUID(),
        kind: ThreadEventKind,
        text: String,
        createdAt: Date = .now,
        sourceStepID: UUID? = nil,
        sourceTurnID: UUID? = nil,
        metrics: ResponseMetrics? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.sourceStepID = sourceStepID
        self.sourceTurnID = sourceTurnID
        self.metrics = metrics
    }
}

/// Unified thread: merges ChatSession and AgentTask into a single data model.
/// - `steps` is the canonical event stream (ChatTurn maps to .userInput/.textOutput).
/// - `source` is a stored property, set at creation time. If not explicitly set, inferred from context.
/// - Legacy `ChatSession` / `AgentTask` are kept for Codable migration.
public struct Thread: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var preview: String
    public var status: TaskStatus
    public var steps: [TaskStep]
    public var connectorID: UUID?
    public var workflowName: String?
    public var context: TaskContext
    public var modelName: String
    public var category: SessionCategory
    public var isPinned: Bool
    public var isArchived: Bool
    public var unreadCount: Int
    public var summaryCache: String?
    public var multiAgentPlan: MultiAgentPlan?
    public var userRating: Int  // 1-5 star rating from user feedback; 0 = unrated
    public var createdAt: Date
    public var updatedAt: Date
    public var source: ThreadSource

    public init(
        id: UUID = UUID(),
        title: String = "新会话",
        preview: String = "",
        status: TaskStatus = .queued,
        steps: [TaskStep] = [],
        connectorID: UUID? = nil,
        workflowName: String? = nil,
        context: TaskContext = TaskContext(),
        modelName: String = "",
        category: SessionCategory = .engineering,
        isPinned: Bool = false,
        isArchived: Bool = false,
        unreadCount: Int = 0,
        summaryCache: String? = nil,
        multiAgentPlan: MultiAgentPlan? = nil,
        userRating: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        source: ThreadSource? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.status = status
        self.steps = steps
        self.connectorID = connectorID
        self.workflowName = workflowName
        self.context = context
        self.modelName = modelName
        self.category = category
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.unreadCount = unreadCount
        self.summaryCache = summaryCache
        self.multiAgentPlan = multiAgentPlan
        self.userRating = userRating
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        // Infer source if not explicitly set
        self.source = source ?? Self.inferSource(context: context, workflowName: workflowName, steps: steps)
    }

    // Custom Codable: tolerate missing fields added after initial schema
    private enum CodingKeys: String, CodingKey {
        case id, title, preview, status, steps, connectorID, workflowName, context
        case modelName, category, isPinned, isArchived, unreadCount, summaryCache
        case multiAgentPlan, userRating, createdAt, updatedAt, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        preview = try c.decode(String.self, forKey: .preview)
        status = try c.decode(TaskStatus.self, forKey: .status)
        steps = try c.decode([TaskStep].self, forKey: .steps)
        connectorID = try c.decodeIfPresent(UUID.self, forKey: .connectorID)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName)
        context = try c.decode(TaskContext.self, forKey: .context)
        modelName = try c.decode(String.self, forKey: .modelName)
        category = try c.decode(SessionCategory.self, forKey: .category)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        summaryCache = try c.decodeIfPresent(String.self, forKey: .summaryCache)
        multiAgentPlan = try c.decodeIfPresent(MultiAgentPlan.self, forKey: .multiAgentPlan)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        source = try c.decode(ThreadSource.self, forKey: .source)
    }

    /// Infer ThreadSource from content — used as fallback when source is not explicitly set
    public static func inferSource(context: TaskContext, workflowName: String?, steps: [TaskStep]) -> ThreadSource {
        context.workspaceRoot.isEmpty && workflowName == nil && steps.allSatisfy {
            $0.kind == .userInput || $0.kind == .textOutput || $0.kind == .aiThinking || $0.kind == .error
        } ? .session : .task
    }

    /// Create a Thread from a legacy ChatSession.
    public init(session: ChatSession) {
        id = session.id
        title = session.title
        preview = session.preview
        status = .completed
        steps = session.turns.map { turn in
            TaskStep(
                id: turn.id,
                kind: turn.role == .user ? .userInput : .textOutput,
                text: turn.text,
                isCollapsible: false,
                isCollapsed: false,
                metrics: turn.metrics,
                createdAt: turn.createdAt
            )
        }
        connectorID = nil
        workflowName = nil
        context = TaskContext()
        modelName = session.modelName
        category = session.category
        isPinned = session.isPinned
        isArchived = false
        unreadCount = session.unreadCount
        summaryCache = nil
        userRating = 0
        createdAt = session.updatedAt
        updatedAt = session.updatedAt
        source = .session
    }

    /// Create a Thread from a legacy AgentTask.
    public init(task: AgentTask) {
        id = task.id
        title = task.title
        preview = task.preview
        status = task.status
        steps = task.steps
        connectorID = task.connectorID
        workflowName = task.workflowName
        context = task.context
        modelName = ""
        category = .engineering
        isPinned = false
        isArchived = false
        unreadCount = 0
        summaryCache = nil
        multiAgentPlan = task.multiAgentPlan
        userRating = 0
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        source = .task
    }
}

public struct ThreadRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var source: ThreadSource
    public var title: String
    public var preview: String
    public var status: TaskStatus?
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var events: [ThreadEvent]
    public var session: ChatSession?
    public var task: AgentTask?

    public init(thread: Thread, includeEvents: Bool = true) {
        id = thread.id
        source = thread.source
        title = thread.title
        preview = thread.preview
        status = thread.source == .task ? thread.status : nil
        updatedAt = thread.updatedAt
        isPinned = thread.isPinned
        isArchived = thread.isArchived
        events = includeEvents ? thread.steps.map { step in
            ThreadEvent(
                id: step.id,
                kind: Self.eventKind(for: step.kind, isFailure: step.isFailure),
                text: step.text,
                createdAt: step.createdAt,
                sourceStepID: step.id,
                metrics: step.metrics
            )
        } : []
        session = thread.source == .session ? ChatSession(thread: thread) : nil
        task = thread.source == .task ? AgentTask(thread: thread) : nil
    }

    public init(session: ChatSession, includeEvents: Bool = true) {
        id = session.id
        source = .session
        title = session.title
        preview = session.preview
        status = nil
        updatedAt = session.updatedAt
        isPinned = session.isPinned
        isArchived = false
        events = includeEvents ? session.turns.map { turn in
            ThreadEvent(
                id: turn.id,
                kind: turn.role == .user ? .user : .assistant,
                text: turn.text,
                createdAt: turn.createdAt,
                sourceTurnID: turn.id,
                metrics: turn.metrics
            )
        } : []
        self.session = session
        task = nil
    }

    public init(task: AgentTask, includeEvents: Bool = true) {
        id = task.id
        source = .task
        title = task.title
        preview = task.preview
        status = task.status
        updatedAt = task.updatedAt
        isPinned = false
        isArchived = false
        events = includeEvents ? task.steps.map { step in
            ThreadEvent(
                id: step.id,
                kind: Self.eventKind(for: step.kind, isFailure: step.isFailure),
                text: step.text,
                createdAt: step.createdAt,
                sourceStepID: step.id,
                metrics: step.metrics
            )
        } : []
        session = nil
        self.task = task
    }

    private static func eventKind(for stepKind: TaskStepKind, isFailure: Bool) -> ThreadEventKind {
        if isFailure { return .error }
        switch stepKind {
        case .userInput: return .user
        case .aiThinking: return .thinking
        case .toolCall: return .toolCall
        case .toolResult: return .toolResult
        case .textOutput: return .assistant
        case .error: return .error
        case .reviewRequest, .reviewResult: return .review
        }
    }
}

// MARK: - Tool System

public struct ToolResult: Equatable, Codable, Sendable {
    public var output: String
    public var data: [String: String]?
    public var success: Bool
    public var error: String?

    public init(output: String = "", data: [String: String]? = nil, success: Bool = true, error: String? = nil) {
        self.output = output
        self.data = data
        self.success = success
        self.error = error
    }
}

public enum DiffLineType: String, Codable, Sendable {
    case context
    case added
    case removed
}

public struct DiffLine: Equatable, Codable, Sendable {
    public var type: DiffLineType
    public var content: String

    public init(type: DiffLineType, content: String) {
        self.type = type
        self.content = content
    }
}

public struct GitDiffHunk: Equatable, Codable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Equatable, Codable, Sendable {
    public var filePath: String
    public var hunks: [GitDiffHunk]
    public var oldContent: String
    public var newContent: String

    public init(filePath: String, hunks: [GitDiffHunk] = [], oldContent: String = "", newContent: String = "") {
        self.filePath = filePath
        self.hunks = hunks
        self.oldContent = oldContent
        self.newContent = newContent
    }
}

// MARK: - OpenAI Function Calling Types

public struct FunctionDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: FunctionParameters

    public init(name: String, description: String, parameters: FunctionParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct FunctionParameters: Codable, Sendable, Equatable {
    public var type: String = "object"
    public var properties: [String: FunctionProperty]
    public var required: [String]

    public init(type: String = "object", properties: [String: FunctionProperty] = [:], required: [String] = []) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct FunctionProperty: Codable, Sendable, Equatable {
    public var type: String
    public var description: String?
    public var enumValues: [String]?

    public init(type: String, description: String? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
    }
}

/// Tool definition for OpenAI API request
public struct ToolDefinition: Codable, Sendable, Equatable {
    public var type: String = "function"
    public var function: FunctionDefinition

    public init(type: String = "function", function: FunctionDefinition) {
        self.type = type
        self.function = function
    }
}

/// Function call from LLM response
public struct FunctionCallResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var type: String?
    public var function: FunctionCallDetail

    public init(id: String? = nil, type: String? = nil, function: FunctionCallDetail) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct FunctionCallDetail: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let stringArguments = try? container.decode(String.self, forKey: .arguments) {
            arguments = stringArguments
        } else if let objectArguments = try? container.decode(JSONValue.self, forKey: .arguments) {
            let data = try JSONEncoder().encode(objectArguments)
            arguments = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            arguments = "{}"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(arguments, forKey: .arguments)
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Tool result message for sending back to LLM
public struct ToolResultMessage: Codable, Sendable, Equatable {
    public var role: String = "tool"
    public var toolCallId: String
    public var content: String

    public init(toolCallId: String, content: String) {
        self.toolCallId = toolCallId
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case toolCallId = "tool_call_id"
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        content = try container.decode(String.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(content, forKey: .content)
    }
}

// MARK: - Tool Protocol (Updated for Function Calling)

public protocol LaicaiTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// OpenAI function definition for this tool
    var functionDefinition: FunctionDefinition { get }

    /// Execute tool with JSON arguments (from function calling)
    func execute(argumentsJSON: String, context: TaskContext) async throws -> ToolResult

    /// Validate tool result
    func validate(result: ToolResult) -> Bool

    /// Whether this tool requires user review before execution
    var requiresReview: Bool { get }
}

extension LaicaiTool {
    public func validate(result: ToolResult) -> Bool {
        result.success
    }

    public var requiresReview: Bool {
        false
    }

    /// Backward-compatible execute method for [String: String] params
    public func execute(params: [String: String], context: TaskContext) async throws -> ToolResult {
        var dict: [String: Any] = [:]
        for (key, value) in params {
            if let intVal = Int(value) { dict[key] = intVal }
            else if let doubleVal = Double(value) { dict[key] = doubleVal }
            else if value == "true" { dict[key] = true }
            else if value == "false" { dict[key] = false }
            else { dict[key] = value }
        }
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        return try await execute(argumentsJSON: jsonStr, context: context)
    }
}

// MARK: - Intent Router

public enum UserIntent: Sendable, Equatable {
    case chat
    case research   // Information retrieval: needs web search/fetch, not file mutation
    case task
    case workflow(String)
}

// MARK: - Task Phase

public enum TaskPhase: String, Sendable, Equatable, CaseIterable {
    case explore
    case execute
    case verify
    case summarize

    public var title: String {
        switch self {
        case .explore: return "探索"
        case .execute: return "执行"
        case .verify: return "验证"
        case .summarize: return "总结"
        }
    }

    public var icon: String {
        switch self {
        case .explore: return "magnifyingglass"
        case .execute: return "hammer"
        case .verify: return "checkmark.shield"
        case .summarize: return "doc.text"
        }
    }

    /// Tools available at this phase.
    /// All phases get all tools — the model decides which to use based on context.
    /// Restricting tools per phase was causing the agent to be unable to search,
    /// fetch web pages, or run commands when it needed to.
    public var allowedTools: Set<String> {
        return [
            "file.read", "file.write", "file.edit",
            "code.search", "workspace.index",
            "shell.exec", "verify.build",
            "web.search", "web.fetch",
            "wiki.build", "image.generate",
            "git"
        ]
    }
}

// MARK: - Multi-Agent Collaboration

public enum AgentRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case planner
    case coder
    case reviewer
    case researcher
    case tester

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .planner: return "规划员"
        case .coder: return "编码员"
        case .reviewer: return "审查员"
        case .researcher: return "研究员"
        case .tester: return "测试员"
        }
    }

    public var icon: String {
        switch self {
        case .planner: return "brain.head.profile"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .reviewer: return "eye"
        case .researcher: return "magnifyingglass"
        case .tester: return "checkmark.shield"
        }
    }

    public var allowedTools: Set<String> {
        switch self {
        case .planner:
            return ["file.read", "code.search", "workspace.index"]
        case .coder:
            return ["file.read", "code.search", "workspace.index", "file.write", "shell.exec", "git", "image.generate"]
        case .reviewer:
            return ["file.read", "code.search", "git"]
        case .researcher:
            return ["file.read", "code.search", "web.search", "web.fetch", "workspace.index"]
        case .tester:
            return ["file.read", "code.search", "shell.exec", "git"]
        }
    }
}

public struct AgentNode: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var role: AgentRole
    public var status: TaskStatus
    public var input: String
    public var output: String
    public var stepIDs: [UUID]
    public var dependsOn: [UUID]
    public var connectorID: UUID?
    public var errorMessage: String?
    public var retryCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        status: TaskStatus = .queued,
        input: String = "",
        output: String = "",
        stepIDs: [UUID] = [],
        dependsOn: [UUID] = [],
        connectorID: UUID? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.input = input
        self.output = output
        self.stepIDs = stepIDs
        self.dependsOn = dependsOn
        self.connectorID = connectorID
        self.errorMessage = errorMessage
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isReady: Bool {
        status == .queued
    }

    public var isTerminal: Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}

public struct AgentHandoff: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var fromAgentID: UUID
    public var toAgentID: UUID
    public var artifact: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        fromAgentID: UUID,
        toAgentID: UUID,
        artifact: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fromAgentID = fromAgentID
        self.toAgentID = toAgentID
        self.artifact = artifact
        self.createdAt = createdAt
    }
}

public struct MultiAgentPlan: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var agents: [AgentNode]
    public var handoffs: [AgentHandoff]
    public var status: TaskStatus
    public var isEditable: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        agents: [AgentNode] = [],
        handoffs: [AgentHandoff] = [],
        status: TaskStatus = .queued,
        isEditable: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.agents = agents
        self.handoffs = handoffs
        self.status = status
        self.isEditable = isEditable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var currentAgents: [AgentNode] {
        agents.filter { $0.status == .running }
    }

    public var currentAgent: AgentNode? {
        currentAgents.first
    }

    public var completedCount: Int {
        agents.filter { $0.status == .completed }.count
    }

    public var progress: String {
        "\(completedCount)/\(agents.count)"
    }

    public var failedAgents: [AgentNode] {
        agents.filter { $0.status == .failed }
    }

    /// Agents whose dependencies are all completed — ready to run in parallel.
    public func readyAgents(excluding running: Set<UUID> = []) -> [AgentNode] {
        agents.filter { node in
            node.isReady
            && !running.contains(node.id)
            && node.dependsOn.allSatisfy { depID in
                agents.first(where: { $0.id == depID })?.status == .completed
            }
        }
    }

    public mutating func addAgent(_ agent: AgentNode, after: UUID? = nil) {
        if let afterID = after, let idx = agents.firstIndex(where: { $0.id == afterID }) {
            agents.insert(agent, at: idx + 1)
        } else {
            agents.append(agent)
        }
        rebuildHandoffs()
    }

    public mutating func removeAgent(_ agentID: UUID) {
        agents.removeAll { $0.id == agentID }
        for i in agents.indices {
            agents[i].dependsOn.removeAll { $0 == agentID }
        }
        handoffs.removeAll { $0.fromAgentID == agentID || $0.toAgentID == agentID }
    }

    public mutating func moveAgent(from: Int, to: Int) {
        guard agents.indices.contains(from), agents.indices.contains(to), from != to else { return }
        let agent = agents.remove(at: from)
        agents.insert(agent, at: to)
        rebuildLinearDependencies()
        rebuildHandoffs()
    }

    public mutating func rebuildLinearDependencies() {
        for i in agents.indices {
            agents[i].dependsOn = i > 0 ? [agents[i - 1].id] : []
        }
    }

    private mutating func rebuildHandoffs() {
        handoffs = []
        for i in 1..<agents.count {
            let from = agents[i - 1]
            let to = agents[i]
            if to.dependsOn.contains(from.id) {
                handoffs.append(AgentHandoff(fromAgentID: from.id, toAgentID: to.id, artifact: ""))
            }
        }
    }
}

// MARK: - Chat Message Types (for LLM API)

// MARK: - Multimodal Content Parts (Vision support)

public struct ContentPart: Codable, Sendable, Equatable {
    public var type: String  // "text" or "image_url"
    public var text: String?
    public var imageURL: ImageURL?

    public struct ImageURL: Codable, Sendable, Equatable {
        public var url: String
        public var detail: String?

        public init(url: String, detail: String? = "auto") {
            self.url = url
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case url
            case detail
        }
    }

    public static func text(_ text: String) -> ContentPart {
        ContentPart(type: "text", text: text, imageURL: nil)
    }

    public static func imageURL(_ url: String, detail: String? = "auto") -> ContentPart {
        ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: url, detail: detail))
    }

    public static func imageBase64(data: Data, mediaType: String = "image/png", detail: String? = "auto") -> ContentPart {
        let b64 = data.base64EncodedString()
        let dataURI = "data:\(mediaType);base64,\(b64)"
        return .imageURL(dataURI, detail: detail)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String?
    public var contentParts: [ContentPart]?  // Multimodal content (vision)
    public var reasoningContent: String?
    public var toolCalls: [FunctionCallResponse]?
    public var toolCallId: String?

    public init(
        role: String,
        content: String? = nil,
        contentParts: [ContentPart]? = nil,
        reasoningContent: String? = nil,
        toolCalls: [FunctionCallResponse]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.contentParts = contentParts
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Convenience: create a message with both text and images
    public static func userWithImages(text: String, imageURLs: [String]) -> ChatMessage {
        var parts: [ContentPart] = [.text(text)]
        parts.append(contentsOf: imageURLs.map { .imageURL($0) })
        return ChatMessage(role: "user", contentParts: parts)
    }

    /// Returns the effective text content (from content or contentParts)
    public var effectiveContent: String? {
        if let content { return content }
        return contentParts?.compactMap { $0.text }.joined(separator: "\n")
    }

    /// Whether this message contains image content
    public var hasImages: Bool {
        contentParts?.contains(where: { $0.type == "image_url" }) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // Decode content: either a plain string or an array of ContentPart
        if let parts = try? container.decode([ContentPart].self, forKey: .content) {
            contentParts = parts
            content = parts.compactMap { $0.text }.joined(separator: "\n")
        } else {
            content = try container.decodeIfPresent(String.self, forKey: .content)
            contentParts = nil
        }

        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCalls = try container.decodeIfPresent([FunctionCallResponse].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        // Encode content: use array format when multimodal parts are present
        if let parts = contentParts, !parts.isEmpty {
            try container.encode(parts, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }

        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
    }
}

// MARK: - Existing Types (unchanged)

public enum WorkbenchTab: String, Codable, Sendable, CaseIterable, Identifiable {
    case context
    case tools
    case workflows
    case skills
    case agents
    case wiki
    case report
    case logs

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .context:
            return "连接"
        case .tools:
            return "活动"
        case .workflows:
            return "工作流"
        case .skills:
            return "技能"
        case .agents:
            return "Agent"
        case .wiki:
            return "Wiki"
        case .report:
            return "报告"
        case .logs:
            return "诊断"
        }
    }

    public var icon: String {
        switch self {
        case .context: return "plug"
        case .tools: return "wrench.and.screwdriver"
        case .workflows: return "arrow.triangle.branch"
        case .skills: return "bolt.horizontal"
        case .agents: return "person.3"
        case .wiki: return "book.closed"
        case .report: return "chart.bar.doc.horizontal"
        case .logs: return "waveform.path.ecg"
        }
    }
}

public enum ConnectorHealth: String, Codable, Sendable, CaseIterable {
    case ready
    case attention
    case offline

    public var title: String {
        switch self {
        case .ready: return "就绪"
        case .attention: return "模型需确认"
        case .offline: return "离线"
        }
    }
}

public enum ConnectorToolCallingPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case enabled
    case disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "自动"
        case .enabled: return "开启"
        case .disabled: return "关闭"
        }
    }
}

public enum ConnectorToolCallingCapability: String, Codable, Sendable, CaseIterable {
    case supported
    case unsupported

    public var title: String {
        switch self {
        case .supported: return "已验证支持"
        case .unsupported: return "已验证不兼容"
        }
    }
}

public enum ConnectorToolCallingCapabilityObservationSource: String, Codable, Sendable, CaseIterable {
    case connectorProbe
    case taskRun

    public var title: String {
        switch self {
        case .connectorProbe: return "连接测试"
        case .taskRun: return "任务运行"
        }
    }
}

public struct ConnectorProfile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: String
    public var endpoint: String
    public var modelName: String
    public var note: String
    public var toolCallingPolicy: ConnectorToolCallingPolicy?
    public var toolCallingCapability: ConnectorToolCallingCapability?
    public var toolCallingCapabilitySource: ConnectorToolCallingCapabilityObservationSource?
    public var toolCallingCapabilityLearnedAt: Date?
    public var health: ConnectorHealth
    public var lastCheckedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: String,
        endpoint: String,
        modelName: String,
        note: String,
        toolCallingPolicy: ConnectorToolCallingPolicy? = nil,
        toolCallingCapability: ConnectorToolCallingCapability? = nil,
        toolCallingCapabilitySource: ConnectorToolCallingCapabilityObservationSource? = nil,
        toolCallingCapabilityLearnedAt: Date? = nil,
        health: ConnectorHealth,
        lastCheckedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.modelName = modelName
        self.note = note
        self.toolCallingPolicy = toolCallingPolicy
        self.toolCallingCapability = toolCallingCapability
        self.toolCallingCapabilitySource = toolCallingCapabilitySource
        self.toolCallingCapabilityLearnedAt = toolCallingCapabilityLearnedAt
        self.health = health
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct ToolActivity: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var statusLine: String
    public var timestamp: Date
    public var isFailure: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        statusLine: String,
        timestamp: Date = .now,
        isFailure: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.statusLine = statusLine
        self.timestamp = timestamp
        self.isFailure = isFailure
    }
}

public struct WorkflowRun: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var goal: String
    public var statusLine: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        goal: String,
        statusLine: String,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.statusLine = statusLine
        self.updatedAt = updatedAt
    }
}

public enum ContextMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case economy
    case balanced
    case deep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .economy: return "轻量"
        case .balanced: return "平衡"
        case .deep: return "深度"
        }
    }

    public var detail: String {
        switch self {
        case .economy: return "更少文件、更短结果，适合轻量问答"
        case .balanced: return "默认预算，适合日常迭代"
        case .deep: return "更多上下文和迭代，适合复杂任务"
        }
    }

    public var maxIterations: Int {
        switch self {
        case .economy: return 8
        case .balanced: return 20
        case .deep: return 40
        }
    }

    public var maxTokensPerTurn: Int {
        switch self {
        case .economy: return 8192
        case .balanced: return 32768
        case .deep: return 65536
        }
    }

    public var relevantFileLimit: Int {
        switch self {
        case .economy: return 40
        case .balanced: return 150
        case .deep: return 300
        }
    }

    public var tokenBudget: Int {
        switch self {
        case .economy: return 64_000
        case .balanced: return 256_000
        case .deep: return 512_000
        }
    }
}

public struct AppSettings: Equatable, Codable, Sendable {
    public var workspacePath: String
    public var vaultPath: String
    public var defaultConnectorName: String
    public var compactComposer: Bool
    public var showDebugPanels: Bool
    public var contextMode: ContextMode
    public var comfyUIServerURL: String
    public var comfyUIModelName: String
    // G16: Multi-workspace support — recent workspace paths for quick switching
    public var recentWorkspaces: [String]

    public init(
        workspacePath: String,
        vaultPath: String = "",
        defaultConnectorName: String,
        compactComposer: Bool,
        showDebugPanels: Bool,
        contextMode: ContextMode = .balanced,
        comfyUIServerURL: String = "http://127.0.0.1:8188",
        comfyUIModelName: String = "",
        recentWorkspaces: [String] = []
    ) {
        self.workspacePath = workspacePath
        self.vaultPath = vaultPath
        self.defaultConnectorName = defaultConnectorName
        self.compactComposer = compactComposer
        self.showDebugPanels = showDebugPanels
        self.contextMode = contextMode
        self.comfyUIServerURL = comfyUIServerURL
        self.comfyUIModelName = comfyUIModelName
        self.recentWorkspaces = recentWorkspaces
    }

    private enum CodingKeys: String, CodingKey {
        case workspacePath
        case vaultPath
        case defaultConnectorName
        case compactComposer
        case showDebugPanels
        case contextMode
        case comfyUIServerURL
        case comfyUIModelName
        case recentWorkspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspacePath = try container.decode(String.self, forKey: .workspacePath)
        vaultPath = try container.decodeIfPresent(String.self, forKey: .vaultPath) ?? ""
        defaultConnectorName = try container.decode(String.self, forKey: .defaultConnectorName)
        compactComposer = try container.decodeIfPresent(Bool.self, forKey: .compactComposer) ?? false
        showDebugPanels = try container.decodeIfPresent(Bool.self, forKey: .showDebugPanels) ?? false
        contextMode = try container.decodeIfPresent(ContextMode.self, forKey: .contextMode) ?? .balanced
        comfyUIServerURL = try container.decodeIfPresent(String.self, forKey: .comfyUIServerURL) ?? "http://127.0.0.1:8188"
        comfyUIModelName = try container.decodeIfPresent(String.self, forKey: .comfyUIModelName) ?? ""
        recentWorkspaces = try container.decodeIfPresent([String].self, forKey: .recentWorkspaces) ?? []
    }

    // G16: Switch active workspace and track in recents
    public mutating func switchWorkspace(to path: String) {
        let old = workspacePath
        workspacePath = path
        if !old.isEmpty && !recentWorkspaces.contains(old) {
            recentWorkspaces.insert(old, at: 0)
        }
        recentWorkspaces.removeAll { $0 == path }
        if recentWorkspaces.count > 10 {
            recentWorkspaces = Array(recentWorkspaces.prefix(10))
        }
    }
}
