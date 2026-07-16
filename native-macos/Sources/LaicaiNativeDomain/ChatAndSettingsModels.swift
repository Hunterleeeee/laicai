import Foundation

// MARK: - Chat Message Types (for LLM API)

// MARK: - Multimodal Content Parts (Vision support)

public struct ContentPartImageURL: Codable, Sendable, Equatable {
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

public struct ContentPart: Codable, Sendable, Equatable {
    public typealias ImageURL = ContentPartImageURL

    public var type: String  // "text" or "image_url"
    public var text: String?
    public var imageURL: ImageURL?

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
    case schedules
    case agents
    case wiki
    case report
    case stats
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
        case .schedules:
            return "定时"
        case .agents:
            return "会话"
        case .wiki:
            return "Wiki"
        case .report:
            return "报告"
        case .stats:
            return "统计"
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
        case .schedules: return "alarm"
        case .agents: return "person.3"
        case .wiki: return "book.closed"
        case .report: return "chart.bar.doc.horizontal"
        case .stats: return "chart.bar.xaxis"
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

public enum ConnectorToolCallObservationSource: String, Codable, Sendable, CaseIterable {
    case connectorProbe
    case taskRun

    public var title: String {
        switch self {
        case .connectorProbe: return "连接测试"
        case .taskRun: return "任务运行"
        }
    }
}

/// Routing role for a connector — determines which task phases it is best suited for.
/// nil means "general" (can handle anything, used as fallback).
public enum ConnectorRole: String, Codable, Sendable, CaseIterable {
    case fast  // Quick responses: explore, chat, search
    case code  // Code generation: execute, edit, refactor
    case strong  // Complex reasoning: verify, review, plan

    public var title: String {
        switch self {
        case .fast: return "快速"
        case .code: return "代码"
        case .strong: return "强力"
        }
    }

    public var icon: String {
        switch self {
        case .fast: return "bolt"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .strong: return "brain"
        }
    }

    /// Which task phases this role is best at.
    public var preferredPhases: Set<TaskPhase> {
        switch self {
        case .fast: return [.explore, .summarize]
        case .code: return [.execute]
        case .strong: return [.verify]
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
    public var role: ConnectorRole?
    public var toolCallingPolicy: ConnectorToolCallingPolicy?
    public var toolCallingCapability: ConnectorToolCallingCapability?
    public var toolCallingCapabilitySource: ConnectorToolCallObservationSource?
    public var toolCallingCapabilityLearnedAt: Date?
    public var probedContextWindow: Int?
    public var health: ConnectorHealth
    public var lastCheckedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: String,
        endpoint: String,
        modelName: String,
        note: String,
        role: ConnectorRole? = nil,
        toolCallingPolicy: ConnectorToolCallingPolicy? = nil,
        toolCallingCapability: ConnectorToolCallingCapability? = nil,
        toolCallingCapabilitySource: ConnectorToolCallObservationSource? = nil,
        toolCallingCapabilityLearnedAt: Date? = nil,
        probedContextWindow: Int? = nil,
        health: ConnectorHealth,
        lastCheckedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.modelName = modelName
        self.note = note
        self.role = role
        self.toolCallingPolicy = toolCallingPolicy
        self.toolCallingCapability = toolCallingCapability
        self.toolCallingCapabilitySource = toolCallingCapabilitySource
        self.toolCallingCapabilityLearnedAt = toolCallingCapabilityLearnedAt
        self.probedContextWindow = probedContextWindow
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
        case .deep: return "更多上下文和迭代，适合复杂 Agent"
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
        defaultConnectorName: String = "None",
        compactComposer: Bool = false,
        showDebugPanels: Bool = false,
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
        case kernelMode
        case usePipeline
        case leanMode
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
        // kernelMode is ignored — codexFull is the only runtime path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encode(vaultPath, forKey: .vaultPath)
        try container.encode(defaultConnectorName, forKey: .defaultConnectorName)
        try container.encode(compactComposer, forKey: .compactComposer)
        try container.encode(showDebugPanels, forKey: .showDebugPanels)
        try container.encode(contextMode, forKey: .contextMode)
        try container.encode(comfyUIServerURL, forKey: .comfyUIServerURL)
        try container.encode(comfyUIModelName, forKey: .comfyUIModelName)
        try container.encode(recentWorkspaces, forKey: .recentWorkspaces)
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
