import Foundation
import LaicaiNativeDomain

// MARK: - Timeout

private struct TimeoutError: Error, LocalizedError {
    let errorDescription: String? = "操作超时"
}

private func withTimeout<T>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Validation Engine

public struct ValidationEngine {
    public static let maxRetries = 3
    public static let baseDelayMs: UInt64 = 250  // Base delay for exponential backoff

    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let error: String?
        public let retryCount: Int

        public init(isValid: Bool, error: String? = nil, retryCount: Int = 0) {
            self.isValid = isValid
            self.error = error
            self.retryCount = retryCount
        }
    }

    public static func validate(tool: any LaicaiTool, result: ToolResult) -> Bool {
        tool.validate(result: result)
    }

    /// Execute tool with validation and exponential backoff retry
    public static func executeWithValidation(
        tool: any LaicaiTool,
        params: [String: String],
        context: TaskContext,
        maxRetries: Int = maxRetries
    ) async -> (result: ToolResult, validation: ValidationResult) {
        var lastResult: ToolResult?
        var lastError: String?

        for attempt in 0...maxRetries {
            do {
                let result = try await tool.execute(params: params, context: context)
                lastResult = result

                if validate(tool: tool, result: result) {
                    return (result, ValidationResult(isValid: true, retryCount: attempt))
                }

                lastError = result.error ?? "工具结果验证失败"
                if attempt < maxRetries {
                    await exponentialBackoff(attempt: attempt)
                }
            } catch {
                lastError = error.localizedDescription
                if attempt < maxRetries {
                    await exponentialBackoff(attempt: attempt)
                }
            }
        }

        let fallback = lastResult ?? ToolResult(output: "", success: false, error: lastError)
        return (fallback, ValidationResult(isValid: false, error: lastError, retryCount: maxRetries))
    }

    /// Errors that are deterministic and won't resolve by retrying with the same arguments
    private static let deterministicErrors: Set<String> = [
        "invalid_params", "invalid_edits", "invalid_batch_edits", "empty_edits", "empty_batch_edits",
        "patch_not_found", "patch_ambiguous", "all_edits_failed",
        "file_not_found", "unsupported_binary_file", "unsupported_file_type", "security_denied", "unknown_tool"
    ]

    /// Execute tool with JSON arguments (function calling style)
    public static func executeWithValidationJSON(
        tool: any LaicaiTool,
        argumentsJSON: String,
        context: TaskContext,
        maxRetries: Int = maxRetries
    ) async -> (result: ToolResult, validation: ValidationResult) {
        var lastResult: ToolResult?
        var lastError: String?

        let timeoutSeconds = timeoutSeconds(for: tool)

        for attempt in 0...maxRetries {
            do {
                let result = try await withTimeout(seconds: timeoutSeconds) {
                    try await tool.execute(argumentsJSON: argumentsJSON, context: context)
                }
                lastResult = result

                if validate(tool: tool, result: result) {
                    return (result, ValidationResult(isValid: true, retryCount: attempt))
                }

                lastError = result.error ?? "工具结果验证失败"
                // Don't retry deterministic errors — same args will produce same failure
                if let errorCode = result.error, deterministicErrors.contains(errorCode) {
                    return (result, ValidationResult(isValid: false, error: lastError, retryCount: attempt))
                }
                if attempt < maxRetries {
                    await exponentialBackoff(attempt: attempt)
                }
            } catch _ as TimeoutError {
                lastError = "工具执行超时（\(Int(timeoutSeconds))秒）"
                lastResult = ToolResult(output: "", success: false, error: lastError)
                if attempt < maxRetries, shouldRetryTimeout(for: tool) {
                    await exponentialBackoff(attempt: attempt)
                } else {
                    return (lastResult!, ValidationResult(isValid: false, error: lastError, retryCount: attempt))
                }
            } catch {
                lastError = error.localizedDescription
                if attempt < maxRetries {
                    await exponentialBackoff(attempt: attempt)
                }
            }
        }

        let fallback = lastResult ?? ToolResult(output: "", success: false, error: lastError)
        return (fallback, ValidationResult(isValid: false, error: lastError, retryCount: maxRetries))
    }

    /// Exponential backoff with jitter: baseDelay * 2^attempt + random jitter
    private static func exponentialBackoff(attempt: Int) async {
        let exponentialDelay = baseDelayMs * (1 << attempt)  // 2^attempt
        let jitter = UInt64.random(in: 0...100)  // 0-100ms random jitter
        let totalDelayMs = exponentialDelay + jitter
        try? await Task.sleep(for: .milliseconds(totalDelayMs))
    }

    public static func timeoutSeconds(for toolName: String) -> TimeInterval {
        switch ToolNameCodec.canonicalName(toolName) {
        case "image.generate":
            return NetworkDefaults.imageRequest + 20
        case "shell.exec":
            return 300
        case "verify.build":
            return 150
        case "browser", "browser.real", "computer":
            return 60
        case "code.search", "workspace.index", "web.search":
            return 30
        case "web.fetch":
            return NetworkDefaults.webFetch + 5
        default:
            return 120
        }
    }

    private static func timeoutSeconds(for tool: any LaicaiTool) -> TimeInterval {
        timeoutSeconds(for: tool.name)
    }

    private static func shouldRetryTimeout(for tool: any LaicaiTool) -> Bool {
        switch ToolNameCodec.canonicalName(tool.name) {
        case "shell.exec", "verify.build", "image.generate":
            return false
        default:
            return true
        }
    }
}

// MARK: - Error Recovery Engine

public enum RecoveryAction: Sendable {
    case retry
    case retryWithModifiedParams([String: String])
    case retryWithModifiedJSON(String)
    case fallbackTool(String, String)
    case askUser(String)
    case abort(String)
}

public struct RecoveryPlan: Sendable {
    public let action: RecoveryAction
    public let description: String
    /// Ordered fallback chain: if primary action fails, try these in sequence.
    public let fallbackChain: [RecoveryAction]
    /// Whether to mark the original failure step as collapsed after successful recovery.
    public let suppressOriginalFailure: Bool

    public init(action: RecoveryAction, description: String, fallbackChain: [RecoveryAction] = [], suppressOriginalFailure: Bool = false) {
        self.action = action
        self.description = description
        self.fallbackChain = fallbackChain
        self.suppressOriginalFailure = suppressOriginalFailure
    }
}

// MARK: - Verification Command Suggester

extension ValidationEngine {
    /// Suggest a verification command based on project type detected from workspace files.
    public static func suggestVerificationCommand(workspaceRoot: String) -> String? {
        let fileManager = FileManager.default
        let projectIndicators: [(file: String, command: String)] = [
            ("Package.swift", "swift build"),
            ("Podfile", "pod lib lint"),
            ("pyproject.toml", "python -m pytest"),
            ("requirements.txt", "python -m pytest"),
            ("package.json", "npm test"),
            ("Cargo.toml", "cargo test"),
            ("go.mod", "go test ./..."),
            ("pom.xml", "mvn test"),
            ("build.gradle", "gradle test"),
            ("Gemfile", "bundle exec rspec"),
            ("Makefile", "make test")
        ]
        for indicator in projectIndicators {
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(indicator.file)
            if fileManager.fileExists(atPath: fullPath) {
                return indicator.command
            }
        }
        return nil
    }
}

public struct ErrorRecoveryEngine {
    public static func planRecovery(
        error: String,
        toolName: String,
        params: [String: String],
        attemptCount: Int
    ) -> RecoveryPlan {
        let recoveryBuilders: [() -> RecoveryPlan?] = [
            { fileNotFoundRecovery(error: error, params: params) },
            { policyRecovery(error: error, toolName: toolName) },
            { securityRecovery(error: error) },
            { forbiddenCommandRecovery(error: error) },
            { exitRecovery(error: error, attemptCount: attemptCount) },
            { authRecovery(error: error) },
            { timeoutRecovery(error: error, toolName: toolName, params: params) },
            { codeSearchRecovery(toolName: toolName) },
            { binaryFileReadRecovery(error: error, toolName: toolName, params: params) },
            { fileExtractUnsupportedRecovery(error: error, toolName: toolName, params: params) },
            { fileReadRecovery(toolName: toolName, params: params, attemptCount: attemptCount) }
        ]
        for builder in recoveryBuilders {
            if let plan = builder() { return plan }
        }
        return genericRecovery(attemptCount: attemptCount)
    }

    private static func fileNotFoundRecovery(error: String, params: [String: String]) -> RecoveryPlan? {
        guard error.contains("file_not_found") || error.contains("文件不存在") else { return nil }
        if let plan = similarFileRecovery(params: params) {
            return plan
        }
        return RecoveryPlan(
            action: .fallbackTool("code.search", "{\"query\":\"\(params["path"] ?? "")\"}"),
            description: "文件未找到，改用代码搜索定位",
            fallbackChain: [.askUser("文件不存在：\(params["path"] ?? "未知")，请确认路径")],
            suppressOriginalFailure: false
        )
    }

    private static func similarFileRecovery(params: [String: String]) -> RecoveryPlan? {
        guard let path = params["path"] else { return nil }
        let altPath = findSimilarFile(hint: path)
        guard !altPath.isEmpty else { return nil }
        return RecoveryPlan(
            action: .retryWithModifiedParams(["path": altPath]),
            description: "文件未找到，尝试相似路径：\(altPath)",
            fallbackChain: [
                .fallbackTool("code.search", "{\"query\":\"\((path as NSString).lastPathComponent)\"}"),
                .askUser("文件不存在：\(path)，请确认路径")
            ],
            suppressOriginalFailure: true
        )
    }

    private static func policyRecovery(error: String, toolName: String) -> RecoveryPlan? {
        guard toolName == "shell.exec", error.contains("工具策略拦截") else { return nil }
        return RecoveryPlan(
            action: .fallbackTool("workspace.index", "{\"maxFiles\":300,\"maxDepth\":5}"),
            description: "shell 遍历被工具策略拦截，改用受控项目索引",
            fallbackChain: [.fallbackTool("code.search", "{\"query\":\"文件列表\"}")],
            suppressOriginalFailure: true
        )
    }

    private static func securityRecovery(error: String) -> RecoveryPlan? {
        guard error.contains("security_denied") || error.contains("安全") else { return nil }
        return RecoveryPlan(
            action: .askUser("操作被安全策略拦截：\(error)"),
            description: "请求用户授权"
        )
    }

    private static func forbiddenCommandRecovery(error: String) -> RecoveryPlan? {
        guard error.contains("forbidden_command") || error.contains("白名单") else { return nil }
        return RecoveryPlan(
            action: .askUser("命令不在白名单中，是否允许执行？"),
            description: "请求用户授权执行"
        )
    }

    private static func exitRecovery(error: String, attemptCount: Int) -> RecoveryPlan? {
        guard error.contains("exit_") else { return nil }
        return RecoveryPlan(
            action: .retry,
            description: "命令执行失败，重试（第 \(attemptCount + 1) 次）",
            fallbackChain: attemptCount >= 2 ? [.abort("重试次数已达上限")] : []
        )
    }

    private static func authRecovery(error: String) -> RecoveryPlan? {
        guard error.contains("鉴权失败") || error.contains("401") else { return nil }
        return RecoveryPlan(
            action: .askUser("鉴权失败，请检查 API 密钥"),
            description: "请求用户检查密钥配置"
        )
    }

    private static func timeoutRecovery(
        error: String,
        toolName: String,
        params: [String: String]
    ) -> RecoveryPlan? {
        guard error.contains("timeout") || error.contains("超时") else { return nil }
        var newParams = params
        let currentTimeout = Int(newParams["timeout"] ?? "30") ?? 30
        newParams["timeout"] = "\(min(currentTimeout * 2, 120))"
        return RecoveryPlan(
            action: .retryWithModifiedParams(newParams),
            description: "超时，增加超时时间到 \(newParams["timeout"] ?? "60")s 重试",
            fallbackChain: toolName == "code.search"
                ? [.fallbackTool("workspace.index", "{\"maxFiles\":200,\"maxDepth\":4}")]
                : [],
            suppressOriginalFailure: true
        )
    }

    private static func codeSearchRecovery(toolName: String) -> RecoveryPlan? {
        guard toolName == "code.search" else { return nil }
        return RecoveryPlan(
            action: .fallbackTool("workspace.index", "{\"maxFiles\":300,\"maxDepth\":5}"),
            description: "搜索工具失败，回退到受控项目索引",
            suppressOriginalFailure: true
        )
    }

    private static func binaryFileReadRecovery(
        error: String,
        toolName: String,
        params: [String: String]
    ) -> RecoveryPlan? {
        guard toolName == "file.read",
              error.contains("unsupported_binary_file") || error.contains("file_extract") else {
            return nil
        }
        let path = params["path"] ?? ""
        let payload: [String: Any] = ["path": path, "limit": 60_000]
        let json = jsonString(payload, fallback: "{\"path\":\"\(path)\"}", options: [.withoutEscapingSlashes])
        return RecoveryPlan(
            action: .fallbackTool("file.extract", json),
            description: "file.read 检测到表格/文档，改用 file.extract 提取文本",
            suppressOriginalFailure: true
        )
    }

    private static func fileExtractUnsupportedRecovery(
        error: String,
        toolName: String,
        params: [String: String]
    ) -> RecoveryPlan? {
        guard toolName == "file.extract",
              error.contains("unsupported_file_type") || error.contains("暂不支持提取") else {
            return nil
        }
        let path = params["path"] ?? ""
        if ["pptx", "docx", "xlsx", "xlsm"].contains((path as NSString).pathExtension.lowercased()) {
            return officeDocumentRecovery(path: path)
        }
        return RecoveryPlan(
            action: .askUser("当前内置提取器不支持此文件类型：\(path)。请改用 shell_exec/系统工具转换，或说明缺少转换/OCR组件，不能重复调用 file.extract。"),
            description: "file.extract 不支持该类型，停止同参数重试"
        )
    }

    private static func officeDocumentRecovery(path: String) -> RecoveryPlan {
        let payload: [String: Any] = [
            "action": "prepare",
            "sourcePath": path,
            "chunkSize": 80,
            "onlyChinese": true
        ]
        let json = jsonString(payload, fallback: "{\"sourcePath\":\"\(path)\"}")
        return RecoveryPlan(
            action: .fallbackTool("document.transform", json),
            description: "file.extract 不足以完成 Office 文档交付，改用 document.transform",
            suppressOriginalFailure: true
        )
    }

    private static func fileReadRecovery(
        toolName: String,
        params: [String: String],
        attemptCount: Int
    ) -> RecoveryPlan? {
        guard toolName == "file.read" else { return nil }
        return RecoveryPlan(
            action: .retry,
            description: "文件读取失败，重试（第 \(attemptCount + 1) 次）",
            fallbackChain: [
                .fallbackTool("code.search", "{\"query\":\"\(params["path"] ?? "")\"}"),
                .fallbackTool("workspace.index", "{\"maxFiles\":200,\"maxDepth\":4}")
            ],
            suppressOriginalFailure: attemptCount >= 1
        )
    }

    private static func genericRecovery(attemptCount: Int) -> RecoveryPlan {
        if attemptCount >= 3 {
            return RecoveryPlan(
                action: .abort("重试次数已达上限（\(attemptCount) 次）"),
                description: "放弃重试，报告失败"
            )
        }
        return RecoveryPlan(action: .retry, description: "重试（第 \(attemptCount + 1) 次）")
    }

    private static func jsonString(
        _ payload: [String: Any],
        fallback: String,
        options: JSONSerialization.WritingOptions = []
    ) -> String {
        (try? JSONSerialization.data(withJSONObject: payload, options: options))
            .flatMap { String(data: $0, encoding: .utf8) } ?? fallback
    }

    /// Plan recovery for JSON-based function calls
    public static func planRecoveryJSON(
        error: String,
        toolName: String,
        argumentsJSON: String,
        attemptCount: Int
    ) -> RecoveryPlan {
        // Parse params from JSON for error analysis
        var params: [String: String] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            params = json.mapValues { "\($0)" }
        }

        // Use the same logic as params-based recovery
        let plan = planRecovery(error: error, toolName: toolName, params: params, attemptCount: attemptCount)

        // Convert to JSON-based action if needed
        switch plan.action {
        case .retryWithModifiedParams(let newParams):
            if let jsonData = try? JSONSerialization.data(withJSONObject: newParams),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                return RecoveryPlan(action: .retryWithModifiedJSON(jsonStr), description: plan.description)
            }
        case .fallbackTool:
            return plan
        default:
            break
        }

        return plan
    }

    private static func findSimilarFile(hint: String) -> String {
        let filename = (hint as NSString).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["find", ".", "-name", filename, "-maxdepth", "4"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let first = output.components(separatedBy: "\n").first { !$0.isEmpty } ?? ""
            return first.hasPrefix("./") ? String(first.dropFirst(2)) : first
        } catch {
            return ""
        }
    }
}

extension RecoveryAction {
    public var isRetryable: Bool {
        switch self {
        case .retry, .retryWithModifiedParams, .retryWithModifiedJSON, .fallbackTool:
            return true
        case .askUser, .abort:
            return false
        }
    }
}
