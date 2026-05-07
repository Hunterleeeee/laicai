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
    private static let historyTurnLimit = 40
    private static let historyCharacterBudget = 60_000
    private static let probeMessages = [
        ChatMessage(role: "system", content: "你正在执行连接器兼容性自检。直接输出 ok。"),
        ChatMessage(role: "user", content: "请直接回复 ok。")
    ]
    private static let probeToolDefinitions = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "connector_probe_noop",
                description: "Connector compatibility probe. Do not call unless tool calling is supported.",
                parameters: FunctionParameters()
            )
        )
    ]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        guard let connector = request.connector else {
            return Self.fallbackResponse(request: request)
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
        let urlRequest = Self.buildURLRequest(
            url: url,
            body: Self.requestBody(
                connector: connector,
                messages: messages,
                stream: false,
                tools: request.tools,
                maxOutputTokens: request.maxOutputTokens,
                isOllamaNative: isOllamaNative
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
            if isOllamaNative,
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
            return SendMessageResponse(
                assistantText: "无法连接 \(connector.name)：\(error.localizedDescription)",
                toolActivities: [ToolActivity(name: "chat.error", summary: "连接 \(connector.name) 网络错误", statusLine: error.localizedDescription, isFailure: true)]
            )
        }
    }

    public func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        guard let connector = request.connector else {
            return Self.fallbackResponse(request: request)
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
        let urlRequest = Self.buildURLRequest(
            url: url,
            body: Self.requestBody(
                connector: connector,
                messages: messages,
                stream: true,
                tools: request.tools,
                maxOutputTokens: request.maxOutputTokens,
                isOllamaNative: isOllamaNative
            ),
            apiKey: connector.note,
            isLocal: isOllamaNative
        )

        let (bytes, response) = try await session.bytes(for: urlRequest)
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
        let chunkFlushThreshold = 80  // chars
        let chunkFlushInterval = 0.15 // seconds

        for try await line in bytes.lines {
            if isOllamaNative {
                // Ollama native NDJSON (no tool calling support in native format)
                guard let data = line.data(using: .utf8) else { continue }
                if let ollamaChunk = try? decoder.decode(OllamaChatChunk.self, from: data) {
                    if ollamaChunk.done == true {
                        finalOllamaChunk = ollamaChunk
                    }
                    if let thinking = ollamaChunk.message?.thinking {
                        reasoningCount += thinking.count
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
                            // H6: batch deltas
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
                    }
                    if let delta = chunk.choices.first?.delta.content {
                        rawText += delta
                        let nextVisible = Self.visibleAnswer(from: rawText)
                        if nextVisible.count > visibleText.count {
                            let visibleDelta = String(nextVisible.dropFirst(visibleText.count))
                            visibleText = nextVisible
                            if firstVisibleAt == nil { firstVisibleAt = Date() }
                            // H6: batch deltas
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
            let health: ConnectorHealth
            if isOllama {
                let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !requestedModel.isEmpty else {
                    health = .ready
                    if !probeToolCalling {
                        return ConnectorProbeResult(health: health)
                    }
                    let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
                    return ConnectorProbeResult(health: health, toolCallingCapability: capability)
                }
                guard let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
                    return ConnectorProbeResult(health: .attention)
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
                        return ConnectorProbeResult(health: health)
                    }
                    let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
                    return ConnectorProbeResult(health: health, toolCallingCapability: capability)
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
                return ConnectorProbeResult(health: health)
            }
            let capability = try await toolCallingCapabilityProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            return ConnectorProbeResult(health: health, toolCallingCapability: capability)
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

    // MARK: - Helpers

    private struct AccumulatedToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    static func buildURL(from endpoint: String, kind: String = "openai-compatible") -> URL {
        let cleaned = normalizedEndpoint(endpoint, kind: kind)
        return URL(string: cleaned) ?? URL(string: "http://127.0.0.1/invalid-endpoint")!
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
        if cleaned.hasSuffix("/chat/completions") {
            return String(cleaned.dropLast(17))
        }
        if cleaned.hasSuffix("/api/chat") {
            return String(cleaned.dropLast(9))
        }
        return cleaned
    }

    private static func openAICompatibleBase(from endpoint: String) -> String {
        endpoint
    }

    public static func normalizedConnectorKind(_ kind: String, endpoint: String) -> String {
        usesOllamaNativeProtocol(endpoint: endpoint, kind: kind) ? "ollama" : "openai-compatible"
    }

    public static func usesOllamaNativeProtocol(endpoint: String, kind: String) -> Bool {
        let cleaned = baseEndpoint(from: endpoint)
        guard let url = URL(string: cleaned) else {
            return normalizedKindValue(kind) == "ollama"
        }
        let path = normalizedPath(for: url)
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""

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

    private static func userFacingErrorMessage(statusCode: Int, bodyText: String, connectorName: String) -> String {
        let extracted = extractServerMessage(from: bodyText)
        switch statusCode {
        case 400:
            return extracted.isEmpty
                ? "请求格式不被 \(connectorName) 接受，请检查端点、模型名和请求兼容性。"
                : "请求格式不被 \(connectorName) 接受：\(extracted)"
        case 401:
            return "鉴权失败，请检查 API 密钥是否正确。"
        case 403:
            return "请求被拒绝，请检查当前密钥或服务权限。"
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
        isOllamaNative: Bool
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
        return ChatCompletionRequest(
            model: connector.modelName,
            messages: messages,
            max_tokens: outputCap,
            stream: stream,
            tools: tools
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
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(AnyEncodable(body))
        request.timeoutInterval = isLocal ? NetworkDefaults.localChat : NetworkDefaults.remoteChat
        return request
    }

    private static func isOllamaNativeURL(_ url: URL) -> Bool {
        url.path.hasSuffix("/api/chat")
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
