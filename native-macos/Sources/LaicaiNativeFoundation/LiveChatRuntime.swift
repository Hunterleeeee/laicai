import Foundation
import LaicaiNativeDomain

// MARK: - Request / Response Types

public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var max_tokens: Int?
    public var stream: Bool
    public var tools: [ToolDefinition]?

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        max_tokens: Int? = nil,
        stream: Bool = false,
        tools: [ToolDefinition]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.stream = stream
        self.tools = tools
    }
}

public struct ChatCompletionResponse: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public struct Message: Codable, Sendable, Equatable {
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
        public var message: Message
        public var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(Message.self, forKey: .message)
            finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(finishReason, forKey: .finishReason)
        }
    }
    public var choices: [Choice]
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

public struct StreamChunk: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        public struct Delta: Codable, Sendable, Equatable {
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
        public var delta: Delta
        public var finish_reason: String?
    }
    public var choices: [Choice]
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
public struct OllamaChatChunk: Codable, Sendable, Equatable {
    public struct Message: Codable, Sendable, Equatable {
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
    public var message: Message?
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

public struct OllamaChatRequest: Codable, Sendable, Equatable {
    public struct Options: Codable, Sendable, Equatable {
        public var num_predict: Int?
        public var num_ctx: Int?
    }

    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool
    public var think: Bool?
    public var options: Options?
    public var tools: [ToolDefinition]?
    public var keep_alive: String?
}

// MARK: - Anthropic Messages API Types

/// Anthropic Messages API request body.
/// Key differences from OpenAI: `system` is a top-level field (not a message),
/// `max_tokens` is required, and tool definitions use a different schema.
private struct AnthropicMessagesRequest: Encodable {
    var model: String
    var max_tokens: Int
    var system: String?
    var messages: [AnthropicMessage]
    var stream: Bool
    var tools: [AnthropicTool]?
    var temperature: Double?

    struct AnthropicMessage: Encodable {
        var role: String
        var content: AnyEncodable
    }

    struct AnthropicTool: Encodable {
        var name: String
        var description: String
        var input_schema: AnyEncodable
    }
}

/// Encodable wrapper for pre-serialized JSON data (tool_use input).
private struct RawJSON: Encodable {
    let data: Data

    func encode(to encoder: Encoder) throws {
        // Forward the raw JSON bytes directly to the encoder
        let decoder = JSONDecoder()
        let container = try decoder.decode(RawJSONContainer.self, from: data)
        try container.encode(to: encoder)
    }
}

/// Helper for forwarding raw JSON through Encodable.
private enum RawJSONContainer: Codable {
    case dict([String: RawJSONContainer])
    case array([RawJSONContainer])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode([String: RawJSONContainer].self) { self = .dict(d) }
        else if let a = try? container.decode([RawJSONContainer].self) { self = .array(a) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dict(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }
}

/// Anthropic content block types for encoding.
private enum AnthropicContentBlock: Encodable {
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
            try container.encode(toolUseId, forKey: .tool_use_id)
            try container.encode(content, forKey: .content)
        case .image(let url):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("url", forKey: .sourceType)
            try source.encode(url, forKey: .url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, tool_use_id, content, source
    }

    private enum SourceKeys: String, CodingKey {
        case sourceType = "type", url
    }
}

/// Anthropic streaming event types.
private struct AnthropicStreamEvent: Decodable {
    var type: String
    var index: Int?
    var delta: Delta?
    var message: AnthropicMessageResponse?
    var content_block: ContentBlock?
    var usage: AnthropicUsage?

    struct Delta: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var partial_json: String?
        var stop_reason: String?
    }

    struct ContentBlock: Decodable {
        var type: String
        var id: String?
        var name: String?
        var text: String?
        var thinking: String?
    }

    struct AnthropicMessageResponse: Decodable {
        var id: String?
        var content: [ContentBlock]?
        var usage: AnthropicUsage?
        var stop_reason: String?
    }

    struct AnthropicUsage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
    }
}

private struct OllamaTagsResponse: Codable {
    struct Model: Codable {
        var name: String?
        var model: String?
    }

    var models: [Model]
}

private struct OpenAIModelsResponse: Codable {
    struct Model: Codable {
        var id: String?
    }

    var data: [Model]
}

// MARK: - Live Chat Runtime

public struct LiveChatRuntime: ChatRuntimeClient {
    public struct ConnectorRequestError: LocalizedError, Sendable {
        public let connectorName: String
        public let message: String

        public var errorDescription: String? {
            "无法连接 \(connectorName)：\(message)"
        }
    }

    private static let historyTurnLimit = 40
    private static let historyCharacterBudget = 60_000
    private static let probeMessages = [
        ChatMessage(role: "system", content: "你正在执行连接器兼容性自检。直接输出 ok。"),
        ChatMessage(role: "user", content: "请直接回复 ok。")
    ]
    /// Probe tools mimic real production tools (string params, required fields, JSON schema)
    /// so we don't false-positive on servers that accept trivial empty-params tools but reject
    /// realistic schemas.
    private static let probeToolDefinitions: [ToolDefinition] = {
        let pathParam = FunctionParameters(
            type: "object",
            properties: [
                "path": .init(type: "string", description: "Absolute file path"),
                "encoding": .init(type: "string", description: "Optional encoding, e.g. utf-8")
            ],
            required: ["path"]
        )
        let queryParam = FunctionParameters(
            type: "object",
            properties: [
                "query": .init(type: "string", description: "Search keyword"),
                "limit": .init(type: "string", description: "Optional max results")
            ],
            required: ["query"]
        )
        return [
            ToolDefinition(function: FunctionDefinition(
                name: "connector_probe_read",
                description: "Probe: representative file read tool with required path parameter.",
                parameters: pathParam
            )),
            ToolDefinition(function: FunctionDefinition(
                name: "connector_probe_search",
                description: "Probe: representative search tool with required query parameter.",
                parameters: queryParam
            ))
        ]
    }()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        guard let connector = request.connector else {
            return Self.fallbackResponse(request: request)
        }
        if let response = Self.imageOnlyModelResponse(for: connector) {
            return response
        }

        let startedAt = Date()
        let url = Self.buildURL(from: connector.endpoint, kind: connector.kind)
        let messages = Self.buildMessages(
            history: request.history,
            currentMessage: request.message,
            systemPrompt: request.systemPrompt,
            overrideMessages: request.messages,
            imageAttachments: request.imageAttachments
        )
        let isOllamaNative = Self.isOllamaNativeURL(url)
        let isAnthropic = Self.isAnthropicURL(url)
        let urlRequest = Self.buildURLRequest(
            url: url,
            body: Self.requestBody(
                connector: connector,
                messages: messages,
                stream: false,
                tools: request.tools,
                maxOutputTokens: request.maxOutputTokens,
                isOllamaNative: isOllamaNative,
                isAnthropic: isAnthropic
            ),
            apiKey: connector.note,
            isLocal: isOllamaNative
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard (200...299).contains(statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "empty"
                let message = Self.userFacingErrorMessage(statusCode: statusCode, bodyText: bodyText, connectorName: connector.name)
                let urlHint = "URL: \(url.absoluteString)"
                return SendMessageResponse(
                    assistantText: "\(message)\n\(urlHint)",
                    toolActivities: [ToolActivity(name: "chat.error", summary: "\(connector.name) 返回 HTTP \(statusCode)", statusLine: "\(urlHint) · \(bodyText.prefix(80))", isFailure: true)]
                )
            }

            let text: String
            let reasoningContent: String?
            let toolCalls: [FunctionCallResponse]
            let finishReason: String?
            let metrics: ResponseMetrics
            if isAnthropic {
                let decoded = try JSONDecoder().decode(AnthropicStreamEvent.AnthropicMessageResponse.self, from: data)
                var contentText = ""
                var thinkingText = ""
                var parsedToolCalls: [FunctionCallResponse] = []
                for block in decoded.content ?? [] {
                    if block.type == "text", let t = block.text {
                        contentText += t
                    } else if block.type == "thinking", let t = block.thinking {
                        thinkingText += t
                    } else if block.type == "tool_use", let id = block.id, let name = block.name {
                        // tool_use input is a JSON object in the response
                        let argsJSON = "{}"
                        parsedToolCalls.append(FunctionCallResponse(
                            id: id, type: "function",
                            function: FunctionCallDetail(name: name, arguments: argsJSON)
                        ))
                    }
                }
                reasoningContent = thinkingText.isEmpty ? nil : thinkingText
                text = Self.finalAssistantText(fromVisible: contentText, reasoningContent: nil, fallbackForEmpty: false)
                toolCalls = parsedToolCalls
                finishReason = decoded.stop_reason
                let inputTokens = decoded.usage?.input_tokens
                let outputTokens = decoded.usage?.output_tokens
                metrics = ResponseMetrics(
                    thinkingDuration: 0,
                    totalDuration: max(0.001, Date().timeIntervalSince(startedAt)),
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    tokensPerSecond: 0
                )
            } else if isOllamaNative,
               let ollama = try? JSONDecoder().decode(OllamaChatChunk.self, from: data) {
                reasoningContent = ollama.message?.thinking
                text = Self.finalAssistantText(
                    fromVisible: Self.visibleAnswer(from: ollama.message?.content ?? ""),
                    reasoningContent: reasoningContent,
                    fallbackForEmpty: false
                )
                toolCalls = ollama.message?.toolCalls ?? []
                finishReason = nil
                metrics = Self.metrics(
                    startedAt: startedAt,
                    firstVisibleAt: nil,
                    messages: messages,
                    outputText: text,
                    usage: nil,
                    ollama: ollama
                )
            } else {
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                let choice = decoded.choices.first
                reasoningContent = choice?.message.reasoningContent ?? choice?.message.reasoning
                text = Self.finalAssistantText(
                    fromVisible: Self.visibleAnswer(from: choice?.message.content ?? ""),
                    reasoningContent: reasoningContent,
                    fallbackForEmpty: false
                )
                toolCalls = choice?.message.toolCalls ?? []
                finishReason = choice?.finishReason
                metrics = Self.metrics(
                    startedAt: startedAt,
                    firstVisibleAt: nil,
                    messages: messages,
                    outputText: text,
                    usage: decoded.usage,
                    ollama: nil
                )
            }

            return SendMessageResponse(
                assistantText: text,
                reasoningContent: reasoningContent,
                toolCalls: toolCalls,
                finishReason: finishReason,
                toolActivities: [ToolActivity(name: "chat.complete", summary: "收到 \(connector.name) 的响应", statusLine: toolCalls.isEmpty ? "文本响应" : "\(toolCalls.count) 个工具调用", isFailure: false)],
                metrics: metrics
            )
        } catch {
            throw Self.connectorRequestError(connector: connector, error: error)
        }
    }

    public func sendMessageStream(_ request: SendMessageRequest, onChunk: @escaping @Sendable @MainActor (String) -> Void, onReasoningChunk: @escaping @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        return try await sendMessageStreamImpl(request, onChunk: onChunk, onReasoningChunk: onReasoningChunk)
    }

    public func sendMessageStream(_ request: SendMessageRequest, onChunk: @escaping @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        return try await sendMessageStreamImpl(request, onChunk: onChunk, onReasoningChunk: nil)
    }

    private func sendMessageStreamImpl(_ request: SendMessageRequest, onChunk: @escaping @Sendable @MainActor (String) -> Void, onReasoningChunk: (@Sendable @MainActor (String) -> Void)?) async throws -> SendMessageResponse {
        guard let connector = request.connector else {
            return Self.fallbackResponse(request: request)
        }
        if let response = Self.imageOnlyModelResponse(for: connector) {
            return response
        }

        let startedAt = Date()
        var firstVisibleAt: Date?
        let url = Self.buildURL(from: connector.endpoint, kind: connector.kind)
        let messages = Self.buildMessages(
            history: request.history,
            currentMessage: request.message,
            systemPrompt: request.systemPrompt,
            overrideMessages: request.messages,
            imageAttachments: request.imageAttachments
        )
        let isOllamaNative = Self.isOllamaNativeURL(url)
        let isAnthropic = Self.isAnthropicURL(url)
        let urlRequest = Self.buildURLRequest(
            url: url,
            body: Self.requestBody(
                connector: connector,
                messages: messages,
                stream: true,
                tools: request.tools,
                maxOutputTokens: request.maxOutputTokens,
                isOllamaNative: isOllamaNative,
                isAnthropic: isAnthropic
            ),
            apiKey: connector.note,
            isLocal: isOllamaNative
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw Self.connectorRequestError(connector: connector, error: error)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            let message = Self.userFacingErrorMessage(statusCode: statusCode, bodyText: errorBody, connectorName: connector.name)
            let urlHint = "URL: \(url.absoluteString)"
            return SendMessageResponse(
                assistantText: "\(message)\n\(urlHint)",
                toolActivities: [ToolActivity(name: "chat.error", summary: "\(connector.name) 返回 HTTP \(statusCode)", statusLine: "\(urlHint) · \(errorBody.prefix(80))", isFailure: true)]
            )
        }

        var rawText = ""
        var visibleText = ""
        var reasoningText = ""
        var reasoningCount = 0
        var accumulatedToolCalls: [Int: AccumulatedToolCall] = [:]
        var finishReason: String?
        var usage: TokenUsage?
        var finalOllamaChunk: OllamaChatChunk?
        let decoder = JSONDecoder()

        // H6: Micro-batch stream deltas to reduce MainActor hops.
        // Instead of one await per SSE token, batch small deltas.
        var pendingDelta = ""
        var lastChunkAt = CFAbsoluteTimeGetCurrent()
        let chunkFlushThreshold = 240  // chars
        let chunkFlushInterval = 0.35 // seconds

        // Anthropic: track tool_use block index for accumulation
        var anthropicCurrentToolIndex: Int = 0

        do {
            for try await line in bytes.lines {
                if isAnthropic {
                    // Anthropic SSE: "event: <type>\ndata: <json>" format
                    // We only care about data lines; event lines are informational
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    guard let data = jsonStr.data(using: .utf8) else { continue }
                    guard let event = try? decoder.decode(AnthropicStreamEvent.self, from: data) else { continue }

                    switch event.type {
                    case "content_block_start":
                        if event.content_block?.type == "tool_use" {
                            let idx = event.index ?? anthropicCurrentToolIndex
                            accumulatedToolCalls[idx] = AccumulatedToolCall(
                                id: event.content_block?.id ?? "call_\(idx)",
                                name: event.content_block?.name ?? "",
                                arguments: ""
                            )
                            anthropicCurrentToolIndex = idx + 1
                        }
                    case "content_block_delta":
                        if event.delta?.type == "text_delta", let text = event.delta?.text {
                            rawText += text
                            let nextVisible = rawText  // Anthropic doesn't use think tags
                            if nextVisible.count > visibleText.count {
                                let visibleDelta = String(nextVisible.dropFirst(visibleText.count))
                                visibleText = nextVisible
                                if firstVisibleAt == nil { firstVisibleAt = Date() }
                                pendingDelta += visibleDelta
                                let now = CFAbsoluteTimeGetCurrent()
                                if pendingDelta.count >= chunkFlushThreshold || (now - lastChunkAt) >= chunkFlushInterval {
                                    let batch = pendingDelta
                                    pendingDelta = ""
                                    lastChunkAt = now
                                    await onChunk(batch)
                                }
                            }
                        } else if event.delta?.type == "thinking_delta", let thinking = event.delta?.thinking {
                            reasoningText += thinking
                            reasoningCount += thinking.count
                            if let onReasoningChunk { await onReasoningChunk(thinking) }
                        } else if event.delta?.type == "input_json_delta", let partial = event.delta?.partial_json {
                            // Accumulate tool call arguments
                            let idx = (event.index ?? anthropicCurrentToolIndex) - 1
                            if var acc = accumulatedToolCalls[idx] {
                                acc.arguments += partial
                                accumulatedToolCalls[idx] = acc
                            }
                        }
                    case "message_delta":
                        if let stopReason = event.delta?.stop_reason {
                            finishReason = stopReason
                        }
                        if let u = event.usage {
                            usage = TokenUsage(promptTokens: u.input_tokens, completionTokens: u.output_tokens, totalTokens: nil)
                        }
                    case "message_stop":
                        break  // End of stream
                    default:
                        break
                    }
                } else if isOllamaNative {
                // Ollama native NDJSON (no tool calling support in native format)
                    guard let data = line.data(using: .utf8) else { continue }
                    if let ollamaChunk = try? decoder.decode(OllamaChatChunk.self, from: data) {
                        if ollamaChunk.done == true {
                            finalOllamaChunk = ollamaChunk
                        }
                        if let thinking = ollamaChunk.message?.thinking {
                            reasoningText += thinking
                            reasoningCount += thinking.count
                            if let onReasoningChunk { await onReasoningChunk(thinking) }
                        }
                        if let chunkToolCalls = ollamaChunk.message?.toolCalls {
                            for (offset, tc) in chunkToolCalls.enumerated() {
                                let idx = accumulatedToolCalls.count + offset
                                accumulatedToolCalls[idx] = AccumulatedToolCall(
                                    id: tc.id ?? "call_ollama_\(idx)",
                                    name: tc.function.name,
                                    arguments: tc.function.arguments
                                )
                            }
                        }
                        if let content = ollamaChunk.message?.content {
                            rawText += content
                            let nextVisible = Self.visibleAnswer(from: rawText)
                            if nextVisible.count > visibleText.count {
                                let delta = String(nextVisible.dropFirst(visibleText.count))
                                visibleText = nextVisible
                                if firstVisibleAt == nil { firstVisibleAt = Date() }
                                pendingDelta += delta
                                let now = CFAbsoluteTimeGetCurrent()
                                if pendingDelta.count >= chunkFlushThreshold || (now - lastChunkAt) >= chunkFlushInterval {
                                    let batch = pendingDelta
                                    pendingDelta = ""
                                    lastChunkAt = now
                                    await onChunk(batch)
                                }
                            }
                        }
                    }
                } else {
                // OpenAI compatible SSE: data: {...}
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
                    guard let data = jsonStr.data(using: .utf8) else { continue }

                    if let chunk = try? decoder.decode(StreamChunk.self, from: data) {
                        if let chunkUsage = chunk.usage {
                            usage = chunkUsage
                        }
                        if let reasoning = chunk.choices.first?.delta.reasoningContent ?? chunk.choices.first?.delta.reasoning {
                            reasoningText += reasoning
                            reasoningCount += reasoning.count
                            if let onReasoningChunk { await onReasoningChunk(reasoning) }
                        }
                        if let delta = chunk.choices.first?.delta.content {
                            rawText += delta
                            let nextVisible = Self.visibleAnswer(from: rawText)
                            if nextVisible.count > visibleText.count {
                                let visibleDelta = String(nextVisible.dropFirst(visibleText.count))
                                visibleText = nextVisible
                                if firstVisibleAt == nil { firstVisibleAt = Date() }
                                pendingDelta += visibleDelta
                                let now = CFAbsoluteTimeGetCurrent()
                                if pendingDelta.count >= chunkFlushThreshold || (now - lastChunkAt) >= chunkFlushInterval {
                                    let batch = pendingDelta
                                    pendingDelta = ""
                                    lastChunkAt = now
                                    await onChunk(batch)
                                }
                            }
                        }
                        if let toolCallDeltas = chunk.choices.first?.delta.toolCalls {
                            for tc in toolCallDeltas {
                                let idx = tc.index ?? 0
                                var acc = accumulatedToolCalls[idx] ?? AccumulatedToolCall()
                                if let id = tc.id { acc.id = id }
                                if let name = tc.function?.name { acc.name = name }
                                if let args = tc.function?.arguments { acc.arguments += args }
                                accumulatedToolCalls[idx] = acc
                            }
                        }
                        if let fr = chunk.choices.first?.finish_reason {
                            finishReason = fr
                        }
                    }
                }
            }
        } catch {
            throw Self.connectorRequestError(connector: connector, error: error)
        }

        // H6: Flush remaining batched delta
        if !pendingDelta.isEmpty {
            let batch = pendingDelta
            pendingDelta = ""
            await onChunk(batch)
        }

        // Convert accumulated tool calls to final format
        let toolCalls = accumulatedToolCalls.sorted { $0.key < $1.key }.compactMap { (_, acc) -> FunctionCallResponse? in
            guard !acc.name.isEmpty else { return nil }
            return FunctionCallResponse(
                id: acc.id,
                type: "function",
                function: FunctionCallDetail(name: acc.name, arguments: acc.arguments)
            )
        }

        let finalText = Self.finalAssistantText(
            fromVisible: visibleText,
            reasoningContent: reasoningText.isEmpty ? nil : reasoningText,
            fallbackForEmpty: false
        )
        let metrics = Self.metrics(
            startedAt: startedAt,
            firstVisibleAt: firstVisibleAt,
            messages: messages,
            outputText: finalText,
            usage: usage,
            ollama: finalOllamaChunk
        )

        return SendMessageResponse(
            assistantText: finalText,
            reasoningContent: reasoningText.isEmpty ? nil : reasoningText,
            toolCalls: toolCalls,
            finishReason: finishReason,
            toolActivities: [ToolActivity(name: "chat.complete", summary: "流式收到 \(connector.name) 的响应", statusLine: toolCalls.isEmpty ? Self.responseStatusLine(finalText: finalText, reasoningCount: reasoningCount) : "\(toolCalls.count) 个工具调用", isFailure: false)],
            metrics: metrics
        )
    }

    private static func connectorRequestError(connector: ConnectorProfile, error: Error) -> ConnectorRequestError {
        if let connectorError = error as? ConnectorRequestError {
            return connectorError
        }
        return ConnectorRequestError(connectorName: connector.name, message: error.localizedDescription)
    }

    public func healthCheck(endpoint: String, model: String, apiKey: String, kind: String = "openai-compatible") async throws -> ConnectorHealth {
        try await probeConnector(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind, probeToolCalling: false).health
    }

    public func probeConnector(
        endpoint: String,
        model: String,
        apiKey: String,
        kind: String = "openai-compatible",
        probeToolCalling: Bool = true
    ) async throws -> ConnectorProbeResult {
        let base = Self.serviceBaseEndpoint(from: Self.baseEndpoint(from: endpoint))
        let isOllama = Self.usesOllamaNativeProtocol(endpoint: endpoint, kind: kind)
        let isAnthropic = Self.usesAnthropicProtocol(endpoint: endpoint, kind: kind)

        // Anthropic: no model listing API; do a minimal messages request to verify key
        if isAnthropic {
            let health: ConnectorHealth = apiKey.isEmpty ? .attention : .ready
            let ctx = await contextWindowProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            guard probeToolCalling, health == .ready else {
                return ConnectorProbeResult(health: health, contextWindow: ctx)
            }
            let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            return ConnectorProbeResult(health: health, toolCallingCapability: capability, contextWindow: ctx)
        }

        let urlString: String
        if isOllama {
            let ollamaBase = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            let cleanBase = ollamaBase.hasSuffix("/api") ? String(ollamaBase.dropLast(4)) : ollamaBase
            urlString = cleanBase.hasSuffix("/api/tags") ? cleanBase : cleanBase + "/api/tags"
        } else {
            let apiBase = Self.openAICompatibleBase(from: base)
            urlString = apiBase.hasSuffix("/models") ? apiBase : apiBase + "/models"
        }

        guard let url = URL(string: urlString) else {
            return ConnectorProbeResult(health: .offline)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty && !isOllama {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = NetworkDefaults.modelList

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                return ConnectorProbeResult(health: .attention)
            }
            // Probe context window in parallel (non-blocking, best-effort)
            let ctxWindow = await contextWindowProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            let health: ConnectorHealth
            if isOllama {
                let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !requestedModel.isEmpty else {
                    health = .ready
                    if !probeToolCalling {
                        return ConnectorProbeResult(health: health, contextWindow: ctxWindow)
                    }
                    let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
                    return ConnectorProbeResult(health: health, toolCallingCapability: capability, contextWindow: ctxWindow)
                }
                guard let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
                    return ConnectorProbeResult(health: .attention, contextWindow: ctxWindow)
                }
                let exists = tags.models.contains {
                    $0.name == requestedModel || $0.model == requestedModel
                }
                health = exists ? .ready : .attention
            } else {
                let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !requestedModel.isEmpty else {
                    health = .ready
                    if !probeToolCalling {
                        return ConnectorProbeResult(health: health, contextWindow: ctxWindow)
                    }
                    let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
                    return ConnectorProbeResult(health: health, toolCallingCapability: capability, contextWindow: ctxWindow)
                }
                if let models = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data), !models.data.isEmpty {
                    let exists = models.data.contains {
                        $0.id?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(requestedModel) == .orderedSame
                    }
                    health = exists ? .ready : .attention
                } else {
                    health = .ready
                }
            }
            guard probeToolCalling, health == .ready else {
                return ConnectorProbeResult(health: health, contextWindow: ctxWindow)
            }
            let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            return ConnectorProbeResult(health: health, toolCallingCapability: capability, contextWindow: ctxWindow)
        } catch {
            return ConnectorProbeResult(health: .offline)
        }
    }

    private func toolCallingCapabilityProbe(
        endpoint: String,
        model: String,
        apiKey: String,
        kind: String
    ) async throws -> ConnectorToolCallingCapability? {
        let connector = ConnectorProfile(
            name: "probe",
            kind: kind,
            endpoint: endpoint,
            modelName: model,
            note: apiKey,
            health: .attention
        )
        let url = Self.buildURL(from: endpoint, kind: kind)
        let isOllamaNative = Self.isOllamaNativeURL(url)
        let isAnthropic = Self.isAnthropicURL(url)
        let body: any Encodable
        if isOllamaNative {
            body = OllamaChatRequest(
                model: model,
                messages: Self.probeMessages,
                stream: false,
                think: false,
                options: .init(num_predict: 1, num_ctx: Self.localContextWindow(for: connector)),
                tools: Self.probeToolDefinitions,
                keep_alive: "30s"
            )
        } else if isAnthropic {
            body = Self.buildAnthropicRequest(
                model: model,
                messages: Self.probeMessages,
                stream: false,
                tools: Self.probeToolDefinitions,
                maxTokens: 1
            )
        } else {
            body = ChatCompletionRequest(
                model: model,
                messages: Self.probeMessages,
                max_tokens: 1,
                stream: false,
                tools: Self.probeToolDefinitions
            )
        }
        let request = Self.buildURLRequest(
            url: url,
            body: body,
            apiKey: apiKey,
            isLocal: isOllamaNative
        )
        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard !(200...299).contains(statusCode) else { return .supported }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let detail = ([bodyText, Self.extractServerMessage(from: bodyText)])
                .joined(separator: " ")
                .lowercased()
            if (400...499).contains(statusCode) && (
                statusCode == 400
                    || statusCode == 422
                    || detail.contains("tool")
                    || detail.contains("function")
                    || detail.contains("兼容")
            ) {
                return .unsupported
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Probe the connector's context window by querying model info endpoints.
    private func contextWindowProbe(
        endpoint: String,
        model: String,
        apiKey: String,
        kind: String
    ) async -> Int? {
        let base = Self.serviceBaseEndpoint(from: Self.baseEndpoint(from: endpoint))
        let isOllama = Self.usesOllamaNativeProtocol(endpoint: endpoint, kind: kind)
        let isAnthropic = Self.usesAnthropicProtocol(endpoint: endpoint, kind: kind)

        if isOllama {
            // Ollama: POST /api/show with model name returns details including context length
            let ollamaBase = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            let cleanBase = ollamaBase.hasSuffix("/api") ? String(ollamaBase.dropLast(4)) : ollamaBase
            let urlString = cleanBase + "/api/show"
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["name": model])
            request.timeoutInterval = 10
            guard let (data, response) = try? await session.data(for: request),
                  let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200...299).contains(statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelInfo = json["model_info"] as? [String: Any] else {
                return nil
            }
            // Ollama reports context length as "general.context_length" key
            for (key, value) in modelInfo {
                if key.hasSuffix(".context_length"), let ctx = value as? Int {
                    return ctx
                }
            }
            // Fallback: check parameters for num_ctx
            if let params = json["parameters"] as? String {
                for line in params.split(separator: "\n") {
                    let parts = line.split(separator: " ", maxSplits: 1)
                    if parts.count == 2, parts[0] == "num_ctx", let ctx = Int(parts[1]) {
                        return ctx
                    }
                }
            }
            return nil
        }

        if isAnthropic {
            // Anthropic: no model info API; use known context windows
            let m = model.lowercased()
            if m.contains("claude-4") || m.contains("claude-3.7") { return 1_000_000 }
            if m.contains("claude-3-5") || m.contains("claude-3.5") { return 200_000 }
            if m.contains("claude-3") { return 200_000 }
            return 200_000
        }

        // OpenAI-compatible: GET /models/{model_id} may include context_window
        let apiBase = Self.openAICompatibleBase(from: base)
        let urlString = apiBase + "/" + model
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200...299).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Some providers return "context_window" or "max_context_length"
        if let ctx = json["context_window"] as? Int { return ctx }
        if let ctx = json["max_context_length"] as? Int { return ctx }
        if let ctx = json["max_input_tokens"] as? Int { return ctx }
        // Nested in "metadata" or "info"
        if let meta = json["metadata"] as? [String: Any] {
            if let ctx = meta["context_window"] as? Int { return ctx }
            if let ctx = meta["max_context_length"] as? Int { return ctx }
        }
        return nil
    }

    // MARK: - Helpers

    private struct AccumulatedToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    static func buildURL(from endpoint: String, kind: String = "openai-compatible") -> URL {
        let cleaned = normalizedEndpoint(endpoint, kind: kind)
        guard let url = URL(string: cleaned), url.host != nil else {
            return URL(string: "http://127.0.0.1/invalid-endpoint")!
        }
        return url
    }

    static func baseEndpoint(from endpoint: String) -> String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedEndpoint(_ endpoint: String, kind: String) -> String {
        let cleaned = baseEndpoint(from: endpoint)
        guard let url = URL(string: cleaned), url.host != nil else {
            return cleaned
        }

        let path = normalizedPath(for: url)

        // Anthropic Messages API: auto-append /v1/messages
        if usesAnthropicProtocol(endpoint: cleaned, kind: kind) {
            if path.isEmpty { return appendPath("v1/messages", to: cleaned) }
            if path == "v1" || path.hasSuffix("/v1") { return appendPath("messages", to: cleaned) }
            if path.hasSuffix("messages") { return cleaned }
            // Custom path (e.g. /anthropic, /proxy): append /v1/messages
            return appendPath("v1/messages", to: cleaned)
        }

        // Ollama native: auto-append /api/chat. Explicit OpenAI-compatible
        // paths such as /v1 remain OpenAI-compatible even if an old profile was
        // saved with kind=ollama.
        if usesOllamaNativeProtocol(endpoint: cleaned, kind: kind) {
            if path.isEmpty { return appendPath("api/chat", to: cleaned) }
            if path == "api" { return appendPath("chat", to: cleaned) }
            return cleaned
        }

        // OpenAI-compatible: auto-append /v1/chat/completions
        if path.isEmpty { return appendPath("v1/chat/completions", to: cleaned) }
        if path == "v1" || path.hasSuffix("/v1") { return appendPath("chat/completions", to: cleaned) }
        return cleaned
    }

    private static func appendPath(_ suffix: String, to endpoint: String) -> String {
        let trimmedSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if endpoint.hasSuffix("/") {
            return endpoint + trimmedSuffix
        }
        return endpoint + "/" + trimmedSuffix
    }

    static func serviceBaseEndpoint(from endpoint: String) -> String {
        let cleaned = baseEndpoint(from: endpoint)
        guard let url = URL(string: cleaned), url.host != nil else {
            return cleaned
        }
        let path = normalizedPath(for: url)
        if path.hasSuffix("chat/completions") {
            let components = path.split(separator: "/").map(String.init)
            let basePath: String
            if components.count >= 3, components.suffix(2) == ["chat", "completions"], components[components.count - 3] == "v1" {
                basePath = url.host?.localizedCaseInsensitiveContains("deepseek") == true ? "/v1" : ""
            } else {
                basePath = "/" + components.dropLast(2).joined(separator: "/")
            }
            return rootEndpoint(from: url, path: basePath)
        }
        if path.hasSuffix("api/chat") {
            let components = path.split(separator: "/").map(String.init)
            let basePath = components.count > 2 ? "/" + components.dropLast(2).joined(separator: "/") : ""
            return rootEndpoint(from: url, path: basePath)
        }
        if path.hasSuffix("messages") && !path.hasSuffix("chat/completions") {
            // Anthropic: /v1/messages → strip to base
            let components = path.split(separator: "/").map(String.init)
            let basePath = components.count > 2 ? "/" + components.dropLast(2).joined(separator: "/") : ""
            return rootEndpoint(from: url, path: basePath)
        }
        return cleaned
    }

    private static func rootEndpoint(from url: URL, path: String = "") -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = path == "/" ? "" : path
        return components.string ?? "\(url.scheme ?? "http")://\(url.host ?? "127.0.0.1")\(path)"
    }

    private static func openAICompatibleBase(from endpoint: String) -> String {
        endpoint
    }

    public static func normalizedConnectorKind(_ kind: String, endpoint: String) -> String {
        if usesAnthropicProtocol(endpoint: endpoint, kind: kind) { return "anthropic" }
        return usesOllamaNativeProtocol(endpoint: endpoint, kind: kind) ? "ollama" : "openai-compatible"
    }

    /// Detect Anthropic Messages API endpoints.
    public static func usesAnthropicProtocol(endpoint: String, kind: String) -> Bool {
        let kindLower = normalizedKindValue(kind)
        if kindLower == "anthropic" { return true }
        let cleaned = baseEndpoint(from: endpoint)
        guard let url = URL(string: cleaned) else { return false }
        let host = url.host?.lowercased() ?? ""
        return host.contains("anthropic")
    }

    public static func usesOllamaNativeProtocol(endpoint: String, kind: String) -> Bool {
        let cleaned = baseEndpoint(from: endpoint)
        guard let url = URL(string: cleaned) else {
            return normalizedKindValue(kind) == "ollama"
        }
        let path = normalizedPath(for: url)
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""

        // Anthropic is never Ollama
        if usesAnthropicProtocol(endpoint: cleaned, kind: kind) { return false }

        // Explicit paths beat the saved kind. This fixes profiles that were
        // accidentally saved as Ollama while pointing at /v1 OpenAI-compatible
        // services.
        if isOpenAICompatiblePath(path) { return false }
        if path.hasSuffix("api/chat") { return true }

        // Port 11434 is definitively Ollama when no OpenAI-compatible path was
        // provided.
        if url.port == 11434 || cleaned.hasSuffix(":11434") || cleaned.contains(":11434/") {
            return true
        }
        // HTTPS remote endpoints are never Ollama native (even if user picked wrong kind)
        if scheme == "https" && host != "localhost" && host != "127.0.0.1" && host != "::1" {
            return false
        }
        // Local endpoints: respect the user's kind selection unless the path
        // already identified the service.
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return normalizedKindValue(kind) == "ollama"
        }
        return false
    }

    private static func normalizedKindValue(_ kind: String) -> String {
        kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedPath(for url: URL) -> String {
        url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func isOpenAICompatiblePath(_ path: String) -> Bool {
        path == "v1"
            || path.hasSuffix("/v1")
            || path == "chat/completions"
            || path.hasSuffix("/chat/completions")
    }

    private static let useEnglishErrors: Bool = {
        let lang = Locale.preferredLanguages.first ?? ""
        return !lang.hasPrefix("zh")
    }()

    private static func userFacingErrorMessage(statusCode: Int, bodyText: String, connectorName: String) -> String {
        let extracted = extractServerMessage(from: bodyText)
        if useEnglishErrors {
            return userFacingErrorMessageEN(statusCode: statusCode, extracted: extracted, connectorName: connectorName)
        }
        switch statusCode {
        case 400:
            return extracted.isEmpty
                ? "请求格式不被 \(connectorName) 接受，请检查端点、模型名和请求兼容性。"
                : "请求格式不被 \(connectorName) 接受：\(extracted)"
        case 401:
            return "鉴权失败，请检查 API 密钥是否正确。"
        case 403:
            return extracted.isEmpty
                ? "请求被拒绝，请检查当前密钥或服务权限。"
                : "请求被拒绝，请检查当前密钥或服务权限：\(extracted)"
        case 404:
            return "未找到接口，请检查端点地址是否正确。\n提示：OpenAI 兼容接口通常以 /v1/chat/completions 结尾，Ollama 以 /api/chat 结尾。"
        case 429:
            return "请求过于频繁，请稍后再试。"
        case 500...599:
            return "服务暂时不可用（HTTP \(statusCode)），请稍后重试。"
        default:
            return extracted.isEmpty
                ? "请求失败（HTTP \(statusCode)）。"
                : "请求失败（HTTP \(statusCode)）：\(extracted)"
        }
    }

    private static func userFacingErrorMessageEN(statusCode: Int, extracted: String, connectorName: String) -> String {
        switch statusCode {
        case 400:
            return extracted.isEmpty
                ? "Request format not accepted by \(connectorName). Check endpoint, model name and compatibility."
                : "Request not accepted by \(connectorName): \(extracted)"
        case 401:
            return "Authentication failed. Please check your API key."
        case 403:
            return extracted.isEmpty
                ? "Request denied. Check your API key or service permissions."
                : "Request denied: \(extracted)"
        case 404:
            return "Endpoint not found. Check the URL.\nHint: OpenAI-compatible endpoints end with /v1/chat/completions, Ollama with /api/chat."
        case 429:
            return "Too many requests. Please wait and try again."
        case 500...599:
            return "Service temporarily unavailable (HTTP \(statusCode)). Please retry later."
        default:
            return extracted.isEmpty
                ? "Request failed (HTTP \(statusCode))."
                : "Request failed (HTTP \(statusCode)): \(extracted)"
        }
    }

    private static func extractServerMessage(from bodyText: String) -> String {
        guard let data = bodyText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let message = object["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func buildMessages(
        history: [TaskStep],
        currentMessage: String,
        systemPrompt: String?,
        overrideMessages: [ChatMessage]?,
        imageAttachments: [ImageAttachment] = []
    ) -> [ChatMessage] {
        // If caller provides full messages array (for multi-turn function calling), use it directly
        if let messages = overrideMessages, !messages.isEmpty {
            return messages
        }

        // Otherwise, build from history
        var messages: [ChatMessage] = []

        // System prompt
        let system = systemPrompt ?? "你是一个有帮助的助手。"
        messages.append(ChatMessage(role: "system", content: system))

        // History
        let compactedHistory = compactHistory(history)
        if compactedHistory.omittedCount > 0 {
            messages.append(ChatMessage(
                role: "system",
                content: "较早的 \(compactedHistory.omittedCount) 条历史已省略。请优先延续最近上下文，不要被无关旧任务牵引；如果当前消息是追问，以上一轮相关内容为准。"
            ))
        }
        for turn in compactedHistory.turns {
            messages.append(ChatMessage(role: turn.role, content: turn.content))
        }

        // Current message — use contentParts when images are attached (vision)
        if !imageAttachments.isEmpty {
            var parts: [ContentPart] = [.text(currentMessage)]
            for img in imageAttachments {
                parts.append(img.toContentPart())
            }
            messages.append(ChatMessage(role: "user", contentParts: parts))
        } else {
            messages.append(ChatMessage(role: "user", content: currentMessage))
        }

        return messages
    }

    private static func compactHistory(_ history: [TaskStep]) -> (turns: [(role: String, content: String)], omittedCount: Int) {
        var remainingBudget = historyCharacterBudget
        var compacted: [(role: String, content: String)] = []
        let nonEmptyHistory = history.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let recentSteps = nonEmptyHistory.suffix(historyTurnLimit)

        for step in recentSteps {
            let role = apiRole(for: step.kind)
            let limit = min(characterLimit(for: step.kind), max(600, remainingBudget))
            var content = compactHistoryText(step.text, limit: limit)
            switch step.kind {
            case .toolCall:
                content = "上一轮工具调用：\(content)"
            case .toolResult:
                content = step.isFailure ? "上一轮工具失败：\(content)" : "上一轮工具结果：\(content)"
            case .error:
                content = "上一轮出现错误：\(content)"
            case .reviewResult:
                content = "上一轮审查结果：\(content)"
            default:
                break
            }
            // Merge consecutive same-role messages to avoid confusing models
            if let last = compacted.last, last.role == role {
                compacted[compacted.count - 1].content += "\n\n" + content
            } else {
                compacted.append((role: role, content: content))
            }
            remainingBudget -= content.count
            if remainingBudget <= 0 { break }
        }

        return (compacted, max(0, nonEmptyHistory.count - compacted.count))
    }

    private static func apiRole(for kind: TaskStepKind) -> String {
        switch kind {
        case .userInput: return "user"
        case .textOutput: return "assistant"
        case .aiThinking: return "assistant"
        case .toolCall, .toolResult, .error, .reviewRequest, .reviewResult: return "assistant"
        }
    }

    private static func characterLimit(for kind: TaskStepKind) -> Int {
        switch kind {
        case .userInput: return 4_000
        case .textOutput: return 6_000
        case .aiThinking: return 2_000
        case .toolCall: return 2_000
        case .toolResult: return 3_000
        case .error: return 2_000
        case .reviewRequest, .reviewResult: return 2_000
        }
    }

    private static func compactHistoryText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let headCount = max(240, Int(Double(limit) * 0.62))
        let tailCount = max(180, limit - headCount - 40)
        let head = trimmed.prefix(headCount)
        let tail = trimmed.suffix(tailCount)
        return "\(head)\n\n[中间历史已压缩]\n\n\(tail)"
    }

    private static func requestBody(
        connector: ConnectorProfile,
        messages: [ChatMessage],
        stream: Bool,
        tools: [ToolDefinition]?,
        maxOutputTokens: Int?,
        isOllamaNative: Bool,
        isAnthropic: Bool = false
    ) -> any Encodable {
        let outputCap = Self.outputTokenCap(for: connector, requested: maxOutputTokens)
        if isOllamaNative {
            return OllamaChatRequest(
                model: connector.modelName,
                messages: messages,
                stream: stream,
                think: false,
                options: .init(num_predict: outputCap, num_ctx: Self.localContextWindow(for: connector)),
                tools: tools,
                keep_alive: "2m"
            )
        }
        if isAnthropic {
            return Self.buildAnthropicRequest(
                model: connector.modelName,
                messages: messages,
                stream: stream,
                tools: tools,
                maxTokens: outputCap
            )
        }
        return ChatCompletionRequest(
            model: connector.modelName,
            messages: messages,
            max_tokens: outputCap,
            stream: stream,
            tools: tools
        )
    }

    /// Build an Anthropic Messages API request from OpenAI-style messages.
    /// Extracts system messages into the top-level `system` field and converts
    /// tool definitions to Anthropic's `input_schema` format.
    private static func buildAnthropicRequest(
        model: String,
        messages: [ChatMessage],
        stream: Bool,
        tools: [ToolDefinition]?,
        maxTokens: Int
    ) -> AnthropicMessagesRequest {
        var systemParts: [String] = []
        var anthropicMessages: [AnthropicMessagesRequest.AnthropicMessage] = []

        for msg in messages {
            if msg.role == "system" {
                if let content = msg.effectiveContent {
                    systemParts.append(content)
                }
            } else if msg.role == "assistant" {
                // Anthropic assistant messages: text content or tool_use blocks
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    if let content = msg.effectiveContent, !content.isEmpty {
                        blocks.append(.text(content))
                    }
                    for tc in toolCalls {
                        blocks.append(.toolUse(id: tc.id ?? "", name: tc.function.name, inputJSON: tc.function.arguments))
                    }
                    anthropicMessages.append(.init(role: "assistant", content: AnyEncodable(blocks)))
                } else if let content = msg.effectiveContent {
                    anthropicMessages.append(.init(role: "assistant", content: AnyEncodable(content)))
                }
            } else if msg.role == "tool" {
                // Anthropic uses "user" role with tool_result content blocks
                let resultContent = msg.effectiveContent ?? ""
                let blocks: [AnthropicContentBlock] = [.toolResult(toolUseId: msg.toolCallId ?? "", content: resultContent)]
                anthropicMessages.append(.init(role: "user", content: AnyEncodable(blocks)))
            } else if msg.role == "user" {
                if let contentParts = msg.contentParts, !contentParts.isEmpty {
                    // Multimodal: convert to Anthropic content blocks
                    var blocks: [AnthropicContentBlock] = []
                    for part in contentParts {
                        if part.type == "text", let text = part.text {
                            blocks.append(.text(text))
                        } else if part.type == "image_url", let imageURL = part.imageURL {
                            blocks.append(.image(url: imageURL.url))
                        }
                    }
                    anthropicMessages.append(.init(role: "user", content: AnyEncodable(blocks)))
                } else if let content = msg.effectiveContent {
                    anthropicMessages.append(.init(role: "user", content: AnyEncodable(content)))
                }
            }
        }

        // Convert tools to Anthropic format
        let anthropicTools: [AnthropicMessagesRequest.AnthropicTool]? = tools?.map { tool in
            AnthropicMessagesRequest.AnthropicTool(
                name: tool.function.name,
                description: tool.function.description,
                input_schema: AnyEncodable(tool.function.parameters)
            )
        }

        let systemText = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        return AnthropicMessagesRequest(
            model: model,
            max_tokens: maxTokens,
            system: systemText,
            messages: anthropicMessages,
            stream: stream,
            tools: anthropicTools
        )
    }

    private static func outputTokenCap(for connector: ConnectorProfile, requested: Int?) -> Int {
        let fallback = maxOutputTokens(for: connector)
        let value = requested ?? fallback
        if ConnectorCapabilityProfile.isLocalConnector(connector) {
            return max(256, min(value, 4096))
        }
        return max(1024, min(value, 131_072))
    }

    private static func maxOutputTokens(for connector: ConnectorProfile) -> Int {
        if ConnectorCapabilityProfile.isLocalConnector(connector) { return 4096 }
        let model = connector.modelName.lowercased()
        // 1M-class models with large output support
        if model.contains("gpt-5") || model.contains("gpt5") { return 65536 }
        if model.contains("o3") || model.contains("o4") || model.contains("o1") { return 65536 }
        if model.contains("gpt-4.1") { return 32768 }
        if model.contains("gpt-4o") { return 16384 }
        if model.contains("deepseek") {
            if model.contains("v4") || model.contains("r2") { return 65536 }
            return 8192
        }
        if model.contains("claude-4") || model.contains("claude-3.7") { return 65536 }
        if model.contains("claude") { return 16384 }
        if model.contains("gemini") { return 65536 }
        return 32768
    }

    private static func localContextWindow(for connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.isLocalConnector(connector) ? 4096 : 8192
    }

    private static func buildURLRequest(url: URL, body: any Encodable, apiKey: String, isLocal: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            if isAnthropicURL(url) {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try? JSONEncoder().encode(AnyEncodable(body))
        request.timeoutInterval = isLocal ? NetworkDefaults.localChat : NetworkDefaults.remoteChat
        return request
    }

    private static func isOllamaNativeURL(_ url: URL) -> Bool {
        url.path.hasSuffix("/api/chat")
    }

    private static func isAnthropicURL(_ url: URL) -> Bool {
        url.path.hasSuffix("/messages") && !url.path.contains("/chat/completions")
    }

    private static func metrics(
        startedAt: Date,
        firstVisibleAt: Date?,
        messages: [ChatMessage],
        outputText: String,
        usage: TokenUsage?,
        ollama: OllamaChatChunk?
    ) -> ResponseMetrics {
        let finishedAt = Date()
        let totalDuration = max(0.001, finishedAt.timeIntervalSince(startedAt))
        let inputTokens = usage?.promptTokens
            ?? ollama?.promptEvalCount
            ?? estimatedTokens(messages.compactMap(\.content).joined(separator: "\n"))
        let outputTokens = usage?.completionTokens
            ?? ollama?.evalCount
            ?? estimatedTokens(outputText)
        let thinkingDuration = firstVisibleAt?.timeIntervalSince(startedAt) ?? totalDuration
        let outputWindow: TimeInterval
        if let firstVisibleAt {
            outputWindow = max(0.001, finishedAt.timeIntervalSince(firstVisibleAt))
        } else if let evalDuration = ollama?.evalDuration, evalDuration > 0 {
            outputWindow = max(0.001, Double(evalDuration) / 1_000_000_000)
        } else {
            outputWindow = totalDuration
        }

        return ResponseMetrics(
            thinkingDuration: thinkingDuration,
            totalDuration: totalDuration,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            tokensPerSecond: Double(max(0, outputTokens)) / outputWindow
        )
    }

    private static func estimatedTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }

    private static func visibleAnswer(from rawText: String) -> String {
        var output = rawText
        while let start = output.range(of: "<think>", options: [.caseInsensitive]) {
            if let end = output.range(of: "</think>", options: [.caseInsensitive], range: start.upperBound..<output.endIndex) {
                output.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                output.removeSubrange(start.lowerBound..<output.endIndex)
                break
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finalAssistantText(fromVisible visible: String, reasoningContent: String?, fallbackForEmpty: Bool) -> String {
        let text = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        // Thinking model: content is empty but reasoning_content has substance.
        // Extract a usable conclusion instead of discarding it.
        if let reasoning = reasoningContent, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let extracted = extractConclusionFromReasoning(reasoning)
            if !extracted.isEmpty { return extracted }
            // Fallback: return the last portion of reasoning as the answer
            let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(trimmed.suffix(2000))
            return tail
        }
        return fallbackForEmpty ? "模型没有返回可显示内容。请检查模型是否可用，或换一个模型重试。" : ""
    }

    /// Try to extract a conclusion section from reasoning text.
    /// Many thinking models end their reasoning with a summary/conclusion block.
    private static func extractConclusionFromReasoning(_ reasoning: String) -> String {
        let lines = reasoning.components(separatedBy: .newlines)
        // Look for common conclusion markers from the end
        let markers = ["结论", "总结", "最终", "综上", "因此", "所以", "答案", "建议", "方案"]
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 40), by: -1) {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if markers.contains(where: { line.hasPrefix($0) || line.hasPrefix("# ") && line.contains($0) || line.hasPrefix("## ") }) {
                let conclusion = lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if conclusion.count > 20 { return conclusion }
            }
        }
        return ""
    }

    private static func responseStatusLine(finalText: String, reasoningCount: Int) -> String {
        if reasoningCount > 0 && finalText.hasPrefix("模型只返回了思考内容") {
            return "仅收到思考内容"
        }
        if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "空响应"
        }
        return "文本响应"
    }

    private static func fallbackResponse(request: SendMessageRequest) -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "未选择连接器。请从顶部选择一个模型开始。",
            toolActivities: [ToolActivity(name: "chat.fallback", summary: "无可用连接器", statusLine: "等待选择连接器", isFailure: true)]
        )
    }

    private static func imageOnlyModelResponse(for connector: ConnectorProfile) -> SendMessageResponse? {
        guard ConnectorCapabilityProfile.isImageOnlyModel(connector.modelName) else { return nil }
        let message = ConnectorCapabilityProfile.imageOnlyModelChatMessage(modelName: connector.modelName)
        return SendMessageResponse(
            assistantText: message,
            finishReason: "model_not_supported_for_chat",
            toolActivities: [
                ToolActivity(
                    name: "chat.model_unsupported",
                    summary: "图片生成模型不能用于通用 Agent",
                    statusLine: connector.modelName,
                    isFailure: true
                )
            ]
        )
    }
}

private struct AnyEncodable: Encodable {
    private let encodeBlock: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        encodeBlock = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBlock(encoder)
    }
}
