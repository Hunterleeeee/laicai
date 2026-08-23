import Foundation
import LaicaiNativeDomain

// MARK: - Live Chat Runtime

public struct LiveChatRuntime: ChatRuntimeClient {
    static let historyTurnLimit = 40

    private struct ProbeConnectorRequest {
        let endpoint: String
        let model: String
        let apiKey: String
        let kind: String
        let probeToolCalling: Bool
    }
    static let historyCharacterBudget = 60_000
    private static let probeMessages = [
        ChatMessage(role: "system", content: "你正在执行连接器兼容性自检。直接输出 ok。"),
        ChatMessage(role: "user", content: "请直接回复 ok。"),
    ]
    /// Probe tools mimic real production tools (string params, required fields, JSON schema)
    /// so we don't false-positive on servers that accept trivial empty-params tools but reject
    /// realistic schemas.
    private static let probeToolDefinitions: [ToolDefinition] = {
        let pathParam = FunctionParameters(
            type: "object",
            properties: [
                "path": .init(type: "string", description: "Absolute file path"),
                "encoding": .init(type: "string", description: "Optional encoding, e.g. utf-8"),
            ],
            required: ["path"]
        )
        let queryParam = FunctionParameters(
            type: "object",
            properties: [
                "query": .init(type: "string", description: "Search keyword"),
                "limit": .init(type: "string", description: "Optional max results"),
            ],
            required: ["query"]
        )
        return [
            ToolDefinition(
                function: FunctionDefinition(
                    name: "connector_probe_read",
                    description: "Probe: representative file read tool with required path parameter.",
                    parameters: pathParam
                )),
            ToolDefinition(
                function: FunctionDefinition(
                    name: "connector_probe_search",
                    description: "Probe: representative search tool with required query parameter.",
                    parameters: queryParam
                )),
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
                RequestBodyContext(
                    connector: connector,
                    messages: messages,
                    stream: false,
                    tools: request.tools,
                    maxOutputTokens: request.maxOutputTokens,
                    isOllamaNative: isOllamaNative,
                    isAnthropic: isAnthropic
                )),
            apiKey: connector.note,
            isLocal: isOllamaNative
        )

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard (200...299).contains(statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? "empty"
                let message = Self.userFacingErrorMessage(
                    statusCode: statusCode,
                    bodyText: bodyText,
                    connectorName: connector.name
                )
                let urlHint = "URL: \(url.absoluteString)"
                let activity = ToolActivity(
                    name: "chat.error",
                    summary: "\(connector.name) 返回 HTTP \(statusCode)",
                    statusLine: "\(urlHint) · \(bodyText.prefix(80))",
                    isFailure: true
                )
                return SendMessageResponse(
                    assistantText: "\(message)\n\(urlHint)",
                    toolActivities: [activity]
                )
            }

            let text: String
            let reasoningContent: String?
            let toolCalls: [FunctionCallResponse]
            let finishReason: String?
            let metrics: ResponseMetrics
            if isAnthropic {
                let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
                var contentText = ""
                var thinkingText = ""
                var parsedToolCalls: [FunctionCallResponse] = []
                for block in decoded.content ?? [] {
                    if block.type == "text", let textBlock = block.text {
                        contentText += textBlock
                    } else if block.type == "thinking", let thinkingBlock = block.thinking {
                        thinkingText += thinkingBlock
                    } else if block.type == "tool_use", let id = block.id, let name = block.name {
                        let argsJSON = block.input?.jsonString ?? "{}"
                        parsedToolCalls.append(
                            FunctionCallResponse(
                                id: id, type: "function",
                                function: FunctionCallDetail(name: name, arguments: argsJSON)
                            ))
                    }
                }
                reasoningContent = thinkingText.isEmpty ? nil : thinkingText
                text = Self.finalAssistantText(fromVisible: contentText, reasoningContent: nil, fallbackForEmpty: false)
                toolCalls = parsedToolCalls
                finishReason = decoded.stopReason
                let inputTokens = decoded.usage?.inputTokens
                let outputTokens = decoded.usage?.outputTokens
                metrics = ResponseMetrics(
                    thinkingDuration: 0,
                    totalDuration: max(0.001, Date().timeIntervalSince(startedAt)),
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    tokensPerSecond: 0
                )
            } else if isOllamaNative,
                let ollama = try? JSONDecoder().decode(OllamaChatChunk.self, from: data)
            {
                reasoningContent = ollama.message?.thinking
                text = Self.finalAssistantText(
                    fromVisible: Self.visibleAnswer(from: ollama.message?.content ?? ""),
                    reasoningContent: reasoningContent,
                    fallbackForEmpty: false
                )
                toolCalls = ollama.message?.toolCalls ?? []
                finishReason = nil
                metrics = Self.metrics(
                    ResponseMetricsContext(
                        startedAt: startedAt,
                        firstVisibleAt: nil,
                        messages: messages,
                        outputText: text,
                        usage: nil,
                        ollama: ollama
                    ))
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
                    ResponseMetricsContext(
                        startedAt: startedAt,
                        firstVisibleAt: nil,
                        messages: messages,
                        outputText: text,
                        usage: decoded.usage,
                        ollama: nil
                    ))
            }

            return SendMessageResponse(
                assistantText: text,
                reasoningContent: reasoningContent,
                toolCalls: toolCalls,
                finishReason: finishReason,
                toolActivities: [
                    ToolActivity(
                        name: "chat.complete",
                        summary: "收到 \(connector.name) 的响应",
                        statusLine: toolCalls.isEmpty ? "文本响应" : "\(toolCalls.count) 个工具调用",
                        isFailure: false
                    )
                ],
                metrics: metrics
            )
        } catch {
            throw Self.connectorRequestError(connector: connector, error: error)
        }
    }

    public func sendMessageStream(
        _ request: SendMessageRequest,
        onChunk: @escaping @Sendable @MainActor (String) -> Void,
        onReasoningChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async throws -> SendMessageResponse {
        return try await sendMessageStreamImpl(request, onChunk: onChunk, onReasoningChunk: onReasoningChunk)
    }

    public func sendMessageStream(
        _ request: SendMessageRequest,
        onChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async throws -> SendMessageResponse {
        return try await sendMessageStreamImpl(request, onChunk: onChunk, onReasoningChunk: nil)
    }

    private func sendMessageStreamImpl(
        _ request: SendMessageRequest,
        onChunk: @escaping @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async throws -> SendMessageResponse {
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
                RequestBodyContext(
                    connector: connector,
                    messages: messages,
                    stream: true,
                    tools: request.tools,
                    maxOutputTokens: request.maxOutputTokens,
                    isOllamaNative: isOllamaNative,
                    isAnthropic: isAnthropic
                )),
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
            let message = Self.userFacingErrorMessage(
                statusCode: statusCode,
                bodyText: errorBody,
                connectorName: connector.name
            )
            let urlHint = "URL: \(url.absoluteString)"
            let activity = ToolActivity(
                name: "chat.error",
                summary: "\(connector.name) 返回 HTTP \(statusCode)",
                statusLine: "\(urlHint) · \(errorBody.prefix(80))",
                isFailure: true
            )
            return SendMessageResponse(
                assistantText: "\(message)\n\(urlHint)",
                toolActivities: [activity]
            )
        }

        var streamState = StreamDecodeState()
        let decoder = JSONDecoder()
        let streamProvider = Self.streamProvider(isAnthropic: isAnthropic, isOllamaNative: isOllamaNative)

        do {
            for try await line in bytes.lines {
                let didFinish = await Self.decodeStreamLine(
                    request: StreamLineDecodeRequest(
                        line: line,
                        provider: streamProvider,
                        decoder: decoder
                    ),
                    state: &streamState,
                    onChunk: onChunk,
                    onReasoningChunk: onReasoningChunk
                )
                if didFinish {
                    break
                }
            }
        } catch {
            throw Self.connectorRequestError(connector: connector, error: error)
        }

        if let batch = streamState.flushPending() {
            await onChunk(batch)
        }

        let toolCalls = streamState.finalToolCalls()

        let finalText = Self.finalAssistantText(
            fromVisible: streamState.visibleText,
            reasoningContent: streamState.reasoningContent,
            fallbackForEmpty: false
        )
        let metrics = Self.metrics(
            ResponseMetricsContext(
                startedAt: startedAt,
                firstVisibleAt: streamState.firstVisibleAt,
                messages: messages,
                outputText: finalText,
                usage: streamState.usage,
                ollama: streamState.finalOllamaChunk
            ))

        let activity = ToolActivity(
            name: "chat.complete",
            summary: "流式收到 \(connector.name) 的响应",
            statusLine: toolCalls.isEmpty
                ? Self.responseStatusLine(finalText: finalText, reasoningCount: streamState.reasoningCount)
                : "\(toolCalls.count) 个工具调用",
            isFailure: false
        )
        return SendMessageResponse(
            assistantText: finalText,
            reasoningContent: streamState.reasoningContent,
            toolCalls: toolCalls,
            finishReason: streamState.finishReason,
            toolActivities: [activity],
            metrics: metrics
        )
    }

    private static func connectorRequestError(connector: ConnectorProfile, error: Error) -> LiveChatConnectorRequestError {
        if let connectorError = error as? LiveChatConnectorRequestError {
            return connectorError
        }
        return LiveChatConnectorRequestError(connectorName: connector.name, message: error.localizedDescription)
    }

    public func healthCheck(endpoint: String, model: String, apiKey: String, kind: String = "openai-compatible") async throws
        -> ConnectorHealth
    {
        try await probeConnector(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind, probeToolCalling: false).health
    }

    public func probeConnector(
        endpoint: String,
        model: String,
        apiKey: String,
        kind: String = "openai-compatible",
        probeToolCalling: Bool = true
    ) async throws -> ConnectorProbeResult {
        let probeRequest = ProbeConnectorRequest(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            kind: kind,
            probeToolCalling: probeToolCalling
        )
        let base = Self.serviceBaseEndpoint(from: Self.baseEndpoint(from: endpoint))
        let isOllama = Self.usesOllamaNativeProtocol(endpoint: endpoint, kind: kind)
        if Self.usesAnthropicProtocol(endpoint: endpoint, kind: kind) {
            return try await anthropicConnectorProbe(probeRequest)
        }
        guard let url = Self.modelListURL(base: base, isOllama: isOllama) else {
            return ConnectorProbeResult(health: .offline)
        }

        do {
            let request = Self.modelListRequest(url: url, apiKey: apiKey, isOllama: isOllama)
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                return ConnectorProbeResult(health: .attention)
            }
            let ctxWindow = await contextWindowProbe(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind)
            let health = Self.modelListHealth(data: data, model: model, isOllama: isOllama) ?? .attention
            return try await connectorProbeResult(for: probeRequest, health: health, contextWindow: ctxWindow)
        } catch {
            return ConnectorProbeResult(health: .offline)
        }
    }

    private func anthropicConnectorProbe(_ request: ProbeConnectorRequest) async throws -> ConnectorProbeResult {
        let health = await anthropicHealthProbe(
            endpoint: request.endpoint,
            model: request.model,
            apiKey: request.apiKey,
            kind: request.kind
        )
        let ctx = await contextWindowProbe(
            endpoint: request.endpoint,
            model: request.model,
            apiKey: request.apiKey,
            kind: request.kind
        )
        return try await connectorProbeResult(for: request, health: health, contextWindow: ctx)
    }

    private static func modelListURL(base: String, isOllama: Bool) -> URL? {
        let urlString: String
        if isOllama {
            let ollamaBase = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            let cleanBase = ollamaBase.hasSuffix("/api") ? String(ollamaBase.dropLast(4)) : ollamaBase
            urlString = cleanBase.hasSuffix("/api/tags") ? cleanBase : cleanBase + "/api/tags"
        } else {
            let apiBase = Self.openAICompatibleBase(from: base)
            urlString = apiBase.hasSuffix("/models") ? apiBase : apiBase + "/models"
        }
        return URL(string: urlString)
    }

    private static func modelListRequest(url: URL, apiKey: String, isOllama: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty && !isOllama {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = NetworkDefaults.modelList
        return request
    }

    private static func modelListHealth(data: Data, model: String, isOllama: Bool) -> ConnectorHealth? {
        let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else { return .ready }
        return isOllama
            ? ollamaModelListHealth(data: data, requestedModel: requestedModel)
            : openAIModelListHealth(data: data, requestedModel: requestedModel)
    }

    private static func ollamaModelListHealth(data: Data, requestedModel: String) -> ConnectorHealth? {
        guard let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else { return nil }
        let exists = tags.models.contains { $0.name == requestedModel || $0.model == requestedModel }
        return exists ? .ready : .attention
    }

    private static func openAIModelListHealth(data: Data, requestedModel: String) -> ConnectorHealth {
        guard let models = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data), !models.data.isEmpty else {
            return .ready
        }
        let exists = models.data.contains {
            $0.id?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(requestedModel) == .orderedSame
        }
        return exists ? .ready : .attention
    }

    private func connectorProbeResult(
        for request: ProbeConnectorRequest,
        health: ConnectorHealth,
        contextWindow: Int?
    ) async throws -> ConnectorProbeResult {
        guard request.probeToolCalling, health == .ready else {
            return ConnectorProbeResult(health: health, contextWindow: contextWindow)
        }
        let capability = try await toolCallingCapabilityProbe(
            endpoint: request.endpoint,
            model: request.model,
            apiKey: request.apiKey,
            kind: request.kind
        )
        return ConnectorProbeResult(health: health, toolCallingCapability: capability, contextWindow: contextWindow)
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
                options: .init(numPredict: 1, numContext: Self.localContextWindow(for: connector)),
                tools: Self.probeToolDefinitions,
                keepAlive: "30s"
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
                maxTokens: 1,
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
            if (400...499).contains(statusCode)
                && (statusCode == 400
                    || statusCode == 422
                    || detail.contains("tool")
                    || detail.contains("function")
                    || detail.contains("兼容"))
            {
                return .unsupported
            }
            return nil
        } catch {
            return nil
        }
    }

    private func anthropicHealthProbe(endpoint: String, model: String, apiKey: String, kind: String) async -> ConnectorHealth {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .attention }
        let url = Self.buildURL(from: endpoint, kind: kind)
        let body = Self.buildAnthropicRequest(
            model: model,
            messages: Self.probeMessages,
            stream: false,
            tools: nil,
            maxTokens: 1
        )
        var request = Self.buildURLRequest(url: url, body: body, apiKey: apiKey, isLocal: false)
        request.timeoutInterval = NetworkDefaults.quickProbe
        do {
            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) { return .ready }
            if statusCode == 401 || statusCode == 403 { return .attention }
            return .offline
        } catch {
            return .offline
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
            return await ollamaContextWindow(base: base, model: model)
        }
        if isAnthropic {
            return Self.anthropicContextWindow(model: model)
        }
        return await openAIContextWindow(base: base, model: model, apiKey: apiKey)
    }

    private func ollamaContextWindow(base: String, model: String) async -> Int? {
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

        guard let json = await modelInfoJSON(for: request),
            let modelInfo = json["model_info"] as? [String: Any]
        else {
            return nil
        }
        if let contextLength = Self.ollamaModelInfoContextWindow(modelInfo) {
            return contextLength
        }
        return Self.ollamaParameterContextWindow(json["parameters"] as? String)
    }

    private static func anthropicContextWindow(model: String) -> Int {
        // Anthropic: no model info API; use known context windows
        let lowercasedModel = model.lowercased()
        if lowercasedModel.contains("claude-4") || lowercasedModel.contains("claude-3.7") {
            return 1_000_000
        }
        if lowercasedModel.contains("claude-3-5") || lowercasedModel.contains("claude-3.5") {
            return 200_000
        }
        if lowercasedModel.contains("claude-3") { return 200_000 }
        return 200_000
    }

    private func openAIContextWindow(base: String, model: String, apiKey: String) async -> Int? {
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
        guard let json = await modelInfoJSON(for: request) else { return nil }
        return Self.openAIContextWindow(from: json)
    }

    private func modelInfoJSON(for request: URLRequest) async -> [String: Any]? {
        guard let (data, response) = try? await session.data(for: request),
            let statusCode = (response as? HTTPURLResponse)?.statusCode,
            (200...299).contains(statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func ollamaModelInfoContextWindow(_ modelInfo: [String: Any]) -> Int? {
        // Ollama reports context length as "general.context_length" key
        for (key, value) in modelInfo where key.hasSuffix(".context_length") {
            if let contextLength = value as? Int { return contextLength }
        }
        return nil
    }

    private static func ollamaParameterContextWindow(_ parameters: String?) -> Int? {
        guard let parameters else { return nil }
        for line in parameters.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0] == "num_ctx", let contextLength = Int(parts[1]) {
                return contextLength
            }
        }
        return nil
    }

    private static func openAIContextWindow(from json: [String: Any]) -> Int? {
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

    private enum StreamProvider {
        case anthropic
        case ollamaNative
        case openAICompatible
    }

    private struct StreamDecodeState {
        var rawText = ""
        var visibleText = ""
        var reasoningText = ""
        var reasoningCount = 0
        var accumulatedToolCalls: [Int: AccumulatedToolCall] = [:]
        var finishReason: String?
        var usage: TokenUsage?
        var finalOllamaChunk: OllamaChatChunk?
        var firstVisibleAt: Date?
        var anthropicCurrentToolIndex = 0

        private var pendingDelta = ""
        private var lastChunkAt = CFAbsoluteTimeGetCurrent()
        private let chunkFlushThreshold = 240
        private let chunkFlushInterval = 0.35

        var reasoningContent: String? {
            reasoningText.isEmpty ? nil : reasoningText
        }

        mutating func appendAnthropicVisibleText(_ text: String) -> String? {
            rawText += text
            return appendVisible(rawText)
        }

        mutating func appendVisibleRawText(_ text: String) -> String? {
            rawText += text
            return appendVisible(LiveChatRuntime.visibleAnswer(from: rawText))
        }

        mutating func appendReasoning(_ text: String) {
            reasoningText += text
            reasoningCount += text.count
        }

        mutating func startAnthropicToolUse(_ event: AnthropicStreamEvent) {
            guard event.contentBlock?.type == "tool_use" else { return }
            let toolIndex = event.index ?? anthropicCurrentToolIndex
            accumulatedToolCalls[toolIndex] = AccumulatedToolCall(
                id: event.contentBlock?.id ?? "call_\(toolIndex)",
                name: event.contentBlock?.name ?? "",
                arguments: ""
            )
            anthropicCurrentToolIndex = toolIndex + 1
        }

        mutating func appendAnthropicToolArguments(index: Int?, partial: String) {
            let toolIndex = (index ?? anthropicCurrentToolIndex) - 1
            guard var toolCall = accumulatedToolCalls[toolIndex] else { return }
            toolCall.arguments += partial
            accumulatedToolCalls[toolIndex] = toolCall
        }

        mutating func appendOllamaToolCalls(_ toolCalls: [FunctionCallResponse]) {
            for (offset, toolCall) in toolCalls.enumerated() {
                let toolIndex = accumulatedToolCalls.count + offset
                accumulatedToolCalls[toolIndex] = AccumulatedToolCall(
                    id: toolCall.id ?? "call_ollama_\(toolIndex)",
                    name: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
            }
        }

        mutating func appendOpenAIToolDeltas(_ toolCalls: [StreamingToolCall]) {
            for toolCall in toolCalls {
                let toolIndex = toolCall.index ?? 0
                var accumulated = accumulatedToolCalls[toolIndex] ?? AccumulatedToolCall()
                if let id = toolCall.id { accumulated.id = id }
                if let name = toolCall.function?.name { accumulated.name = name }
                if let arguments = toolCall.function?.arguments { accumulated.arguments += arguments }
                accumulatedToolCalls[toolIndex] = accumulated
            }
        }

        mutating func finalToolCalls() -> [FunctionCallResponse] {
            accumulatedToolCalls
                .sorted { $0.key < $1.key }
                .compactMap { _, accumulated -> FunctionCallResponse? in
                    guard !accumulated.name.isEmpty else { return nil }
                    return FunctionCallResponse(
                        id: accumulated.id,
                        type: "function",
                        function: FunctionCallDetail(name: accumulated.name, arguments: accumulated.arguments)
                    )
                }
        }

        mutating func flushPending() -> String? {
            guard !pendingDelta.isEmpty else { return nil }
            let batch = pendingDelta
            pendingDelta = ""
            lastChunkAt = CFAbsoluteTimeGetCurrent()
            return batch
        }

        private mutating func appendVisible(_ nextVisible: String) -> String? {
            // count and dropFirst both use grapheme clusters, keeping emoji
            // and composed characters intact at chunk boundaries.
            guard nextVisible.count > visibleText.count else { return nil }
            let visibleDelta = String(nextVisible.dropFirst(visibleText.count))
            visibleText = nextVisible
            if firstVisibleAt == nil { firstVisibleAt = Date() }
            pendingDelta += visibleDelta
            return flushIfNeeded()
        }

        private mutating func flushIfNeeded() -> String? {
            let now = CFAbsoluteTimeGetCurrent()
            let shouldFlush =
                pendingDelta.count >= chunkFlushThreshold
                || (now - lastChunkAt) >= chunkFlushInterval
            return shouldFlush ? flushPending() : nil
        }
    }

    private static func streamProvider(isAnthropic: Bool, isOllamaNative: Bool) -> StreamProvider {
        if isAnthropic { return .anthropic }
        if isOllamaNative { return .ollamaNative }
        return .openAICompatible
    }

    private struct StreamLineDecodeRequest {
        let line: String
        let provider: StreamProvider
        let decoder: JSONDecoder
    }

    struct RequestBodyContext {
        let connector: ConnectorProfile
        let messages: [ChatMessage]
        let stream: Bool
        let tools: [ToolDefinition]?
        let maxOutputTokens: Int?
        let isOllamaNative: Bool
        let isAnthropic: Bool
    }

    struct ResponseMetricsContext {
        let startedAt: Date
        let firstVisibleAt: Date?
        let messages: [ChatMessage]
        let outputText: String
        let usage: TokenUsage?
        let ollama: OllamaChatChunk?
    }

    private static func decodeStreamLine(
        request: StreamLineDecodeRequest,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> Bool {
        switch request.provider {
        case .anthropic:
            return await decodeAnthropicStreamLine(
                request.line,
                decoder: request.decoder,
                state: &state,
                onChunk: onChunk,
                onReasoningChunk: onReasoningChunk
            )
        case .ollamaNative:
            await decodeOllamaStreamLine(
                request.line,
                decoder: request.decoder,
                state: &state,
                onChunk: onChunk,
                onReasoningChunk: onReasoningChunk
            )
            return false
        case .openAICompatible:
            return await decodeOpenAIStreamLine(
                request.line,
                decoder: request.decoder,
                state: &state,
                onChunk: onChunk,
                onReasoningChunk: onReasoningChunk
            )
        }
    }

    private static func decodeAnthropicStreamLine(
        _ line: String,
        decoder: JSONDecoder,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> Bool {
        guard line.hasPrefix("data: ") else { return false }
        let jsonString = String(line.dropFirst(6))
        guard let data = jsonString.data(using: .utf8),
            let event = try? decoder.decode(AnthropicStreamEvent.self, from: data)
        else { return false }
        await handleAnthropicStreamEvent(
            event,
            state: &state,
            onChunk: onChunk,
            onReasoningChunk: onReasoningChunk
        )
        return false
    }

    private static func handleAnthropicStreamEvent(
        _ event: AnthropicStreamEvent,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async {
        switch event.type {
        case "content_block_start":
            state.startAnthropicToolUse(event)
        case "content_block_delta":
            await handleAnthropicDelta(event, state: &state, onChunk: onChunk, onReasoningChunk: onReasoningChunk)
        case "message_delta":
            updateAnthropicMessageDelta(event, state: &state)
        default:
            break
        }
    }

    private static func handleAnthropicDelta(
        _ event: AnthropicStreamEvent,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async {
        if event.delta?.type == "text_delta", let text = event.delta?.text {
            if let batch = state.appendAnthropicVisibleText(text) { await onChunk(batch) }
        } else if event.delta?.type == "thinking_delta", let thinking = event.delta?.thinking {
            state.appendReasoning(thinking)
            if let onReasoningChunk { await onReasoningChunk(thinking) }
        } else if event.delta?.type == "input_json_delta", let partial = event.delta?.partialJSON {
            state.appendAnthropicToolArguments(index: event.index, partial: partial)
        }
    }

    private static func updateAnthropicMessageDelta(
        _ event: AnthropicStreamEvent,
        state: inout StreamDecodeState
    ) {
        if let stopReason = event.delta?.stopReason {
            state.finishReason = stopReason
        }
        if let usageEvent = event.usage {
            state.usage = TokenUsage(
                promptTokens: usageEvent.inputTokens,
                completionTokens: usageEvent.outputTokens,
                totalTokens: nil
            )
        }
    }

    private static func decodeOllamaStreamLine(
        _ line: String,
        decoder: JSONDecoder,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async {
        guard let data = line.data(using: .utf8),
            let chunk = try? decoder.decode(OllamaChatChunk.self, from: data)
        else { return }
        if chunk.done == true {
            state.finalOllamaChunk = chunk
        }
        if let thinking = chunk.message?.thinking {
            state.appendReasoning(thinking)
            if let onReasoningChunk { await onReasoningChunk(thinking) }
        }
        if let toolCalls = chunk.message?.toolCalls {
            state.appendOllamaToolCalls(toolCalls)
        }
        if let content = chunk.message?.content,
            let batch = state.appendVisibleRawText(content)
        {
            await onChunk(batch)
        }
    }

    private static func decodeOpenAIStreamLine(
        _ line: String,
        decoder: JSONDecoder,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async -> Bool {
        guard line.hasPrefix("data: ") else { return false }
        let jsonString = String(line.dropFirst(6))
        if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" { return true }
        guard let data = jsonString.data(using: .utf8),
            let chunk = try? decoder.decode(StreamChunk.self, from: data)
        else { return false }
        await handleOpenAIStreamChunk(
            chunk,
            state: &state,
            onChunk: onChunk,
            onReasoningChunk: onReasoningChunk
        )
        return false
    }

    private static func handleOpenAIStreamChunk(
        _ chunk: StreamChunk,
        state: inout StreamDecodeState,
        onChunk: @Sendable @MainActor (String) -> Void,
        onReasoningChunk: (@Sendable @MainActor (String) -> Void)?
    ) async {
        if let chunkUsage = chunk.usage {
            state.usage = chunkUsage
        }
        if let reasoning = chunk.choices.first?.delta.reasoningContent ?? chunk.choices.first?.delta.reasoning {
            state.appendReasoning(reasoning)
            if let onReasoningChunk { await onReasoningChunk(reasoning) }
        }
        if let delta = chunk.choices.first?.delta.content,
            let batch = state.appendVisibleRawText(delta)
        {
            await onChunk(batch)
        }
        if let toolCallDeltas = chunk.choices.first?.delta.toolCalls {
            state.appendOpenAIToolDeltas(toolCallDeltas)
        }
        if let responseFinishReason = chunk.choices.first?.finishReason {
            state.finishReason = responseFinishReason
        }
    }
}
