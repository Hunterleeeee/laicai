import Foundation
import LaicaiNativeDomain

public typealias Thread = LaicaiThread

// MARK: - Request / Response

public struct SendMessageRequest: Sendable, Equatable {
    public var sessionID: UUID
    public var message: String
    public var connector: ConnectorProfile?
    public var modeLabel: String
    public var history: [TaskStep]
    /// Override system prompt (from PromptComposer)
    public var systemPrompt: String?
    /// Tool definitions for function calling
    public var tools: [ToolDefinition]?
    /// Conversation messages (for function calling multi-turn)
    public var messages: [ChatMessage]?
    /// Optional provider output cap for this request.
    public var maxOutputTokens: Int?
    /// Image attachments for vision (multimodal)
    public var imageAttachments: [ImageAttachment]

    public init(
        sessionID: UUID,
        message: String,
        connector: ConnectorProfile?,
        modeLabel: String,
        history: [TaskStep] = [],
        systemPrompt: String? = nil,
        tools: [ToolDefinition]? = nil,
        messages: [ChatMessage]? = nil,
        maxOutputTokens: Int? = nil,
        imageAttachments: [ImageAttachment] = []
    ) {
        self.sessionID = sessionID
        self.message = message
        self.connector = connector
        self.modeLabel = modeLabel
        self.history = history
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.imageAttachments = imageAttachments
    }
}

public struct SendMessageResponse: Sendable, Equatable {
    public var assistantText: String
    public var reasoningContent: String?
    public var toolCalls: [FunctionCallResponse]
    public var finishReason: String?
    public var toolActivities: [ToolActivity]
    public var workflowRun: WorkflowRun?
    public var metrics: ResponseMetrics?

    public init(
        assistantText: String,
        reasoningContent: String? = nil,
        toolCalls: [FunctionCallResponse] = [],
        finishReason: String? = nil,
        toolActivities: [ToolActivity] = [],
        workflowRun: WorkflowRun? = nil,
        metrics: ResponseMetrics? = nil
    ) {
        self.assistantText = assistantText
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.toolActivities = toolActivities
        self.workflowRun = workflowRun
        self.metrics = metrics
    }

    /// Whether LLM wants to call tools (vs just returning text)
    public var hasToolCalls: Bool {
        !toolCalls.isEmpty
    }
}

// MARK: - Chat Runtime Client

public struct ConnectorProbeResult: Sendable, Equatable {
    public var health: ConnectorHealth
    public var toolCallingCapability: ConnectorToolCallingCapability?

    public init(
        health: ConnectorHealth,
        toolCallingCapability: ConnectorToolCallingCapability? = nil
    ) {
        self.health = health
        self.toolCallingCapability = toolCallingCapability
    }
}

public protocol ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse
    func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse
    func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void, onReasoningChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse
    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth
    func probeConnector(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool) async throws -> ConnectorProbeResult
}

extension ChatRuntimeClient {
    public func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        return try await sendMessage(request)
    }

    public func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void, onReasoningChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        return try await sendMessageStream(request, onChunk: onChunk)
    }

    public func healthCheck(endpoint: String, model: String, apiKey: String, kind: String = "openai-compatible") async throws -> ConnectorHealth {
        .offline
    }

    public func probeConnector(
        endpoint: String,
        model: String,
        apiKey: String,
        kind: String = "openai-compatible",
        probeToolCalling: Bool = true
    ) async throws -> ConnectorProbeResult {
        ConnectorProbeResult(
            health: try await healthCheck(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind),
            toolCallingCapability: nil
        )
    }
}

// MARK: - Repositories

public protocol SessionRepository {
    func loadSessions() throws -> [ChatSession]?
    func saveSessions(_ sessions: [ChatSession]) throws
}

public protocol ConnectorRepository {
    func loadConnectorCatalog() throws -> ConnectorCatalog?
    func saveConnectors(_ connectors: [ConnectorProfile], activeConnectorID: UUID?) throws
}

public protocol TaskRepository {
    func loadTasks() throws -> [AgentTask]?
    func saveTasks(_ tasks: [AgentTask]) throws
    func appendTask(_ task: AgentTask) throws
    func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws
    func deleteTask(id: UUID) throws
}

public protocol ThreadRepository {
    func loadThreads() throws -> [LaicaiThread]?
    func saveThreads(_ threads: [LaicaiThread]) throws
}

public protocol AgentRepository {
    func loadAgents() throws -> [LaicaiThread]?
    func saveAgents(_ agents: [LaicaiThread]) throws
}

// MARK: - App Environment

public struct AppEnvironment {
    public var runtimeClient: any ChatRuntimeClient
    public var sessionRepository: any SessionRepository
    public var connectorRepository: any ConnectorRepository
    public var taskRepository: any TaskRepository
    public var threadRepository: any ThreadRepository
    public var agentRepository: any AgentRepository

    public init(
        runtimeClient: any ChatRuntimeClient,
        sessionRepository: any SessionRepository,
        connectorRepository: any ConnectorRepository,
        taskRepository: any TaskRepository,
        threadRepository: any ThreadRepository,
        agentRepository: (any AgentRepository)? = nil
    ) {
        self.runtimeClient = runtimeClient
        self.sessionRepository = sessionRepository
        self.connectorRepository = connectorRepository
        self.taskRepository = taskRepository
        self.threadRepository = threadRepository
        self.agentRepository = agentRepository ?? ThreadRepositoryAgentAdapter(threadRepository)
    }

    public static var preview: AppEnvironment {
        AppEnvironment(
            runtimeClient: PreviewChatRuntime(),
            sessionRepository: NoopSessionRepository(),
            connectorRepository: NoopConnectorRepository(),
            taskRepository: NoopTaskRepository(),
            threadRepository: NoopThreadRepository(),
            agentRepository: NoopAgentRepository()
        )
    }

    public static var live: AppEnvironment {
        let sqlite = SQLiteRepository()
        return AppEnvironment(
            runtimeClient: LiveChatRuntime(),
            sessionRepository: sqlite,
            connectorRepository: sqlite,
            taskRepository: sqlite,
            threadRepository: sqlite,
            agentRepository: sqlite
        )
    }
}

// MARK: - Preview / Noop Implementations

public struct PreviewChatRuntime: ChatRuntimeClient {
    public init() {}

    public func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        try await Task.sleep(for: .milliseconds(600))
        let connectorName = request.connector?.name ?? "无模型"
        let toolActivities = [
            ToolActivity(
                name: "model.missing",
                summary: "\(connectorName) 尚未连接",
                statusLine: "请先在设置中选择模型",
                isFailure: true
            )
        ]

        return SendMessageResponse(
            assistantText: "未连接模型。请先在设置中添加或选择一个模型。",
            toolActivities: toolActivities,
            workflowRun: nil
        )
    }
}

public struct NoopSessionRepository: SessionRepository {
    public init() {}

    public func loadSessions() throws -> [ChatSession]? {
        nil
    }

    public func saveSessions(_ sessions: [ChatSession]) throws {}
}

public struct NoopConnectorRepository: ConnectorRepository {
    public init() {}

    public func loadConnectorCatalog() throws -> ConnectorCatalog? {
        nil
    }

    public func saveConnectors(_ connectors: [ConnectorProfile], activeConnectorID: UUID?) throws {}
}

public struct NoopTaskRepository: TaskRepository {
    public init() {}

    public func loadTasks() throws -> [AgentTask]? {
        nil
    }

    public func saveTasks(_ tasks: [AgentTask]) throws {}

    public func appendTask(_ task: AgentTask) throws {}

    public func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws {}

    public func deleteTask(id: UUID) throws {}
}

public struct NoopThreadRepository: ThreadRepository {
    public init() {}

    public func loadThreads() throws -> [Thread]? {
        nil
    }

    public func saveThreads(_ threads: [Thread]) throws {}
}

public struct NoopAgentRepository: AgentRepository {
    public init() {}

    public func loadAgents() throws -> [Thread]? {
        nil
    }

    public func saveAgents(_ agents: [Thread]) throws {}
}

public struct ThreadRepositoryAgentAdapter: AgentRepository {
    private let repository: any ThreadRepository

    public init(_ repository: any ThreadRepository) {
        self.repository = repository
    }

    public func loadAgents() throws -> [Thread]? {
        try repository.loadThreads()
    }

    public func saveAgents(_ agents: [Thread]) throws {
        try repository.saveThreads(agents)
    }
}

// MARK: - ConnectorCatalog (legacy)

public struct ConnectorCatalog: Codable, Sendable, Equatable {
    public var connectors: [ConnectorProfile]
    public var activeConnectorID: UUID?

    public init(connectors: [ConnectorProfile] = [], activeConnectorID: UUID? = nil) {
        self.connectors = connectors
        self.activeConnectorID = activeConnectorID
    }
}
