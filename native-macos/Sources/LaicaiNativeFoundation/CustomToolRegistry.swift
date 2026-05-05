import Foundation

// MARK: - Custom Tool Definition

public struct CustomToolDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String
    public var parameters: [CustomToolParam]
    public var executionMode: ExecutionMode
    public var createdAt: Date
    public var updatedAt: Date

    public struct CustomToolParam: Equatable, Codable, Sendable {
        public var name: String
        public var type: String  // "string", "integer", "boolean"
        public var description: String
        public var required: Bool

        public init(name: String, type: String = "string", description: String = "", required: Bool = true) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
        }
    }

    public enum ExecutionMode: Equatable, Codable, Sendable {
        case shell(template: String)      // e.g. "curl -s {{url}}"
        case http(method: String, urlTemplate: String, headers: [String: String], bodyTemplate: String)
        case script(path: String, interpreter: String)  // e.g. path: "./tools/my_tool.py", interpreter: "python3"

        var displayName: String {
            switch self {
            case .shell: return "Shell 命令"
            case .http: return "HTTP 请求"
            case .script: return "脚本文件"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        parameters: [CustomToolParam] = [],
        executionMode: ExecutionMode = .shell(template: ""),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.executionMode = executionMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var qualifiedName: String { "custom.\(slug)" }

    private var slug: String {
        name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

// MARK: - Custom Tool Registry

@MainActor
public final class CustomToolRegistry: ObservableObject {
    public static let shared = CustomToolRegistry()

    @Published public private(set) var tools: [CustomToolDefinition] = []

    private init() {}

    public func refresh(workspaceRoot: String) {
        tools = Self.loadLocalTools(workspaceRoot: workspaceRoot)
    }

    @discardableResult
    public func create(_ tool: CustomToolDefinition, workspaceRoot: String) throws -> CustomToolDefinition {
        var t = tool
        t.updatedAt = .now
        try save(t, workspaceRoot: workspaceRoot)
        tools.append(t)
        tools.sort { $0.name < $1.name }
        return t
    }

    public func update(_ tool: CustomToolDefinition, workspaceRoot: String) throws {
        var t = tool
        t.updatedAt = .now
        try save(t, workspaceRoot: workspaceRoot)
        if let idx = tools.firstIndex(where: { $0.id == t.id }) {
            tools[idx] = t
        } else {
            tools.append(t)
        }
        tools.sort { $0.name < $1.name }
    }

    public func delete(_ tool: CustomToolDefinition, workspaceRoot: String) {
        let url = Self.fileURL(for: tool, workspaceRoot: workspaceRoot)
        try? FileManager.default.removeItem(at: url)
        tools.removeAll { $0.id == tool.id }
    }

    // MARK: - Persistence

    private func save(_ tool: CustomToolDefinition, workspaceRoot: String) throws {
        let dir = Self.toolsDirectory(workspaceRoot: workspaceRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tool)
        try data.write(to: Self.fileURL(for: tool, workspaceRoot: workspaceRoot), options: Data.WritingOptions.atomic)
    }

    public static func loadLocalTools(workspaceRoot: String) -> [CustomToolDefinition] {
        let dir = toolsDirectory(workspaceRoot: workspaceRoot)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> CustomToolDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CustomToolDefinition.self, from: data)
            }
            .sorted { $0.name < $1.name }
    }

    private static func toolsDirectory(workspaceRoot: String) -> URL {
        URL(fileURLWithPath: (workspaceRoot as NSString).appendingPathComponent(".laicai/tools"))
    }

    private static func fileURL(for tool: CustomToolDefinition, workspaceRoot: String) -> URL {
        let slug = tool.name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return toolsDirectory(workspaceRoot: workspaceRoot).appendingPathComponent("\(slug.isEmpty ? tool.id.uuidString : slug).json")
    }

    // MARK: - All available tool names (built-in + custom)

    public static let builtinTools = [
        "code.search", "file.read", "file.write", "file.edit",
        "shell.exec", "web.search", "web.fetch", "workspace.index",
        "verify.build"
    ]

    public func allToolNames() -> [String] {
        Self.builtinTools + tools.map { $0.qualifiedName }
    }
}
