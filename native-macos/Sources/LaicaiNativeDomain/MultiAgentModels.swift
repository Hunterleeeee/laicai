import Foundation

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
            return [
                "file.read", "file.extract", "document.transform", "code.search", "workspace.index", "shell.exec", "skill.manage", "git",
            ]
        case .coder:
            return [
                "file.read", "file.extract", "document.transform", "code.search", "workspace.index",
                "file.write", "file.edit", "diff.apply",
                "shell.exec", "verify.build", "skill.manage", "git", "image.generate",
                "browser", "browser.real", "computer",
            ]
        case .reviewer:
            return [
                "file.read", "file.extract", "document.transform", "code.search", "workspace.index", "shell.exec", "verify.build", "git",
                "browser",
                "browser.real", "computer",
            ]
        case .researcher:
            return [
                "file.read", "file.extract", "document.transform", "code.search", "web.search", "web.fetch", "workspace.index", "browser",
            ]
        case .tester:
            return [
                "file.read", "file.extract", "document.transform", "code.search", "workspace.index", "shell.exec", "verify.build",
                "skill.manage", "git",
                "browser", "browser.real", "computer",
            ]
        }
    }

    public var outputContract: String {
        switch self {
        case .planner:
            return "输出 artifact: 任务分解、完成标准、风险、建议读取/修改文件；不得写入项目文件。"
        case .researcher:
            return "输出 artifact: 已读取来源、代码位置、关键事实和引用依据；不得写入项目文件。"
        case .coder:
            return "输出 artifact: 实际修改文件、变更摘要、验证记录或验证阻塞；Coder 是唯一允许写入项目文件的角色。"
        case .tester:
            return "输出 artifact: 运行命令、完整结果摘要、失败文件/关键错误、是否通过；不得写入项目文件。"
        case .reviewer:
            return "输出 artifact: 基于 diff/文件内容/验收标准的审查结论、严重问题和残余风险；不得写入项目文件。"
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
        for index in agents.indices {
            agents[index].dependsOn.removeAll { $0 == agentID }
        }
        handoffs.removeAll { $0.fromAgentID == agentID || $0.toAgentID == agentID }
    }

    public mutating func moveAgent(from sourceIndex: Int, to targetIndex: Int) {
        guard agents.indices.contains(sourceIndex), agents.indices.contains(targetIndex), sourceIndex != targetIndex else { return }
        let agent = agents.remove(at: sourceIndex)
        agents.insert(agent, at: targetIndex)
        rebuildLinearDependencies()
        rebuildHandoffs()
    }

    public mutating func rebuildLinearDependencies() {
        for index in agents.indices {
            agents[index].dependsOn = index > 0 ? [agents[index - 1].id] : []
        }
    }

    private mutating func rebuildHandoffs() {
        handoffs = []
        for index in 1..<agents.count {
            let fromAgent = agents[index - 1]
            let toAgent = agents[index]
            if toAgent.dependsOn.contains(fromAgent.id) {
                handoffs.append(AgentHandoff(fromAgentID: fromAgent.id, toAgentID: toAgent.id, artifact: ""))
            }
        }
    }
}
