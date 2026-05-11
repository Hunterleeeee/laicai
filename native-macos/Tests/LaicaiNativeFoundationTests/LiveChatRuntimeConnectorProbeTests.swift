import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

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
                return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
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
            return (response, #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.data(using: .utf8)!)
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
                return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 422,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"error":{"message":"tools are not supported by this model"}}"#.data(using: .utf8)!)
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
            return (response, #"{"data":[{"id":"target-model"}]}"#.data(using: .utf8)!)
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
        XCTAssertEqual(requestMethods, ["GET"])
    }
    func testLiveChatRuntimePreservesEmptyAssistantContentForOrchestratorRecovery() async throws {
        let session = makeStubbedSession(
            body: #"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        )
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(SendMessageRequest(
            sessionID: UUID(),
            message: "ping",
            connector: ConnectorProfile(name: "Test", kind: "openai-compatible", endpoint: "https://api.example.com/v1/chat/completions", modelName: "test", note: "", health: .ready),
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

        let response = try await runtime.sendMessage(SendMessageRequest(
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
        XCTAssertTrue(response.assistantText.contains("不能作为聊天/任务模型使用"))
        XCTAssertEqual(response.finishReason, "model_not_supported_for_chat")
        XCTAssertEqual(response.toolActivities.first?.name, "chat.model_unsupported")
        XCTAssertEqual(response.toolActivities.first?.isFailure, true)
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

        let response = try await runtime.sendMessageStream(SendMessageRequest(
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
            return (response, #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.data(using: .utf8)!)
        }
        let runtime = LiveChatRuntime(session: session)

        let response = try await runtime.sendMessage(SendMessageRequest(
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
}
