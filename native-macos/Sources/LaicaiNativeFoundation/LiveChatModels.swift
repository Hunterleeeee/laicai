import Foundation
import LaicaiNativeDomain

enum RawJSONValue: Codable, Sendable {
    case object([String: RawJSONValue])
    case array([RawJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RawJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

// MARK: - Request / Response Types

public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool
    public var tools: [ToolDefinition]?

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [ToolDefinition]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case tools
    }
}

public struct ChatCompletionMessage: Codable, Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var reasoningContent: String?
    public var reasoning: String?
    public var toolCalls: [FunctionCallResponse]?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case toolCalls = "tool_calls"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([FunctionCallResponse].self, forKey: .toolCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }
}

public struct ChatCompletionChoice: Codable, Sendable, Equatable {
    public var message: ChatCompletionMessage
    public var finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(ChatCompletionMessage.self, forKey: .message)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(finishReason, forKey: .finishReason)
    }
}

public struct ChatCompletionResponse: Codable, Sendable, Equatable {
    public var choices: [ChatCompletionChoice]
    public var usage: TokenUsage?
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct StreamDelta: Codable, Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var reasoningContent: String?
    public var reasoning: String?
    public var toolCalls: [StreamingToolCall]?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case toolCalls = "tool_calls"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([StreamingToolCall].self, forKey: .toolCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }
}

public struct StreamChoice: Codable, Sendable, Equatable {
    public var delta: StreamDelta
    public var finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

public struct StreamChunk: Codable, Sendable, Equatable {
    public var choices: [StreamChoice]
    public var usage: TokenUsage?
}

/// Streaming tool call chunk (has index for accumulation)
public struct StreamingToolCall: Codable, Sendable, Equatable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: StreamingFunctionCall?

    public init(index: Int? = nil, id: String? = nil, type: String? = nil, function: StreamingFunctionCall? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct StreamingFunctionCall: Codable, Sendable, Equatable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

// Ollama native /api/chat response chunk
public struct OllamaChatMessage: Codable, Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var thinking: String?
    public var toolCalls: [FunctionCallResponse]?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case thinking
        case toolCalls = "tool_calls"
    }
}

public struct OllamaChatChunk: Codable, Sendable, Equatable {
    public var message: OllamaChatMessage?
    public var done: Bool?
    public var totalDuration: Int?
    public var promptEvalCount: Int?
    public var evalCount: Int?
    public var evalDuration: Int?

    private enum CodingKeys: String, CodingKey {
        case message
        case done
        case totalDuration = "total_duration"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

public struct OllamaChatOptions: Codable, Sendable, Equatable {
    public var numPredict: Int?
    public var numContext: Int?

    private enum CodingKeys: String, CodingKey {
        case numPredict = "num_predict"
        case numContext = "num_ctx"
    }
}

public struct OllamaChatRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool
    public var think: Bool?
    public var options: OllamaChatOptions?
    public var tools: [ToolDefinition]?
    public var keepAlive: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case think
        case options
        case tools
        case keepAlive = "keep_alive"
    }
}

// MARK: - Anthropic Messages API Types

/// Anthropic Messages API request body.
/// Key differences from OpenAI: `system` is a top-level field (not a message),
/// `max_tokens` is required, and tool definitions use a different schema.
struct AnthropicMessagesRequest: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicRequestMessage]
    var stream: Bool
    var tools: [AnthropicRequestTool]?
    var temperature: Double?

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
        case tools
        case temperature
    }
}

struct AnthropicRequestMessage: Encodable {
    var role: String
    var content: AnyEncodable
}

struct AnthropicRequestTool: Encodable {
    var name: String
    var description: String
    var inputSchema: AnyEncodable

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

/// Encodable wrapper for pre-serialized JSON data (tool_use input).
struct RawJSON: Encodable {
    let data: Data

    func encode(to encoder: Encoder) throws {
        // Forward the raw JSON bytes directly to the encoder
        let decoder = JSONDecoder()
        let container = try decoder.decode(RawJSONContainer.self, from: data)
        try container.encode(to: encoder)
    }
}

/// Helper for forwarding raw JSON through Encodable.
enum RawJSONContainer: Codable {
    case dict([String: RawJSONContainer])
    case array([RawJSONContainer])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dictionary = try? container.decode([String: RawJSONContainer].self) {
            self = .dict(dictionary)
        } else if let array = try? container.decode([RawJSONContainer].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dict(let dictionary): try container.encode(dictionary)
        case .array(let array): try container.encode(array)
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        }
    }
}

/// Anthropic content block types for encoding.
enum AnthropicContentBlock: Encodable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: String)
    case image(url: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let inputJSON):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            let data = inputJSON.data(using: .utf8) ?? Data("{}".utf8)
            try container.encode(RawJSON(data: data), forKey: .input)
        case .toolResult(let toolUseId, let content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
        case .image(let url):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("url", forKey: .sourceType)
            try source.encode(url, forKey: .url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, source
        case toolUseId = "tool_use_id"
    }

    private enum SourceKeys: String, CodingKey {
        case sourceType = "type"
        case url
    }
}

/// Anthropic streaming event types.
struct AnthropicStreamEvent: Decodable {
    var type: String
    var index: Int?
    var delta: AnthropicStreamDelta?
    var message: AnthropicMessageResponse?
    var contentBlock: AnthropicStreamContentBlock?
    var usage: AnthropicUsage?

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case delta
        case message
        case contentBlock = "content_block"
        case usage
    }
}

struct AnthropicStreamDelta: Decodable {
    var type: String?
    var text: String?
    var thinking: String?
    var partialJSON: String?
    var stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
    }
}

struct AnthropicStreamContentBlock: Decodable {
    var type: String
    var id: String?
    var name: String?
    var text: String?
    var thinking: String?
    var input: RawJSONValue?
}

struct AnthropicMessageResponse: Decodable {
    var id: String?
    var content: [AnthropicStreamContentBlock]?
    var usage: AnthropicUsage?
    var stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case usage
        case stopReason = "stop_reason"
    }
}

struct AnthropicUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct OllamaTagsModel: Codable {
    var name: String?
    var model: String?
}

struct OllamaTagsResponse: Codable {
    var models: [OllamaTagsModel]
}

struct OpenAIModel: Codable {
    var id: String?
}

struct OpenAIModelsResponse: Codable {
    var data: [OpenAIModel]
}

public struct LiveChatConnectorRequestError: LocalizedError, Sendable {
    public let connectorName: String
    public let message: String

    public var errorDescription: String? {
        "无法连接 \(connectorName)：\(message)"
    }
}

struct AnyEncodable: Encodable {
    private let encodeBlock: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        encodeBlock = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBlock(encoder)
    }
}
