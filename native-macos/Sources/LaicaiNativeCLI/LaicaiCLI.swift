// 来财 CLI — 独立终端会话
// 直接在终端运行 AgentLoop，不依赖桌面 App
//
// 用法：
//   laicai "review this PR"              — 单次任务
//   laicai -i                            — 交互式 REPL
//   echo "hello" | laicai "翻译"          — pipe 输入
//   laicai --model claude-3.5-sonnet     — 指定模型
//   laicai --endpoint https://api.xxx    — 指定 API
//   laicai --help                        — 帮助

import Foundation
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - ANSI Terminal Colors

enum Term {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let italic = "\u{001B}[3m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let gray = "\u{001B}[90m"
    static let white = "\u{001B}[37m"

    static let bgRed = "\u{001B}[41m"
    static let bgGreen = "\u{001B}[42m"
    static let bgYellow = "\u{001B}[43m"
    static let bgBlue = "\u{001B}[44m"

    static func colored(_ text: String, _ color: String) -> String {
        "\(color)\(text)\(reset)"
    }

    static func header(_ text: String) -> String {
        "\(bold)\(cyan)╭─ \(text)\(reset)"
    }

    static func footer(_ text: String) -> String {
        "\(dim)\(cyan)╰─ \(text)\(reset)"
    }

    static func toolCall(_ name: String, _ detail: String) -> String {
        "\(yellow)⚡ \(bold)\(name)\(reset)\(dim) \(detail)\(reset)"
    }

    static func success(_ text: String) -> String {
        "\(green)✓\(reset) \(text)"
    }

    static func error(_ text: String) -> String {
        "\(red)✗\(reset) \(text)"
    }

    static func thinking(_ text: String) -> String {
        "\(magenta)● \(italic)\(text)\(reset)"
    }

    static func prompt() -> String {
        "\(bold)\(blue)来财 ▸\(reset) "
    }
}

// MARK: - CLI Argument Parser

enum CLICommand: String {
    case run
    case doctor
    case health
    case skills
}

enum CLIParseError: LocalizedError, Equatable {
    case unknownOption(String)
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option): return "未知参数：\(option)"
        case .missingValue(let option): return "参数缺少值：\(option)"
        }
    }
}

enum CLIConfigurationError: LocalizedError, Equatable {
    case missingConnector
    case missingAPIKey(endpoint: String)
    case connectorStore(String)
    case invalidWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .missingConnector:
            return "未找到可用连接器。请先在来财 App 中配置，或通过 --endpoint、--model 和 --api-key 指定。"
        case .missingAPIKey(let endpoint):
            return "连接器 \(endpoint) 需要 API key。请使用 --api-key、LAICAI_API_KEY 或对应服务商的环境变量。"
        case .connectorStore(let message):
            return "读取 App 连接器失败：\(message)"
        case .invalidWorkspace(let path):
            return "工作区不存在或不是目录：\(path)"
        }
    }
}

struct CLIConfig {
    var command: CLICommand = .run
    var message: String?
    var pipeInput: String?
    var workspaceRoot: String?
    var interactive: Bool = false
    var showHelp: Bool = false
    var showVersion: Bool = false
    var endpoint: String?
    var model: String?
    var apiKey: String?
    var autoApprove: Bool = false
    var contextMode: String = "balanced"

    private static let booleanFlags: [String: WritableKeyPath<CLIConfig, Bool>] = [
        "--help": \.showHelp,
        "-h": \.showHelp,
        "--version": \.showVersion,
        "-v": \.showVersion,
        "--interactive": \.interactive,
        "-i": \.interactive,
        "--yes": \.autoApprove,
        "-y": \.autoApprove,
    ]

    private static let valueFlags: [String: WritableKeyPath<CLIConfig, String?>] = [
        "--workspace": \.workspaceRoot,
        "-w": \.workspaceRoot,
        "--endpoint": \.endpoint,
        "-e": \.endpoint,
        "--model": \.model,
        "-m": \.model,
        "--api-key": \.apiKey,
        "-k": \.apiKey,
    ]

    private static let contextFlags: [String: String] = [
        "--deep": "deep",
        "--economy": "economy",
    ]

    static func parse(_ args: [String], readStdin: Bool = true) throws -> CLIConfig {
        var config = CLIConfig()
        var messageParts: [String] = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                messageParts.append(contentsOf: args.dropFirst(index + 1))
                break
            }
            try config.consume(
                arg: arg,
                args: args,
                index: &index,
                messageParts: &messageParts
            )
            index += 1
        }

        if let first = messageParts.first,
            messageParts.count == 1,
            let command = CLICommand(rawValue: first),
            command != .run
        {
            config.command = command
        } else if !messageParts.isEmpty {
            config.message = messageParts.joined(separator: " ")
        }
        config.pipeInput = readStdin ? readPipeInput() : nil
        return config
    }

    private mutating func consume(
        arg: String,
        args: [String],
        index: inout Int,
        messageParts: inout [String]
    ) throws {
        if let flag = Self.booleanFlags[arg] {
            self[keyPath: flag] = true
            return
        }
        if let flag = Self.valueFlags[arg] {
            index += 1
            guard index < args.count, !args[index].hasPrefix("-") else {
                throw CLIParseError.missingValue(arg)
            }
            self[keyPath: flag] = args[index]
            return
        }
        if let contextMode = Self.contextFlags[arg] {
            self.contextMode = contextMode
            return
        }
        if arg.hasPrefix("-") {
            throw CLIParseError.unknownOption(arg)
        }
        messageParts.append(arg)
    }

    private static func readPipeInput() -> String? {
        if isatty(STDIN_FILENO) == 0 {
            var pipeData = Data()
            while true {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
                pipeData.append(buffer, count: count)
            }
            if let input = String(data: pipeData, encoding: .utf8),
                !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return input.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - Help Text

let helpText = """
    \(Term.bold)\(Term.cyan)来财\(Term.reset) — 本地终端 AI会话

    \(Term.bold)用法：\(Term.reset)
      laicai <消息>                     单次执行任务
      laicai -i                         交互式 REPL (类似 Claude Code)
      <命令> | laicai <消息>             pipe 输入
      laicai doctor                     检查本机配置（不调用模型）
      laicai health                     检查当前连接器健康状态
      laicai skills                     列出内置和工作区技能
      laicai --help                     显示帮助

    \(Term.bold)选项：\(Term.reset)
      -w, --workspace <路径>      指定工作区（默认当前目录）
      -i, --interactive           交互模式 REPL
      -m, --model <模型名>        指定模型 (e.g. claude-3.5-sonnet)
      -e, --endpoint <URL>        指定 API endpoint
      -k, --api-key <key>         API key (或设置 LAICAI_API_KEY 环境变量)
      -y, --yes                   自动批准所有文件变更
      --deep                      深度上下文模式
      --economy                   节省 token 模式
      -h, --help                  显示帮助
      -v, --version               显示版本

    \(Term.bold)示例：\(Term.reset)
      laicai "review this PR"
      laicai "fix the build error in src/main.swift"
      git diff | laicai "审查这个变更"
      laicai -i                   \(Term.dim)# 进入交互模式\(Term.reset)
      laicai -y "添加 unit tests" \(Term.dim)# 自动批准变更\(Term.reset)

    \(Term.bold)环境变量：\(Term.reset)
      LAICAI_API_KEY              API key
      LAICAI_ENDPOINT             默认 endpoint
      LAICAI_MODEL                默认模型
    """

// MARK: - CLI Session State

final class CLISession {
    let workspace: String
    let connector: ConnectorProfile
    let runtime: LiveChatRuntime
    let autoApprove: Bool
    let contextMode: ContextMode
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var taskCount = 0

    init(workspace: String, connector: ConnectorProfile, autoApprove: Bool, contextMode: ContextMode) {
        self.workspace = workspace
        self.connector = connector
        self.runtime = LiveChatRuntime()
        self.autoApprove = autoApprove
        self.contextMode = contextMode
    }

    func printBanner() {
        print(Term.header("来财 Terminal 会话"))
        print("\(Term.dim)  工作区: \(workspace)\(Term.reset)")
        print("\(Term.dim)  模型:   \(connector.modelName)\(Term.reset)")
        print("\(Term.dim)  端点:   \(connector.endpoint)\(Term.reset)")
        if autoApprove {
            print("\(Term.yellow)  ⚠ 自动批准模式已开启\(Term.reset)")
        }
        print(Term.footer("输入 /help 查看命令, /quit 退出"))
        print()
    }

    func printSessionStats() {
        print()
        print(Term.footer("会话统计"))
        print("\(Term.dim)  任务数: \(taskCount)  输入 tokens: \(totalInputTokens)  输出 tokens: \(totalOutputTokens)\(Term.reset)")
    }

    // MARK: - Run single task

    @discardableResult
    func runTask(message: String) async -> Bool {
        taskCount += 1
        let startTime = Date()
        let decision = IntentRouter.plan(message)
        let intent = decision.intent

        let loopConfig = AgentLoop.Config(
            maxIterations: intent == .chat ? 3 : 30,
            workspaceRoot: workspace,
            supportsToolCalling: intent != .chat,
            contextMode: contextMode
        )
        let loop = await AgentLoop(config: loopConfig, runtime: runtime)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace,
            userInput: message,
            fileLimit: intent == .chat ? 0 : 200
        )

        print(Term.header("\(intent == .chat ? "问答" : "任务") #\(taskCount)"))
        print("\(Term.dim)  路由: \(decision.routeLabel) · \(decision.reason)\(Term.reset)")
        print()

        var lastStepKind: TaskStepKind?
        var pendingReviews: [(UUID, TaskStep)] = []
        let taskID = UUID()

        do {
            let completedTask = try await loop.run(
                taskID: taskID,
                message: message,
                intent: intent,
                connector: connector,
                context: context,
                onStep: { @MainActor step in
                    self.renderStep(step, lastKind: lastStepKind)
                    lastStepKind = step.kind

                    // Collect review requests for approval
                    if step.kind == .reviewRequest {
                        pendingReviews.append((step.id, step))
                    }
                },
                onStreamDelta: { @MainActor delta in
                    print(delta, terminator: "")
                    fflush(stdout)
                }
            )

            // Handle pending reviews
            var approvedFiles: [String] = []
            var reviewsSucceeded = true
            for (_, step) in pendingReviews {
                let succeeded = await handleReview(step: step)
                reviewsSucceeded = reviewsSucceeded && succeeded
                if succeeded, let file = step.diffFilePath {
                    approvedFiles.append(file)
                }
            }

            // Stats
            if let metrics = completedTask.steps.last(where: { $0.metrics != nil })?.metrics {
                totalInputTokens += metrics.inputTokens ?? 0
                totalOutputTokens += metrics.outputTokens ?? 0
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let succeeded = completedTask.status == .completed && reviewsSucceeded
            let status =
                succeeded
                ? Term.success("完成")
                : Term.error("失败")
            print()
            print(Term.footer("\(status) · \(completedTask.steps.count) 步 · \(String(format: "%.1f", elapsed))秒"))

            // Summary of changed files
            let changedFiles =
                approvedFiles
                + completedTask.steps
                .filter {
                    ($0.kind == .reviewRequest && $0.approved == true)
                        || ($0.kind == .toolResult && $0.toolName == "file.write" && !$0.isFailure)
                }
                .compactMap { $0.diffFilePath ?? $0.toolParams?["path"] }
            if !changedFiles.isEmpty {
                print("\(Term.dim)  变更文件:\(Term.reset)")
                for file in Set(changedFiles).sorted() {
                    print("    \(Term.green)M\(Term.reset) \(file)")
                }
            }
            print()
            return succeeded

        } catch {
            print()
            print(Term.error("任务执行失败: \(error.localizedDescription)"))
            print()
            return false
        }
    }

    // MARK: - Render step to terminal

    private func renderStep(_ step: TaskStep, lastKind: TaskStepKind?) {
        switch step.kind {
        case .userInput:
            break  // Already shown as prompt input

        case .aiThinking:
            renderThinking(step)

        case .toolCall:
            let name = step.toolName ?? "tool"
            let detail = compactToolParams(step.toolParams)
            print(Term.toolCall(name, detail))

        case .toolResult:
            renderToolResult(step)

        case .textOutput:
            renderTextOutput(step, lastKind: lastKind)

        case .error:
            print(Term.error(step.text))

        case .reviewRequest:
            renderReviewRequest(step)

        case .reviewResult:
            let approved = step.approved == true
            print(approved ? Term.success("已批准") : Term.error("已拒绝"))
        }
    }

    private func renderThinking(_ step: TaskStep) {
        let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            print(Term.thinking(String(trimmed.prefix(120))))
        }
    }

    private func renderToolResult(_ step: TaskStep) {
        if step.isFailure {
            print(Term.error("\(step.toolName ?? "tool"): \(String(step.text.prefix(200)))"))
            return
        }
        guard step.toolName == "shell.exec" || step.toolName == "verify.build" else { return }
        let lines = step.text.components(separatedBy: "\n")
        let display = lines.prefix(8).joined(separator: "\n")
        guard !display.isEmpty else { return }
        print("\(Term.dim)\(display)\(Term.reset)")
        if lines.count > 8 {
            print("\(Term.dim)  ... +\(lines.count - 8) lines\(Term.reset)")
        }
    }

    private func renderTextOutput(_ step: TaskStep, lastKind: TaskStepKind?) {
        let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && lastKind != .textOutput {
            print()
        }
        if !trimmed.isEmpty {
            print(trimmed)
        }
    }

    private func renderReviewRequest(_ step: TaskStep) {
        print()
        print("\(Term.bgYellow)\(Term.bold) 📋 需要审查 \(Term.reset)")
        if let path = step.diffFilePath {
            print("  \(Term.bold)文件:\(Term.reset) \(path)")
        }
        if let oldContent = step.diffOldContent, let newContent = step.diffNewContent {
            let oldLines = oldContent.components(separatedBy: "\n")
            let newLines = newContent.components(separatedBy: "\n")
            print("  \(Term.red)--- 当前内容（\(oldLines.count) 行）\(Term.reset)")
            for line in oldLines.prefix(12) {
                renderReviewLine("-\(line)")
            }
            if oldLines.count > 12 {
                print("  \(Term.dim)... +\(oldLines.count - 12) lines\(Term.reset)")
            }
            print("  \(Term.green)+++ 待写入内容（\(newLines.count) 行）\(Term.reset)")
            for line in newLines.prefix(12) {
                renderReviewLine("+\(line)")
            }
            if newLines.count > 12 {
                print("  \(Term.dim)... +\(newLines.count - 12) lines\(Term.reset)")
            }
        } else {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines.prefix(20) {
                renderReviewLine(line)
            }
            if lines.count > 20 {
                print("  \(Term.dim)... +\(lines.count - 20) lines\(Term.reset)")
            }
        }
    }

    private func renderReviewLine(_ line: String) {
        if line.hasPrefix("+") {
            print("  \(Term.green)\(line)\(Term.reset)")
        } else if line.hasPrefix("-") {
            print("  \(Term.red)\(line)\(Term.reset)")
        } else {
            print("  \(Term.dim)\(line)\(Term.reset)")
        }
    }

    private func compactToolParams(_ params: [String: String]?) -> String {
        guard let params else { return "" }
        if let path = params["path"] { return path }
        if let cmd = params["command"] { return String(cmd.prefix(60)) }
        if let query = params["query"] { return "\"\(String(query.prefix(40)))\"" }
        if let sub = params["subcommand"] { return sub }
        return params.values.first.map { String($0.prefix(40)) } ?? ""
    }

    // MARK: - Handle review approval

    @MainActor
    func handleReview(step: TaskStep) async -> Bool {
        if autoApprove {
            print(Term.success("自动批准"))
            return applyReview(step)
        }

        print()
        print(
            "\(Term.bold)批准此变更？\(Term.reset) [\(Term.green)y\(Term.reset)/\(Term.red)n\(Term.reset)/\(Term.dim)s(跳过)\(Term.reset)] ",
            terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            print(Term.error("跳过"))
            return false
        }

        switch input {
        case "y", "yes", "":
            return applyReview(step)
        case "n", "no":
            print(Term.error("已拒绝"))
            return false
        default:
            print("\(Term.dim)已跳过\(Term.reset)")
            return false
        }
    }

    @MainActor
    private func applyReview(_ step: TaskStep) -> Bool {
        do {
            let path = try CLIReviewApplier.apply(step: step, workspace: workspace)
            print(Term.success("已写入 \(path)"))
            return true
        } catch {
            print(Term.error("写入失败: \(error.localizedDescription)"))
            return false
        }
    }

    // MARK: - Interactive REPL

    func startREPL() async {
        printBanner()

        while true {
            print(Term.prompt(), terminator: "")
            fflush(stdout)

            guard let input = readLine() else {
                break  // EOF
            }

            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Slash commands
            switch trimmed.lowercased() {
            case "/quit", "/exit", "/q":
                printSessionStats()
                print(Term.success("再见 👋"))
                return

            case "/help", "/h":
                printREPLHelp()
                continue

            case "/clear":
                print("\u{001B}[2J\u{001B}[H")
                printBanner()
                continue

            case "/stats":
                printSessionStats()
                continue

            case "/compact":
                print(Term.thinking("上下文已压缩"))
                continue

            default:
                break
            }

            _ = await runTask(message: trimmed)
        }
    }

    private func printREPLHelp() {
        print()
        print("\(Term.bold)REPL 命令：\(Term.reset)")
        print("  \(Term.cyan)/help\(Term.reset)      显示此帮助")
        print("  \(Term.cyan)/quit\(Term.reset)      退出")
        print("  \(Term.cyan)/clear\(Term.reset)     清屏")
        print("  \(Term.cyan)/stats\(Term.reset)     显示 token 统计")
        print("  \(Term.cyan)/compact\(Term.reset)   压缩上下文")
        print()
        print("  直接输入自然语言即开始任务。")
        print()
    }
}

enum CLIReviewError: LocalizedError, Equatable {
    case missingChange
    case outsideWorkspace(String)
    case securityPolicy(String)
    case changedSinceReview(String)

    var errorDescription: String? {
        switch self {
        case .missingChange: return "审查请求缺少文件路径或待写入内容"
        case .outsideWorkspace(let path): return "文件不在工作区内：\(path)"
        case .securityPolicy(let reason): return reason
        case .changedSinceReview(let path): return "文件在审查期间已被修改，已取消写入：\(path)"
        }
    }
}

@MainActor
enum CLIReviewApplier {
    static func resolvedPath(step: TaskStep, workspace: String) throws -> String {
        guard let displayPath = step.diffFilePath, !displayPath.isEmpty else {
            throw CLIReviewError.missingChange
        }
        let candidate =
            step.toolParams?["fullPath"]
            ?? (displayPath.hasPrefix("/")
                ? displayPath
                : (workspace as NSString).appendingPathComponent(displayPath))
        let fullPath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.path
        guard fullPath == root || fullPath.hasPrefix(root + "/") else {
            throw CLIReviewError.outsideWorkspace(fullPath)
        }
        return fullPath
    }

    @discardableResult
    static func apply(step: TaskStep, workspace: String) throws -> String {
        guard let content = step.diffNewContent else {
            throw CLIReviewError.missingChange
        }
        let fullPath = try resolvedPath(step: step, workspace: workspace)
        if let securityError = SecurityManager.shared.checkWrite(
            path: fullPath,
            workspaceRoot: workspace
        ) {
            throw CLIReviewError.securityPolicy(securityError)
        }
        if let oldContent = step.diffOldContent,
            FileManager.default.fileExists(atPath: fullPath)
        {
            let currentContent = try String(contentsOfFile: fullPath, encoding: .utf8)
            guard currentContent == oldContent else {
                throw CLIReviewError.changedSinceReview(fullPath)
            }
        }
        try WriteFileTool().performWrite(
            fullPath: fullPath,
            content: content,
            createDirectories: step.toolParams?["createDirectories"] != "false"
        )
        return fullPath
    }
}

// MARK: - Connector Resolution

func resolveConnector(
    config: CLIConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    repository: (() throws -> ConnectorCatalog?)? = nil
) throws -> ConnectorProfile {
    let hasExplicitConfiguration =
        config.endpoint != nil
        || config.model != nil
        || config.apiKey != nil
        || environment["LAICAI_ENDPOINT"] != nil
        || environment["LAICAI_MODEL"] != nil
        || environment["LAICAI_API_KEY"] != nil
        || environment["OPENAI_API_KEY"] != nil
        || environment["ANTHROPIC_API_KEY"] != nil

    if !hasExplicitConfiguration {
        do {
            let catalog = try (repository ?? { try SQLiteRepository().loadConnectorCatalog() })()
            if let catalog {
                if let activeID = catalog.activeConnectorID,
                    let active = catalog.connectors.first(where: { $0.id == activeID })
                {
                    return active
                }
                if let first = catalog.connectors.first {
                    return first
                }
            }
        } catch {
            throw CLIConfigurationError.connectorStore(error.localizedDescription)
        }
        throw CLIConfigurationError.missingConnector
    }

    let endpoint =
        config.endpoint
        ?? environment["LAICAI_ENDPOINT"]
        ?? "https://api.openai.com/v1"
    let model =
        config.model
        ?? environment["LAICAI_MODEL"]
        ?? (endpoint.localizedCaseInsensitiveContains("anthropic") ? "claude-3-5-sonnet-latest" : "gpt-4.1-mini")

    let kind: String
    if endpoint.contains(":11434") || endpoint.contains("ollama") {
        kind = "ollama"
    } else if endpoint.contains("anthropic") {
        kind = "anthropic"
    } else {
        kind = "openai-compatible"
    }

    let providerKey =
        kind == "anthropic"
        ? environment["ANTHROPIC_API_KEY"]
        : environment["OPENAI_API_KEY"]
    let apiKey =
        config.apiKey
        ?? environment["LAICAI_API_KEY"]
        ?? providerKey
    let isLocal =
        endpoint.contains("localhost")
        || endpoint.contains("127.0.0.1")
        || endpoint.contains("[::1]")
        || endpoint.contains(":11434")
    if apiKey == nil && !isLocal {
        throw CLIConfigurationError.missingAPIKey(endpoint: endpoint)
    }

    return ConnectorProfile(
        name: model,
        kind: kind,
        endpoint: endpoint,
        modelName: model,
        note: apiKey ?? "",
        health: .ready
    )
}

// MARK: - Main Entry

struct LaicaiCLI {
    static func run(
        arguments: [String] = CommandLine.arguments,
        readStdin: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdinIsTTY: Bool = isatty(STDIN_FILENO) != 0,
        taskExecutor: ((String, ConnectorProfile, String, ContextMode, Bool) async -> Bool)? = nil
    ) async -> Int32 {
        let config: CLIConfig
        do {
            config = try CLIConfig.parse(arguments, readStdin: readStdin)
        } catch {
            fputs("\(Term.error(error.localizedDescription))\n", stderr)
            fputs("使用 laicai --help 查看可用参数。\n", stderr)
            return 64
        }

        return await execute(
            config: config,
            environment: environment,
            stdinIsTTY: stdinIsTTY,
            taskExecutor: taskExecutor
        )
    }

    private static func execute(
        config: CLIConfig,
        environment: [String: String],
        stdinIsTTY: Bool,
        taskExecutor: ((String, ConnectorProfile, String, ContextMode, Bool) async -> Bool)?
    ) async -> Int32 {
        if config.showHelp {
            print(helpText)
            return 0
        }

        if config.showVersion {
            print("来财 CLI \(versionString())")
            return 0
        }

        let workspace = URL(
            fileURLWithPath: config.workspaceRoot ?? FileManager.default.currentDirectoryPath
        ).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
            fputs("\(Term.error(CLIConfigurationError.invalidWorkspace(workspace).localizedDescription))\n", stderr)
            return 78
        }

        switch config.command {
        case .doctor:
            return runDoctor(config: config, workspace: workspace, environment: environment)
        case .skills:
            return listSkills(workspace: workspace)
        case .run, .health:
            break
        }

        let connector: ConnectorProfile
        do {
            connector = try resolveConnector(config: config, environment: environment)
        } catch {
            fputs("\(Term.error(error.localizedDescription))\n", stderr)
            return 78
        }

        if config.command == .health {
            return await checkHealth(connector: connector)
        }

        return await runTask(
            config: config,
            connector: connector,
            workspace: workspace,
            stdinIsTTY: stdinIsTTY,
            taskExecutor: taskExecutor
        )
    }

    private static func runTask(
        config: CLIConfig,
        connector: ConnectorProfile,
        workspace: String,
        stdinIsTTY: Bool,
        taskExecutor: ((String, ConnectorProfile, String, ContextMode, Bool) async -> Bool)?
    ) async -> Int32 {
        let contextMode: ContextMode
        switch config.contextMode {
        case "deep": contextMode = .deep
        case "economy": contextMode = .economy
        default: contextMode = .balanced
        }

        // Build message from args + pipe
        var message = config.message ?? ""
        if let pipe = config.pipeInput {
            message = pipe + (message.isEmpty ? "" : "\n\(message)")
        }

        if config.interactive || (message.isEmpty && stdinIsTTY) {
            // Interactive REPL mode
            let session = CLISession(
                workspace: workspace,
                connector: connector,
                autoApprove: config.autoApprove,
                contextMode: contextMode
            )
            await session.startREPL()
            return 0
        }

        guard !message.isEmpty else {
            fputs("用法：laicai <消息>\n", stderr)
            fputs("输入 laicai --help 查看完整帮助\n", stderr)
            return 64
        }

        if let taskExecutor {
            let succeeded = await taskExecutor(message, connector, workspace, contextMode, config.autoApprove)
            return succeeded ? 0 : 1
        }

        let session = CLISession(
            workspace: workspace,
            connector: connector,
            autoApprove: config.autoApprove,
            contextMode: contextMode
        )
        let succeeded = await session.runTask(message: message)
        session.printSessionStats()
        return succeeded ? 0 : 1
    }

    private static func runDoctor(
        config: CLIConfig,
        workspace: String,
        environment: [String: String]
    ) -> Int32 {
        print(Term.header("来财 CLI 诊断"))
        var healthy = true
        print(Term.success("工作区存在：\(workspace)"))
        if FileManager.default.isReadableFile(atPath: workspace) {
            print(Term.success("工作区可读"))
        } else {
            print(Term.error("工作区不可读"))
            healthy = false
        }
        if FileManager.default.isWritableFile(atPath: workspace) {
            print(Term.success("工作区可写"))
        } else {
            print(Term.error("工作区不可写"))
            healthy = false
        }

        for tool in ["git", "rg", "swift"] {
            if executablePath(named: tool, environment: environment) != nil {
                print(Term.success("工具可用：\(tool)"))
            } else {
                print(Term.error("工具缺失：\(tool)"))
                healthy = false
            }
        }

        do {
            let connector = try resolveConnector(config: config, environment: environment)
            print(Term.success("连接器已配置：\(connector.name) / \(connector.modelName)"))
        } catch {
            print(Term.error(error.localizedDescription))
            healthy = false
        }
        print(Term.footer(healthy ? "诊断通过" : "发现需处理的问题"))
        return healthy ? 0 : 1
    }

    private static func checkHealth(connector: ConnectorProfile) async -> Int32 {
        do {
            let health = try await LiveChatRuntime().healthCheck(
                endpoint: connector.endpoint,
                model: connector.modelName,
                apiKey: connector.note,
                kind: connector.kind
            )
            let output = "\(connector.name)：\(health.title)"
            print(health == .ready ? Term.success(output) : Term.error(output))
            return health == .ready ? 0 : 1
        } catch {
            fputs("\(Term.error("健康检查失败：\(error.localizedDescription)"))\n", stderr)
            return 1
        }
    }

    private static func listSkills(workspace: String) -> Int32 {
        var skills = SkillRegistry.loadBuiltinSkills()
        for skill in SkillRegistry.loadLocalSkills(workspaceRoot: workspace)
        where !skills.contains(where: { $0.name == skill.name }) {
            skills.append(skill)
        }
        print(Term.header("可用技能（\(skills.count)）"))
        for skill in skills.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let source = skill.isBuiltin ? "内置" : "本地"
            print("\(Term.cyan)•\(Term.reset) \(skill.name) \(Term.dim)[\(source)]\(Term.reset)")
            if !skill.description.isEmpty {
                print("  \(Term.dim)\(skill.description)\(Term.reset)")
            }
        }
        return 0
    }

    static func executablePath(named name: String, environment: [String: String]) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func versionString(
        bundle: Bundle = .main,
        executableURL: URL? = Bundle.main.executableURL
    ) -> String {
        if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        {
            return "v\(version)"
        }
        if let executableURL {
            let plistURL = executableURL.deletingLastPathComponent()
                .appendingPathComponent("Laicai.app/Contents/Info.plist")
            if let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any],
                let version = dictionary["CFBundleShortVersionString"] as? String,
                !version.isEmpty
            {
                return "v\(version)"
            }
        }
        return "development"
    }
}
