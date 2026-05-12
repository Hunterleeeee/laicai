import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class ImageGenerationToolTests: LaicaiNativeFoundationTestCase {
    func testSemanticImageRequestAutoUsesImageConnectorEvenWhenChatConnectorIsActive() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chatConnector = makeConnector(name: "GPT", endpoint: "https://duckcu.tech/v1", modelName: "gpt-5.5", note: "chat-key")
        let imageConnector = makeConnector(name: "图片", endpoint: "https://duckcu.tech", modelName: "gpt-image-2", note: "image-key")
        let store = makeTestStore(
            workspacePath: workspace.path,
            defaultConnectorName: "GPT",
            connectors: [chatConnector, imageConnector],
            activeConnectorID: chatConnector.id
        )

        store.updateDraft("做一张雪碧介绍图")
        store.sendDraft()

        XCTAssertTrue(store.state.isGenerating)
        XCTAssertEqual(store.state.selectedTask?.connectorID, imageConnector.id)
        XCTAssertEqual(store.state.modeLabel, "图片生成")
        XCTAssertTrue(store.state.selectedTask?.steps.contains { $0.text.contains("正在调用 gpt-image-2 生成图片") } == true)
        store.stopGenerating()
    }

    func testImageOnlyConnectorUsesImagesAPIEndpointAndWritesImage() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var capturedURL: URL?
        var capturedBody = ""
        var capturedAuth = ""
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let responseBody = #"{"data":[{"b64_json":"\#(pngData.base64EncodedString())"}]}"#.data(using: .utf8)!
        let session = makeStubbedSession { request in
            capturedURL = request.url
            capturedBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            capturedAuth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        let tool = ComfyUITool(session: session)

        let result = try await tool.execute(
            argumentsJSON: #"{"prompt":"生成一张赛博朋克海报","width":1024,"height":1024}"#,
            context: TaskContext(
                workspaceRoot: workspace.path,
                imageGenerationEndpoint: "https://duckcu.tech/v1/chat/completions",
                imageGenerationModelName: "gpt-image-2",
                imageGenerationAPIKey: "test-key"
            )
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(capturedURL?.absoluteString, "https://duckcu.tech/v1/images/generations")
        XCTAssertEqual(capturedAuth, "Bearer test-key")
        XCTAssertTrue(capturedBody.contains(#""model":"gpt-image-2""#))
        XCTAssertTrue(capturedBody.contains(#""response_format":"b64_json""#))
        let imagePath = try XCTUnwrap(result.data?["imagePath"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), pngData)
    }

    func testImageRequestRetriesOnceWhenConnectionIsLost() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var requestCount = 0
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let responseBody = #"{"data":[{"b64_json":"\#(pngData.base64EncodedString())"}]}"#.data(using: .utf8)!
        let session = makeStubbedSession { request in
            requestCount += 1
            if requestCount == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        let tool = ComfyUITool(session: session)

        let result = try await tool.execute(
            argumentsJSON: #"{"prompt":"生成一张雪碧介绍图","width":1024,"height":1024}"#,
            context: TaskContext(
                workspaceRoot: workspace.path,
                imageGenerationEndpoint: "https://duckcu.tech",
                imageGenerationModelName: "gpt-image-2",
                imageGenerationAPIKey: "test-key"
            )
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(requestCount, 2)
    }

    func testImageConnectionLostErrorExplainsGatewayDisconnect() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let session = makeStubbedSession { _ in
            throw URLError(.networkConnectionLost)
        }
        let tool = ComfyUITool(session: session)

        let result = try await tool.execute(
            argumentsJSON: #"{"prompt":"生成一张雪碧介绍图","width":1024,"height":1024}"#,
            context: TaskContext(
                workspaceRoot: workspace.path,
                imageGenerationEndpoint: "https://duckcu.tech",
                imageGenerationModelName: "gpt-image-2",
                imageGenerationAPIKey: "test-key"
            )
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("图片服务连接中途断开"))
        XCTAssertTrue(result.output.contains("上游网关"))
    }
}
