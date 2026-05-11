import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

struct LoopingToolRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "我会先搜索项目。",
            toolCalls: [
                FunctionCallResponse(
                    id: "call_search",
                    function: FunctionCallDetail(
                        name: "code.search",
                        arguments: #"{"query":"README","scope":"files","maxResults":5}"#
                    )
                )
            ]
        )
    }
}

struct ProviderErrorRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(
            assistantText: "请求格式不被 qwen 接受，请检查端点、模型名和请求兼容性。\nURL: http://127.0.0.1:11434/api/chat",
            toolActivities: [ToolActivity(name: "chat.error", summary: "qwen 返回 HTTP 400", statusLine: "bad request", isFailure: true)]
        )
    }
}

@MainActor
final class ToolRejectedThenPlainRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if request.tools?.isEmpty == false {
            return SendMessageResponse(
                assistantText: "请求格式不被 qwen 接受，请检查端点、模型名和请求兼容性。\nURL: http://127.0.0.1:11434/api/chat",
                toolActivities: [ToolActivity(name: "chat.error", summary: "qwen 返回 HTTP 400", statusLine: "tool_calls bad request", isFailure: true)]
            )
        }
        return SendMessageResponse(assistantText: "当前连接器暂不兼容工具调用；我已改为无工具模式继续回答。")
    }
}

@MainActor
final class LengthThenContinuationRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(assistantText: "这是一段被供应商截断的回复", finishReason: "length")
        }
        return SendMessageResponse(assistantText: "这是自动续写的第二段。")
    }
}

@MainActor
final class FailingThenCapturingRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []
    var shouldFail = true

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if shouldFail {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
        }
        return SendMessageResponse(assistantText: "完成")
    }
}

@MainActor
final class CapturingToolsRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "完成")
    }
}

@MainActor
final class CapturingContinuationRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "后半段新闻内容")
    }
}

@MainActor
final class RealBrowserToolThenFinalRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "我需要打开真实浏览器。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_real_browser",
                        function: FunctionCallDetail(
                            name: "browser_real",
                            arguments: #"{"action":"open","url":"https://example.com"}"#
                        )
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "真实浏览器操作需要用户显式确认，已停止自动执行。")
    }
}

@MainActor
final class ShellTraversalThenFinalRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "我先列出项目文件。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_shell_find",
                        function: FunctionCallDetail(
                            name: "shell_exec",
                            arguments: #"{"command":"find . -type f"}"#
                        )
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已基于恢复索引继续。")
    }
}

@MainActor
final class EmptyThenFinalRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count <= 2 {
            return SendMessageResponse(assistantText: "")
        }
        return SendMessageResponse(assistantText: "已基于已有材料给出结论。")
    }
}

@MainActor
final class StreamingRuntime: ChatRuntimeClient {
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "你好，世界")
    }

    func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        await onChunk("你好，")
        await onChunk("世界")
        return SendMessageResponse(
            assistantText: "你好，世界",
            metrics: ResponseMetrics(
                thinkingDuration: 0.1,
                totalDuration: 0.2,
                inputTokens: 12,
                outputTokens: 4,
                tokensPerSecond: 20
            )
        )
    }
}

@MainActor
final class HealthRuntime: ChatRuntimeClient {
    let health: ConnectorHealth
    var healthRequests: [(endpoint: String, model: String, apiKey: String, kind: String)] = []

    init(health: ConnectorHealth) {
        self.health = health
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append((endpoint, model, apiKey, kind))
        return health
    }
}

@MainActor
final class ProbeHealthRuntime: ChatRuntimeClient {
    let result: ConnectorProbeResult
    var probeRequests: [(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool)] = []

    init(result: ConnectorProbeResult) {
        self.result = result
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func probeConnector(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool) async throws -> ConnectorProbeResult {
        probeRequests.append((endpoint, model, apiKey, kind, probeToolCalling))
        return ConnectorProbeResult(
            health: result.health,
            toolCallingCapability: probeToolCalling ? result.toolCallingCapability : nil
        )
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        result.health
    }
}

@MainActor
final class PausedHealthRuntime: ChatRuntimeClient {
    var healthRequests: [(endpoint: String, model: String, apiKey: String, kind: String)] = []
    private var continuations: [CheckedContinuation<ConnectorHealth, Error>] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append((endpoint, model, apiKey, kind))
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolveNext(with health: ConnectorHealth) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: health)
    }
}

@MainActor
final class CapturingReasoningRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "",
                reasoningContent: "先读取文件。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_read",
                        function: FunctionCallDetail(name: "file_read", arguments: #"{"path":"README.md"}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "README 内容是 hello。")
    }
}

@MainActor
final class CapturingOllamaRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_read",
                        function: FunctionCallDetail(name: "file_read", arguments: #"{"path":"README.md"}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "README 内容是 hello。")
    }
}
