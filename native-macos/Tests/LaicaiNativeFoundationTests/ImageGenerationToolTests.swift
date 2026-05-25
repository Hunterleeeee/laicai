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
        XCTAssertEqual(store.state.selectedThread?.connectorID, imageConnector.id)
        XCTAssertEqual(store.state.modeLabel, "会话 图片")
        XCTAssertTrue(store.state.selectedThread?.steps.contains { $0.text.contains("正在调用 gpt-image-2 生成图片") } == true)
        store.stopGenerating()
    }

    func testImageRequestRejectsDisposableSmokeWorkspace() {
        let chatConnector = makeConnector(name: "GPT", endpoint: "https://duckcu.tech/v1", modelName: "gpt-5.5")
        let imageConnector = makeConnector(name: "图片", endpoint: "https://duckcu.tech", modelName: "gpt-image-2")
        let store = makeTestStore(
            workspacePath: "/tmp/laicai-pptx-smoke",
            defaultConnectorName: "GPT",
            connectors: [chatConnector, imageConnector],
            activeConnectorID: chatConnector.id
        )

        store.updateDraft("生成一张雪碧介绍图")
        store.sendDraft()

        XCTAssertFalse(store.state.isGenerating)
        XCTAssertNil(store.state.selectedThreadID)
        XCTAssertEqual(store.state.notice?.style, .error)
        XCTAssertTrue(store.state.notice?.message.contains("来财测试目录") == true)
    }

    func testImageRequestReusesSelectedPlainSessionAndDoesNotUseActiveProject() async throws {
        let previousActiveProjectID = ProjectManager.shared.activeProjectID
        ProjectManager.shared.activeProjectID = UUID()
        defer { ProjectManager.shared.activeProjectID = previousActiveProjectID }
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let chatConnector = makeConnector(name: "GPT", endpoint: "https://duckcu.tech/v1", modelName: "gpt-5.5")
        let imageConnector = makeConnector(name: "图片", endpoint: "https://duckcu.tech", modelName: "gpt-image-2")
        let store = makeTestStore(
            workspacePath: workspace.path,
            connectors: [chatConnector, imageConnector],
            activeConnectorID: chatConnector.id
        )

        store.newThread()
        let threadID = try XCTUnwrap(store.state.selectedThreadID)
        store.updateDraft("生成一张雪碧介绍图")
        store.sendDraft()

        XCTAssertEqual(store.state.selectedThreadID, threadID)
        XCTAssertNotNil(store.state.selectedThread)
        XCTAssertEqual(store.state.selectedThread?.connectorID, imageConnector.id)
        XCTAssertNil(store.state.selectedThread?.projectID)
        store.stopGenerating()
    }

    func testImageRequestStartedBesideRunningProjectThreadKeepsProjectScope() async throws {
        let projectID = UUID()
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runningProjectThread = Thread(
            title: "项目里正在执行",
            status: .running,
            steps: [TaskStep(kind: .userInput, text: "继续优化项目")],
            projectID: projectID
        )
        let chatConnector = makeConnector(name: "GPT", endpoint: "https://duckcu.tech/v1", modelName: "gpt-5.5")
        let imageConnector = makeConnector(name: "图片", endpoint: "https://duckcu.tech", modelName: "gpt-image-2")
        let store = AppStore(
            state: testState(
                threads: [runningProjectThread],
                selectedThreadID: runningProjectThread.id,
                workspacePath: workspace.path,
                connectors: [chatConnector, imageConnector],
                activeConnectorID: chatConnector.id
            ),
            environment: makeTestEnvironment()
        )
        let decision = PlannerDecision(
            intent: .task,
            confidence: 0.9,
            reason: "测试图片生成路由",
            routeLabel: "会话 图片",
            expectedCapabilities: []
        )
        store.sendImageGenerationDraft(message: "生成一张项目封面图", decision: decision, connector: imageConnector)

        XCTAssertNotEqual(store.state.selectedThreadID, runningProjectThread.id)
        XCTAssertNotNil(store.state.selectedThread)
        XCTAssertEqual(store.state.selectedThread?.connectorID, imageConnector.id)
        XCTAssertEqual(store.state.selectedThread?.projectID, projectID)
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
        let tool = ComfyUITool(session: session, prefersCurlTransport: false)

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
        let tool = ComfyUITool(session: session, prefersCurlTransport: false)

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
        let tool = ComfyUITool(session: session, prefersCurlTransport: false)

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

    func testImageToolAcceptsRecoveryStringNumbersAndTimeoutNoise() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let responseBody = #"{"data":[{"b64_json":"\#(pngData.base64EncodedString())"}]}"#.data(using: .utf8)!
        let session = makeStubbedSession { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        let tool = ComfyUITool(session: session, prefersCurlTransport: false)

        let result = try await tool.execute(
            argumentsJSON: #"{"prompt":"生成一张雪碧介绍图","width":"1024","height":"1024","steps":"24","seed":"-1","timeout":"60"}"#,
            context: TaskContext(
                workspaceRoot: workspace.path,
                imageGenerationEndpoint: "https://duckcu.tech",
                imageGenerationModelName: "gpt-image-2",
                imageGenerationAPIKey: "test-key"
            )
        )

        XCTAssertTrue(result.success)
        let imagePath = try XCTUnwrap(result.data?["imagePath"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testSuccessfulImageResultSatisfiesGenerationTaskDespiteLaterImageRetryFailure() {
        let task = AgentTask(
            title: "访问前端并重新生成页面图",
            steps: [
                TaskStep(kind: .userInput, text: "访问这个项目的前端，然后重新生成一个前端页面图"),
                TaskStep(kind: .toolResult, text: "图片已生成：/tmp/generated.png", toolName: "image.generate", toolParams: ["imagePath": "/tmp/generated.png"]),
                TaskStep(kind: .toolResult, text: "失败：工具执行超时（30秒）", toolName: "image.generate", isFailure: true)
            ]
        )

        XCTAssertTrue(AgentLoop.hasSatisfiedImageGenerationRequest(task))
        XCTAssertTrue(AgentLoop.meetsCompletionCriteria(task: task, intent: .task, didComplete: true, hadFailure: true, wasTruncated: false))
        let check = AgentLoop.completionCheckStep(for: task, didComplete: true, hadFailure: true)
        XCTAssertFalse(check.isFailure)
        XCTAssertTrue(check.text.contains("图片已成功生成"))
    }

    func testImageResultStepParamsCarryGeneratedImagePathForPreview() {
        let params = AgentLoop.resultStepParams(
            toolName: "image.generate",
            arguments: ["prompt": "生成一张图"],
            result: ToolResult(
                output: "图片已生成：/tmp/generated.png",
                data: ["imagePath": "/tmp/generated.png", "model": "gpt-image-2"]
            )
        )

        XCTAssertEqual(params["prompt"], "生成一张图")
        XCTAssertEqual(params["imagePath"], "/tmp/generated.png")
        XCTAssertEqual(params["model"], "gpt-image-2")
    }
}
