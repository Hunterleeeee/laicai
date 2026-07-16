import XCTest

@testable import LaicaiNativeDomain
@testable import LaicaiNativeFoundation

@MainActor
final class LiveChatRuntimeConnectorProbeTests: LaicaiNativeFoundationTestCase {
    func testLiveChatRuntimeProbeConnectorMarksSupportedWhenToolProbeSucceeds() async throws {
        var requestBodies: [String] = []
        let session = makeStubbedSession { request in
            let url = request.url ?? URL(string: "https://example.com")!
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"data":[{"id":"target-model"}]}"#.utf8))
            }
            if let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) {
                requestBodies.append(body)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8))
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: true
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertEqual(result.toolCallingCapability, .supported)
        XCTAssertEqual(requestBodies.count, 1)
        XCTAssertTrue(requestBodies[0].contains("\"tools\""))
    }
    func testLiveChatRuntimeProbeConnectorMarksUnsupportedWhenToolProbeRejectsTools() async throws {
        let session = makeStubbedSession { request in
            let url = request.url ?? URL(string: "https://example.com")!
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"data":[{"id":"target-model"}]}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 422,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":{"message":"tools are not supported by this model"}}"#.utf8))
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: true
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertEqual(result.toolCallingCapability, .unsupported)
    }
    func testLiveChatRuntimeProbeConnectorSkipsToolProbeWhenDisabled() async throws {
        var requestMethods: [String] = []
        let session = makeStubbedSession { request in
            requestMethods.append(request.httpMethod ?? "")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"target-model"}]}"#.utf8))
        }
        let runtime = LiveChatRuntime(session: session)

        let result = try await runtime.probeConnector(
            endpoint: "https://api.example.com/v1",
            model: "target-model",
            apiKey: "key",
            kind: "openai-compatible",
            probeToolCalling: false
        )

        XCTAssertEqual(result.health, .ready)
        XCTAssertNil(result.toolCallingCapability)
        // contextWindowProbe also makes a GET request for OpenAI-compatible
        XCTAssertEqual(requestMethods, ["GET", "GET"])
    }
    func testLiveChatRuntimePreservesEmptyAssistantContentForOrchestratorRecovery() async throws {
        let session = makeStubbedSession(
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#.utf8)
        )
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(
            SendMessageRequest(
                sessionID: UUID(),
                message: "ping",
                connector: ConnectorProfile(
                    name: "Test", kind: "openai-compatible", endpoint: "https://api.example.com/v1/chat/completions", modelName: "test",
                    note: "",
                    health: .ready),
                modeLabel: "测试"
            ))

        XCTAssertEqual(response.assistantText, "")
        XCTAssertFalse(response.assistantText.contains("模型没有返回可显示内容"))
    }
    func testLiveChatRuntimeRejectsImageOnlyModelBeforeNetworkRequest() async throws {
        let session = makeStubbedSession { request in
            XCTFail("Image-only models must not be sent to chat completions: \(request.url?.absoluteString ?? "")")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(
            SendMessageRequest(
                sessionID: UUID(),
                message: "画一张图",
                connector: ConnectorProfile(
                    name: "图片模型",
                    kind: "openai-compatible",
                    endpoint: "https://duckcu.tech/v1/chat/completions",
                    modelName: "gpt-image-2",
                    note: "",
                    health: .ready
                ),
                modeLabel: "测试"
            ))

        XCTAssertTrue(response.assistantText.contains("图片生成模型"))
        XCTAssertTrue(response.assistantText.contains("不能作为通用会话模型使用"))
        XCTAssertEqual(response.finishReason, "model_not_supported_for_chat")
        XCTAssertEqual(response.toolActivities.first?.name, "chat.model_unsupported")
        XCTAssertEqual(response.toolActivities.first?.isFailure, true)
    }
    func testImageOnlyModelMessagePointsToImageTool() async throws {
        let message = ConnectorCapabilityProfile.imageOnlyModelChatMessage(modelName: "gpt-image-2")

        XCTAssertTrue(message.contains("不能作为通用会话模型使用"))
        XCTAssertTrue(message.contains("生成图片请直接发送“生成图片”"))
    }
    func testLiveChatRuntimeRejectsImageOnlyStreamingBeforeNetworkRequest() async throws {
        let session = makeStubbedSession { request in
            XCTFail("Image-only models must not be streamed through chat completions: \(request.url?.absoluteString ?? "")")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        let runtime = LiveChatRuntime(session: session)
        var streamedText = ""

        let response = try await runtime.sendMessageStream(
            SendMessageRequest(
                sessionID: UUID(),
                message: "画一张图",
                connector: ConnectorProfile(
                    name: "图片模型",
                    kind: "openai-compatible",
                    endpoint: "https://duckcu.tech/v1/chat/completions",
                    modelName: "dall-e-3",
                    note: "",
                    health: .ready
                ),
                modeLabel: "测试"
            ), onChunk: { streamedText += $0 })

        XCTAssertTrue(response.assistantText.contains("图片生成模型"))
        XCTAssertEqual(response.finishReason, "model_not_supported_for_chat")
        XCTAssertEqual(streamedText, "")
    }
    func testLiveChatRuntimeTreatsLocalV1OllamaProfileAsOpenAICompatible() async throws {
        var capturedURL: URL?
        var capturedBody = ""
        let session = makeStubbedSession { request in
            capturedURL = request.url
            capturedBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8))
        }
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(
            SendMessageRequest(
                sessionID: UUID(),
                message: "ping",
                connector: ConnectorProfile(
                    name: "本地",
                    kind: "ollama",
                    endpoint: "http://127.0.0.1:53759/v1",
                    modelName: "gpt-5.5",
                    note: "",
                    health: .ready
                ),
                modeLabel: "测试"
            ))

        XCTAssertEqual(response.assistantText, "ok")
        XCTAssertEqual(capturedURL?.absoluteString, "http://127.0.0.1:53759/v1/chat/completions")
        XCTAssertTrue(capturedBody.contains(#""max_tokens""#))
        XCTAssertFalse(capturedBody.contains(#""keep_alive""#))
    }

    func testLiveChatRuntimeStreamPreservesReasoningToolDeltasAndFinishReason() async throws {
        let sseBody = [
            #"data: {"choices":[{"delta":{"reasoning_content":"先看"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"结"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"file_read","#
                + #""arguments":"{\"path\":"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ].joined(separator: "\n")
        let session = makeStubbedSession(body: sseBody.data(using: .utf8)!)
        let runtime = LiveChatRuntime(session: session)

        var visible = ""
        var reasoning = ""
        let response = try await runtime.sendMessageStream(
            SendMessageRequest(
                sessionID: UUID(),
                message: "读 README",
                connector: ConnectorProfile(
                    name: "Test",
                    kind: "openai-compatible",
                    endpoint: "https://api.example.com/v1/chat/completions",
                    modelName: "test-model",
                    note: "",
                    health: .ready
                ),
                modeLabel: "测试"
            ),
            onChunk: { visible += $0 },
            onReasoningChunk: { reasoning += $0 }
        )

        XCTAssertEqual(visible, "结")
        XCTAssertEqual(reasoning, "先看")
        XCTAssertEqual(response.reasoningContent, "先看")
        XCTAssertEqual(response.finishReason, "tool_calls")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "call_1")
        XCTAssertEqual(response.toolCalls.first?.function.name, "file_read")
        XCTAssertEqual(response.toolCalls.first?.function.arguments, #"{"path":"README.md"}"#)
    }

    func testChatRuntimeDefaultReasoningStreamFallbackForwardsChunks() async throws {
        @MainActor
        final class TwoArgOnlyRuntime: ChatRuntimeClient {
            func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
                SendMessageResponse(assistantText: "fallback")
            }

            func sendMessageStream(_ request: SendMessageRequest, onChunk: @Sendable @MainActor (String) -> Void) async throws
                -> SendMessageResponse
            {
                onChunk("alpha")
                onChunk("beta")
                return SendMessageResponse(assistantText: "alphabeta")
            }
        }

        let runtime = TwoArgOnlyRuntime()
        var visible = ""
        var reasoning = ""

        let response = try await runtime.sendMessageStream(
            SendMessageRequest(
                sessionID: UUID(),
                message: "ping",
                connector: nil,
                modeLabel: "测试"
            ),
            onChunk: { visible += $0 },
            onReasoningChunk: { reasoning += $0 }
        )

        XCTAssertEqual(response.assistantText, "alphabeta")
        XCTAssertEqual(visible, "alphabeta")
        XCTAssertEqual(reasoning, "alphabeta")
    }
}
