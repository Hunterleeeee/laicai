import Foundation
import LaicaiNativeDomain

extension LiveChatRuntime {
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

    static func appendPath(_ suffix: String, to endpoint: String) -> String {
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
                let host = url.host ?? ""
                basePath =
                    (host.localizedCaseInsensitiveContains("deepseek")
                        || host.localizedCaseInsensitiveContains("api.openai.com")) ? "/v1" : ""
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

    static func rootEndpoint(from url: URL, path: String = "") -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = path == "/" ? "" : path
        return components.string ?? "\(url.scheme ?? "http")://\(url.host ?? "127.0.0.1")\(path)"
    }

    static func openAICompatibleBase(from endpoint: String) -> String {
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

    static func normalizedKindValue(_ kind: String) -> String {
        kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedPath(for url: URL) -> String {
        url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    static func isOpenAICompatiblePath(_ path: String) -> Bool {
        path == "v1"
            || path.hasSuffix("/v1")
            || path == "chat/completions"
            || path.hasSuffix("/chat/completions")
    }

    private static let useEnglishErrors: Bool = {
        let lang = Locale.preferredLanguages.first ?? ""
        return !lang.hasPrefix("zh")
    }()

    static func userFacingErrorMessage(statusCode: Int, bodyText: String, connectorName: String) -> String {
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

    static func userFacingErrorMessageEN(statusCode: Int, extracted: String, connectorName: String) -> String {
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
            return
                "Endpoint not found. Check the URL.\nHint: OpenAI-compatible endpoints end with /v1/chat/completions, Ollama with /api/chat."
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

    static func extractServerMessage(from bodyText: String) -> String {
        guard let data = bodyText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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

    static func buildMessages(
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
            messages.append(
                ChatMessage(
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

    static func compactHistory(_ history: [TaskStep]) -> (turns: [(role: String, content: String)], omittedCount: Int) {
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

    static func apiRole(for kind: TaskStepKind) -> String {
        switch kind {
        case .userInput: return "user"
        case .textOutput: return "assistant"
        case .aiThinking: return "assistant"
        case .toolCall, .toolResult, .error, .reviewRequest, .reviewResult: return "assistant"
        }
    }

    static func characterLimit(for kind: TaskStepKind) -> Int {
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

    static func compactHistoryText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let headCount = max(240, Int(Double(limit) * 0.62))
        let tailCount = max(180, limit - headCount - 40)
        let head = trimmed.prefix(headCount)
        let tail = trimmed.suffix(tailCount)
        return "\(head)\n\n[中间历史已压缩]\n\n\(tail)"
    }

    static func requestBody(_ context: RequestBodyContext) -> any Encodable {
        let connector = context.connector
        let outputCap = Self.outputTokenCap(for: connector, requested: context.maxOutputTokens)
        if context.isOllamaNative {
            return OllamaChatRequest(
                model: connector.modelName,
                messages: context.messages,
                stream: context.stream,
                think: false,
                options: .init(numPredict: outputCap, numContext: Self.localContextWindow(for: connector)),
                tools: context.tools,
                keepAlive: "2m"
            )
        }
        if context.isAnthropic {
            return Self.buildAnthropicRequest(
                model: connector.modelName,
                messages: context.messages,
                stream: context.stream,
                tools: context.tools,
                maxTokens: outputCap
            )
        }
        return ChatCompletionRequest(
            model: connector.modelName,
            messages: context.messages,
            maxTokens: outputCap,
            stream: context.stream,
            tools: context.tools
        )
    }

    /// Build an Anthropic Messages API request from OpenAI-style messages.
    /// Extracts system messages into the top-level `system` field and converts
    /// tool definitions to Anthropic's `input_schema` format.
    static func buildAnthropicRequest(
        model: String,
        messages: [ChatMessage],
        stream: Bool,
        tools: [ToolDefinition]?,
        maxTokens: Int
    ) -> AnthropicMessagesRequest {
        var systemParts: [String] = []
        var anthropicMessages: [AnthropicRequestMessage] = []

        for msg in messages {
            appendAnthropicMessage(msg, systemParts: &systemParts, anthropicMessages: &anthropicMessages)
        }

        // Convert tools to Anthropic format
        let anthropicTools: [AnthropicRequestTool]? = tools?.map { tool in
            AnthropicRequestTool(
                name: tool.function.name,
                description: tool.function.description,
                inputSchema: AnyEncodable(tool.function.parameters)
            )
        }

        let systemText = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        return AnthropicMessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: systemText,
            messages: anthropicMessages,
            stream: stream,
            tools: anthropicTools
        )
    }

    static func appendAnthropicMessage(
        _ message: ChatMessage,
        systemParts: inout [String],
        anthropicMessages: inout [AnthropicRequestMessage]
    ) {
        switch message.role {
        case "system":
            if let content = message.effectiveContent {
                systemParts.append(content)
            }
        case "assistant":
            if let converted = anthropicAssistantMessage(from: message) {
                anthropicMessages.append(converted)
            }
        case "tool":
            anthropicMessages.append(anthropicToolMessage(from: message))
        case "user":
            if let converted = anthropicUserMessage(from: message) {
                anthropicMessages.append(converted)
            }
        default:
            return
        }
    }

    static func anthropicAssistantMessage(from message: ChatMessage) -> AnthropicRequestMessage? {
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            var blocks: [AnthropicContentBlock] = []
            if let content = message.effectiveContent, !content.isEmpty {
                blocks.append(.text(content))
            }
            for toolCall in toolCalls {
                blocks.append(
                    .toolUse(
                        id: toolCall.id ?? "",
                        name: toolCall.function.name,
                        inputJSON: toolCall.function.arguments
                    ))
            }
            return .init(role: "assistant", content: AnyEncodable(blocks))
        }
        guard let content = message.effectiveContent else { return nil }
        return .init(role: "assistant", content: AnyEncodable(content))
    }

    static func anthropicToolMessage(from message: ChatMessage) -> AnthropicRequestMessage {
        let resultContent = message.effectiveContent ?? ""
        let blocks: [AnthropicContentBlock] = [
            .toolResult(toolUseId: message.toolCallId ?? "", content: resultContent)
        ]
        return .init(role: "user", content: AnyEncodable(blocks))
    }

    static func anthropicUserMessage(from message: ChatMessage) -> AnthropicRequestMessage? {
        if let contentParts = message.contentParts, !contentParts.isEmpty {
            let blocks = contentParts.compactMap(anthropicContentBlock(from:))
            return .init(role: "user", content: AnyEncodable(blocks))
        }
        guard let content = message.effectiveContent else { return nil }
        return .init(role: "user", content: AnyEncodable(content))
    }

    static func anthropicContentBlock(from part: ContentPart) -> AnthropicContentBlock? {
        if part.type == "text", let text = part.text {
            return .text(text)
        }
        if part.type == "image_url", let imageURL = part.imageURL {
            return .image(url: imageURL.url)
        }
        return nil
    }

    static func outputTokenCap(for connector: ConnectorProfile, requested: Int?) -> Int {
        let fallback = maxOutputTokens(for: connector)
        let value = requested ?? fallback
        if ConnectorCapabilityProfile.isLocalConnector(connector) {
            return max(256, min(value, 4096))
        }
        return max(1024, min(value, 131_072))
    }

    static func maxOutputTokens(for connector: ConnectorProfile) -> Int {
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

    static func localContextWindow(for connector: ConnectorProfile) -> Int {
        ConnectorCapabilityProfile.isLocalConnector(connector) ? 4096 : 8192
    }

    static func buildURLRequest(url: URL, body: any Encodable, apiKey: String, isLocal: Bool = false) -> URLRequest {
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

    static func isOllamaNativeURL(_ url: URL) -> Bool {
        url.path.hasSuffix("/api/chat")
    }

    static func isAnthropicURL(_ url: URL) -> Bool {
        url.path.hasSuffix("/messages") && !url.path.contains("/chat/completions")
    }

    static func metrics(_ context: ResponseMetricsContext) -> ResponseMetrics {
        let startedAt = context.startedAt
        let firstVisibleAt = context.firstVisibleAt
        let usage = context.usage
        let ollama = context.ollama
        let finishedAt = Date()
        let totalDuration = max(0.001, finishedAt.timeIntervalSince(startedAt))
        let inputTokens =
            usage?.promptTokens
            ?? ollama?.promptEvalCount
            ?? estimatedTokens(context.messages.compactMap(\.content).joined(separator: "\n"))
        let outputTokens =
            usage?.completionTokens
            ?? ollama?.evalCount
            ?? estimatedTokens(context.outputText)
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

    static func estimatedTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }

    static func visibleAnswer(from rawText: String) -> String {
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

    static func finalAssistantText(fromVisible visible: String, reasoningContent: String?, fallbackForEmpty: Bool) -> String {
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
    static func extractConclusionFromReasoning(_ reasoning: String) -> String {
        let lines = reasoning.components(separatedBy: .newlines)
        // Look for common conclusion markers from the end
        let markers = ["结论", "总结", "最终", "综上", "因此", "所以", "答案", "建议", "方案"]
        for lineIndex in stride(from: lines.count - 1, through: max(0, lines.count - 40), by: -1) {
            let line = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if markers.contains(where: { line.hasPrefix($0) || line.hasPrefix("# ") && line.contains($0) || line.hasPrefix("## ") }) {
                let conclusion = lines[lineIndex...]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if conclusion.count > 20 { return conclusion }
            }
        }
        return ""
    }

    static func responseStatusLine(finalText: String, reasoningCount: Int) -> String {
        if reasoningCount > 0 && finalText.hasPrefix("模型只返回了思考内容") {
            return "仅收到思考内容"
        }
        if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "空响应"
        }
        return "文本响应"
    }

    static func fallbackResponse(request: SendMessageRequest) -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "未选择连接器。请从顶部选择一个模型开始。",
            toolActivities: [ToolActivity(name: "chat.fallback", summary: "无可用连接器", statusLine: "等待选择连接器", isFailure: true)]
        )
    }

    static func imageOnlyModelResponse(for connector: ConnectorProfile) -> SendMessageResponse? {
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
