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
    public static let maxRetries = 1
    public static let baseDelayMs: UInt64 = 200  // Base delay for exponential backoff

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
        "file_not_found", "security_denied", "unknown_tool"
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

        let timeoutSeconds: TimeInterval = tool.name.contains("shell") ? 60 : 30

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
                // Don't retry on timeout
                return (lastResult!, ValidationResult(isValid: false, error: lastError, retryCount: attempt))
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
        let fm = FileManager.default
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
            ("Makefile", "make test"),
        ]
        for indicator in projectIndicators {
            let fullPath = (workspaceRoot as NSString).appendingPathComponent(indicator.file)
            if fm.fileExists(atPath: fullPath) {
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
        // File not found: try similar path → code.search → ask user
        if error.contains("file_not_found") || error.contains("文件不存在") {
            if let path = params["path"] {
                let altPath = findSimilarFile(hint: path)
                if !altPath.isEmpty {
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
            }
            return RecoveryPlan(
                action: .fallbackTool("code.search", "{\"query\":\"\(params["path"] ?? "")\"}"),
                description: "文件未找到，改用代码搜索定位",
                fallbackChain: [.askUser("文件不存在：\(params["path"] ?? "未知")，请确认路径")],
                suppressOriginalFailure: false
            )
        }

        // Shell blocked by tool policy: workspace.index → code.search
        if toolName == "shell.exec", error.contains("工具策略拦截") {
            return RecoveryPlan(
                action: .fallbackTool("workspace.index", "{\"maxFiles\":300,\"maxDepth\":5}"),
                description: "shell 遍历被工具策略拦截，改用受控项目索引",
                fallbackChain: [.fallbackTool("code.search", "{\"query\":\"文件列表\"}")],
                suppressOriginalFailure: true
            )
        }

        // Security denied: ask user
        if error.contains("security_denied") || error.contains("安全") {
            return RecoveryPlan(
                action: .askUser("操作被安全策略拦截：\(error)"),
                description: "请求用户授权"
            )
        }

        // Forbidden command: ask user
        if error.contains("forbidden_command") || error.contains("白名单") {
            return RecoveryPlan(
                action: .askUser("命令不在白名单中，是否允许执行？"),
                description: "请求用户授权执行"
            )
        }

        // Exit code failure: retry → retry with modified params
        if error.contains("exit_") {
            return RecoveryPlan(
                action: .retry,
                description: "命令执行失败，重试（第 \(attemptCount + 1) 次）",
                fallbackChain: attemptCount >= 2 ? [.abort("重试次数已达上限")] : []
            )
        }

        // Auth failure: ask user
        if error.contains("鉴权失败") || error.contains("401") {
            return RecoveryPlan(
                action: .askUser("鉴权失败，请检查 API 密钥"),
                description: "请求用户检查密钥配置"
            )
        }

        // Timeout: increase timeout → retry with simpler query
        if error.contains("timeout") || error.contains("超时") {
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

        // Code search failure: workspace.index
        if toolName == "code.search" {
            return RecoveryPlan(
                action: .fallbackTool("workspace.index", "{\"maxFiles\":300,\"maxDepth\":5}"),
                description: "搜索工具失败，回退到受控项目索引",
                suppressOriginalFailure: true
            )
        }

        // File read failure: code.search → workspace.index
        if toolName == "file.read" {
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

        // Generic: retry with limit
        if attemptCount >= 3 {
            return RecoveryPlan(
                action: .abort("重试次数已达上限（\(attemptCount) 次）"),
                description: "放弃重试，报告失败"
            )
        }

        return RecoveryPlan(
            action: .retry,
            description: "重试（第 \(attemptCount + 1) 次）"
        )
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
