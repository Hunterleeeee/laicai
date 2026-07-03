import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

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
final class BlockingMessageRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []
    private var continuations: [CheckedContinuation<SendMessageResponse, Error>] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAll()
            }
        }
    }

    func resumeAll(_ response: SendMessageResponse = SendMessageResponse(assistantText: "完成")) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: response) }
    }

    func cancelAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class WikiBuildWhenAvailableRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        let hasWikiBuild =
            request.tools?.contains {
                ToolNameCodec.canonicalName($0.function.name) == "wiki.build"
            } == true
        if hasWikiBuild && requests.count == 1 {
            return SendMessageResponse(
                assistantText: "我会把已有输出沉淀到 Wiki。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_wiki_save",
                        function: FunctionCallDetail(
                            name: "wiki_build",
                            arguments:
                                #"{"topic":"Vibe Coding 安全检查清单","mode":"atomic","save":true,"sourceTitle":"已整理输出","# +
                                #""sourceText":"根据上一轮已读取的文章整理出的 Vibe Coding 产品上线安全检查清单。"}"#
                        )
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已沉淀到 Wiki。")
    }
}

@MainActor
final class WikiPlanOnlyRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(
            assistantText: """
                同意，建议沉淀成一篇 Wiki，定位为：

                ```text
                docs/wiki/vibe-coding-security-checklist.md
                ```

                标题可以叫：
                # Vibe Coding 产品上线安全检查清单
                """
        )
    }
}

/// Runtime that produces tool call evidence for tests requiring task completion.
@MainActor
final class EvidenceProducingRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "完成",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_evidence_\(requests.count)",
                        function: FunctionCallDetail(name: "file.read", arguments: #"{"path":"README.md"}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已基于读取的文件完成任务。")
    }
}

@MainActor
final class InlineCommandJSONRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(
            assistantText:
                #"我先查看一下当前工作区，了解需要修改/生成什么文件。{"cmd":"ls -la /tmp/laicai-pptx-smoke && find . "# +
                    #"-maxdepth 2 -type f","cwd":"/tmp/laicai-pptx-smoke","max_output_tokens":12000}可以整理成一段给 Gemini 的完整提示词。"#
        )
    }
}

@MainActor
final class FakeToolCallBlockThenToolRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText:
                    "我先查看目录。\n\n<|tool_call|>\n```json\n{\n  \"name\": \"list_directory\",\n"
                        + "  \"arguments\": {\"path\": \"/var/folders/aa/bb/T/demo\"}\n}\n```\n</|tool_call|>",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_index",
                        function: FunctionCallDetail(name: "workspace_index", arguments: #"{}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已完成。")
    }
}

@MainActor
final class UIInspectThenFinalRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(
                assistantText: "我先检查页面并截图。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_browser_screenshot",
                        function: FunctionCallDetail(
                            name: "browser",
                            arguments: #"{"action":"screenshot"}"#
                        )
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已根据页面截图完成 UI 检查。")
    }
}

@MainActor
final class PlainThenToolRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        if requests.count == 1 {
            return SendMessageResponse(assistantText: "这个项目主要问题可能是渲染和状态更新导致卡顿。")
        }
        if requests.count == 2 {
            return SendMessageResponse(
                assistantText: "我先读取项目索引。",
                toolCalls: [
                    FunctionCallResponse(
                        id: "call_index",
                        function: FunctionCallDetail(name: "workspace_index", arguments: #"{}"#)
                    )
                ]
            )
        }
        return SendMessageResponse(assistantText: "已基于项目索引给出下一步。")
    }
}

@MainActor
final class PlanningOnlyRuntime: ChatRuntimeClient {
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "我会先分析目标，然后继续处理。")
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
    var requests: [SendMessageRequest] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        requests.append(request)
        return SendMessageResponse(assistantText: "你好，世界")
    }

    func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws -> SendMessageResponse {
        requests.append(request)
        onChunk("你好，")
        onChunk("世界")
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

struct HealthCheckRequest {
    let endpoint: String
    let model: String
    let apiKey: String
    let kind: String
}

struct ConnectorProbeRequest {
    let endpoint: String
    let model: String
    let apiKey: String
    let kind: String
    let probeToolCalling: Bool
}

@MainActor
final class HealthRuntime: ChatRuntimeClient {
    let health: ConnectorHealth
    var healthRequests: [HealthCheckRequest] = []

    init(health: ConnectorHealth) {
        self.health = health
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append(HealthCheckRequest(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind))
        return health
    }
}

@MainActor
final class ProbeHealthRuntime: ChatRuntimeClient {
    let result: ConnectorProbeResult
    var probeRequests: [ConnectorProbeRequest] = []

    init(result: ConnectorProbeResult) {
        self.result = result
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func probeConnector(endpoint: String, model: String, apiKey: String, kind: String, probeToolCalling: Bool) async throws -> ConnectorProbeResult {
        probeRequests.append(
            ConnectorProbeRequest(
                endpoint: endpoint,
                model: model,
                apiKey: apiKey,
                kind: kind,
                probeToolCalling: probeToolCalling
            ))
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
    var healthRequests: [HealthCheckRequest] = []
    private var continuations: [CheckedContinuation<ConnectorHealth, Error>] = []

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        SendMessageResponse(assistantText: "完成")
    }

    func healthCheck(endpoint: String, model: String, apiKey: String, kind: String) async throws -> ConnectorHealth {
        healthRequests.append(HealthCheckRequest(endpoint: endpoint, model: model, apiKey: apiKey, kind: kind))
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
