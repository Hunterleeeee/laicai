import Foundation

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

public enum ToolExecutionPolicy: String, Sendable, Codable, Equatable {
    case immediate
    case fileChangeReview
    case explicitUserApproval
}

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

    /// How the agent loop should gate and present tool execution.
    var executionPolicy: ToolExecutionPolicy { get }
}

extension LaicaiTool {
    public func validate(result: ToolResult) -> Bool {
        result.success
    }

    public var requiresReview: Bool {
        false
    }

    public var executionPolicy: ToolExecutionPolicy {
        requiresReview ? .explicitUserApproval : .immediate
    }

    /// Backward-compatible execute method for [String: String] params
    public func execute(params: [String: String], context: TaskContext) async throws -> ToolResult {
        var dict: [String: Any] = [:]
        for (key, value) in params {
            if let intVal = Int(value) {
                dict[key] = intVal
            } else if let doubleVal = Double(value) {
                dict[key] = doubleVal
            } else if value == "true" {
                dict[key] = true
            } else if value == "false" {
                dict[key] = false
            } else {
                dict[key] = value
            }
        }
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        return try await execute(argumentsJSON: jsonStr, context: context)
    }
}

// MARK: - Intent Router

public enum UserIntent: Sendable, Equatable {
    case chat
    case research  // Information retrieval: needs web search/fetch, not file mutation
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
            "file.read", "file.write", "file.edit", "diff.apply",
            "file.extract", "document.transform",
            "code.search", "workspace.index",
            "shell.exec", "verify.build",
            "web.search", "web.fetch",
            "browser", "browser.real", "computer",
            "wiki.build", "image.generate",
            "skill.manage", "git",
        ]
    }
}
