import Foundation

// MARK: - Unified Thread Model

public enum AgentMode: String, Codable, Sendable {
    case ask
    case act
    case research
    case workflow
    case image
    case multiAgent

    public var title: String {
        switch self {
        case .ask: return "Agent 问答"
        case .act: return "Agent 执行"
        case .research: return "Agent 研究"
        case .workflow: return "Agent 工作流"
        case .image: return "Agent 图片"
        case .multiAgent: return "多 Agent 协同"
        }
    }
}

public enum AgentThreadState: String, Codable, Sendable {
    case idle
    case planning
    case running
    case waitingForApproval
    case blocked
    case paused
    case failed
    case completed
    case archived

    public var title: String {
        switch self {
        case .idle: return "空闲"
        case .planning: return "规划中"
        case .running: return "运行中"
        case .waitingForApproval: return "待确认"
        case .blocked: return "阻塞"
        case .paused: return "已暂停"
        case .failed: return "失败"
        case .completed: return "已完成"
        case .archived: return "已归档"
        }
    }
}

public struct AgentArtifact: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var path: String
    public var kind: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        path: String,
        kind: String = "file",
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.kind = kind
        self.createdAt = createdAt
    }
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
public typealias LaicaiThread = Thread

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
    public var projectID: UUID?  // Codex-style: bind thread to a project
    public var executionState: AgentThreadState
    public var goal: String?
    public var currentPlan: [String]
    public var artifacts: [AgentArtifact]
    public var taskProtocol: AgentTaskProtocol?
    public var executionLedger: AgentExecutionLedger?

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
        projectID: UUID? = nil,
        executionState: AgentThreadState? = nil,
        goal: String? = nil,
        currentPlan: [String] = [],
        artifacts: [AgentArtifact] = [],
        taskProtocol: AgentTaskProtocol? = nil,
        executionLedger: AgentExecutionLedger? = nil
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
        self.projectID = projectID
        self.executionState = executionState ?? Self.inferAgentState(status: status)
        self.goal = goal
        self.currentPlan = currentPlan
        self.artifacts = artifacts
        self.taskProtocol = taskProtocol
        self.executionLedger = executionLedger
    }

    // Custom Codable: tolerate missing fields added after initial schema
    private enum CodingKeys: String, CodingKey {
        case id, title, preview, status, steps, connectorID, workflowName, context
        case modelName, category, isPinned, isArchived, unreadCount, summaryCache
        case multiAgentPlan, userRating, createdAt, updatedAt, projectID
        case executionState = "agentState"
        case goal = "agentGoal"
        case currentPlan, artifacts
        case taskProtocol, executionLedger
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "新会话"
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .completed
        steps = try container.decodeIfPresent([TaskStep].self, forKey: .steps) ?? []
        connectorID = try container.decodeIfPresent(UUID.self, forKey: .connectorID)
        workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        context = try container.decodeIfPresent(TaskContext.self, forKey: .context) ?? TaskContext()
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        category = try container.decodeIfPresent(SessionCategory.self, forKey: .category) ?? .engineering
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        summaryCache = try container.decodeIfPresent(String.self, forKey: .summaryCache)
        multiAgentPlan = try container.decodeIfPresent(MultiAgentPlan.self, forKey: .multiAgentPlan)
        userRating = try container.decodeIfPresent(Int.self, forKey: .userRating) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        executionState =
            try container.decodeIfPresent(AgentThreadState.self, forKey: .executionState)
            ?? Self.inferAgentState(status: status)
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        currentPlan = try container.decodeIfPresent([String].self, forKey: .currentPlan) ?? []
        artifacts = try container.decodeIfPresent([AgentArtifact].self, forKey: .artifacts) ?? []
        taskProtocol = try container.decodeIfPresent(AgentTaskProtocol.self, forKey: .taskProtocol)
        executionLedger = try container.decodeIfPresent(AgentExecutionLedger.self, forKey: .executionLedger)
    }

    /// Short human-readable ID (first 6 hex chars of UUID, uppercased)
    public var shortID: String {
        String(id.uuidString.prefix(6))
    }

    public static func inferAgentState(status: TaskStatus) -> AgentThreadState {
        switch status {
        case .queued:
            return .idle
        case .running:
            return .running
        case .waitingReview:
            return .waitingForApproval
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .paused
        }
    }

    public static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "新线程" || trimmed == "新会话" || trimmed == "新对话"
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
        projectID = nil
        executionState = .idle
        goal = nil
        currentPlan = []
        artifacts = []
        taskProtocol = nil
        executionLedger = nil
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
        projectID = nil
        executionState = Self.inferAgentState(status: task.status)
        goal = task.steps.first(where: { $0.kind == .userInput })?.text
        currentPlan = []
        artifacts = []
        taskProtocol = task.taskProtocol
        executionLedger = task.executionLedger
    }

    public var isEmptyPlaceholder: Bool {
        steps.isEmpty
            && preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && status == .queued
    }

    public var agentMode: AgentMode {
        if multiAgentPlan != nil { return .multiAgent }
        if workflowName != nil { return .workflow }
        if steps.contains(where: { $0.toolName == "image.generate" }) { return .image }
        if taskProtocol != nil || executionLedger != nil { return .act }
        if steps.contains(where: { step in
            step.kind == .toolCall
                || step.kind == .toolResult
                || step.kind == .reviewRequest
                || step.kind == .reviewResult
        }) {
            return .act
        }
        if context.metadata["intent"] == "research" { return .research }
        return .ask
    }

    public var isChatOnly: Bool {
        agentMode == .ask
    }

    public var isExecution: Bool {
        agentMode != .ask
    }

    public var canContinue: Bool {
        isExecution
            || status == .failed
            || status == .cancelled
            || status == .waitingReview
            || steps.contains { $0.kind == .toolCall || $0.kind == .toolResult || $0.kind == .reviewRequest }
    }

    public var events: [ThreadEvent] {
        ThreadRecord(thread: self, includeEvents: true).events
    }
}

public struct ThreadRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var preview: String
    public var status: TaskStatus?
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var hasContent: Bool
    public var events: [ThreadEvent]
    public var projectID: UUID?
    public var executionState: AgentThreadState?
    public var taskProtocol: AgentTaskProtocol?
    public var executionLedger: AgentExecutionLedger?

    public var shortID: String { String(id.uuidString.prefix(6)) }

    public var resolvedAgentState: AgentThreadState {
        if let executionState { return executionState }
        if let status { return Thread.inferAgentState(status: status) }
        return .idle
    }

    public init(
        id: UUID,
        title: String,
        preview: String,
        status: TaskStatus?,
        updatedAt: Date,
        isPinned: Bool,
        isArchived: Bool,
        hasContent: Bool,
        events: [ThreadEvent],
        projectID: UUID? = nil,
        executionState: AgentThreadState? = nil,
        taskProtocol: AgentTaskProtocol? = nil,
        executionLedger: AgentExecutionLedger? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.status = status
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.hasContent = hasContent
        self.events = events
        self.projectID = projectID
        self.executionState = executionState
        self.taskProtocol = taskProtocol
        self.executionLedger = executionLedger
    }

    public init(thread: Thread, includeEvents: Bool = true) {
        id = thread.id
        title = thread.title
        preview = thread.preview
        status = thread.status
        updatedAt = thread.updatedAt
        isPinned = thread.isPinned
        projectID = thread.projectID
        executionState = thread.executionState
        taskProtocol = includeEvents ? thread.taskProtocol : nil
        executionLedger = includeEvents ? thread.executionLedger : nil
        isArchived = thread.isArchived
        hasContent = !thread.steps.isEmpty
        events =
            includeEvents
            ? thread.steps.map { step in
                ThreadEvent(
                    id: step.id,
                    kind: Self.eventKind(for: step.kind, isFailure: step.isFailure),
                    text: step.text,
                    createdAt: step.createdAt,
                    sourceStepID: step.id,
                    metrics: step.metrics
                )
            } : []
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

public struct AgentRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var preview: String
    public var mode: AgentMode
    public var state: AgentThreadState
    public var goal: String?
    public var plan: [String]
    public var artifacts: [AgentArtifact]
    public var updatedAt: Date
    public var isPinned: Bool
    public var isArchived: Bool
    public var hasContent: Bool
    public var events: [ThreadEvent]
    public var projectID: UUID?
    public var taskProtocol: AgentTaskProtocol?
    public var executionLedger: AgentExecutionLedger?

    public var shortID: String { String(id.uuidString.prefix(6)) }

    public init(thread: Thread, includeEvents: Bool = true) {
        id = thread.id
        title = thread.title
        preview = thread.preview
        mode = thread.agentMode
        state = thread.executionState
        goal = thread.goal
        plan = thread.currentPlan
        artifacts = thread.artifacts
        updatedAt = thread.updatedAt
        isPinned = thread.isPinned
        isArchived = thread.isArchived
        hasContent = !thread.steps.isEmpty
        projectID = thread.projectID
        taskProtocol = includeEvents ? thread.taskProtocol : nil
        executionLedger = includeEvents ? thread.executionLedger : nil
        events =
            includeEvents
            ? thread.steps.map { step in
                ThreadEvent(
                    id: step.id,
                    kind: Self.eventKind(for: step.kind, isFailure: step.isFailure),
                    text: step.text,
                    createdAt: step.createdAt,
                    sourceStepID: step.id,
                    metrics: step.metrics
                )
            } : []
    }

    public var threadRecord: ThreadRecord {
        ThreadRecord(
            id: id,
            title: title,
            preview: preview,
            status: statusForState(state),
            updatedAt: updatedAt,
            isPinned: isPinned,
            isArchived: isArchived,
            hasContent: hasContent,
            events: events,
            projectID: projectID,
            executionState: state,
            taskProtocol: taskProtocol,
            executionLedger: executionLedger
        )
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

    private func statusForState(_ state: AgentThreadState) -> TaskStatus {
        switch state {
        case .idle, .planning:
            return .queued
        case .running:
            return .running
        case .waitingForApproval, .blocked:
            return .waitingReview
        case .paused, .archived:
            return .cancelled
        case .failed:
            return .failed
        case .completed:
            return .completed
        }
    }
}
