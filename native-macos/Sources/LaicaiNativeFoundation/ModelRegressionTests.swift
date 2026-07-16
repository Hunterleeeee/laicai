import Foundation
import LaicaiNativeDomain

// MARK: - Model Regression Test Framework

/// Defines a model compatibility test case
public struct ModelTestCase: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var description: String
    public var endpoint: String
    public var model: String
    public var apiKey: String
    public var kind: String
    public var checks: [Check]

    public enum Check: String, Codable, Sendable {
        case healthCheck  // /models or /api/tags reachable
        case basicChat  // non-streaming text response
        case streamingChat  // streaming SSE response
        case toolCalling  // function calling round-trip
        case reasoning  // reasoning_content field present
        case longContext  // > 4k input tokens accepted
        case chineseOutput  // response contains Chinese
    }

    public init(
        name: String,
        description: String = "",
        endpoint: String,
        model: String,
        apiKey: String = "",
        kind: String = "openai-compatible",
        checks: [Check] = [.healthCheck, .basicChat, .streamingChat]
    ) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.kind = kind
        self.checks = checks
    }
}

/// Result of a single check
public struct CheckResult: Codable, Sendable {
    public var check: ModelTestCase.Check
    public var passed: Bool
    public var latencyMs: Int
    public var detail: String
    public var error: String?
}

/// Result of a full model test
public struct ModelTestResult: Codable, Sendable, Identifiable {
    public let id: UUID
    public var testCase: ModelTestCase
    public var results: [CheckResult]
    public var startedAt: Date
    public var completedAt: Date
    public var overallPassed: Bool

    public var passedCount: Int { results.filter(\.passed).count }
    public var failedCount: Int { results.filter { !$0.passed }.count }
}

// MARK: - Runner

@MainActor
public final class ModelRegressionRunner: ObservableObject {
    public static let shared = ModelRegressionRunner()

    @Published public private(set) var results: [ModelTestResult] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var currentTest: String = ""

    private let runtime = LiveChatRuntime()
    private init() {}

    /// Built-in test matrix
    public static let builtinTests: [ModelTestCase] = [
        ModelTestCase(
            name: "Ollama 本地",
            description: "本地 Ollama 服务",
            endpoint: "http://127.0.0.1:11434",
            model: "qwen3:8b",
            kind: "ollama",
            checks: [.healthCheck, .basicChat, .streamingChat, .chineseOutput]
        ),
        ModelTestCase(
            name: "Ollama OpenAI 兼容",
            description: "Ollama 的 /v1 兼容接口",
            endpoint: "http://127.0.0.1:11434/v1",
            model: "qwen3:8b",
            kind: "openai-compatible",
            checks: [.healthCheck, .basicChat, .streamingChat, .toolCalling]
        ),
        ModelTestCase(
            name: "DeepSeek API",
            description: "DeepSeek 官方 API",
            endpoint: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            kind: "openai-compatible",
            checks: [.healthCheck, .basicChat, .streamingChat, .toolCalling, .reasoning, .chineseOutput]
        ),
        ModelTestCase(
            name: "Qwen API (DashScope)",
            description: "阿里云 DashScope 兼容模式",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus",
            kind: "openai-compatible",
            checks: [.healthCheck, .basicChat, .streamingChat, .toolCalling, .chineseOutput]
        ),
        ModelTestCase(
            name: "OpenAI API",
            description: "OpenAI 官方 API",
            endpoint: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            kind: "openai-compatible",
            checks: [.healthCheck, .basicChat, .streamingChat, .toolCalling, .chineseOutput]
        ),
    ]

    public func runAll(tests: [ModelTestCase]? = nil) async {
        let testCases = tests ?? Self.builtinTests
        isRunning = true
        results = []

        for testCase in testCases {
            currentTest = testCase.name
            let result = await runSingle(testCase)
            results.append(result)
        }

        currentTest = ""
        isRunning = false
    }

    public func runSingle(_ testCase: ModelTestCase) async -> ModelTestResult {
        let startedAt = Date()
        var checkResults: [CheckResult] = []

        for check in testCase.checks {
            let result = await runCheck(check, testCase: testCase)
            checkResults.append(result)
        }

        return ModelTestResult(
            id: UUID(),
            testCase: testCase,
            results: checkResults,
            startedAt: startedAt,
            completedAt: Date(),
            overallPassed: checkResults.allSatisfy(\.passed)
        )
    }

    private func runCheck(_ check: ModelTestCase.Check, testCase: ModelTestCase) async -> CheckResult {
        let start = Date()
        do {
            let detail: String
            switch check {
            case .healthCheck:
                detail = try await checkHealth(testCase)
            case .basicChat:
                detail = try await checkBasicChat(testCase)
            case .streamingChat:
                detail = try await checkStreamingChat(testCase)
            case .toolCalling:
                detail = try await checkToolCalling(testCase)
            case .reasoning:
                detail = try await checkReasoning(testCase)
            case .longContext:
                detail = try await checkLongContext(testCase)
            case .chineseOutput:
                detail = try await checkChineseOutput(testCase)
            }
            let latencyMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            return CheckResult(check: check, passed: true, latencyMs: latencyMilliseconds, detail: detail)
        } catch {
            let latencyMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            return CheckResult(check: check, passed: false, latencyMs: latencyMilliseconds, detail: "", error: error.localizedDescription)
        }
    }

    private func checkHealth(_ testCase: ModelTestCase) async throws -> String {
        let result = try await runtime.probeConnector(
            endpoint: testCase.endpoint, model: testCase.model, apiKey: testCase.apiKey, kind: testCase.kind, probeToolCalling: false
        )
        guard result.health == .ready else {
            throw RegressionError.healthCheckFailed(result.health)
        }
        return "健康状态: ready"
    }

    private func checkBasicChat(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let request = SendMessageRequest(sessionID: UUID(), message: "请直接回复 ok。", connector: connector, modeLabel: "回归测试")
        let response = try await runtime.sendMessage(request)
        guard !response.assistantText.isEmpty, !response.toolActivities.contains(where: \.isFailure) else {
            throw RegressionError.emptyResponse
        }
        return "回复长度: \(response.assistantText.count) 字符"
    }

    private func checkStreamingChat(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let request = SendMessageRequest(sessionID: UUID(), message: "请用一句话介绍自己。", connector: connector, modeLabel: "回归测试")
        var chunks = 0
        let response = try await runtime.sendMessageStream(request) { _ in chunks += 1 }
        guard !response.assistantText.isEmpty else {
            throw RegressionError.emptyResponse
        }
        return "流式 chunks: \(chunks), 回复: \(response.assistantText.prefix(50))…"
    }

    private func checkToolCalling(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let tools = [
            ToolDefinition(
                function: FunctionDefinition(
                    name: "get_weather",
                    description: "获取天气",
                    parameters: FunctionParameters(
                        properties: ["city": FunctionProperty(type: "string", description: "城市名")], required: ["city"])
                ))
        ]
        let request = SendMessageRequest(sessionID: UUID(), message: "北京今天天气怎么样？", connector: connector, modeLabel: "回归测试", tools: tools)
        let response = try await runtime.sendMessage(request)
        guard response.hasToolCalls else {
            throw RegressionError.noToolCalls
        }
        let names = response.toolCalls.map(\.function.name).joined(separator: ", ")
        return "工具调用: \(names)"
    }

    private func checkReasoning(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let request = SendMessageRequest(sessionID: UUID(), message: "请思考并回答：1+1等于几？", connector: connector, modeLabel: "回归测试")
        let response = try await runtime.sendMessage(request)
        if let reasoning = response.reasoningContent, !reasoning.isEmpty {
            return "推理内容: \(reasoning.count) 字符"
        }
        return "模型未返回推理内容（可能不支持 reasoning_content 字段）"
    }

    private func checkLongContext(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let longText = String(repeating: "这是一段很长的文本。", count: 500)  // ~5000 chars
        let request = SendMessageRequest(sessionID: UUID(), message: "请总结以下内容：\n\(longText)", connector: connector, modeLabel: "回归测试")
        let response = try await runtime.sendMessage(request)
        guard !response.toolActivities.contains(where: \.isFailure) else {
            throw RegressionError.contextTooLong
        }
        return "长上下文接受，回复: \(response.assistantText.prefix(50))…"
    }

    private func checkChineseOutput(_ testCase: ModelTestCase) async throws -> String {
        let connector = ConnectorProfile(
            name: testCase.name,
            kind: testCase.kind,
            endpoint: testCase.endpoint,
            modelName: testCase.model,
            note: testCase.apiKey,
            health: .ready
        )
        let request = SendMessageRequest(sessionID: UUID(), message: "请用中文回复：你好", connector: connector, modeLabel: "回归测试")
        let response = try await runtime.sendMessage(request)
        let hasChinese = response.assistantText.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        guard hasChinese else {
            throw RegressionError.noChinese
        }
        return "包含中文: \(response.assistantText.prefix(30))…"
    }

    enum RegressionError: LocalizedError {
        case healthCheckFailed(ConnectorHealth)
        case emptyResponse
        case noToolCalls
        case contextTooLong
        case noChinese

        var errorDescription: String? {
            switch self {
            case .healthCheckFailed(let health): return "健康检查失败: \(health.rawValue)"
            case .emptyResponse: return "回复为空"
            case .noToolCalls: return "未返回工具调用"
            case .contextTooLong: return "长上下文被拒绝"
            case .noChinese: return "回复不包含中文"
            }
        }
    }

    /// Generate markdown report
    public func generateReport() -> String {
        var lines = ["# 来财模型回归测试报告", "", "时间: \(ISO8601DateFormatter().string(from: Date()))", ""]
        lines.append("| 模型 | 通过 | 失败 | 耗时(ms) | 结果 |")
        lines.append("|------|------|------|----------|------|")
        for regressionResult in results {
            let totalMs = regressionResult.results.map(\.latencyMs).reduce(0, +)
            let status = regressionResult.overallPassed ? "✅" : "❌"
            lines.append(
                "| \(regressionResult.testCase.name) | \(regressionResult.passedCount) | \(regressionResult.failedCount) | \(totalMs) | \(status) |"
            )
        }
        lines.append("")
        for regressionResult in results {
            lines.append("## \(regressionResult.testCase.name)")
            lines.append("")
            for caseResult in regressionResult.results {
                let icon = caseResult.passed ? "✅" : "❌"
                let errorDetail = caseResult.error.map { " — \($0)" } ?? ""
                lines.append("- \(icon) \(caseResult.check.rawValue) (\(caseResult.latencyMs)ms) \(caseResult.detail)\(errorDetail)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
