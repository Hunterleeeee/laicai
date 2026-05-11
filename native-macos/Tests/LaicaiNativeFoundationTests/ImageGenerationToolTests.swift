import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
final class ImageGenerationToolTests: LaicaiNativeFoundationTestCase {
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
}
