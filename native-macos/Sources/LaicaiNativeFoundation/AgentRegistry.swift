import Foundation
import LaicaiNativeDomain

public struct CustomAgentDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var role: AgentRole
    public var systemPrompt: String
    public var tools: [String]
    public var preferredConnectorID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        role: AgentRole,
        systemPrompt: String,
        tools: [String] = [],
        preferredConnectorID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.preferredConnectorID = preferredConnectorID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func makeNode(connectorID: UUID? = nil) -> AgentNode {
        AgentNode(
            role: role,
            input: systemPrompt,
            connectorID: connectorID ?? preferredConnectorID
        )
    }
}

@MainActor
public final class AgentRegistry: ObservableObject {
    public static let shared = AgentRegistry()

    @Published public private(set) var agents: [CustomAgentDefinition] = []

    private init() {}

    public func refresh(workspaceRoot: String) {
        agents = Self.loadLocalAgents(workspaceRoot: workspaceRoot)
    }

    @discardableResult
    public func create(
        name: String,
        role: AgentRole,
        systemPrompt: String,
        tools: [String],
        preferredConnectorID: UUID?,
        workspaceRoot: String
    ) throws -> CustomAgentDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var agent = CustomAgentDefinition(
            name: trimmedName.isEmpty ? role.title : trimmedName,
            role: role,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            tools: tools,
            preferredConnectorID: preferredConnectorID
        )
        if agent.systemPrompt.isEmpty {
            agent.systemPrompt = "你是\(agent.name)，角色是\(role.title)。请按该角色推进当前会话目标。"
        }
        try save(agent, workspaceRoot: workspaceRoot)
        agents.append(agent)
        agents.sort { $0.updatedAt > $1.updatedAt }
        return agent
    }

    public func update(_ agent: CustomAgentDefinition, workspaceRoot: String) throws {
        var next = agent
        next.updatedAt = .now
        try save(next, workspaceRoot: workspaceRoot)
        if let idx = agents.firstIndex(where: { $0.id == next.id }) {
            agents[idx] = next
        } else {
            agents.append(next)
        }
        agents.sort { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ agent: CustomAgentDefinition, workspaceRoot: String) {
        let url = Self.fileURL(for: agent, workspaceRoot: workspaceRoot)
        try? FileManager.default.removeItem(at: url)
        agents.removeAll { $0.id == agent.id }
    }

    private func save(_ agent: CustomAgentDefinition, workspaceRoot: String) throws {
        let dir = Self.agentsDirectory(workspaceRoot: workspaceRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(agent)
        try data.write(to: Self.fileURL(for: agent, workspaceRoot: workspaceRoot), options: Data.WritingOptions.atomic)
    }

    public static func loadLocalAgents(workspaceRoot: String) -> [CustomAgentDefinition] {
        let dir = agentsDirectory(workspaceRoot: workspaceRoot)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> CustomAgentDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CustomAgentDefinition.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func agentsDirectory(workspaceRoot: String) -> URL {
        URL(fileURLWithPath: (workspaceRoot as NSString).appendingPathComponent(".laicai/agents"))
    }

    private static func fileURL(for agent: CustomAgentDefinition, workspaceRoot: String) -> URL {
        agentsDirectory(workspaceRoot: workspaceRoot).appendingPathComponent("\(slug(agent.name)).json")
    }

    private static func slug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fa5}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? UUID().uuidString : slug
    }
}
