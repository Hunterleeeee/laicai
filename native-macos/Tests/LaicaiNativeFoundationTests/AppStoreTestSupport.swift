import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
class LaicaiNativeFoundationTestCase: XCTestCase {}

@MainActor
extension LaicaiNativeFoundationTestCase {
    func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeStubbedSession(body: Data, statusCode: Int = 200) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        return URLSession(configuration: configuration)
    }

    func makeStubbedSession(
        responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = responder
        return URLSession(configuration: configuration)
    }

    func waitUntilIdle(_ store: AppStore) async throws {
        for _ in 0..<50 {
            if !store.state.isGenerating { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Store did not finish generating in time")
    }

    func waitForConnectorHealth(_ store: AppStore, id: UUID, health: ConnectorHealth) async throws {
        for _ in 0..<50 {
            if store.state.connectors.first(where: { $0.id == id })?.health == health { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Connector did not reach \(health)")
    }

    func waitForHealthRequestCount(_ runtime: PausedHealthRuntime, count: Int) async throws {
        for _ in 0..<50 {
            if runtime.healthRequests.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Health request count did not reach \(count)")
    }

    func testState(
        sessions: [ChatSession] = [],
        tasks: [AgentTask] = [],
        selectedTaskID: UUID? = nil,
        workspacePath: String = "/tmp",
        connectors: [ConnectorProfile] = [],
        activeConnectorID: UUID? = nil
    ) -> AppState {
        AppState(
            workspaceName: "Test",
            modeLabel: "Build",
            sessions: sessions,
            selectedSessionID: nil,
            workbenchTab: .tools,
            connectors: connectors,
            activeConnectorID: activeConnectorID,
            toolActivities: [],
            workflowRuns: [],
            draftMessage: "",
            isGenerating: false,
            settings: .init(workspacePath: workspacePath, defaultConnectorName: "None", compactComposer: false, showDebugPanels: false),
            tasks: tasks,
            selectedTaskID: selectedTaskID
        )
    }

    func makeMinimalXLSX(at url: URL) throws {
        let temp = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: temp) }
        let relFiles: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
              <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
            </Relationships>
            """),
            ("xl/sharedStrings.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
              <si><t>会员系统</t></si>
              <si><t>替换需求</t></si>
            </sst>
            """),
            ("xl/worksheets/sheet1.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
              </sheetData>
            </worksheet>
            """)
        ]
        for (path, content) in relFiles {
            let file = temp.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = temp
        process.arguments = ["-q", "-r", url.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

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

final class MockURLProtocol: URLProtocol {
    static var responseProvider: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = provider(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct FixedSessionRepository: SessionRepository {
    var sessions: [ChatSession]

    func loadSessions() throws -> [ChatSession]? { sessions }
    func saveSessions(_ sessions: [ChatSession]) throws {}
}

struct FixedTaskRepository: TaskRepository {
    var tasks: [AgentTask]

    func loadTasks() throws -> [AgentTask]? { tasks }
    func saveTasks(_ tasks: [AgentTask]) throws {}
    func appendTask(_ task: AgentTask) throws {}
    func updateTask(id: UUID, _ mutate: (inout AgentTask) -> Void) throws {}
    func deleteTask(id: UUID) throws {}
}

struct FixedThreadRepository: ThreadRepository {
    var threads: [Thread]

    func loadThreads() throws -> [Thread]? { threads }
    func saveThreads(_ threads: [Thread]) throws {}
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
